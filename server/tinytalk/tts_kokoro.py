"""TTS backend: Kokoro-82M.

KPipeline is a blocking generator, so each synthesis runs on a worker thread.
Keeping the event loop free is what lets an interrupt be handled while the
agent is mid-sentence.
"""

from __future__ import annotations

import asyncio
from typing import AsyncIterator, Callable

from . import config
from .audio import float32_to_pcm16
from .engines import EngineError


def _default_pipeline_factory(lang_code: str):
    try:
        from kokoro import KPipeline
    except ImportError as exc:  # pragma: no cover - depends on the environment
        raise EngineError(
            "Kokoro is not installed — run `pip install kokoro soundfile` "
            "and `brew install espeak-ng`"
        ) from exc
    return KPipeline(lang_code=lang_code)


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

    def _get_pipeline(self):
        # Built lazily and cached: loading weights takes seconds, and doing it
        # at import time would slow every test run and CLI invocation.
        if self._pipeline is None:
            self._pipeline = self._pipeline_factory(self._lang_code)
        return self._pipeline

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        if not text.strip():
            return
        try:
            pipeline = await asyncio.to_thread(self._get_pipeline)
            segments = await asyncio.to_thread(
                lambda: list(pipeline(text, voice=self._voice))
            )
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kokoro synthesis failed: {exc}") from exc

        for _graphemes, _phonemes, samples in segments:
            yield float32_to_pcm16(samples)
