import asyncio
import logging
import time
from unittest.mock import patch
from pathlib import Path

from conftest import FakeLlm, FakeStt, FakeTts
from tinytalk import config
from tinytalk.audio import MIC_SAMPLE_RATE
from tinytalk import app as app_module
from tinytalk.app import WebSocketTransport, build_llm, handle_connection
from tinytalk.engines import EngineError
from tinytalk.llm_groq import GroqLlm
from tinytalk.llm_ollama import OllamaLlm
from tinytalk.session import SessionRunner
from tinytalk.state import State
from websockets.exceptions import ConnectionClosedError


class FakeWebSocket:
    """Minimal stand-in for a websockets connection."""

    def __init__(self, incoming: list[str | bytes]) -> None:
        self._incoming = incoming
        self.sent: list[str | bytes] = []

    def __aiter__(self):
        async def generate():
            for item in self._incoming:
                yield item

        return generate()

    async def send(self, payload: str | bytes) -> None:
        self.sent.append(payload)


class AbruptlyClosingWebSocket(FakeWebSocket):
    """Raises ConnectionClosedError partway through iteration -- simulates
    a keepalive ping timeout or WiFi drop, distinct from a clean close
    handshake (which FakeWebSocket's generator already covers by just
    running out of items)."""

    def __aiter__(self):
        async def generate():
            for item in self._incoming:
                yield item
            raise ConnectionClosedError(None, None)

        return generate()


class BoomStt:
    """An STT engine whose finish() blows up, simulating a model failure.

    Mirrors KyutaiStt.finish() raising EngineError, which SessionRunner does
    not catch internally (unlike failures inside the turn task) -- the catch
    has to live in handle_connection's per-message dispatch.
    """

    def feed(self, pcm: bytes) -> str | None:
        return None

    def finish(self) -> str:
        raise EngineError("stt exploded")

    def reset(self) -> None:
        pass


def test_build_llm_defaults_to_ollama(monkeypatch):
    monkeypatch.setattr(config, "LLM_BACKEND", "ollama")
    assert isinstance(build_llm(), OllamaLlm)


def test_build_llm_switches_to_groq_when_configured(monkeypatch):
    monkeypatch.setattr(config, "LLM_BACKEND", "groq")
    monkeypatch.setattr(config, "GROQ_API_KEY", "test-key")
    assert isinstance(build_llm(), GroqLlm)


async def test_transport_sends_text_and_binary_over_the_socket():
    websocket = FakeWebSocket([])
    transport = WebSocketTransport(websocket)

    await transport.send_text('{"type": "turn_end"}')
    await transport.send_bytes(b"\x01\x02")

    assert websocket.sent == ['{"type": "turn_end"}', b"\x01\x02"]


async def test_handle_connection_dispatches_audio_to_stt_before_any_disconnect():
    websocket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    stt = FakeStt()
    session = SessionRunner(
        transport=WebSocketTransport(websocket),
        stt=stt,
        llm=FakeLlm(),
        tts=FakeTts(),
        system_prompt="be kind",
    )

    await handle_connection(websocket, session=session)

    # The binary frame must actually have reached the STT engine -- this is
    # the routing this task is responsible for, and it's easy to break
    # silently since FakeStt.finish() returns a canned transcript regardless
    # of what was fed to it.
    assert stt.fed == [b"\x01\x02"]
    # By the time the fixture "disconnects" (runs out of messages), speech_end
    # has already moved the session to THINKING -- handle_disconnect() only
    # resets STT for a disconnect landing mid-utterance (still LISTENING), so
    # no reset happens here. See test_abrupt_disconnect_is_handled_without_an_unhandled_exception
    # for that case.
    assert stt.resets == 0

    # transcript_final is sent synchronously inside _finish_listening,
    # before the (still-running, not cancelled) turn task even exists --
    # must still arrive even though the fixture "disconnects" (runs out of
    # messages) immediately afterward. See
    # test_handle_connection_lets_an_in_flight_turn_finish_and_buffers_it_for_replay
    # for the reply side of this.
    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert any("transcript_final" in frame for frame in text_frames)
    assert not any("error" in frame for frame in text_frames)


async def test_handle_connection_lets_an_in_flight_turn_finish_and_buffers_it_for_replay():
    # Real scenario, confirmed on real hardware: the fixture running out of
    # messages right after speech_end simulates the client disconnecting
    # before any reply arrives -- exactly what happens when the iOS app is
    # backgrounded while waiting for a response. handle_connection used to
    # cancel the in-flight turn on disconnect; it now deliberately does NOT
    # (see SessionRunner.handle_disconnect()) -- the turn keeps running and
    # everything it sends is buffered so it can be replayed in full to
    # whichever connection asks next (see the reconnect test below).
    websocket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    session = SessionRunner(
        transport=WebSocketTransport(websocket),
        stt=FakeStt(),
        llm=FakeLlm(),
        tts=FakeTts(),
        system_prompt="be kind",
    )

    await handle_connection(websocket, session=session)
    # handle_connection returns as soon as the fake socket runs out of
    # messages -- the turn it left running is a detached background task,
    # awaited here the same way any test waits for one.
    await session.wait_for_turn()

    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert any("response_text" in frame for frame in text_frames), (
        "the turn must be allowed to finish, not cancelled, so its reply exists to replay later"
    )
    assert any("turn_end" in frame for frame in text_frames)


