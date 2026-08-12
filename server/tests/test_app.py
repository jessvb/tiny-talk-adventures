from conftest import FakeLlm, FakeStt, FakeTts
from storyadventure.app import WebSocketTransport, handle_connection
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
    assert any("transcript_final" in frame for frame in text_frames)
    assert any("turn_end" in frame for frame in text_frames)
