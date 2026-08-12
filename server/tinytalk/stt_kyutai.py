"""STT backend: Kyutai STT (MLX build).

The phone's Silero VAD decides when an utterance starts and ends, so this
adapter only needs to accumulate one utterance's audio and transcribe it on
finish(). If the installed moshi_mlx exposes a true streaming API, feed() can
be upgraded to return live partial text without changing any caller.
"""

from __future__ import annotations

from typing import Callable

import numpy as np

from . import config
from .audio import pcm16_to_float32
from .engines import EngineError


class _Recognizer:
    """Thin wrapper over moshi_mlx, built lazily so imports stay cheap.

    Replace the body of transcribe() with the call confirmed in Task 8 Step 1.
    """

    def __init__(self, hf_repo: str) -> None:
        try:
            import moshi_mlx  # noqa: F401
        except ImportError as exc:  # pragma: no cover - depends on environment
            raise EngineError(
                "moshi_mlx is not installed — run `pip install moshi_mlx` "
                "under Python 3.12"
            ) from exc
        self._hf_repo = hf_repo
        self._model = self._load()

    def _load(self):
        raise NotImplementedError(
            "Wire this to the moshi_mlx entry point confirmed in Task 8 Step 1."
        )

    def transcribe(self, samples: np.ndarray) -> str:
        raise NotImplementedError(
            "Wire this to the moshi_mlx entry point confirmed in Task 8 Step 1."
        )


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