async def test_reconnecting_after_a_disconnect_mid_turn_replays_the_buffered_reply():
    first_socket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    session = SessionRunner(
        transport=WebSocketTransport(first_socket),
        stt=FakeStt(),
        llm=FakeLlm(),
        tts=FakeTts(),
        system_prompt="be kind",
    )
    await handle_connection(first_socket, session=session)
    await session.wait_for_turn()

    second_socket = FakeWebSocket([])  # the child reopens the app; no new messages yet
    await handle_connection(second_socket, session=session)

    text_frames = [item for item in second_socket.sent if isinstance(item, str)]
    audio_frames = [item for item in second_socket.sent if isinstance(item, bytes)]
    assert any("response_text" in frame for frame in text_frames), (
        "reconnecting must replay the reply the child never received"
    )
    assert any("turn_end" in frame for frame in text_frames)
    assert audio_frames, "the reply's audio must be replayed too, not just its text"


async def test_reconnecting_while_rewriting_repushes_rewriting_started(monkeypatch):
    first_socket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    session = SessionRunner(
        transport=WebSocketTransport(first_socket),
        stt=FakeStt(),
        llm=FakeLlm(chunks=["The end."]),
        tts=FakeTts(),
        system_prompt="be kind",
    )
    # Prevent story_store.save_story() from writing to disk
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: Path("20260101T000000-fakestory0.json"),
    )
    await handle_connection(first_socket, session=session)
    await session.wait_for_turn()
    assert session.state is State.REWRITING

    second_socket = FakeWebSocket([])  # the child reopens the app mid-rewrite
    await handle_connection(second_socket, session=session)

    text_frames = [item for item in second_socket.sent if isinstance(item, str)]
    assert any('"type": "rewriting_started"' in frame for frame in text_frames), (
        "reconnecting mid-rewrite must tell the client it can't start a new "
        "story yet"
    )


async def test_a_third_connection_still_gets_the_reply_replayed_if_the_second_died_fast():
    # Real bug, found on real hardware: an EARLIER version consumed the
    # replay buffer on first use, so a reconnect that itself died quickly
    # (e.g. the child backgrounding the app twice in a row, each time
    # before the reply could actually finish playing) burned the one
    # replay attempt without the child ever hearing it -- silently losing
    # the reply for good. The buffer must survive across as many flaky
    # reconnects as it takes, forgotten only once a genuinely new
    # utterance starts (see test_a_new_turn_clears_the_previous_turns_replay_buffer
    # in test_session.py).
    first_socket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    session = SessionRunner(
        transport=WebSocketTransport(first_socket),
        stt=FakeStt(),
        llm=FakeLlm(),
        tts=FakeTts(),
        system_prompt="be kind",
    )
    await handle_connection(first_socket, session=session)
    await session.wait_for_turn()

    second_socket = FakeWebSocket([])
    await handle_connection(second_socket, session=session)
    assert second_socket.sent, "sanity check: the first reconnect should have gotten the replay"

    third_socket = FakeWebSocket([])
    await handle_connection(third_socket, session=session)

    assert third_socket.sent, (
        "the third connection must still get the reply -- the second one dying "
        "fast must not have burned the only replay attempt"
    )


async def test_engine_failure_during_dispatch_sends_an_error_frame_and_keeps_the_socket_open():
    # A speech_end that triggers an STT failure (e.g. KyutaiStt.finish()
    # raising EngineError) is not guarded inside SessionRunner itself --
    # handle_connection's per-message dispatch is the one seam responsible
    # for turning that into an error frame instead of killing the
    # connection with no message sent to the client at all.
    websocket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    session = SessionRunner(
        transport=WebSocketTransport(websocket),
        stt=BoomStt(),
        llm=FakeLlm(),
        tts=FakeTts(),
        system_prompt="be kind",
    )

    await handle_connection(websocket, session=session)

    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert text_frames, "expected an error frame, but nothing was sent to the client"
    assert any(
        '"type": "error"' in frame and "stt exploded" in frame for frame in text_frames
    )


