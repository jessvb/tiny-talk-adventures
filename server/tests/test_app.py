from conftest import FakeLlm, FakeStt, FakeTts
from tinytalk import config
from tinytalk.app import WebSocketTransport, build_llm, handle_connection
from tinytalk.engines import EngineError
from tinytalk.llm_groq import GroqLlm
from tinytalk.llm_ollama import OllamaLlm
from tinytalk.session import SessionRunner
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
