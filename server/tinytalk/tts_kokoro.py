"""TTS backend: Kokoro-82M.

KPipeline is a blocking generator, so each synthesis runs on a worker thread.
Keeping the event loop free is what lets an interrupt be handled while the
agent is mid-sentence.
"""

from __future__ import annotations

import asyncio
import shutil
import threading
from pathlib import Path
from typing import AsyncIterator, Callable

import torch

from . import config
from .audio import float32_to_pcm16
from .engines import EngineError


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


def _default_pipeline_factory(lang_code: str):
    try:
        from kokoro import KPipeline
    except ImportError as exc:  # pragma: no cover - depends on the environment
        raise EngineError(
            "Kokoro is not installed — run `pip install kokoro soundfile` "
            "and `brew install espeak-ng`"
        ) from exc
    _configure_espeak_from_homebrew()
    return KPipeline(lang_code=lang_code, device=config.KOKORO_DEVICE)


class KokoroTts:
    """TtsEngine backed by Kokoro-82M."""

    def __init__(
        self,
        lang_code: str = config.KOKORO_LANG_CODE,
        voice: str = config.KOKORO_VOICE,
        *,
        pipeline_factory: Callable[[str], object] | None = None,
    ) -> None:
        self._lang_code = lang_code
        self._voice = voice
        self._pipeline_factory = pipeline_factory or _default_pipeline_factory
        self._pipeline = None
        # A real OS thread lock, not asyncio.Lock -- see synthesize()'s
        # comment on why an asyncio-level lock can't do this job.
        self._synthesis_lock = threading.Lock()

    def _get_pipeline(self):
        # Built lazily and cached: loading weights takes seconds, and doing it
        # at import time would slow every test run and CLI invocation.
        if self._pipeline is None:
            self._pipeline = self._pipeline_factory(self._lang_code)
        return self._pipeline

    def _run_pipeline(self, pipeline, text: str) -> list:
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
            return list(pipeline(text, voice=self._voice))

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        if not text.strip():
            return
        try:
            pipeline = await asyncio.to_thread(self._get_pipeline)
            segments = await asyncio.to_thread(self._run_pipeline, pipeline, text)
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kokoro synthesis failed: {exc}") from exc
        finally:
            if config.KOKORO_DEVICE == "mps":
                # PyTorch's MPS caching allocator holds onto memory for
                # reuse WITHIN this process rather than returning it to the
                # OS after each call. This instance is built once and
                # shared for the server's whole lifetime (see app.py), so
                # without this, its cached footprint only grows across a
                # session -- confirmed via real on-device testing
                # (2026-08-25) as the cause of each LATER turn's Ollama
                # call getting progressively worse than the first (Groq,
                # which doesn't compete for local memory at all, showed no
                # such pattern with the same session). In `finally` so a
                # failed synthesis attempt still releases whatever it
                # allocated before failing.
                await asyncio.to_thread(torch.mps.empty_cache)

        for _graphemes, _phonemes, samples in segments:
            yield float32_to_pcm16(samples)
