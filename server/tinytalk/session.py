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

from . import config, safety, storybook, story_store, synced_storybook
from .animal_facts import AnimalFactTracker
from .audio import TTS_SAMPLE_RATE, split_sentences
from .conversation import Conversation, Turn
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .image_gen import ImageGenBackend
from .object_recognition import ObjectTracker
from .protocol import (
    ConcludeStory,
    GetPageImage,
    GetStory,
    Interrupt,
    ListStories,
    NewStory,
    ObjectSeen,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    SyncDemoStories,
    SynthesizePage,
    UpdateSettings,
    decode_client_message,
    encode_arc_stage,
    encode_error,
    encode_llm_backend,
    encode_page_audio_done,
    encode_page_image_done,
    encode_response_text,
    encode_rewriting_done,
    encode_rewriting_started,
    encode_story_detail,
    encode_story_list,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)
from .state import Event, InvalidTransition, State, TurnStateMachine
from .story_arc import Stage, StoryArc

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

# Fed back to the model when a forced-conclude reply gets flagged by the
# kid-safety check -- same idea as storybook.py's own _SAFETY_RETRY_TEMPLATE,
# but phrased for a single spoken reply rather than a JSON rewrite.
_CONCLUDE_SAFETY_RETRY_TEMPLATE = (
    "That reply isn't appropriate for a young child -- it mentioned: "
    "{terms}. Give the same warm, complete ending again, same story, but "
    "leave out any mention of that. Remember: this must be the last "
    "reply, and it should end with the words \"The end.\""
)

