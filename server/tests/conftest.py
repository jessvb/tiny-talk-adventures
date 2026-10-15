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
        self.all_fed: list[bytes] = []  # unlike fed, survives reset() -- for asserting
        self.resets = 0

    def feed(self, pcm: bytes) -> str | None:
        self.fed.append(pcm)
        self.all_fed.append(pcm)
        return None

    def finish(self) -> str:
        return self.transcript

    def reset(self) -> None:
        self.resets += 1
        self.fed.clear()


class FakeLlm:
    """Yields fixed chunks, optionally pausing so a test can interrupt mid-stream.

    `chunks_by_call`, if given, overrides `chunks` and picks a different
    chunk list per call() -- index min(len(self.calls) - 1, last index), so
    the last list repeats if more calls happen than lists were given (same
    convention as test_storybook.py's FakeRewriteLlm). Needed for a
    same-turn retry loop (e.g. session.py's forced-conclude safety retry),
    where every attempt happens inside one _run_turn() call, too fast for a
    test to reassign `chunks` between attempts the way existing tests
    reassign it between separate turns.
    """

    def __init__(
        self,
        chunks: list[str] | None = None,
        delay: float = 0.0,
        chunks_by_call: list[list[str]] | None = None,
    ) -> None:
        self.chunks = chunks if chunks is not None else ["Once upon a time. ", "A fox ran."]
        self.chunks_by_call = chunks_by_call
        self.delay = delay
        self.calls: list[list[dict[str, str]]] = []
        self.cancelled = False

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        if self.chunks_by_call is not None:
            index = min(len(self.calls) - 1, len(self.chunks_by_call) - 1)
            chunks = self.chunks_by_call[index]
        else:
            chunks = self.chunks
        try:
            for chunk in chunks:
                if self.delay:
                    await asyncio.sleep(self.delay)
                yield chunk
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class FakeTts:
    """Emits one audio chunk per sentence, optionally slowly.

    seconds_per_sentence, if set, sizes the emitted chunk's byte count to
    match TTS_SAMPLE_RATE math (2 bytes/sample, PCM16 mono) for that many
    seconds of audio -- independent of `delay`, which only affects how long
    synthesize() itself takes to run (simulating slow synthesis), not how
    much real-world PLAYBACK time the resulting bytes represent. A test
    needs this knob to control what SessionRunner's byte-count-based
    playback-duration ESTIMATE computes, since the default tiny placeholder
    bytes below represent a negligible (sub-millisecond) duration no matter
    how long `delay` makes synthesis itself take.
    """

    def __init__(
        self,
        delay: float = 0.0,
        delays: list[float] | None = None,
        seconds_per_sentence: float = 0.0,
    ) -> None:
        self.delay = delay
        # Per-call override for `delay`, indexed by call count -- lets a
        # test give an EARLIER sentence a short delay (sent quickly) and a
        # LATER one a long delay (keeps _run_turn()'s task genuinely in
        # flight), which a single flat `delay` can't express.
        self.delays = delays
        self.seconds_per_sentence = seconds_per_sentence
        self.spoken: list[str] = []
        self.cancelled = False
        self._call_count = 0
        # Every set_voice() call, in order (issue #78).
        self.voices_set: list[str] = []

    def set_voice(self, voice: str) -> None:
        self.voices_set.append(voice)

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        try:
            call_delay = self.delay
            if self.delays is not None:
                call_delay = self.delays[self._call_count]
            self._call_count += 1
            if call_delay:
                await asyncio.sleep(call_delay)
            self.spoken.append(text)
            if self.seconds_per_sentence:
                byte_count = int(self.seconds_per_sentence * 2 * 24000)
                yield b"\x00" * byte_count
            else:
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


@pytest.fixture(autouse=True)
def isolated_animal_facts(tmp_path, monkeypatch):
    """Redirects the animal facts cache and disables the real API key for
    every test in the suite -- without this, a developer's real
    ANIMAL_FACTS_API_KEY env var would make tests using the default
    transcript ("tell me about a fox") take the live-API code path instead
    of the intended cache-miss/no-key path, both slowing the suite and
    (if the key is real) burning API quota."""
    path = tmp_path / "animal_facts.json"
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", path)
    monkeypatch.setattr("tinytalk.config.ANIMAL_FACTS_API_KEY", "")
    return path
