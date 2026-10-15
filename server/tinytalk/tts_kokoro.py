"""TTS backend: Kokoro-82M.

KPipeline is a blocking generator, so each synthesis runs on a worker thread.
Keeping the event loop free is what lets an interrupt be handled while the
agent is mid-sentence.
"""

from __future__ import annotations

import asyncio
import logging
import shutil
import threading
from pathlib import Path
from typing import AsyncIterator, Callable

import torch

from . import config
from .audio import float32_to_pcm16
from .engines import EngineError

logger = logging.getLogger(__name__)


def _configure_espeak_from_homebrew() -> None:
    """Kokoro's G2P (misaki) unconditionally points itself at the espeak-ng
    copy bundled by the `espeakng-loader` PyPI package. Confirmed on real
    hardware (2026-08-28) that espeakng-loader 0.2.4's macOS dylib has a
    data path hard-coded from its GitHub Actions build machine
    (/Users/runner/work/espeakng-loader/...), which doesn't exist on any
    real Mac -- every phonemize call fails with "Error processing file
    '.../phontab': No such file or directory" the moment it's used. Same
    root cause as bootphon/phonemizer#159 and rhasspy/piper#73; their fix
    is the same one applied here: point phonemizer's espeak wrapper at a
    real `brew install espeak-ng` instead of the broken bundled copy.
    Must run after `import kokoro` (which imports misaki, which sets the
    broken default at ITS import time) and before constructing any
    KPipeline, which is the only thing that actually triggers phonemizing.
    """
    espeak_ng = shutil.which("espeak-ng")
    if espeak_ng is None:
        raise EngineError(
            "espeak-ng not found on PATH -- Kokoro's phonemizer needs a "
            "real system install (the one bundled by the espeakng-loader "
            "pip package is broken on macOS): run `brew install espeak-ng`"
        )
    # Homebrew's stable `opt/<formula>` alias, not the versioned Cellar
    # path -- survives `brew upgrade espeak-ng` without this breaking again.
    prefix = Path(espeak_ng).parent.parent
    library = prefix / "opt" / "espeak-ng" / "lib" / "libespeak-ng.dylib"
    data = prefix / "opt" / "espeak-ng" / "share" / "espeak-ng-data"
    if not library.exists() or not data.exists():
        raise EngineError(
            f"found espeak-ng on PATH but not the expected Homebrew layout "
            f"at {prefix}/opt/espeak-ng -- try `brew reinstall espeak-ng`"
        )
    from phonemizer.backend.espeak.wrapper import EspeakWrapper

    EspeakWrapper.set_library(str(library))
    EspeakWrapper.set_data_path(str(data))


def _default_pipeline_factory(lang_code: str, model=None):
    """`model`, if given, is an already-loaded KModel to share -- see
    KokoroTts._pipeline_for."""
    try:
        from kokoro import KPipeline
    except ImportError as exc:  # pragma: no cover - depends on the environment
        raise EngineError(
            "Kokoro is not installed — run `pip install kokoro soundfile` "
            "and `brew install espeak-ng`"
        ) from exc
    _configure_espeak_from_homebrew()
    if model is not None:
        pipeline = KPipeline(lang_code=lang_code, device=config.KOKORO_DEVICE, model=model)
    else:
        pipeline = KPipeline(lang_code=lang_code, device=config.KOKORO_DEVICE)
    # What the loaded model reports, not just what was asked for -- the one
    # line that confirms on real hardware which backend is actually live.
    logger.info("tts: Kokoro pipeline loaded on device=%s", pipeline.model.device)
    return pipeline


