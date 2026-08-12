from conftest import FakeLlm, FakeStt, FakeTts
from storyadventure.app import WebSocketTransport, handle_connection
from storyadventure.engines import EngineError
from storyadventure.session import SessionRunner


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


async def test_transport_sends_text_and_binary_over_the_socket():
    websocket = FakeWebSocket([])
    transport = WebSocketTransport(websocket)

    await transport.send_text('{"type": "turn_end"}')
    await transport.send_bytes(b"\x01\x02")

    assert websocket.sent == ['{"type": "turn_end"}', b"\x01\x02"]


async def test_handle_connection_drives_a_full_turn():
    websocket = FakeWebSocket(
        ['{"type": "speech_start"}', b"\x01\x02", '{"type": "speech_end"}']
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
    # of what was fed to it.
    assert stt.fed == [b"\x01\x02"]

    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert any("transcript_final" in frame for frame in text_frames)
    assert any("turn_end" in frame for frame in text_frames)
    assert not any("error" in frame for frame in text_frames)


async def test_engine_failure_during_dispatch_sends_an_error_frame_and_keeps_the_socket_open():
    # A speech_end that triggers an STT failure (e.g. KyutaiStt.finish()
    # raising EngineError) is not guarded inside SessionRunner itself --
    # handle_connection's per-message dispatch is the one seam responsible
    # for turning that into an error frame instead of killing the
    # connection with no message sent to the client at all.
    websocket = FakeWebSocket(
        ['{"type": "speech_start"}', b"\x01\x02", '{"type": "speech_end"}']
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
