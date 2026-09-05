"""Session orchestration, persistent across reconnects.

One SessionRunner per *household*, not per WebSocket connection: app.py
constructs it once at server startup and rebinds it onto whichever
connection is current (rebind_transport()) as the phone app disconnects and
reconnects (e.g. iOS backgrounding it while a reply is in flight). The turn
(LLM generation plus TTS playback) runs as its own asyncio task so that an
interrupt can cancel it mid-flight — that cancellation, and recording what
the agent had already said, is the core of the barge-in behaviour. A plain
disconnect (as opposed to an interrupt) deliberately does NOT cancel an
in-flight turn: it is left running, and everything it sends is buffered so
it can be replayed in full to whichever connection asks for it next. See
replay_last_turn() and handle_disconnect().
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Protocol

from . import config, safety, story_store
from .animal_facts import AnimalFactTracker
from .audio import TTS_SAMPLE_RATE, split_sentences
from .conversation import Conversation
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .object_recognition import ObjectTracker
from .protocol import (
    Interrupt,
    NewStory,
    ObjectSeen,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    decode_client_message,
    encode_error,
    encode_response_text,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)
from .state import Event, InvalidTransition, State, TurnStateMachine
from .story_arc import StoryArc

logger = logging.getLogger(__name__)

# Shown to the LLM (appended to the per-turn guidance) whenever STT heard
# something -- the VAD's amplitude threshold fired, so a turn genuinely
# started -- but transcribed no recognizable words: background noise,
# fabric rustling against the mic, a bump. Real on-device testing found
# this genuinely happens, and the old behavior (silently ending the turn
# with no reply at all) read as the app breaking rather than mishearing.
# Deliberately doesn't ask the model to say "I didn't understand you" or
# similar -- from the child's perspective nothing went wrong, there's
# just nothing new to react to, so the natural move is to nudge the story
# forward using what's already happened, same as picking back up after a
# pause.
_STT_FAILURE_GUIDANCE = (
    "You didn't hear anything new from the child just now -- it might "
    "have been background noise. Don't mention this or ask them to "
    "repeat themselves. Instead, gently continue the story yourself "
    "using what's already happened, and end with an easy, inviting "
    "question so they have a natural opening to jump back in."
)


class Transport(Protocol):
    async def send_text(self, payload: str) -> None: ...
    async def send_bytes(self, payload: bytes) -> None: ...


class SessionRunner:
    def __init__(
        self,
        transport: Transport,
        stt: SttEngine,
        llm: LlmEngine,
        tts: TtsEngine,
        *,
        system_prompt: str = config.SYSTEM_PROMPT,
        conversation: Conversation | None = None,
    ) -> None:
        self._transport = transport
        # Starts at 0 rather than 1: app.py builds this session around a
        # NullTransport before any client exists, and the first real
        # connection's rebind_transport() is what makes it generation 1.
        self._transport_generation = 0
        # Guards every actual transport send (both a live turn's own sends
        # and replay_last_turn()'s catch-up sends) so the two can never
        # interleave: without this, a reconnect landing mid-turn could let a
        # newly-generated chunk reach the client before the buffered ones
        # that logically precede it.
        self._transport_lock = asyncio.Lock()
        self._stt = stt
        self._llm = llm
        self._tts = tts
        self._system_prompt = system_prompt
        self._conversation = conversation or Conversation()
        self._story_arc = StoryArc()
        self._animal_facts = AnimalFactTracker()
        self._object_recognition = ObjectTracker()
        self._machine = TurnStateMachine()
        self._turn_task: asyncio.Task | None = None
        # (sentence text, estimated real-world time.monotonic() at which
        # the child would actually have finished HEARING it) -- see
        # _run_turn()'s TTS loop and _cancel_turn() for why "sent" and
        # "heard" are tracked separately. Only meaningful while a turn is
        # in flight; always cleared to [] once a turn ends or is cancelled.
        self._spoken: list[tuple[str, float]] = []
        # Everything _run_turn() has sent for the CURRENT turn (response
        # text, each audio chunk, turn_end), in order -- see
        # replay_last_turn(). Cleared only when a genuinely new turn starts
        # (_finish_listening), not on disconnect: a reply nobody has heard
        # yet must survive across a reconnect.
        self._turn_replay_buffer: list[tuple[str, str | bytes]] = []
        # See protocol.py's module docstring for why this exists: the
        # client assigns a new turn_id on every speech_start/interrupt, and
        # every event this session sends is stamped with whichever turn_id
        # it was most recently told, so the client can tell a late reply
        # for an utterance it has already abandoned apart from a reply for
        # its current one.
        self._current_turn_id = 0

    @property
    def state(self) -> State:
        return self._machine.state

    @property
    def conversation(self) -> Conversation:
        return self._conversation

    @property
    def current_turn_id(self) -> int:
        return self._current_turn_id

    async def handle_text(self, raw: str) -> None:
        try:
            message = decode_client_message(raw)
        except ProtocolError as exc:
            logger.warning("bad control frame: %s", exc)
            await self._transport.send_text(encode_error(str(exc), self._current_turn_id))
            return

        match message:
            case SpeechStart(turn_id=turn_id):
                await self._start_listening(turn_id)
            case SpeechEnd():
                await self._finish_listening()
            case Interrupt(turn_id=turn_id):
                await self._interrupt(turn_id)
            case ObjectSeen(label=label):
                # The feature's one safety decision -- log receipt and the
                # accept/discard outcome here rather than threading logging
                # into ObjectTracker.record_seen() itself: safety.is_safe()
                # is a cheap, pure check (see safety.py), so re-running it
                # here purely for visibility, right before the same check
                # runs for real inside record_seen(), is fine.
                accepted = safety.is_safe(label)
                logger.info("object_seen: %r (accepted=%s)", label, accepted)
                self._object_recognition.record_seen(label)
            case NewStory():
                await self.handle_new_story()

    async def handle_new_story(self) -> None:
        """Abandon the current story (if any) and start fresh, without
        tearing down the connection or session -- a debug/testing
        affordance for resetting without a full reconnect. Cancels any
        in-flight turn (nothing to salvage -- the story it belonged to is
        being discarded) and clears the replay buffer, so nothing from the
        old story can ever be replayed to a later connection under a
        turn_id the new story reuses. Deliberately does NOT reset
        _current_turn_id: turn_id just keeps incrementing across stories
        within the same connection, the same way it already does across
        ordinary turns -- resetting it would risk exactly the kind of
        turn_id collision this whole area of the codebase already has
        enough trouble with."""
        await self._cancel_turn(record_spoken=False)
        if self._machine.state is State.LISTENING:
            self._stt.reset()
        self._turn_replay_buffer = []
        self._conversation = Conversation()
        self._story_arc = StoryArc()
        self._animal_facts = AnimalFactTracker()
        self._object_recognition = ObjectTracker()
        self._machine = TurnStateMachine()
        # Said out loud because the child tapping "New Story" is a real
        # event with no other trace: everything above is a silent in-memory
        # reset, so a log that didn't mention it left no way to tell whether
        # the tap had even reached the server. turn_id is included precisely
        # because it does NOT reset here -- that surprises people (the app
        # displays it as "Turn"), so the log should say it plainly.
        logger.info(
            "new story: conversation, story arc and replay buffer cleared "
            "(turn_id stays at %d -- it numbers messages, not story turns)",
            self._current_turn_id,
        )

    async def handle_audio(self, pcm: bytes) -> None:
        # Audio arriving outside LISTENING is stale — a frame in flight when
        # the utterance ended. Dropping it is correct, not an error.
        if self._machine.state is not State.LISTENING:
            return
        # KyutaiStt.feed() now decodes incrementally (a real MLX forward
        # pass per audio chunk, not just a buffer append -- see
        # stt_kyutai.py's module docstring for why), so it needs the same
        # off-the-event-loop treatment as finish()'s to_thread usage below,
        # for the same reason: keep it from stalling the process-wide event
        # loop and websocket keepalive for its duration.
        partial = await asyncio.to_thread(self._stt.feed, pcm)
        if partial:
            await self._transport.send_text(
                encode_transcript_partial(partial, self._current_turn_id)
            )

    async def wait_for_turn(self) -> None:
        """Await the in-flight turn to finish naturally. Test-only -- real
        callers never block a connection on this; see handle_disconnect()
        and replay_last_turn() for how a turn's result actually reaches a
        (possibly different) client."""
        if self._turn_task is not None:
            await asyncio.gather(self._turn_task, return_exceptions=True)

    @property
    def transport_generation(self) -> int:
        """Bumped by every rebind_transport() call, so a connection handler
        can tell whether it still owns this session. Exactly one connection
        does at a time -- see rebind_transport()'s docstring."""
        return self._transport_generation

    def rebind_transport(self, transport: Transport) -> None:
        """Point this session at a new connection's transport. Called by
        app.py on every connect, including a reconnect after a disconnect
        mid-turn -- the still-running turn task's own sends (guarded by
        _transport_lock, same as replay_last_turn()) will start reaching
        the new connection as soon as this returns.

        Bumping the generation here is what makes "the newest connection
        owns the session" enforceable rather than merely conventional. It
        matters because a handler outlives its own socket by however long
        it takes to finish processing what that socket already delivered
        (see app.py's handle_connection): without this, a reconnect landing
        during that window would have two handlers feeding the one shared
        streaming STT session -- interleaving two utterances into a single
        transcript, running two MLX calls from two threads at once, and
        letting the older handler's handle_disconnect() reset an utterance
        the newer connection had already started."""
        logger.info("transport rebound (session state=%s)", self._machine.state.name)
        self._transport = transport
        self._transport_generation += 1

    async def replay_last_turn(self) -> None:
        """Resend everything buffered for the current/most recent turn to
        whichever transport is current -- call after rebind_transport() on
        every new connection. If the turn already finished before this
        connection arrived, this delivers the whole reply at once; if it's
        still in flight, this is a catch-up burst of whatever's landed so
        far, after which the turn's own live sends continue seamlessly (the
        shared lock makes the two mutually exclusive, so ordering is
        preserved either way). A no-op if nothing is buffered -- e.g. a
        fresh session, or a turn already superseded by a new utterance.

        Deliberately does NOT clear the buffer after replaying -- an
        earlier version did, on the theory that a reply already fully
        heard live shouldn't be replayed again to some later, unrelated
        reconnect (real annoyance, confirmed on real hardware). That
        traded a mild annoyance for a worse bug, also confirmed on real
        hardware: a connection that itself dies quickly after reconnecting
        (e.g. the child backgrounding the app twice in a row) would
        consume the ONE replay attempt without ever actually getting to
        hear it, silently losing the reply for good -- no other connection
        would ever get a turn at it. There is no reliable server-side
        signal for "the child genuinely heard this" (a send not raising
        does not mean it reached a live listener -- see WebSocketTransport
        -- so a connection can go quiet for a long time before the server
        even notices it is gone). Given that, losing a reply the child is
        actively still trying to catch up on is worse than occasionally
        replaying one they already heard, so this only ever gets
        forgotten once a genuinely new utterance starts (see
        _finish_listening's buffer reset) -- the one unambiguous signal
        that the child is not waiting on this reply anymore.
        """
        async with self._transport_lock:
            if not self._turn_replay_buffer:
                logger.debug("replay_last_turn: nothing buffered")
                return
            logger.info(
                "replaying %d buffered item(s) for turn_id=%s to the new connection",
                len(self._turn_replay_buffer),
                self._current_turn_id,
            )
            for kind, payload in self._turn_replay_buffer:
                if kind == "text":
                    await self._transport.send_text(payload)
                else:
                    await self._transport.send_bytes(payload)

    async def _send_and_buffer(self, *, text: str | None = None, audio: bytes | None = None) -> None:
        async with self._transport_lock:
            if text is not None:
                self._turn_replay_buffer.append(("text", text))
                await self._transport.send_text(text)
            else:
                assert audio is not None
                self._turn_replay_buffer.append(("bytes", audio))
                await self._transport.send_bytes(audio)

    async def handle_disconnect(self) -> None:
        """Called by app.py on every WebSocket disconnect (clean or
        abrupt). Unlike aclose(), this deliberately does NOT cancel an
        in-flight turn or unconditionally reset STT -- the session is
        persistent across reconnects (see rebind_transport()/
        replay_last_turn()), so a reply already being generated when the
        phone app is backgrounded should keep generating, ready to deliver
        whenever the child reopens the app. The one thing that does need
        cleanup here: a disconnect landing mid-utterance (LISTENING, before
        speech_end/stt.finish() ever ran) means STT's own per-utterance
        reset -- normally triggered by finish() -- never fired, which would
        otherwise leak partial audio into whatever the child says next."""
        logger.info(
            "handling disconnect (session state=%s, turn in flight=%s, replay buffer=%d item(s))",
            self._machine.state.name,
            self._turn_task is not None and not self._turn_task.done(),
            len(self._turn_replay_buffer),
        )
        if self._machine.state is State.LISTENING:
            self._stt.reset()
            self._transition(Event.ABANDON)

    async def aclose(self) -> None:
        """Full teardown: cancels any in-flight turn and resets STT.
        Distinct from handle_disconnect() (which a plain WebSocket drop
        uses) -- this is for when the session itself is going away, e.g.
        server shutdown, not for an ordinary reconnect-expected disconnect."""
        await self._cancel_turn(record_spoken=False)
        self._stt.reset()

    async def _start_listening(self, turn_id: int) -> None:
        if self._machine.state in (State.THINKING, State.SPEAKING):
            # A speech_start arriving mid-turn means the child started
            # talking again before the agent finished — that is an
            # interrupt in every way that matters (cancel in-flight work,
            # record what was already spoken, reset STT, land in
            # LISTENING), so handle it exactly like one instead of firing a
            # SPEECH_START transition that only exists from IDLE. (A
            # duplicate speech_start while already LISTENING is left as the
            # existing no-op below — nothing is in flight to abort.)
            await self._interrupt(turn_id)
            return
        await self._cancel_turn(record_spoken=True)
        self._current_turn_id = turn_id
        self._transition(Event.SPEECH_START)
        # Both of these get called "turn" and they are NOT the same thing.
        # turn_id is a protocol message-routing id: it exists so a reply
        # arriving after a reconnect can be matched to the utterance that
        # asked for it, and it deliberately never resets -- not across
        # stories, not on new_story (see handle_new_story). The story stage
        # is the one that actually tracks story progress, and it DOES reset.
        # The iOS debug UI shows turn_id, labelled just "Turn", which reads
        # exactly like story progress and is not: a real session produced
        # "the app still says turn 2 after New Story" and neither number
        # appeared anywhere in the log to settle it. Log both, together.
        logger.info(
            "utterance started: turn_id=%d, story stage %s",
            turn_id,
            self._story_arc.stage.name,
        )

    async def _finish_listening(self) -> None:
        if self._machine.state is not State.LISTENING:
            return
        self._transition(Event.SPEECH_END)
        # Captured once, not re-read from self._current_turn_id later in
        # this method or in _run_turn/_fail_turn: this utterance's events
        # must all carry the turn_id that was active when it started, even
        # though self._current_turn_id can only actually change again once
        # _cancel_turn() has awaited this turn's task to a full stop (an
        # interrupt/new speech_start cancels-and-awaits before updating
        # it) -- capturing makes that invariant explicit rather than
        # relying on the caller's ordering.
        turn_id = self._current_turn_id
        try:
            # KyutaiStt.finish() runs model inference (an MLX forward pass
            # over the whole utterance) — potentially 0.5-3s. Running it off
            # the event loop keeps that call from stalling the process-wide
            # event loop and websocket keepalive for its whole duration,
            # same reasoning as KokoroTts.synthesize's asyncio.to_thread
            # usage. It does NOT, today, let an interrupt for *this* session
            # be handled concurrently with this await: app.py's read loop
            # awaits each message handler serially, so an interrupt frame
            # can't even be read off the socket until this coroutine yields
            # control back. The state re-check right below exists for when
            # that changes -- if a future concurrency change does let an
            # interrupt interleave here, it will have moved self._machine's
            # state out from under us while we were suspended.
            stt_start = time.monotonic()
            transcript = await asyncio.to_thread(self._stt.finish)
            logger.info(
                "stt finish took %.1f ms -> %d chars: %r",
                (time.monotonic() - stt_start) * 1000,
                len(transcript),
                transcript,
            )
        except EngineError as exc:
            logger.error("engine failure finishing the utterance: %s", exc)
            await self._fail_turn(str(exc), turn_id)
            return
        if self._machine.state is not State.THINKING:
            # Something (an interrupt, once handling stops being serialized)
            # already moved the session elsewhere while we were suspended in
            # to_thread above. The transcript we just finished is stale --
            # discard it rather than building a reply to an utterance the
            # child has already interrupted.
            logger.info(
                "discarding stale transcript -- state is %s, not THINKING",
                self._machine.state,
            )
            return
        await self._transport.send_text(encode_transcript_final(transcript, turn_id))
        # An empty transcript still becomes a real turn (see
        # _STT_FAILURE_GUIDANCE) rather than ending in silence -- the VAD
        # already decided this was a genuine utterance attempt (that's how
        # execution reached here at all), STT just couldn't make out
        # words in it.
        self._spoken = []
        # A new turn supersedes whatever the previous one left buffered for
        # replay -- the child has moved the story forward, so there is
        # nothing left worth resuming from the old reply.
        self._turn_replay_buffer = []
        self._turn_task = asyncio.create_task(self._run_turn(transcript, turn_id))

    async def _interrupt(self, turn_id: int) -> None:
        interrupt_received = time.monotonic()
        await self._cancel_turn(record_spoken=True)
        self._stt.reset()
        self._current_turn_id = turn_id
        self._transition(Event.INTERRUPT)
        logger.info(
            "interrupt handled in %.1f ms",
            (time.monotonic() - interrupt_received) * 1000,
        )

    async def _cancel_turn(self, *, record_spoken: bool) -> None:
        task, self._turn_task = self._turn_task, None
        if task is None or task.done():
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            # `await task` raises CancelledError both when the turn task
            # itself finished being cancelled by our own `task.cancel()`
            # above (expected — swallow it) and when cancellation was aimed
            # at *this* coroutine instead (e.g. the connection handler being
            # cancelled during shutdown while sitting at this await). Since
            # we unconditionally call task.cancel() on every path here,
            # `task.cancelled()` is True in both cases and can't tell them
            # apart. `current_task().cancelling()` can: it reports whether
            # *our own* task has an outstanding cancellation request,
            # independent of what we did to the inner task. Only re-raise
            # when that's the case, so the caller's own cancellation isn't
            # silently absorbed.
            current = asyncio.current_task()
            if current is not None and current.cancelling():
                raise
        if record_spoken and self._spoken:
            # "Sent" is not "heard": network transfer + synthesis is much
            # faster than real-time audio playback (confirmed on real
            # hardware -- an entire multi-sentence reply can finish
            # SENDING in ~1-2s while its audio takes 5-8+s to actually
            # play), so by the time an interrupt lands, sentences can
            # already be recorded as "spoken" here that the child has not
            # actually finished hearing yet -- observed for real as later
            # story content (e.g. a character introduced in a sentence
            # that was sent, but not yet played) leaking into the
            # conversation history as if the child had heard it. Only
            # include sentences whose ESTIMATED real-world playback would
            # already be complete by now.
            now = time.monotonic()
            actually_heard = [text for text, complete_at in self._spoken if now >= complete_at]
            if actually_heard:
                self._conversation.add_agent(" ".join(actually_heard), interrupted=True)
        self._spoken = []

    async def _run_turn(self, transcript: str, turn_id: int) -> None:
        # Per-stage timing: this pipeline is a personal pet project running
        # on modest hardware (see CLAUDE.md), and latency was found to be
        # noticeably higher than the design's 1-2s target -- logging where
        # time actually goes (STT is timed separately, in
        # _finish_listening) beats guessing which of LLM generation or TTS
        # synthesis is the bottleneck before deciding what to optimize.
        turn_start = time.monotonic()
        try:
            self._conversation.add_child(transcript)  # no-op if transcript is empty
            guidance = self._story_arc.record_turn(transcript)
            fact_guidance = await self._animal_facts.record_turn(
                transcript, self._story_arc.stage
            )
            if fact_guidance:
                guidance = f"{guidance}\n\n{fact_guidance}"
            object_guidance = self._object_recognition.consume_guidance()
            if object_guidance:
                guidance = f"{guidance}\n\n{object_guidance}"
            if not transcript.strip():
                guidance = f"{guidance}\n\n{_STT_FAILURE_GUIDANCE}"
            messages = self._conversation.to_messages(
                self._system_prompt + "\n\n" + guidance
            )

            parts: list[str] = []
            llm_start = time.monotonic()
            first_chunk_at: float | None = None
            async for chunk in self._llm.stream_reply(messages):
                if first_chunk_at is None:
                    first_chunk_at = time.monotonic()
                parts.append(chunk)
            llm_done = time.monotonic()
            reply = safety.filter_reply("".join(parts).strip())
            self._story_arc.record_reply(reply)
            logger.info(
                "llm stream_reply: %.1f ms to first chunk, %.1f ms total (%d chars)",
                ((first_chunk_at or llm_done) - llm_start) * 1000,
                (llm_done - llm_start) * 1000,
                len(reply),
            )

            await self._send_and_buffer(text=encode_response_text(reply, turn_id))
            self._transition(Event.RESPONSE_READY)

            tts_start = time.monotonic()
            first_audio_at: float | None = None
            # Cumulative estimated audio duration (seconds) sent so far this
            # turn -- lets each sentence record when its own playback would
            # actually finish, not just when its bytes finished sending. See
            # _cancel_turn()'s doc comment for why this distinction matters.
            playback_offset = 0.0
            for sentence in split_sentences(reply):
                sentence_bytes = 0
                async for pcm in self._tts.synthesize(sentence):
                    if first_audio_at is None:
                        first_audio_at = time.monotonic()
                    await self._send_and_buffer(audio=pcm)
                    sentence_bytes += len(pcm)
                # PCM16 mono at the wire sample rate (audio.py) -- 2 bytes/sample.
                playback_offset += sentence_bytes / (2 * TTS_SAMPLE_RATE)
                # Recorded once fully sent, paired with its ESTIMATED
                # real-world playback-complete time (assuming the client
                # plays back starting at first_audio_at, at roughly
                # real-time pace) -- not just the raw text -- so an
                # interrupt can tell what was actually HEARD apart from
                # what was merely SENT.
                self._spoken.append((sentence, (first_audio_at or time.monotonic()) + playback_offset))
            tts_done = time.monotonic()
            logger.info(
                "tts synth+send: %.1f ms to first audio, %.1f ms total",
                ((first_audio_at or tts_done) - tts_start) * 1000,
                (tts_done - tts_start) * 1000,
            )

            self._conversation.add_agent(reply)
            self._spoken = []
            self._transition(Event.TTS_DONE)
            await self._send_and_buffer(text=encode_turn_end(turn_id))
            logger.info(
                "turn total (transcript -> turn_end): %.1f ms",
                (time.monotonic() - turn_start) * 1000,
            )
            if self._story_arc.is_done:
                saved_path = story_store.save_story(self._conversation)
                if saved_path is not None:
                    logger.info("story saved to %s", saved_path)
                self._conversation = Conversation()
                self._story_arc = StoryArc()
                self._animal_facts = AnimalFactTracker()
                self._object_recognition = ObjectTracker()
        except asyncio.CancelledError:
            raise
        except EngineError as exc:
            logger.error("engine failure during turn: %s", exc)
            await self._fail_turn(str(exc), turn_id)
        except Exception as exc:  # noqa: BLE001 - a session must survive one bad turn
            logger.exception("unexpected failure during turn")
            await self._fail_turn(f"internal error: {exc}", turn_id)

    async def _fail_turn(self, message: str, turn_id: int) -> None:
        # Restore state before sending: if the transport is dead (closed
        # socket mid-turn) send_text can raise, and the exception must not
        # leave the state machine stuck outside IDLE.
        self._spoken = []
        if self._machine.state is State.THINKING:
            self._transition(Event.RESPONSE_READY)
        if self._machine.state is State.SPEAKING:
            self._transition(Event.TTS_DONE)
        await self._transport.send_text(encode_error(message, turn_id))

    def _transition(self, event: Event) -> None:
        try:
            self._machine.handle(event)
        except InvalidTransition as exc:
            # Races are expected here (an interrupt landing as a turn ends);
            # log and keep the session alive rather than tearing it down.
            logger.debug("ignoring invalid transition: %s", exc)
