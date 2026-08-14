"""STT backend: Kyutai STT (MLX build).

The phone's Silero VAD decides when an utterance starts and ends, so this
adapter only needs to accumulate one utterance's audio and transcribe it on
finish(). If the installed moshi_mlx exposes a true streaming API, feed() can
be upgraded to return live partial text without changing any caller.

The real model API (moshi_mlx has no ready-made "Recognizer" class -- this
is assembled from the single-file flow in moshi_mlx.run_inference, confirmed
working against the real kyutai/stt-2.6b-en-mlx weights):

- Everything runs at 24kHz. That is why MIC_SAMPLE_RATE == TTS_SAMPLE_RATE
  in audio.py -- it was changed to match Kyutai's native rate once this was
  discovered, rather than resampling on every utterance.
- The model needs padding around the real audio: `audio_silence_prefix_seconds`
  of silence before it, and `audio_delay_seconds + 1.0` seconds after it (both
  from the model's own config.json, under "stt_config"). Without the trailing
  pad the model doesn't have room to emit the tail of the transcript -- it is
  causal and running behind the audio by `audio_delay_seconds`.
- Audio is fed to the audio tokenizer in fixed 1920-sample chunks (80ms at
  24kHz); each chunk advances the text generator by one step, which may or
  may not emit a text token.
"""

from __future__ import annotations

import json
from typing import Callable

import numpy as np

from . import config
from .audio import MIC_SAMPLE_RATE, pcm16_to_float32
from .engines import EngineError

_STEP_SAMPLES = 1920  # moshi_mlx's audio tokenizer processes audio in this chunk size


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
        self._models = models  # kept for LmGen at transcribe() time
        self._utils = utils  # kept for Sampler at transcribe() time

    def transcribe(self, samples: np.ndarray) -> str:
        import mlx.core as mx

        pad_left = int(self._stt_config.get("audio_silence_prefix_seconds", 0.0) * MIC_SAMPLE_RATE)
        pad_right = int(
            (self._stt_config.get("audio_delay_seconds", 0.0) + 1.0) * MIC_SAMPLE_RATE
        )
        padded = np.pad(samples.astype(np.float32), (pad_left, pad_right), mode="constant")

        steps = len(padded) // _STEP_SAMPLES
        gen = self._models.LmGen(
            model=self._model,
            max_steps=steps,
            text_sampler=self._utils.Sampler(top_k=25, temp=0.0),
            audio_sampler=self._utils.Sampler(top_k=250, temp=0.0),
            cfg_coef=1.0,
            check=False,
        )

        pieces: list[str] = []
        for step in range(steps):
            chunk = padded[step * _STEP_SAMPLES : (step + 1) * _STEP_SAMPLES]
            other_audio_tokens = self._audio_tokenizer.encode_step(chunk[None, None, :])
            other_audio_tokens = mx.array(other_audio_tokens).transpose(0, 2, 1)
            other_audio_tokens = other_audio_tokens[:, :, : self._other_codebooks]
            text_token = gen.step(other_audio_tokens[0], self._condition_tensor)
            text_token = text_token[0].item()
            if text_token not in self._text_padding_ids:
                piece = self._text_tokenizer.id_to_piece(text_token)
                pieces.append(piece.replace("▁", " "))

        return "".join(pieces).strip()


def _default_recognizer_factory(hf_repo: str) -> _Recognizer:
    return _Recognizer(hf_repo)


class KyutaiStt:
    """SttEngine backed by Kyutai STT."""

    def __init__(
        self,
        hf_repo: str = config.STT_HF_REPO,
        *,
        recognizer_factory: Callable[[str], object] | None = None,
    ) -> None:
        self._hf_repo = hf_repo
        self._recognizer_factory = recognizer_factory or _default_recognizer_factory
        self._recognizer = None
        self._buffer: list[np.ndarray] = []

    def _get_recognizer(self):
        if self._recognizer is None:
            self._recognizer = self._recognizer_factory(self._hf_repo)
        return self._recognizer

    def feed(self, pcm: bytes) -> str | None:
        samples = pcm16_to_float32(pcm)
        if len(samples):
            self._buffer.append(samples)
        return None

    def finish(self) -> str:
        if not self._buffer:
            return ""
        samples = np.concatenate(self._buffer)
        self._buffer.clear()
        try:
            return self._get_recognizer().transcribe(samples)
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kyutai STT failed to transcribe: {exc}") from exc

    def reset(self) -> None:
        self._buffer.clear()
