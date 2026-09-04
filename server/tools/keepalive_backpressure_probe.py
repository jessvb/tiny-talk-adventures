"""Guards the fix for the "app randomly disconnects mid-story" bug.

The unit tests in tests/test_app.py check that reading the socket isn't
gated on message processing, but they do it against fakes -- and the bug
lived in the interaction with the real `websockets` library, not in our
own logic. This runs the real handle_connection over a real socket, with
STT standing in at the ~4x-realtime speed KyutaiStt.feed() actually
manages on this Mac, and checks the connection is still alive afterwards.

Keepalive is squeezed to 1s + 1s here so a failure that takes 40s in
production (ping_interval + ping_timeout) shows up in about two seconds.

    server/.venv/bin/python tools/keepalive_backpressure_probe.py

Exits 0 if the connection survives, 1 if the server hung up on it.
Before the fix this failed with `1011 keepalive ping timeout` partway
through the utterance, without ever processing the speech_end.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import time
from pathlib import Path

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tinytalk.app import handle_connection  # noqa: E402

logging.basicConfig(
    level=logging.INFO, format="%(relativeCreated)6.0fms %(name)s: %(message)s"
)
logger = logging.getLogger("probe")

FRAME_MS = 80  # one client audio frame's worth of speech
SPEECH_SECONDS = 6  # an ordinary sentence from a child
STT_SLOWDOWN = 4.0  # KyutaiStt.feed() decodes this much slower than realtime
IDLE_WAIT_SECONDS = 15  # the quiet stretch that used to kill the connection


class SlowSttSession:
    """Just enough SessionRunner surface for handle_connection, with the
    one property that matters here: consuming audio far slower than it
    arrives."""

    def __init__(self) -> None:
        self.audio_frames = 0
        self.control: list[str] = []
        self.current_turn_id = 1
        self.transport_generation = 0

    def rebind_transport(self, transport) -> None:
        self.transport = transport
        self.transport_generation += 1

    async def replay_last_turn(self) -> None:
        return None

    async def handle_audio(self, pcm: bytes) -> None:
        await asyncio.sleep(FRAME_MS / 1000 * STT_SLOWDOWN)
        self.audio_frames += 1

    async def handle_text(self, raw: str) -> None:
        self.control.append(raw)
        logger.info("server handled %s (after %d audio frames)", raw, self.audio_frames)

    async def handle_disconnect(self) -> None:
        logger.info(
            "server cleanup: %d audio frame(s), control=%s", self.audio_frames, self.control
        )


async def main() -> int:
    session = SlowSttSession()

    async def handler(websocket) -> None:
        await handle_connection(websocket, session=session)

    async with websockets.serve(
        handler, "127.0.0.1", 8802, max_size=None, ping_interval=1, ping_timeout=1
    ):
        async with websockets.connect("ws://127.0.0.1:8802", ping_interval=None) as socket:
            started = time.perf_counter()
            await socket.send('{"type":"speech_start","turn_id":1}')
            for _ in range(int(SPEECH_SECONDS * 1000 / FRAME_MS)):
                await socket.send(b"\x00" * (24_000 * 2 * FRAME_MS // 1000))
                await asyncio.sleep(FRAME_MS / 1000)
            await socket.send('{"type":"speech_end"}')
            logger.info(
                "client spoke for %.1fs; now waiting quietly, as the app does while "
                "the reply is generated",
                time.perf_counter() - started,
            )
            try:
                await asyncio.wait_for(socket.wait_closed(), timeout=IDLE_WAIT_SECONDS)
            except asyncio.TimeoutError:
                logger.info("PASS -- still connected after %ds idle", IDLE_WAIT_SECONDS)
                return 0
            logger.error(
                "FAIL -- server hung up %.1fs in: code=%s reason=%r",
                time.perf_counter() - started,
                socket.close_code,
                socket.close_reason,
            )
            return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
