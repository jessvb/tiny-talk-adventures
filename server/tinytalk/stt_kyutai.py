"""STT backend: Kyutai STT (MLX build).

The phone's Silero VAD decides when an utterance starts and ends. Audio is
decoded INCREMENTALLY as it arrives via feed(), not buffered and decoded
all at once in finish() -- see _StreamingUtterance's docstring for why this
matters. If a future moshi_mlx version needs re-verifying against this
approach, moshi_mlx.local's server() function (a genuinely live, mic-driven
transcription loop, not the batch-file run_inference.py this was originally
built from) is the real reference for constructing one LmGen and stepping
it repeatedly as data arrives -- confirmed directly against the installed
package, not assumed.

The real model API (moshi_mlx has no ready-made "Recognizer" class -- this
is assembled from the single-file flow in moshi_mlx.run_inference, confirmed
working against the real kyutai/stt-2.6b-en-mlx weights):

- Everything runs at 24kHz. That is why MIC_SAMPLE_RATE == TTS_SAMPLE_RATE
  in audio.py -- it was changed to match Kyutai's native rate once this was
  discovered, rather than resampling on every utterance.
- The model needs padding around the real audio: `audio_silence_prefix_seconds`
  of silence before it, and `audio_delay_seconds + 1.0` seconds after it (both
  from the model's own config.json, under "stt_config" -- confirmed real
  values for kyutai/stt-2.6b-en-mlx: 1.0s prefix, 2.5s delay, so 3.5s of
  trailing pad). Without the trailing pad the model doesn't have room to
  emit the tail of the transcript -- it is causal and running behind the
  audio by `audio_delay_seconds`. This is a FIXED cost paid every utterance
  regardless of length (confirmed on real hardware: a 0.9s utterance and a
  batch-decoded multi-second one both took ~8.5s in the old all-at-once
  design, because the 4.5s of padding dominated the step count either way)
  -- which is exactly why streaming it during feed() matters: the fixed
  cost gets paid while the child is still talking instead of all at once
  in silence after they stop. Only the 3.5s trailing flush is unavoidable.
- Audio is fed to the audio tokenizer in fixed 1920-sample chunks (80ms at
  24kHz); each chunk advances the text generator by one step, which may or
  may not emit a text token.
"""

from __future__ import annotations

import json
import logging
import tempfile
import time
import wave
from typing import Callable

import numpy as np

from . import config
from .audio import MIC_SAMPLE_RATE, pcm16_to_float32
from .engines import EngineError

logger = logging.getLogger(__name__)

_STEP_SAMPLES = 1920  # moshi_mlx's audio tokenizer processes audio in this chunk size
# Generous upper bound on how many steps a single utterance's LmGen will
# ever need -- real usage stops calling step() once finish() is called, so
# this only needs to be large enough that no realistic utterance hits it.
_MAX_UTTERANCE_SECONDS = 60


class _StreamingUtterance:
    """One utterance's incremental decode state: a fresh LmGen fed as audio
    arrives, rather than one big batch decode at the end.

    Mirrors moshi_mlx.local's live server() loop (confirmed against the
    installed package): construct LmGen once, call step() once per
    1920-sample chunk as data becomes available. The silence prefix is fed
    immediately on construction -- the model needs that warm-up regardless
    of when it happens, and doing it now (right as listening starts,
    typically before or just as the child begins speaking) is strictly
    better than deferring it. Real audio is decoded progressively as feed()
    is called. finish() flushes the trailing pad (the model's fixed
    catch-up delay) plus any leftover partial chunk, and returns the full
    transcript.
    """

    def __init__(
        self,
        *,
        model,
        models_module,
        utils_module,
        audio_tokenizer,
        text_tokenizer,
        other_codebooks: int,
        condition_tensor,
        text_padding_ids: frozenset[int],
        pad_left_samples: int,
        pad_right_samples: int,
    ) -> None:
        self._models = models_module
        self._audio_tokenizer = audio_tokenizer
        self._text_tokenizer = text_tokenizer
        self._other_codebooks = other_codebooks
        self._condition_tensor = condition_tensor
        self._text_padding_ids = text_padding_ids
        self._pad_right_samples = pad_right_samples
        self._pending = np.zeros(0, dtype=np.float32)
        self._pieces: list[str] = []

        max_steps = (
            pad_left_samples + pad_right_samples + _MAX_UTTERANCE_SECONDS * MIC_SAMPLE_RATE
        ) // _STEP_SAMPLES
        self._gen = models_module.LmGen(
            model=model,
            max_steps=max_steps,
            text_sampler=utils_module.Sampler(top_k=25, temp=0.0),
            audio_sampler=utils_module.Sampler(top_k=250, temp=0.0),
            cfg_coef=1.0,
            check=False,
        )
        self._append(np.zeros(pad_left_samples, dtype=np.float32))

    def _append(self, samples: np.ndarray) -> str:
        import mlx.core as mx

        if len(samples):
            self._pending = np.concatenate([self._pending, samples])
        new_pieces: list[str] = []
        while len(self._pending) >= _STEP_SAMPLES:
            chunk, self._pending = self._pending[:_STEP_SAMPLES], self._pending[_STEP_SAMPLES:]
            other_audio_tokens = self._audio_tokenizer.encode_step(chunk[None, None, :])
            other_audio_tokens = mx.array(other_audio_tokens).transpose(0, 2, 1)
            other_audio_tokens = other_audio_tokens[:, :, : self._other_codebooks]
            text_token = self._gen.step(other_audio_tokens[0], self._condition_tensor)
            text_token = text_token[0].item()
            if text_token not in self._text_padding_ids:
                piece = self._text_tokenizer.id_to_piece(text_token)
                new_pieces.append(piece.replace("▁", " "))
        if new_pieces:
            self._pieces.extend(new_pieces)
        return "".join(new_pieces)

    def feed(self, samples: np.ndarray) -> str:
        return self._append(samples)

    def finish(self) -> str:
        self._append(np.zeros(self._pad_right_samples, dtype=np.float32))
        return "".join(self._pieces).strip()


