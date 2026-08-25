"""WebSocket entry point.

Binary frames are mic audio; text frames are JSON control messages.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal

import websockets
from websockets.exceptions import ConnectionClosed

from . import config
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .llm_groq import GroqLlm
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
        await self._send(payload)

    async def send_bytes(self, payload: bytes) -> None:
        await self._send(payload)

    async def _send(self, payload: str | bytes) -> None:
        try:
            await self._websocket.send(payload)
        except ConnectionClosed:
            # The client is already gone -- a network drop, the phone app
            # backgrounded, or (most commonly, observed on real hardware)
            # the server itself shutting down while an in-flight STT/LLM/TTS
            # call for this connection was still running. There is nobody
            # to receive this send either way. Swallowing it here, rather
            # than letting it propagate, is what stops a single dead
            # connection from producing a second, confusing failure on top
            # of whatever already happened -- handle_connection's own
            # `async for message in websocket` loop notices the closed
            # connection and unwinds normally on its own.
            logger.warning("could not send -- connection already closed")


class NullTransport:
    """Placeholder transport for the brief window between server startup and
    the first real connection -- SessionRunner requires a transport at
    construction time, but nothing can be in flight to send before any
    client has ever connected. rebind_transport() replaces this with a real
    WebSocketTransport on first connect and it is never used again."""

    async def send_text(self, payload: str) -> None:  # pragma: no cover - unreachable
        pass

    async def send_bytes(self, payload: bytes) -> None:  # pragma: no cover - unreachable
        pass


def build_session(
    transport: Transport, *, stt: SttEngine, llm: LlmEngine, tts: TtsEngine
) -> SessionRunner:
    return SessionRunner(transport=transport, stt=stt, llm=llm, tts=tts)


def build_llm() -> LlmEngine:
    if config.LLM_BACKEND == "groq":
        return GroqLlm()
    return OllamaLlm()


async def handle_connection(
    websocket,
    *,
    session: SessionRunner,
) -> None:
    """One call per WebSocket connection, but `session` is shared across all
    of them (see serve()) -- a reconnect after the phone app was backgrounded
    rebinds the SAME session onto the new socket rather than starting fresh,
    so an in-flight or just-finished turn can still reach the child."""
    transport = WebSocketTransport(websocket)
    session.rebind_transport(transport)
    logger.info("client connected")
    # Deliver anything left over from before this connection existed --
    # a turn that finished (or made partial progress) while nobody was
    # connected to hear it. A no-op if there's nothing buffered.
    await session.replay_last_turn()
    try:
        async for message in websocket:
            try:
                if isinstance(message, bytes):
                    await session.handle_audio(message)
                else:
                    await session.handle_text(message)
            except EngineError as exc:
                logger.error("engine failure handling message: %s", exc)
                await transport.send_text(encode_error(str(exc), session.current_turn_id))
            except Exception:  # noqa: BLE001 - one bad frame must not kill the socket
                logger.exception("unexpected failure handling message")
                await transport.send_text(encode_error("internal error", session.current_turn_id))
    except ConnectionClosed:
        # `async for message in websocket` itself raises this when the
        # connection drops abnormally mid-read (e.g. a keepalive ping
        # timeout after the phone app backgrounds, or a WiFi hiccup) rather
        # than via a clean close handshake -- distinct from
        # WebSocketTransport._send's own ConnectionClosed handling, which
        # only covers outgoing sends. A normal real-world occurrence, not a
        # bug: the finally below still runs the exact same session cleanup
        # as a clean disconnect. Caught here so it doesn't propagate as an
        # unhandled exception and produce a scary traceback in the logs
        # for something expected.
        logger.info("connection dropped abnormally (not a clean close)")
    finally:
        # Deliberately session.handle_disconnect(), not session.aclose():
        # an in-flight turn (e.g. the child backgrounded the app while
        # waiting for a reply) must be left running, not cancelled -- see
        # handle_disconnect()'s docstring. The session survives; only this
        # one connection is going away.
        await session.handle_disconnect()
        logger.info("client disconnected")


async def serve() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    logger.info(
        "listening on ws://%s:%s (llm_backend=%s, model=%s, think=%s)",
        config.SERVER_HOST,
        config.SERVER_PORT,
        config.LLM_BACKEND,
        config.GROQ_MODEL if config.LLM_BACKEND == "groq" else config.OLLAMA_MODEL,
        # Groq doesn't have a "thinking" toggle in this codebase; only
        # meaningful for the Ollama backend, but always shown for
        # visibility -- confirming this at a glance (rather than only via
        # request-body inspection) is exactly what would have saved a
        # round of real debugging on 2026-08-25.
        config.OLLAMA_THINK if config.LLM_BACKEND == "ollama" else "n/a",
    )

    # Built once and shared across every connection: each of these lazily
    # loads a multi-GB model on first use and caches it for its own
    # lifetime. Constructing fresh ones per connection (the original design)
    # meant every reconnect reloaded gigabytes of weights from disk from
    # scratch for no reason -- confirmed wasteful by inspection (KyutaiStt
    # and KokoroTts both cache their model on first use per-instance, so a
    # new instance always pays that cost again). Sharing is safe because
    # none of the three carry cross-utterance state except KyutaiStt's
    # buffer, which SessionRunner.handle_disconnect() resets when a
    # disconnect lands mid-utterance. See the design spec's "Open questions
    # / risks" for the separate, larger finding this benchmarking surfaced:
    # running all three models concurrently is a real memory-pressure risk
    # on a 16GB Mac, traced to Ollama's own inference rather than to engine
    # construction here.
    stt = KyutaiStt()
    llm = build_llm()
    tts = KokoroTts()
    # One SessionRunner for the server's whole lifetime, not one per
    # connection -- see session.py's module docstring. This is what lets a
    # reply survive the phone app being backgrounded and reconnecting:
    # rebind_transport()/replay_last_turn() move it onto each new
    # connection in turn, rather than a fresh, memory-less session starting
    # over every time.
    session = build_session(NullTransport(), stt=stt, llm=llm, tts=tts)

    # Tracks connection handler tasks currently in flight, so shutdown can
    # wait for them to finish naturally instead of tearing an actively-
    # connected client down mid-computation. Confirmed on real hardware:
    # Ctrl+C during an in-flight STT call (asyncio.to_thread, can run
    # 5-20+ real seconds) does not stop that background thread --
    # ThreadPoolExecutor's own atexit handling makes the interpreter wait
    # for it regardless, uncontrolled, and by the time it finishes the
    # connection is usually already torn down, so the final send fails with
    # a raw ConnectionClosedError -- observed to sometimes cascade into a
    # native bus error crash. Waiting for it HERE, explicitly and visibly,
    # is the same wait that was going to happen anyway, but keeps the
    # connection alive long enough for that final send to actually succeed
    # normally. This no longer covers an in-flight *turn* left running for
    # an already-disconnected client (handle_disconnect() deliberately
    # doesn't wait for those) -- the explicit session.aclose() below covers
    # that instead.
    active_connections: set[asyncio.Task] = set()

    async def handler(websocket) -> None:
        task = asyncio.current_task()
        assert task is not None
        active_connections.add(task)
        try:
            await handle_connection(websocket, session=session)
        finally:
            active_connections.discard(task)

    shutdown_requested = asyncio.Event()

    def on_sigint() -> None:
        if shutdown_requested.is_set():
            # Second Ctrl+C: the operator has explicitly asked not to wait.
            # os._exit skips further Python-level cleanup (including
            # ThreadPoolExecutor's own atexit wait) on purpose -- this is
            # the deliberate "I know, stop now anyway" escape hatch.
            logger.warning("second Ctrl+C -- forcing immediate exit")
            os._exit(1)
        logger.info("shutting down -- press Ctrl+C again to force immediate exit")
        shutdown_requested.set()

    asyncio.get_running_loop().add_signal_handler(signal.SIGINT, on_sigint)

    async with websockets.serve(
        handler, config.SERVER_HOST, config.SERVER_PORT, max_size=None
    ):
        await shutdown_requested.wait()
        logger.info("no longer accepting new connections")
        if active_connections:
            logger.info(
                "waiting for %d in-flight connection(s) to finish "
                "(an active STT/LLM/TTS call can take up to ~20s)",
                len(active_connections),
            )
            await asyncio.gather(*active_connections, return_exceptions=True)
        # A turn left running for an already-disconnected client (see
        # handle_disconnect()) isn't tied to any connection task, so the
        # gather above doesn't wait for it -- cancel it explicitly here
        # rather than abandoning it mid-computation as the process exits.
        await session.aclose()


def main() -> None:
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        # Only reachable if Ctrl+C lands before serve() registers its own
        # SIGINT handler (e.g. during model loading at startup, before
        # add_signal_handler runs) -- everything after that point is
        # handled by on_sigint()/shutdown_requested instead. A plain
        # message here beats an unhandled-KeyboardInterrupt traceback for
        # that narrow window.
        logger.info("shutting down")


if __name__ == "__main__":
    main()