class KokoroTts:
    """TtsEngine backed by Kokoro-82M."""

    def __init__(
        self,
        lang_code: str = config.KOKORO_LANG_CODE,
        voice: str = config.KOKORO_VOICE,
        *,
        pipeline_factory: Callable[..., object] | None = None,
    ) -> None:
        self._lang_code = lang_code
        # Only ever read or written on the event loop thread (set_voice,
        # and synthesize() before it hands off to a worker) -- see
        # set_voice for why that matters.
        self._voice = voice
        self._pipeline_factory = pipeline_factory or _default_pipeline_factory
        # One pipeline per G2P language code ('a' American, 'b' British),
        # all sharing one set of model weights -- see _pipeline_for.
        self._pipelines: dict[str, object] = {}
        # A real OS thread lock, not asyncio.Lock -- see synthesize()'s
        # comment on why an asyncio-level lock can't do this job.
        self._synthesis_lock = threading.Lock()
        # Logged at construction (server startup) because the weights
        # themselves only load on the first synthesis; the "loaded on
        # device=" line from _default_pipeline_factory follows once they do.
        logger.info(
            "tts: Kokoro will run on device=%s (TINYTALK_TTS_DEVICE=cpu|mps to change)",
            config.KOKORO_DEVICE,
        )

    def set_voice(self, voice: str) -> None:
        """Switch voice for every synthesize() call started from now on
        (issue #78). Only assigns an attribute: must be called on the
        event loop thread, the same thread synthesize() reads it from
        before handing the value to its worker as an argument -- so a
        worker thread already running (possibly an orphaned one, see
        _run_pipeline) never sees the voice change underneath it. The new
        voice's pack itself loads inside _run_pipeline, under the lock."""
        self._voice = voice

    def _pipeline_for(self, voice: str):
        # Built lazily and cached: loading weights takes seconds, and doing it
        # at import time would slow every test run and CLI invocation.
        # Only called from _run_pipeline, inside _synthesis_lock.
        #
        # Kokoro's G2P (pronunciation) is per-pipeline: a British voice
        # (bf_/bm_) read through the American pipeline gets American
        # pronunciations (Kokoro just logs "Language mismatch"). So a
        # voice gets the pipeline for its own prefix, and any pipeline
        # after the first reuses the first one's model weights instead of
        # loading a second copy -- only the (small) G2P side is new.
        lang_code = voice[0] if voice[:1] in ("a", "b") else self._lang_code
        pipeline = self._pipelines.get(lang_code)
        if pipeline is None:
            if self._pipelines:
                shared = next(iter(self._pipelines.values())).model
                pipeline = self._pipeline_factory(lang_code, model=shared)
            else:
                pipeline = self._pipeline_factory(lang_code)
            self._pipelines[lang_code] = pipeline
        return pipeline

    def _run_pipeline(self, text: str, voice: str) -> list:
        # Holds a real thread lock for the pipeline call itself (not just
        # the asyncio await around it). Confirmed on real hardware
        # (2026-08-28): a barge-in/reconnect can cancel a turn whose TTS
        # call is already mid-flight on this pipeline's worker thread --
        # asyncio.to_thread cannot actually stop a thread that's already
        # running (documented Python behaviour: Future.cancel() is a
        # no-op once the callable has started), so that thread runs to
        # completion regardless, orphaned. A new turn's own synthesize()
        # call can then start a SECOND concurrent call into this same
        # shared KPipeline instance (built once, reused for the server's
        # whole lifetime) while the orphaned one is still running.
        # PyTorch's MPS backend is not safe for that: two threads issuing
        # Metal compute commands to the same pipeline crashed the whole
        # process outright with "A command encoder is already encoding to
        # this command buffer" (SIGABRT, no Python traceback -- every open
        # connection dropped at once). An asyncio.Lock can't prevent this:
        # it gets released the instant the awaiting coroutine is
        # cancelled, exactly while the orphaned thread is still running.
        # A plain threading.Lock, acquired here inside the worker thread
        # itself, keeps a second call waiting (in ITS OWN worker thread,
        # not the event loop) until the first is actually, physically
        # done -- turning the crash into a bounded wait instead.
        with self._synthesis_lock:
            try:
                # Pipeline lookup/construction and the voice pack's own
                # first-use load (inside Kokoro's pipeline call) both
                # happen here, under the lock -- never alongside another
                # thread's in-flight synthesis (issue #78).
                pipeline = self._pipeline_for(voice)
                return list(pipeline(text, voice=voice))
            finally:
                # Inside the lock, on this same worker thread, on purpose
                # (issue #34): this used to run from synthesize()'s own
                # `finally` on a SECOND worker thread. When a turn was
                # cancelled mid-synthesis, that release fired at once,
                # while the orphaned call above was still running -- and
                # torch.mps.empty_cache() also destroys PyTorch's
                # process-wide MPSGraph cache, i.e. the very graphs the
                # running LSTM/embedding kernel was using. Reproduced on
                # real hardware within ~5s of repeated barge-ins: SIGSEGV
                # in _lstm_mps (the original report) or an ObjC "cannot
                # form weak reference to MPSGraph" abort, never a Python
                # traceback. Here the release can only happen once this
                # call is done and before any other call starts.
                self._release_mps_cache()

    def _release_mps_cache(self) -> None:
        if config.KOKORO_DEVICE != "mps":
            return
        # PyTorch's MPS caching allocator holds onto memory for reuse
        # WITHIN this process rather than returning it to the OS after
        # each call. This instance is built once and shared for the
        # server's whole lifetime (see app.py), so without this, its
        # cached footprint only grows across a session -- confirmed via
        # real on-device testing (2026-08-25) as the cause of each LATER
        # turn's Ollama call getting progressively worse than the first
        # (Groq, which doesn't compete for local memory at all, showed no
        # such pattern with the same session). Called from _run_pipeline's
        # `finally` so a failed synthesis attempt still releases whatever
        # it allocated before failing.
        torch.mps.empty_cache()

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        if not text.strip():
            return
        # Read here, on the event loop, and passed by value -- see set_voice.
        voice = self._voice
        try:
            segments = await asyncio.to_thread(self._run_pipeline, text, voice)
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kokoro synthesis failed: {exc}") from exc

        for _graphemes, _phonemes, samples in segments:
            yield float32_to_pcm16(samples)