async def test_abrupt_disconnect_is_handled_without_an_unhandled_exception():
    # A keepalive ping timeout or WiFi drop raises ConnectionClosedError
    # out of `async for message in websocket` itself, not just out of a
    # send -- this must not propagate as an unhandled exception (which
    # would otherwise produce a scary traceback in the logs for what is,
    # in real-world mobile usage, an expected occurrence).
    websocket = AbruptlyClosingWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02"]
    )
    stt = FakeStt()
    session = SessionRunner(
        transport=WebSocketTransport(websocket),
        stt=stt,
        llm=FakeLlm(),
        tts=FakeTts(),
        system_prompt="be kind",
    )

    await handle_connection(websocket, session=session)  # must not raise

    # No speech_end ever arrived, so the disconnect landed mid-utterance
    # (still LISTENING) -- handle_disconnect() resets STT in exactly this
    # case, since STT's own per-utterance reset (normally triggered by
    # finish()) never got a chance to fire.
    assert stt.resets == 1


class RecordingWebSocket(FakeWebSocket):
    """Records when the socket-reading loop actually drained the last
    inbound frame, so a test can assert reading is not gated on how long
    processing those frames takes."""

    def __init__(self, incoming: list[str | bytes]) -> None:
        super().__init__(incoming)
        self.read_finished_at: float | None = None

    def __aiter__(self):
        async def generate():
            for item in self._incoming:
                yield item
                # A real socket read suspends; without this the reader
                # would starve the worker and the test would prove nothing.
                await asyncio.sleep(0)
            self.read_finished_at = time.perf_counter()

        return generate()


class SlowSession:
    """A SessionRunner stand-in whose per-message work is far slower than
    the inbound stream, which is the real situation on hardware: measured
    from production logs, KyutaiStt.feed() decodes roughly 4x slower than
    realtime, so audio arrives faster than it can possibly be consumed."""

    def __init__(self, per_message_delay: float = 0.02) -> None:
        self.per_message_delay = per_message_delay
        self.handled: list[str | bytes] = []
        self.handled_at: list[float] = []
        self.current_turn_id = 0
        self.disconnects = 0
        self.transport_generation = 0

    def rebind_transport(self, transport) -> None:
        self.transport = transport
        self.transport_generation += 1

    async def replay_last_turn(self) -> None:
        return None

    async def resend_current_status(self) -> None:
        return None

    async def _work(self, item: str | bytes) -> None:
        await asyncio.sleep(self.per_message_delay)
        self.handled.append(item)
        self.handled_at.append(time.perf_counter())

    async def handle_audio(self, pcm: bytes) -> None:
        await self._work(pcm)

    async def handle_text(self, raw: str) -> None:
        await self._work(raw)

    async def handle_disconnect(self) -> None:
        self.disconnects += 1


async def test_socket_reading_is_not_gated_on_slow_message_handling():
    """The disconnect bug's root cause, as a test.

    websockets pauses reading the TCP socket entirely once more than
    max_queue (16) frames are waiting -- and a paused socket never reads
    the client's keepalive PONG either, so the server kills its own
    healthy connection ping_interval + ping_timeout (40s) later. That can
    only happen if the read loop is gated on per-message work, so the
    guarantee to hold is: the reader drains the socket without waiting for
    processing to catch up.
    """
    frames: list[str | bytes] = [b"\x00" * 64 for _ in range(20)]
    frames.append('{"type":"speech_end"}')
    socket = RecordingWebSocket(frames)
    session = SlowSession(per_message_delay=0.02)

    await handle_connection(socket, session=session)

    assert session.handled == frames, "every frame must still be handled, in order"
    assert socket.read_finished_at is not None
    assert socket.read_finished_at < session.handled_at[-1], (
        "the socket was still being read only because processing had finished -- "
        "reading is gated on per-message work"
    )


async def test_a_barge_in_discards_audio_still_queued_for_the_abandoned_utterance():
    """Audio sitting in the queue ahead of an interrupt belongs to the
    utterance the child just talked over, which the server is about to
    abandon anyway. Feeding it costs ~4x realtime for nothing and is what
    lets a backlog build in the first place."""
    stale: list[str | bytes] = [f"stale-{i}".encode() for i in range(8)]
    fresh: list[str | bytes] = [f"fresh-{i}".encode() for i in range(3)]
    socket = FakeWebSocket([*stale, '{"type":"interrupt","turn_id":2}', *fresh])
    session = SlowSession(per_message_delay=0)

    await handle_connection(socket, session=session)

    assert session.handled == ['{"type":"interrupt","turn_id":2}', *fresh]


