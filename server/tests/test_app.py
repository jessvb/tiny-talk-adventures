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

    def session_factory(transport):
        return SessionRunner(
            transport=transport,
            stt=stt,
            llm=FakeLlm(),
            tts=FakeTts(),
            system_prompt="be kind",
        )

    await handle_connection(websocket, session_factory=session_factory)

    # The binary frame must actually have reached the STT engine -- this is
    # the routing this task is responsible for, and it's easy to break
    # silently since FakeStt.finish() returns a canned transcript regardless
    # of what was fed to it. Checked via resets/all_fed rather than
    # stt.fed directly: handle_connection's cleanup now resets the STT on
    # every disconnect (shared engines mean a dropped connection must not
    # leave stale buffered audio for whoever connects next), which clears
    # stt.fed as its own correct side effect.
    assert stt.all_fed == [b"\x01\x02"]
    assert stt.resets == 1

    # transcript_final is sent synchronously inside _finish_listening,
    # before the (cancellable) turn task even exists -- must still arrive
    # even though the fixture "disconnects" (runs out of messages)
    # immediately afterward, with no reply ever coming back. See
    # test_handle_connection_cancels_an_in_flight_turn_on_disconnect for
    # the reply side of this.
    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert any("transcript_final" in frame for frame in text_frames)
    assert not any("error" in frame for frame in text_frames)


async def test_handle_connection_cancels_an_in_flight_turn_on_disconnect():
    # Real bug, confirmed on real hardware: the fixture running out of
    # messages right after speech_end simulates the client disconnecting
    # before any reply arrives -- exactly what happens when the iOS app is
    # backgrounded while waiting for a response. handle_connection used to
    # call session.wait_for_turn() here, which WAITS for the in-flight
    # turn rather than cancelling it -- so a disconnect mid-turn let a
    # full LLM generation + TTS synthesis run to completion (confirmed on
    # real hardware to take 10s of seconds under real memory pressure) for
    # a client that would never receive it, every send silently failing
    # and logging "could not send -- connection already closed" the whole
    # way through. The turn must be cancelled promptly instead (via
    # aclose()'s existing _cancel_turn()), so no reply frames are ever
    # produced for a connection that's already gone.
    websocket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )

    def session_factory(transport):
        return SessionRunner(
            transport=transport,
            stt=FakeStt(),
            llm=FakeLlm(),
            tts=FakeTts(),
            system_prompt="be kind",
        )

    await handle_connection(websocket, session_factory=session_factory)

    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert not any("response_text" in frame for frame in text_frames), (
        "the turn must be cancelled on disconnect, not run to completion for a reply nobody will receive"
    )
    assert not any("turn_end" in frame for frame in text_frames)


async def test_engine_failure_during_dispatch_sends_an_error_frame_and_keeps_the_socket_open():
    # A speech_end that triggers an STT failure (e.g. KyutaiStt.finish()
    # raising EngineError) is not guarded inside SessionRunner itself --
    # handle_connection's per-message dispatch is the one seam responsible
    # for turning that into an error frame instead of killing the
    # connection with no message sent to the client at all.
    websocket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )

    def session_factory(transport):
        return SessionRunner(
            transport=transport,
            stt=BoomStt(),
            llm=FakeLlm(),
            tts=FakeTts(),
            system_prompt="be kind",
        )

    await handle_connection(websocket, session_factory=session_factory)

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

    def session_factory(transport):
        return SessionRunner(
            transport=transport, stt=stt, llm=FakeLlm(), tts=FakeTts(), system_prompt="be kind"
        )

    await handle_connection(websocket, session_factory=session_factory)  # must not raise

    # Cleanup still ran exactly as it would on a clean disconnect.
    assert stt.resets == 1
