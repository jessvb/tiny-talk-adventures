"""WebSocket entry point.

Binary frames are mic audio; text frames are JSON control messages.
"""

from __future__ import annotations

import asyncio
import functools
import logging
from typing import Callable

import websockets

from . import config
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .llm_ollama import OllamaLlm
from .protocol import encode_error
from .session import SessionRunner, Transport
from .stt_kyutai import KyutaiStt
from .tts_kokoro import KokoroTts

logger = logging.getLogger(__name__)


class WebSocketTransport:
    def __init__(self, websocket) -> None:
        self._websocket = websocket

    async def send_text(self, payload: str) -> None:
        await self._websocket.send(payload)

    async def send_bytes(self, payload: bytes) -> None:
        await self._websocket.send(payload)


def build_session(
    transport: Transport, *, stt: SttEngine, llm: LlmEngine, tts: TtsEngine
) -> SessionRunner:
    return SessionRunner(transport=transport, stt=stt, llm=llm, tts=tts)


async def handle_connection(
    websocket,
    *,
    session_factory: Callable[[Transport], SessionRunner],
) -> None:
    transport = WebSocketTransport(websocket)
    session = session_factory(transport)
    logger.info("client connected")
    try:
        async for message in websocket:
            try:
                if isinstance(message, bytes):
                    await session.handle_audio(message)
                else:
                    await session.handle_text(message)
            except EngineError as exc:
                logger.error("engine failure handling message: %s", exc)
                await transport.send_text(encode_error(str(exc)))
            except Exception:  # noqa: BLE001 - one bad frame must not kill the socket
                logger.exception("unexpected failure handling message")
                await transport.send_text(encode_error("internal error"))
        await session.wait_for_turn()
    finally:
        await session.aclose()
        logger.info("client disconnected")


async def serve() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    logger.info(
        "listening on ws://%s:%s (model=%s)",
        config.SERVER_HOST,
        config.SERVER_PORT,
        config.OLLAMA_MODEL,
    )

    # Built once and shared across every connection: each of these lazily
    # loads a multi-GB model on first use and caches it for its own
    # lifetime. Constructing fresh ones per connection (the original design)
    # meant every reconnect reloaded gigabytes of weights from disk from
    # scratch for no reason -- confirmed wasteful by inspection (KyutaiStt
    # and KokoroTts both cache their model on first use per-instance, so a
    # new instance always pays that cost again). Sharing is safe because
    # none of the three carry cross-utterance state except KyutaiStt's
    # buffer, which SessionRunner.aclose() resets on every disconnect. See
    # the design spec's "Open questions / risks" for the separate, larger
    # finding this benchmarking surfaced: running all three models
    # concurrently is a real memory-pressure risk on a 16GB Mac, traced to
    # Ollama's own inference rather than to engine construction here.
    stt = KyutaiStt()
    llm = OllamaLlm()
    tts = KokoroTts()
    session_factory = functools.partial(build_session, stt=stt, llm=llm, tts=tts)
    handler = functools.partial(handle_connection, session_factory=session_factory)

    async with websockets.serve(
        handler, config.SERVER_HOST, config.SERVER_PORT, max_size=None
    ):
        await asyncio.Future()


def main() -> None:
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        logger.info("shutting down")


if __name__ == "__main__":
    main()