async def test_a_conclude_story_discards_audio_still_queued_for_the_abandoned_utterance():
    """conclude_story ("Finish this story") resets STT and abandons an
    in-progress utterance exactly like an interrupt does (see
    SessionRunner.handle_conclude_story) -- so audio queued ahead of it
    is just as much waste to decode as audio queued ahead of an interrupt.
    Without "conclude_story" in _UTTERANCE_ABANDONING_TYPES, this stale
    audio would be fed to STT anyway, wasting real decode time on audio
    about to be thrown away regardless."""
    stale: list[str | bytes] = [f"stale-{i}".encode() for i in range(8)]
    fresh: list[str | bytes] = [f"fresh-{i}".encode() for i in range(3)]
    socket = FakeWebSocket([*stale, '{"type":"conclude_story","turn_id":9}', *fresh])
    session = SlowSession(per_message_delay=0)

    await handle_connection(socket, session=session)

    assert session.handled == ['{"type":"conclude_story","turn_id":9}', *fresh]


async def test_a_flooded_queue_drops_audio_but_never_control_frames():
    """A bounded queue keeps a runaway client from growing memory without
    limit, but dropping a speech_end/interrupt would strand the session --
    so only audio is ever droppable."""
    flood: list[str | bytes] = [f"audio-{i}".encode() for i in range(64)]
    socket = FakeWebSocket([*flood, '{"type":"speech_end"}'])
    session = SlowSession(per_message_delay=0)

    with patch.object(app_module, "INBOUND_QUEUE_MAXSIZE", 8):
        await handle_connection(socket, session=session)

    assert '{"type":"speech_end"}' in session.handled
    assert len([item for item in session.handled if isinstance(item, bytes)]) <= 8


async def test_a_superseded_connection_stops_processing_and_leaves_cleanup_to_its_replacement():
    """Only one connection may drive the shared session at a time.

    The session (and so the single streaming STT utterance inside it) is
    shared across connections by design. Now that a dead connection drains
    what it already read instead of stopping at one message, a reconnect
    arriving during that drain would otherwise have two connections feeding
    the same STT session at once -- interleaving two children's utterances
    into one transcript, and running two MLX calls from two threads. Worse,
    the old connection's handle_disconnect() would then reset the STT
    session the NEW connection had already started filling.
    """
    session = SlowSession(per_message_delay=0.01)
    superseded = FakeWebSocket([f"stale-{i}".encode() for i in range(40)])
    draining = asyncio.create_task(handle_connection(superseded, session=session))
    await asyncio.sleep(0.05)
    handled_before_takeover = len(session.handled)

    await handle_connection(FakeWebSocket([]), session=session)
    await draining

    assert len(session.handled) - handled_before_takeover <= 2, (
        "the superseded connection kept feeding the session after a newer "
        "connection took it over"
    )
    assert session.disconnects == 1, (
        "the superseded connection ran session cleanup that belongs to the "
        "connection that replaced it"
    )


async def test_a_dead_connection_stops_draining_its_backlog_instead_of_grinding_on():
    """Cleanup must not sit and chew through a backlog nobody is waiting for.

    Confirmed on real hardware, from a live stack dump of a wedged server:
    with STT decoding ~2.3x slower than realtime, a connection whose phone
    had long since gone away spent THIRTEEN MINUTES inside this cleanup,
    feeding queued audio to MLX and pinning the GPU. handle_disconnect()
    only runs after that drain, so the session stayed wedged for the whole
    time too. Finishing what was already read is worth a bounded wait, not
    an unbounded one.
    """
    backlog: list[str | bytes] = [b"\x00" * 64 for _ in range(200)]
    socket = FakeWebSocket(backlog)
    # Fully draining this would take 200 * 0.05 = 10s.
    session = SlowSession(per_message_delay=0.05)

    with patch.object(app_module, "POST_DISCONNECT_DRAIN_SECONDS", 0.2):
        started = time.perf_counter()
        await handle_connection(socket, session=session)
        elapsed = time.perf_counter() - started

    assert elapsed < 3.0, f"cleanup ground on for {elapsed:.1f}s instead of giving up"
    assert len(session.handled) < len(backlog), "the whole backlog was drained anyway"
    assert session.disconnects == 1, "session cleanup never ran"


async def test_stt_falling_behind_realtime_is_logged_loudly(caplog):
    """The single log line that would have made this bug obvious.

    When STT cannot keep up, the server goes completely silent -- no turn
    starts, nothing is logged, and the app just waits. That is exactly what
    made the real incident take an hour to diagnose: thirteen minutes of
    solid GPU work with not one line of output. Queued audio that STT has
    not consumed is the direct measure of falling behind, so say so.
    """
    one_second_of_audio = b"\x00" * (2 * MIC_SAMPLE_RATE)
    socket = FakeWebSocket([one_second_of_audio for _ in range(6)])
    session = SlowSession(per_message_delay=0)

    with caplog.at_level(logging.WARNING, logger="tinytalk.app"):
        await handle_connection(socket, session=session)

    warnings = [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
    assert any("behind realtime" in message for message in warnings), (
        f"a growing STT backlog was never reported; got {warnings}"
    )