# Fed back when a forced-conclude attempt comes back empty -- confirmed on
# real hardware that simply resubmitting the exact same messages tends to
# reproduce the same empty completion again (the model has nothing new to
# react to), so this gives it something to actually respond to instead of
# just hoping resampling alone breaks the pattern.
_CONCLUDE_EMPTY_RETRY_NUDGE = (
    "You didn't write anything. Please write your ending now -- a few "
    "warm sentences that finish the story, ending with the words "
    "\"The end.\""
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
        image_backend: ImageGenBackend | None = None,
        groq_llm: LlmEngine | None = None,
        llm_backend: str = "ollama",
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
        # Server-mode backend toggle (issue #25, docs/superpowers/specs/
        # 2026-09-22-server-llm-backend-toggle-design.md). self._llm stays
        # the local (Ollama) engine; _groq_llm exists only when
        # GROQ_API_KEY was set at startup. _llm_backend is the parent's
        # preference, resolved into _story_llm once per story by
        # _begin_story() -- never mid-story.
        self._groq_llm = groq_llm
        self._llm_backend = llm_backend
        self._tts = tts
        # What self._tts was last told to use (issue #78) -- starts at the
        # engine's own startup default, config.KOKORO_VOICE.
        self._tts_voice = config.KOKORO_VOICE
        self._image_backend = image_backend
        self._system_prompt = system_prompt
        self._conversation = conversation or Conversation()
        self._target_turns = config.STORY_TARGET_TURNS
        self._page_count = config.STORYBOOK_PAGE_COUNT
        self._story_page_count = config.STORYBOOK_PAGE_COUNT
        self._begin_story()
        self._animal_facts = AnimalFactTracker()
        self._object_recognition = ObjectTracker()
        self._machine = TurnStateMachine()
        self._turn_task: asyncio.Task | None = None
        self._rewrite_task: asyncio.Task | None = None
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
            case ConcludeStory(turn_id=turn_id):
                await self.handle_conclude_story(turn_id)
            case ListStories():
                await self.handle_list_stories()
            case GetStory(story_id=story_id):
                await self.handle_get_story(story_id)
            case SynthesizePage(story_id=story_id, page_index=page_index):
                await self.handle_synthesize_page(story_id, page_index)
            case GetPageImage(story_id=story_id, page_index=page_index):
                await self.handle_get_page_image(story_id, page_index)
            case SyncDemoStories(stories=stories):
                await self.handle_sync_demo_stories(stories)
            case UpdateSettings(
                target_turns=target_turns,
                page_count=page_count,
                llm_backend=llm_backend,
                tts_voice=tts_voice,
            ):
                await self.handle_update_settings(
                    target_turns, page_count, llm_backend, tts_voice
                )

    async def handle_conclude_story(self, turn_id: int) -> None:
        """The "Finish this story" action: cancels whatever's in flight
        (same as a barge-in) and forces one final reply using
        StoryArc.force_conclude_guidance() instead of the normal
        stage-based guidance, then marks the story done unconditionally
        -- an explicit request to finish must not be able to silently
        fail to end just because the reply's wording doesn't happen to
        match the natural-conclusion phrase list."""
        if self._machine.state is State.REWRITING:
            logger.info(
                "conclude_story ignored -- a storybook rewrite is still in "
                "progress (turn_id=%d)",
                turn_id,
            )
            return
        await self._cancel_turn(record_spoken=True)
        if self._machine.state is State.LISTENING:
            self._stt.reset()
        self._current_turn_id = turn_id
        self._transition(Event.CONCLUDE)
        self._turn_replay_buffer = []
        logger.info("conclude_story: forcing a final reply for turn_id=%d", turn_id)
        self._turn_task = asyncio.create_task(
            self._run_turn("", turn_id, forced_conclude=True)
        )

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
        if self._machine.state is State.REWRITING:
            logger.info("new_story ignored -- a storybook rewrite is still in progress")
            return
        await self._cancel_turn(record_spoken=False)
        if self._machine.state is State.LISTENING:
            self._stt.reset()
        self._turn_replay_buffer = []
        self._conversation = Conversation()
        self._begin_story()
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

    async def handle_list_stories(self) -> None:
        stories = story_store.list_stories()
        await self._send_text_unbuffered(encode_story_list(stories))

    def _resolve_llm(self) -> tuple[LlmEngine, str]:
        """The engine the parent's current preference maps to: Groq only
        if it was asked for AND this server has one (GROQ_API_KEY set at
        startup), otherwise the local engine."""
        if self._llm_backend == "groq" and self._groq_llm is not None:
            return self._groq_llm, "groq"
        return self._llm, "ollama"

    def _begin_story(self) -> None:
        """One place where a story's settings are captured -- the arc's
        target_turns and the page count its eventual rewrite will use.
        See handle_update_settings for why this is also called from
        there (a change made while no story is in progress must still
        reach the next one, and __init__'s own StoryArc construction
        only ever runs once per SERVER PROCESS -- session.py's
        SessionRunner is a long-lived singleton rebind_transport() reuses
        across every connection, not something built fresh per
        connection, see app.py's serve())."""
        self._story_arc = StoryArc(target_turns=self._target_turns)
        self._story_page_count = self._page_count
        self._story_llm, self._story_llm_name = self._resolve_llm()
        if self._llm_backend == "groq" and self._story_llm_name != "groq":
            logger.warning(
                "groq requested but GROQ_API_KEY is not set on this server -- "
                "the next story will use ollama"
            )
        logger.info("next story llm: %s", self._story_llm_name)

    async def handle_update_settings(
        self,
        target_turns: int,
        page_count: int,
        llm_backend: str | None = None,
        tts_voice: str | None = None,
    ) -> None:
        """Parent-adjustable story-length settings from the Settings
        screen -- see protocol.py's UpdateSettings and this project's
        story-length-settings design spec. Clamped here (not at decode
        time in protocol.py) since this is a semantic/business-rule
        bound, not a protocol-validity concern -- an out-of-range value
        is well-formed, just outside what this app supports. Takes
        effect for the next story only: StoryArc()/_page_count are only
        ever read at the start of a story (see __init__, handle_new_story,
        and _run_turn's post-conclusion reset), so there is nothing
        in-flight to migrate."""
        self._target_turns = max(4, min(12, target_turns))
        self._page_count = max(3, min(10, page_count))
        if llm_backend is not None:
            self._llm_backend = llm_backend
        # __init__'s arc/page-count capture happens once per SERVER
        # PROCESS (see _begin_story's own doc comment), and the
        # post-conclusion reset captures the next story's settings
        # before the parent has had any chance to change anything -- so
        # "applies to the next story" needs the not-yet-started arc (and
        # its page count) rebuilt here too. An arc mid-story
        # (has_started) is deliberately left alone -- that's the "never
        # retroactively" half of the requirement.
        if not self._story_arc.has_started:
            self._begin_story()
        if tts_voice is not None:
            self._apply_tts_voice(tts_voice)
        _, active = self._resolve_llm()
        logger.info(
            "update_settings: target_turns=%d, page_count=%d, llm_backend=%s "
            "(active=%s) (will apply to the next story)",
            self._target_turns,
            self._page_count,
            self._llm_backend,
            active,
        )
        if llm_backend is not None:
            await self._send_text_unbuffered(
                encode_llm_backend(self._llm_backend, active, self._groq_llm is not None)
            )

    def _apply_tts_voice(self, voice: str) -> None:
        """The parent's "Home voice" choice (issue #78). Unlike the story
        settings above, this takes effect from the next synthesized
        sentence, not the next story -- a voice isn't part of a story.
        An ID outside config.KOKORO_VOICES (e.g. from a newer phone build
        that knows voices this server doesn't) is ignored rather than
        handed to Kokoro, which would try to download it from Hugging
        Face and fail the turn if it doesn't exist."""
        if voice not in config.KOKORO_VOICES:
            logger.warning("tts: ignoring unknown voice %r (keeping %s)", voice, self._tts_voice)
            return
        if voice == self._tts_voice:
            return
        # Runs on the event loop, same thread every synthesize() call
        # reads the voice from -- see KokoroTts.set_voice.
        self._tts.set_voice(voice)
        self._tts_voice = voice
        logger.info("tts: voice set to %s", voice)

    async def handle_get_story(self, story_id: str) -> None:
        story = story_store.load_story(story_id)
        if story is None:
            await self._send_text_unbuffered(
                encode_error(f"no saved story with id {story_id!r}", self._current_turn_id)
            )
            return
        pages = story.get("pages")
        client_pages = (
            [{"text": p["text"], "has_image": bool(p.get("image_path"))} for p in pages]
            if pages
            else pages
        )
        await self._send_text_unbuffered(
            encode_story_detail(
                {
                    "id": story["id"],
                    "title": story.get("title"),
                    "pages": client_pages,
                    "epilogue": story.get("epilogue"),
                    "rewrite_status": story.get("rewrite_status", "pending"),
                    "illustrations_status": story.get("illustrations_status"),
                }
            )
        )

    async def _page_or_error(self, story_id: str, page_index: int) -> list[dict] | None:
        """Shared bounds-check-and-error preamble for handle_synthesize_page
        and handle_get_page_image: loads the story once, validates
        story_id/page_index, and on any problem sends the client's error
        frame and returns None. Returning the already-loaded pages list
        (rather than just a bool) lets handle_get_page_image read that
        page's image_path directly off it instead of loading the story a
        second time via story_store.read_page_image()."""
        story = story_store.load_story(story_id)
        pages = story.get("pages") if story else None
        if not pages or page_index < 0 or page_index >= len(pages):
            await self._send_text_unbuffered(
                encode_error(
                    f"no page {page_index} for story {story_id!r}", self._current_turn_id
                )
            )
            return None
        return pages

    async def handle_synthesize_page(self, story_id: str, page_index: int) -> None:
        pages = await self._page_or_error(story_id, page_index)
        if pages is None:
            return
        text = pages[page_index]["text"]
        async with self._transport_lock:
            async for pcm in self._tts.synthesize(text):
                await self._transport.send_bytes(pcm)
            await self._transport.send_text(encode_page_audio_done(story_id, page_index))

    async def handle_get_page_image(self, story_id: str, page_index: int) -> None:
        pages = await self._page_or_error(story_id, page_index)
        if pages is None:
            return
        filename = pages[page_index].get("image_path")
        data: bytes | None = None
        if filename:
            try:
                data = (story_store.STORIES_DIR / filename).read_bytes()
            except OSError as exc:
                logger.error(
                    "failed to read page image for story %s page %d: %s",
                    story_id,
                    page_index,
                    exc,
                )
        async with self._transport_lock:
            if data is not None:
                await self._transport.send_bytes(data)
            await self._transport.send_text(
                encode_page_image_done(story_id, page_index, has_image=data is not None)
            )

    async def handle_sync_demo_stories(self, stories: tuple[dict, ...]) -> None:
        """Persists each story the phone completed away from home, then
        kicks off the same background rewrite pipeline a live story
        triggers -- see story_store.save_synced_story() and
        _run_rewrite(). Runs independent of self._machine's state
        (unlike the live-turn actions above): a synced batch has no
        relationship to whatever live story is or isn't in flight.

        A story may also carry a finished `storybook` the phone already
        wrote away from home (title, pages, illustrations). When it passes
        synced_storybook's validation the rewrite is skipped entirely --
        the phone's work is kept, not redone; otherwise (absent, or
        rejected as untrusted input) the story is rewritten from its
        transcript exactly as before."""
        for payload in stories:
            saved_path = story_store.save_synced_story(payload)
            if saved_path is None:
                continue
            story_id = story_store.story_id_from_path(saved_path)
            try:
                turns = [
                    Turn(
                        speaker=turn["speaker"],
                        text=turn["text"],
                        interrupted=turn.get("interrupted", False),
                    )
                    for turn in payload.get("turns", [])
                ]
            except (KeyError, TypeError) as exc:
                logger.error(
                    "skipping rewrite for synced story %s: malformed turns (%s)", story_id, exc
                )
                continue
            shared_facts = [
                (pair[0], pair[1])
                for pair in payload.get("shared_facts", [])
                if isinstance(pair, list) and len(pair) == 2
            ]
            uploaded_storybook = payload.get("storybook")
            if uploaded_storybook is not None and synced_storybook.store_uploaded_storybook(
                story_id, uploaded_storybook, shared_facts
            ):
                continue
            asyncio.create_task(self._run_synced_rewrite(story_id, turns, shared_facts))

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

    async def wait_for_rewrite(self) -> None:
        """Await the in-flight background rewrite to finish. Test-only,
        mirroring wait_for_turn()."""
        if self._rewrite_task is not None:
            await asyncio.gather(self._rewrite_task, return_exceptions=True)

    async def resend_current_status(self) -> None:
        """Called by app.py right after a (re)connect, in addition to
        replay_last_turn() -- a phone that reconnects while a storybook
        rewrite is still in flight must be told so immediately, not left
        to assume it's free to start a new story."""
        if self._machine.state is State.REWRITING:
            await self._send_text_unbuffered(encode_rewriting_started())

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

    async def _send_text_unbuffered(self, text: str) -> None:
        """Sends a control message outside any turn's replay buffer -- for
        pushes that aren't part of the live turn currently in flight, if
        any (rewriting_started/rewriting_done, story browsing
        responses)."""
        async with self._transport_lock:
            await self._transport.send_text(text)

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
        if self._machine.state is State.REWRITING:
            logger.info(
                "speech_start ignored -- a storybook rewrite is still in "
                "progress (turn_id=%d)",
                turn_id,
            )
            return
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
        if self._machine.state is State.REWRITING:
            logger.info(
                "interrupt ignored -- a storybook rewrite is still in "
                "progress (turn_id=%d)",
                turn_id,
            )
            return
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

    async def _stream_llm_reply(
        self, messages: list[dict[str, str]]
    ) -> tuple[str, float | None, float]:
        """One LLM streaming call -- returns the raw joined text plus the
        timing markers _run_turn's own latency log line needs. Factored out
        so a forced-conclude safety retry can call this more than once per
        turn without duplicating the streaming loop."""
        parts: list[str] = []
        first_chunk_at: float | None = None
        async for chunk in self._story_llm.stream_reply(messages):
            if first_chunk_at is None:
                first_chunk_at = time.monotonic()
            parts.append(chunk)
        return "".join(parts).strip(), first_chunk_at, time.monotonic()

    async def _run_turn(
        self, transcript: str, turn_id: int, *, forced_conclude: bool = False
    ) -> None:
        # Per-stage timing: this pipeline is a personal pet project running
        # on modest hardware (see CLAUDE.md), and latency was found to be
        # noticeably higher than the design's 1-2s target -- logging where
        # time actually goes (STT is timed separately, in
        # _finish_listening) beats guessing which of LLM generation or TTS
        # synthesis is the bottleneck before deciding what to optimize.
        turn_start = time.monotonic()
        try:
            self._conversation.add_child(transcript)  # no-op if transcript is empty
            if forced_conclude:
                guidance = self._story_arc.force_conclude_guidance()
            else:
                guidance = self._story_arc.record_turn(transcript)
            # force_conclude_guidance() deliberately does NOT advance
            # _turn_count/stage (it's an out-of-band final turn, not the
            # next turn of the normal budget) -- but this reply IS the
            # story's ending regardless, so the Story screen's progress
            # dots must be told "done" here rather than whatever mid-story
            # stage the arc still reports.
            pushed_stage = (
                Stage.DONE.value if forced_conclude else self._story_arc.stage.value
            )
            await self._send_and_buffer(text=encode_arc_stage(pushed_stage, turn_id))
            fact_guidance = await self._animal_facts.record_turn(
                transcript, self._story_arc.stage
            )
            if fact_guidance:
                guidance = f"{guidance}\n\n{fact_guidance}"
            object_guidance = self._object_recognition.consume_guidance()
            if object_guidance:
                guidance = f"{guidance}\n\n{object_guidance}"
            if not transcript.strip() and not forced_conclude:
                guidance = f"{guidance}\n\n{_STT_FAILURE_GUIDANCE}"
            messages = self._conversation.to_messages(
                self._system_prompt + "\n\n" + guidance
            )

            llm_start = time.monotonic()
            raw, first_chunk_at, llm_done = await self._stream_llm_reply(messages)
            reply = safety.filter_reply(raw)
            if forced_conclude:
                # An explicit "finish this story" request must not end on
                # the generic safety-fallback line -- unlike a normal turn
                # (where the conversation just continues and a redirect is
                # a fine recovery), this reply becomes the story's
                # permanent, saved ending. Retry with the flagged word(s)
                # fed back, mirroring storybook.py's own rewrite retry,
                # before finally accepting the fallback as a last resort.
                attempt = 1
                while (
                    reply == safety.SAFE_FALLBACK
                    and attempt < config.CONCLUDE_SAFETY_RETRY_ATTEMPTS
                ):
                    attempt += 1
                    blocked_terms = safety.find_blocked(raw)
                    if blocked_terms:
                        logger.warning(
                            "conclude_story reply flagged by the kid-safety "
                            "check (%s) -- retrying (attempt %d/%d)",
                            ", ".join(blocked_terms),
                            attempt,
                            config.CONCLUDE_SAFETY_RETRY_ATTEMPTS,
                        )
                        messages = [
                            *messages,
                            {"role": "assistant", "content": raw},
                            {
                                "role": "user",
                                "content": _CONCLUDE_SAFETY_RETRY_TEMPLATE.format(
                                    terms=", ".join(blocked_terms)
                                ),
                            },
                        ]
                    else:
                        # filter_reply() also falls back on a genuinely
                        # empty completion (a separate failure mode from a
                        # flagged one, see its own comment) -- nothing to
                        # name, so nudge it to actually write something
                        # instead of resubmitting the identical messages.
                        logger.warning(
                            "conclude_story got an empty reply -- retrying "
                            "(attempt %d/%d)",
                            attempt,
                            config.CONCLUDE_SAFETY_RETRY_ATTEMPTS,
                        )
                        messages = [
                            *messages,
                            {"role": "user", "content": _CONCLUDE_EMPTY_RETRY_NUDGE},
                        ]
                    llm_start = time.monotonic()
                    raw, first_chunk_at, llm_done = await self._stream_llm_reply(messages)
                    reply = safety.filter_reply(raw)
                self._story_arc.mark_done()
            else:
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
            concluding = self._story_arc.is_done
            if concluding:
                self._transition(Event.REWRITE_STARTED)
            else:
                self._transition(Event.TTS_DONE)
            await self._send_and_buffer(text=encode_turn_end(turn_id))
            logger.info(
                "turn total (transcript -> turn_end): %.1f ms",
                (time.monotonic() - turn_start) * 1000,
            )
            if concluding:
                saved_path = story_store.save_story(self._conversation)
                turns = list(self._conversation.full_history)
                shared_facts = list(self._animal_facts.shared_facts)
                # Captured BEFORE _begin_story() swaps in the next story's
                # settings: the rewrite belongs to the story that just
                # ended, so it must use that story's engine and page count
                # even if the parent changed either mid-story.
                story_llm = self._story_llm
                story_llm_name = self._story_llm_name
                story_page_count = self._story_page_count
                self._conversation = Conversation()
                self._begin_story()
                self._animal_facts = AnimalFactTracker()
                self._object_recognition = ObjectTracker()
                if saved_path is not None:
                    logger.info("story saved to %s", saved_path)
                    story_id = story_store.story_id_from_path(saved_path)
                    await self._send_text_unbuffered(encode_rewriting_started())
                    logger.info(
                        "storybook rewrite for %s using %s", story_id, story_llm_name
                    )
                    self._rewrite_task = asyncio.create_task(
                        self._run_rewrite(
                            story_id, turns, shared_facts,
                            llm=story_llm, page_count=story_page_count,
                        )
                    )
                else:
                    # save_story() itself failed -- there is nothing to
                    # rewrite, and nothing should stay gated on a rewrite
                    # that will never run.
                    self._transition(Event.REWRITE_DONE)
        except asyncio.CancelledError:
            raise
        except EngineError as exc:
            logger.error("engine failure during turn: %s", exc)
            await self._fail_turn(str(exc), turn_id)
        except Exception as exc:  # noqa: BLE001 - a session must survive one bad turn
            logger.exception("unexpected failure during turn")
            await self._fail_turn(f"internal error: {exc}", turn_id)

    async def _run_rewrite(
        self,
        story_id: str,
        turns: list,
        shared_facts: list[tuple[str, str]],
        *,
        llm: LlmEngine,
        page_count: int,
    ) -> None:
        try:
            await storybook.build_and_attach(
                story_id, turns, shared_facts, llm=llm,
                page_count=page_count,
                image_backend=self._image_backend,
            )
        except Exception:  # noqa: BLE001 - the REWRITING gate must always release
            logger.exception("unexpected failure running storybook rewrite for %s", story_id)
        finally:
            self._transition(Event.REWRITE_DONE)
            await self._send_text_unbuffered(encode_rewriting_done())

    async def _run_synced_rewrite(
        self, story_id: str, turns: list, shared_facts: list[tuple[str, str]]
    ) -> None:
        """Runs the storybook rewrite for a story synced from
        away-from-home mode -- deliberately does NOT touch self._machine
        or send rewriting_started/rewriting_done: unlike a live story's
        conclusion (_run_rewrite), a synced batch has no relationship to
        this session's live REWRITING gate or to whatever connection is
        currently attached, and must not perturb either."""
        try:
            # No story start on THIS server to have locked an engine to --
            # the story was played out entirely in away-from-home mode --
            # so there is nothing to reuse here; this always resolves the
            # parent's current preference fresh, same as any other
            # not-yet-started story would.
            await storybook.build_and_attach(
                story_id, turns, shared_facts, llm=self._resolve_llm()[0],
                page_count=config.STORYBOOK_PAGE_COUNT,
            )
        except Exception:  # noqa: BLE001 - a background rewrite must survive any single bad story
            logger.exception(
                "unexpected failure running synced-story storybook rewrite for %s", story_id
            )

    async def _fail_turn(self, message: str, turn_id: int) -> None:
        # Restore state before sending: if the transport is dead (closed
        # socket mid-turn) send_text can raise, and the exception must not
        # leave the state machine stuck outside IDLE.
        self._spoken = []
        if self._machine.state is State.THINKING:
            self._transition(Event.RESPONSE_READY)
        if self._machine.state is State.SPEAKING:
            self._transition(Event.TTS_DONE)
        if self._machine.state is State.REWRITING:
            # A concluding turn transitions into REWRITING before its
            # remaining sends (encode_turn_end, then -- once saved --
            # encode_rewriting_started) and its _rewrite_task creation.
            # If either of those sends raises (e.g. a dead transport),
            # this lands here with state already REWRITING but no
            # rewrite task ever scheduled to release it -- and since
            # every action handler now gates on REWRITING, that would be
            # a permanent lockout recoverable only by a server restart.
            self._transition(Event.REWRITE_DONE)
        await self._transport.send_text(encode_error(message, turn_id))

    def _transition(self, event: Event) -> None:
        try:
            self._machine.handle(event)
        except InvalidTransition as exc:
            # Races are expected here (an interrupt landing as a turn ends);
            # log and keep the session alive rather than tearing it down.
            logger.debug("ignoring invalid transition: %s", exc)