class _Recognizer:
    """Thin wrapper over moshi_mlx, built lazily so imports stay cheap."""

    def __init__(self, hf_repo: str) -> None:
        try:
            import moshi_mlx  # noqa: F401
        except ImportError as exc:  # pragma: no cover - depends on environment
            raise EngineError(
                "moshi_mlx is not installed — run `pip install moshi_mlx` "
                "under Python 3.12"
            ) from exc
        self._hf_repo = hf_repo
        self._load()

    def _load(self) -> None:
        import mlx.core as mx
        import mlx.nn as nn
        import rustymimi
        import sentencepiece
        from huggingface_hub import hf_hub_download
        from moshi_mlx import models, utils

        mx.random.seed(299792458)

        config_path = hf_hub_download(self._hf_repo, "config.json")
        with open(config_path, "r") as fobj:
            lm_config_dict = json.load(fobj)
        self._stt_config = lm_config_dict.get("stt_config") or {}
        self._text_padding_ids = frozenset(
            {0, lm_config_dict.get("existing_text_padding_id", 3)}
        )

        mimi_weights = hf_hub_download(self._hf_repo, lm_config_dict["mimi_name"])
        moshi_name = lm_config_dict.get("moshi_name", "model.safetensors")
        moshi_weights = hf_hub_download(self._hf_repo, moshi_name)
        tokenizer_path = hf_hub_download(self._hf_repo, lm_config_dict["tokenizer_name"])

        lm_config = models.LmConfig.from_config_dict(lm_config_dict)
        model = models.Lm(lm_config)
        model.set_dtype(mx.bfloat16)
        if moshi_weights.endswith(".q4.safetensors"):
            nn.quantize(model, bits=4, group_size=32)
        elif moshi_weights.endswith(".q8.safetensors"):
            nn.quantize(model, bits=8, group_size=64)
        model.load_weights(moshi_weights, strict=True)

        self._text_tokenizer = sentencepiece.SentencePieceProcessor(tokenizer_path)

        self._other_codebooks = lm_config.other_codebooks
        mimi_codebooks = max(lm_config.generated_codebooks, self._other_codebooks)
        self._audio_tokenizer = rustymimi.Tokenizer(mimi_weights, num_codebooks=mimi_codebooks)

        self._condition_tensor = (
            model.condition_provider.condition_tensor("description", "very_good")
            if model.condition_provider is not None
            else None
        )

        model.warmup(self._condition_tensor)
        self._model = model
        self._models = models  # kept for LmGen at start_session() time
        self._utils = utils  # kept for Sampler at start_session() time

    def start_session(self) -> _StreamingUtterance:
        # self._model and self._audio_tokenizer are shared across every
        # utterance for this process's whole lifetime (loaded once, reused
        # -- see app.py's own comment on why). Without resetting their
        # internal state here, each new utterance's attention silently
        # keeps attending to -- and being influenced by -- every PRIOR
        # utterance's audio and text tokens, unbounded, for as long as the
        # server runs. Confirmed on real hardware, then reproduced
        # deterministically here: STT correctly transcribes the first
        # several utterances of a session, then degrades (a truncated
        # transcript, then empty output) for every utterance after that,
        # for the rest of the session -- fixed by resetting both caches
        # confirmed real: Lm.warmup() (this same package) performs the
        # identical `for c in self.transformer_cache: c.reset()` pattern
        # right after its own dummy inference call; depformer_cache is the
        # analogous cache for the audio-codebook sub-model and needs the
        # same treatment even though this STT usage never reads its output,
        # since _sample() unconditionally advances it every step regardless;
        # rustymimi.Tokenizer.reset() confirmed to exist via direct
        # introspection (dir(rustymimi.Tokenizer)), not assumed.
        for layer_cache in self._model.transformer_cache:
            layer_cache.reset()
        for layer_cache in self._model.depformer_cache:
            layer_cache.reset()
        self._audio_tokenizer.reset()

        pad_left = int(self._stt_config.get("audio_silence_prefix_seconds", 0.0) * MIC_SAMPLE_RATE)
        pad_right = int(
            (self._stt_config.get("audio_delay_seconds", 0.0) + 1.0) * MIC_SAMPLE_RATE
        )
        return _StreamingUtterance(
            model=self._model,
            models_module=self._models,
            utils_module=self._utils,
            audio_tokenizer=self._audio_tokenizer,
            text_tokenizer=self._text_tokenizer,
            other_codebooks=self._other_codebooks,
            condition_tensor=self._condition_tensor,
            text_padding_ids=self._text_padding_ids,
            pad_left_samples=pad_left,
            pad_right_samples=pad_right,
        )


