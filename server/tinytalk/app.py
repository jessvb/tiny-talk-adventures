"""WebSocket entry point.

Binary frames are mic audio; text frames are JSON control messages.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
from collections import deque

import websockets
from websockets.exceptions import ConnectionClosed

from . import config
from .audio import MIC_SAMPLE_RATE
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .image_gen import ImageGenBackend, StableDiffusionBackend
from .llm_groq import GroqLlm
from .llm_ollama import OllamaLlm
from .protocol import encode_error
from .session import SessionRunner, Transport
from .stt_kyutai import KyutaiStt
from .tts_kokoro import KokoroTts

logger = logging.getLogger(__name__)

# Ceiling on how many not-yet-processed inbound frames may sit in this
# server's own queue. Deliberately generous: with reading decoupled from
# processing (see handle_connection), the queue holds at most the tail of
# a single utterance -- a few hundred KB -- and the child's own VAD ends
# utterances long before this. It exists purely so a misbehaving client
# that streams audio forever without ever sending speech_end grows memory
# to a bounded ceiling rather than without limit.
INBOUND_QUEUE_MAXSIZE = 512

# How much unprocessed speech may pile up before the server says out loud
# that STT is not keeping up. Decoupling the read loop from processing (see
# handle_connection) stopped a backlog from killing the connection, but it
# cannot make STT any faster -- and a backlog now shows up as the app simply
# waiting, with the server logging absolutely nothing. That silence is what
# made the real incident take an hour to diagnose (thirteen minutes of solid
# GPU work, not one line of output), so a backlog past a couple of seconds
# gets said plainly, once per utterance.
STT_LAG_WARN_SECONDS = 3.0

# Ceiling on how long a connection that has already gone away may keep
# working through what it had already read. Some of it is worth finishing --
# a speech_end read just before the socket died is what starts the turn a
# reconnect can be given (see the finally block) -- but only for a bounded
# time. Confirmed on real hardware from a live stack dump: with STT running
# slower than realtime, one wedged connection sat here for THIRTEEN MINUTES
# after the phone was gone, pinning the GPU and holding the shared session
# hostage (handle_disconnect() runs only once this finishes). Comfortably
# clears a healthy queue plus one STT flush (measured worst case ~8s).
POST_DISCONNECT_DRAIN_SECONDS = 20.0

# Control frames meaning "the utterance that was in progress is over and
# is being thrown away". Any audio still queued AHEAD of one of these
# belongs to that abandoned utterance, so feeding it to STT is pure waste
# -- and at roughly 4x realtime (measured on this hardware), waste that
# actively builds the backlog this whole design exists to avoid.
# speech_end is deliberately NOT in this set: the audio queued ahead of it
# is exactly that utterance's content. conclude_story belongs here too --
# SessionRunner.handle_conclude_story() resets STT and abandons an
# in-progress utterance exactly like an interrupt does (see session.py).
_UTTERANCE_ABANDONING_TYPES = frozenset(
    {"speech_start", "interrupt", "new_story", "conclude_story"}
)


def _abandons_queued_utterance(raw: str) -> bool:
    """Cheap, lenient peek at a control frame's type.

    Deliberately does not go through decode_client_message(): a malformed
    frame is the dispatch worker's problem to report properly, and the
    reader must never do anything that can raise or take real time."""
    try:
        payload = json.loads(raw)
        return payload.get("type") in _UTTERANCE_ABANDONING_TYPES
    except (ValueError, AttributeError):
        return False


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
    transport: Transport, *, stt: SttEngine, llm: LlmEngine, tts: TtsEngine,
    image_backend: ImageGenBackend | None = None,
) -> SessionRunner:
    return SessionRunner(transport=transport, stt=stt, llm=llm, tts=tts, image_backend=image_backend)


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
    so an in-flight or just-finished turn can still reach the child.

    Reading the socket and processing what was read are two separate tasks,
    and that separation is load-bearing rather than stylistic. It is the fix
    for a real, reproduced bug: the server killing its own perfectly healthy
    connection roughly 40 seconds after the child said something.

    The mechanism, confirmed against websockets 17.1's own source
    (asyncio/connection.py wires the frame assembler's high-water mark
    straight to `transport.pause_reading`): once more than `max_queue` (16
    by default) frames are waiting to be handed to application code,
    websockets stops reading the TCP socket entirely. Not just data frames
    -- ALL bytes, including the client's keepalive PONG. The keepalive task
    then hits `ping_interval + ping_timeout` (20 + 20 = the observed 40s)
    without seeing a pong and closes the connection as dead, with the
    control frame that was queued behind the audio (a speech_end, say)
    never processed at all.

    Processing here is far slower than the inbound stream -- KyutaiStt.feed()
    decodes at roughly 4x realtime on this hardware -- so awaiting it inline
    in the read loop meant every utterance longer than a second or two built
    a backlog, paused the socket, and started a 40-second fuse. Short
    utterances finished draining in time and survived, which is exactly why
    it presented as a random disconnect rather than a reproducible one.

    So: the reader below does nothing that can block. It drains frames into
    `inbound` and immediately goes back to the socket, which keeps pongs
    flowing no matter how far behind processing falls. Ordering is fully
    preserved -- one worker consumes the queue serially, exactly as the
    single inline loop used to."""
    transport = WebSocketTransport(websocket)
    session.rebind_transport(transport)
    # This handler outlives its own socket by however long the drain in the
    # finally block takes, so "am I still the connection driving this
    # session?" stops being obvious and has to be asked explicitly -- see
    # rebind_transport()'s docstring for what goes wrong otherwise.
    generation = session.transport_generation
    logger.info("client connected")
    # Deliver anything left over from before this connection existed --
    # a turn that finished (or made partial progress) while nobody was
    # connected to hear it. A no-op if there's nothing buffered.
    await session.replay_last_turn()
    await session.resend_current_status()

    # A deque rather than an asyncio.Queue purely because a barge-in needs
    # to remove already-queued audio from the middle (see the reader loop);
    # asyncio.Queue offers no way to do that.
    inbound: deque[str | bytes] = deque()
    arrived = asyncio.Event()
    reader_done = False
    dropped_audio_frames = 0
    # Unprocessed speech still sitting in `inbound`, in bytes. Tracked
    # incrementally rather than summed on demand so the reader stays free of
    # anything that grows with queue depth. See STT_LAG_WARN_SECONDS.
    queued_audio_bytes = 0
    lag_reported = False

    async def dispatch(message: str | bytes) -> None:
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

    async def process_inbound() -> None:
        """Consumes `inbound` serially, for as long as the reader is alive
        or anything is still queued. `arrived` is cleared BEFORE the drain,
        not after: clearing afterwards would discard a wakeup posted by the
        reader while this was mid-dispatch, and the worker would sleep on a
        non-empty queue."""
        nonlocal queued_audio_bytes
        while session.transport_generation == generation:
            arrived.clear()
            while inbound and session.transport_generation == generation:
                message = inbound.popleft()
                if isinstance(message, bytes):
                    queued_audio_bytes -= len(message)
                await dispatch(message)
            if reader_done:
                return
            await arrived.wait()
        logger.info("stopping message processing -- a newer connection owns the session")

    worker = asyncio.create_task(process_inbound())
    try:
        async for message in websocket:
            if isinstance(message, str) and _abandons_queued_utterance(message):
                stale = [item for item in inbound if isinstance(item, bytes)]
                if stale:
                    kept = [item for item in inbound if not isinstance(item, bytes)]
                    inbound.clear()
                    inbound.extend(kept)
                    queued_audio_bytes = 0
                    lag_reported = False
                    logger.info(
                        "barge-in: dropped %d queued audio frame(s) belonging to the "
                        "abandoned utterance",
                        len(stale),
                    )
            elif isinstance(message, bytes) and len(inbound) >= INBOUND_QUEUE_MAXSIZE:
                # Only ever audio: dropping a speech_end/interrupt would
                # strand the session waiting for something that never comes.
                dropped_audio_frames += 1
                continue
            inbound.append(message)
            if isinstance(message, bytes):
                queued_audio_bytes += len(message)
                queued_seconds = queued_audio_bytes / (2 * MIC_SAMPLE_RATE)
                if queued_seconds >= STT_LAG_WARN_SECONDS and not lag_reported:
                    lag_reported = True
                    logger.warning(
                        "STT is running behind realtime -- %.1fs of speech is queued and "
                        "still undecoded. The child's turn cannot start until it drains, "
                        "so expect a long wait. Check for memory pressure (a swapped-out "
                        "model decodes far slower) and see TINYTALK_STT_REPO.",
                        queued_seconds,
                    )
            arrived.set()
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
        # Let the worker finish what the socket already delivered before
        # tearing anything down -- the same semantics the old inline loop
        # had, where a message that had been read was always fully handled.
        # This matters for a real case: the child speaks and immediately
        # backgrounds the app, so speech_end is already in the queue when
        # the socket dies. Draining it is what starts the turn that
        # replay_last_turn() later delivers on reconnect.
        reader_done = True
        arrived.set()
        try:
            await asyncio.wait_for(worker, POST_DISCONNECT_DRAIN_SECONDS)
        except asyncio.TimeoutError:
            # wait_for has already cancelled the worker. Whatever was still
            # queued belonged to an utterance whose owner is gone, and
            # handle_disconnect() below abandons the partial utterance and
            # resets STT, so nothing is left half-fed.
            logger.warning(
                "gave up draining this connection's backlog after %.0fs -- %d message(s) "
                "still queued when the client was already gone. STT is running far behind "
                "realtime; see the warning above.",
                POST_DISCONNECT_DRAIN_SECONDS,
                len(inbound),
            )
        if dropped_audio_frames:
            logger.warning(
                "dropped %d audio frame(s): more than %d frames were queued unprocessed "
                "-- the client streamed audio without ever ending the utterance",
                dropped_audio_frames,
                INBOUND_QUEUE_MAXSIZE,
            )
        if session.transport_generation != generation:
            # A newer connection took the session over while this one was
            # draining. Its cleanup is not ours to run: handle_disconnect()
            # resets STT mid-utterance, which would wipe an utterance the
            # new connection has already started. (Written as an if/else
            # rather than an early return -- a `return` inside `finally`
            # silently swallows whatever exception was propagating.)
            logger.info("client disconnected (session already owned by a newer connection)")
        else:
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
    image_backend = StableDiffusionBackend()
    # One SessionRunner for the server's whole lifetime, not one per
    # connection -- see session.py's module docstring. This is what lets a
    # reply survive the phone app being backgrounded and reconnecting:
    # rebind_transport()/replay_last_turn() move it onto each new
    # connection in turn, rather than a fresh, memory-less session starting
    # over every time.
    session = build_session(NullTransport(), stt=stt, llm=llm, tts=tts, image_backend=image_backend)

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
        handler,
        config.SERVER_HOST,
        config.SERVER_PORT,
        max_size=None,
        # Spelled out rather than left implicit, because these two defaults
        # ARE the disconnect bug's stopwatch: websockets closes a connection
        # ping_interval + ping_timeout (20 + 20 = 40s) after the last pong it
        # managed to read. When the read loop was gated on STT (see
        # handle_connection), a paused socket meant pongs went unread and
        # this fired on a connection that was perfectly healthy. Left at the
        # library defaults on purpose -- with reading decoupled, a keepalive
        # timeout now means what it should: the network really is gone.
        ping_interval=20,
        ping_timeout=20,
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
