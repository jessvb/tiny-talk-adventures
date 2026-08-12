import asyncio
import json
from typing import AsyncIterator

import pytest


class FakeTransport:
    """Records everything the session sends back to the client."""

    def __init__(self) -> None:
        self.text: list[str] = []
        self.audio: list[bytes] = []

    async def send_text(self, payload: str) -> None:
        self.text.append(payload)

    async def send_bytes(self, payload: bytes) -> None:
        self.audio.append(payload)

    def messages_of_type(self, kind: str) -> list[dict]:
        decoded = [json.loads(item) for item in self.text]
        return [item for item in decoded if item["type"] == kind]

    def types(self) -> list[str]:
        return [json.loads(item)["type"] for item in self.text]


class FakeStt:
    def __init__(self, transcript: str = "tell me about a fox") -> None:
        self.transcript = transcript
        self.fed: list[bytes] = []
        self.resets = 0

    def feed(self, pcm: bytes) -> str | None:
        self.fed.append(pcm)
        return None

    def finish(self) -> str:
        return self.transcript

    def reset(self) -> None:
        self.resets += 1
        self.fed.clear()


class FakeLlm:
    """Yields fixed chunks, optionally pausing so a test can interrupt mid-stream."""

    def __init__(self, chunks: list[str] | None = None, delay: float = 0.0) -> None:
        self.chunks = chunks if chunks is not None else ["Once upon a time. ", "A fox ran."]
        self.delay = delay
        self.calls: list[list[dict[str, str]]] = []
        self.cancelled = False

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        try:
            for chunk in self.chunks:
                if self.delay:
                    await asyncio.sleep(self.delay)
                yield chunk
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class FakeTts:
    """Emits one audio chunk per sentence, optionally slowly."""

    def __init__(self, delay: float = 0.0) -> None:
        self.delay = delay
        self.spoken: list[str] = []
        self.cancelled = False

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        try:
            if self.delay:
                await asyncio.sleep(self.delay)
            self.spoken.append(text)
            yield f"<audio:{text}>".encode()
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class FailingLlm:
    def __init__(self, error: Exception) -> None:
        self.error = error

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        raise self.error
        yield ""  # pragma: no cover - unreachable, marks this a generator


@pytest.fixture
def transport() -> FakeTransport:
    return FakeTransport()
