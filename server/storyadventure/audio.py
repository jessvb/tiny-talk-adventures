"""Audio format conversion and text chunking for streaming TTS."""

from __future__ import annotations

import re

import numpy as np

MIC_SAMPLE_RATE = 16000
TTS_SAMPLE_RATE = 24000

_SENTENCE_BOUNDARY = re.compile(r"(?<=[.!?])\s+")


def float32_to_pcm16(samples: np.ndarray) -> bytes:
    """Convert model float audio in [-1.0, 1.0] to wire-format PCM16 LE."""
    # Coerce whatever array-like object the model backend yields (a numpy
    # array, a torch tensor, a plain list) into a real numpy float32 array.
    # Kokoro's real KPipeline yields torch tensors, not numpy arrays.
    samples = np.asarray(samples, dtype=np.float32)
    clipped = np.clip(samples, -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def pcm16_to_float32(data: bytes) -> np.ndarray:
    """Convert wire-format PCM16 LE to float audio in [-1.0, 1.0]."""
    return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0


def split_sentences(text: str) -> list[str]:
    """Split a reply into sentences so TTS can stream one at a time."""
    stripped = text.strip()
    if not stripped:
        return []
    return [part.strip() for part in _SENTENCE_BOUNDARY.split(stripped) if part.strip()]