def _default_recognizer_factory(hf_repo: str) -> _Recognizer:
    return _Recognizer(hf_repo)


class KyutaiStt:
    """SttEngine backed by Kyutai STT, decoded incrementally as audio arrives."""

    def __init__(
        self,
        hf_repo: str = config.STT_HF_REPO,
        *,
        recognizer_factory: Callable[[str], object] | None = None,
    ) -> None:
        self._hf_repo = hf_repo
        self._recognizer_factory = recognizer_factory or _default_recognizer_factory
        self._recognizer = None
        self._utterance: _StreamingUtterance | None = None
        self._fed_samples = 0
        # Diagnostic only: retained purely so an empty-transcript result can
        # be dumped to a real WAV file (see finish() below) -- confirmed
        # on-device that STT sometimes returns "" for utterances that
        # clearly contained real speech, and there was no way to tell
        # whether that's a real decode bug or a genuine recognition miss
        # (quiet speech, background noise, a VAD false trigger) without
        # being able to listen to exactly what was captured.
        self._raw_pcm_chunks: list[bytes] = []

    def _get_recognizer(self):
        if self._recognizer is None:
            self._recognizer = self._recognizer_factory(self._hf_repo)
        return self._recognizer

    def feed(self, pcm: bytes) -> str | None:
        samples = pcm16_to_float32(pcm)
        if not len(samples):
            return None
        if self._utterance is None:
            self._utterance = self._get_recognizer().start_session()
            self._fed_samples = 0
            self._raw_pcm_chunks = []
        self._fed_samples += len(samples)
        self._raw_pcm_chunks.append(pcm)
        try:
            return self._utterance.feed(samples) or None
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kyutai STT failed to transcribe: {exc}") from exc

    def finish(self) -> str:
        if self._utterance is None:
            logger.info("finish() called with no audio ever fed")
            return ""
        utterance, self._utterance = self._utterance, None
        raw_pcm_chunks, self._raw_pcm_chunks = self._raw_pcm_chunks, []
        logger.info(
            "flushing streaming session: %.2fs of real audio fed incrementally (%d samples)",
            self._fed_samples / MIC_SAMPLE_RATE,
            self._fed_samples,
        )
        try:
            transcript = utterance.finish()
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kyutai STT failed to transcribe: {exc}") from exc
        # Diagnostic only -- see _raw_pcm_chunks' doc comment. 0.2s is a
        # rough floor to skip dumping on genuinely-trivial fragments (a
        # single VAD-onset chunk or two), which return "" so routinely
        # they'd just be noise here.
        if not transcript.strip() and self._fed_samples / MIC_SAMPLE_RATE >= 0.2:
            self._dump_empty_transcript_audio(raw_pcm_chunks)
        return transcript

    def _dump_empty_transcript_audio(self, raw_pcm_chunks: list[bytes]) -> None:
        path = f"{tempfile.gettempdir()}/tinytalk-empty-transcript-{int(time.time())}.wav"
        try:
            with wave.open(path, "wb") as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)  # PCM16
                wav_file.setframerate(int(MIC_SAMPLE_RATE))
                wav_file.writeframes(b"".join(raw_pcm_chunks))
            logger.warning(
                "STT returned an empty transcript for %.2fs of real audio -- saved to %s "
                "for inspection (play with: afplay %s)",
                self._fed_samples / MIC_SAMPLE_RATE,
                path,
                path,
            )
        except OSError as exc:
            logger.warning("could not save empty-transcript audio for inspection: %s", exc)

    def reset(self) -> None:
        self._utterance = None
        self._fed_samples = 0
        self._raw_pcm_chunks = []
