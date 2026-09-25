"""Narrow interfaces for the three models.

Orchestration depends on these Protocols rather than on the concrete model
wrappers, so session logic can be tested with fakes — no model weights, no
Metal, no network.
"""

from __future__ import annotations

from typing import AsyncIterator, Protocol


class EngineError(RuntimeError):
    """A model backend failed. Surfaced to the client as an error message."""


class SttEngine(Protocol):
    def feed(self, pcm: bytes) -> str | None:
        """Feed PCM16 LE mic audio. Returns updated partial text, or None."""
        ...

    def finish(self) -> str:
        """Finalize the utterance and return the full transcript.

        May block on model inference (e.g. an MLX forward pass); callers
        should run it off the event loop, e.g. via `asyncio.to_thread`.
        """
        ...

    def reset(self) -> None:
        """Discard any in-progress utterance state."""
        ...


class LlmEngine(Protocol):
    def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        """Stream the reply as text chunks."""
        ...


class TtsEngine(Protocol):
    def synthesize(self, text: str) -> AsyncIterator[bytes]:
        """Stream synthesized speech as PCM16 LE audio chunks."""
        ...

    def set_voice(self, voice: str) -> None:
        """Use this voice for every synthesize() call started from now on."""
        ...
