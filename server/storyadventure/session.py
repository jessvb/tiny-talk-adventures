"""Per-connection orchestration.

One SessionRunner per WebSocket connection. The turn (LLM generation plus TTS
playback) runs as its own asyncio task so that an interrupt can cancel it
mid-flight — that cancellation, and recording what the agent had already said,
is the core of the barge-in behaviour.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Protocol

from . import config, safety
from .audio import split_sentences
from .conversation import Conversation
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .protocol import (
    Interrupt,
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

logger = logging.getLogger(__name__)


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
        self._stt = stt
        self._llm = llm
        self._tts = tts
        self._system_prompt = system_prompt
        self._conversation = conversation or Conversation()
        self._machine = TurnStateMachine()
        self._turn_task: asyncio.Task | None = None
        self._spoken: list[str] = []

    @property
    def state(self) -> State:
        return self._machine.state

    @property
    def conversation(self) -> Conversation:
        return self._conversation

    async def handle_text(self, raw: str) -> None:
        try:
            message = decode_client_message(raw)
        except ProtocolError as exc:
            logger.warning("bad control frame: %s", exc)
            await self._transport.send_text(encode_error(str(exc)))
            return

        match message:
            case SpeechStart():
                await self._start_listening()
            case SpeechEnd():
                await self._finish_listening()
            case Interrupt():
                await self._interrupt()

    async def handle_audio(self, pcm: bytes) -> None:
        # Audio arriving outside LISTENING is stale — a frame in flight when
        # the utterance ended. Dropping it is correct, not an error.
        if self._machine.state is not State.LISTENING:
            return
        partial = self._stt.feed(pcm)
        if partial:
            await self._transport.send_text(encode_transcript_partial(partial))

    async def wait_for_turn(self) -> None:
        """Await the in-flight turn. Used by tests and on disconnect."""
        if self._turn_task is not None:
            await asyncio.gather(self._turn_task, return_exceptions=True)

    async def aclose(self) -> None:
        await self._cancel_turn(record_spoken=False)

    async def _start_listening(self) -> None:
        if self._machine.state in (State.THINKING, State.SPEAKING):
            # A speech_start arriving mid-turn means the child started
            # talking again before the agent finished — that is an
            # interrupt in every way that matters (cancel in-flight work,
            # record what was already spoken, reset STT, land in
            # LISTENING), so handle it exactly like one instead of firing a
            # SPEECH_START transition that only exists from IDLE. (A
            # duplicate speech_start while already LISTENING is left as the
            # existing no-op below — nothing is in flight to abort.)
            await self._interrupt()
            return
        await self._cancel_turn(record_spoken=True)
        self._transition(Event.SPEECH_START)

    async def _finish_listening(self) -> None:
        if self._machine.state is not State.LISTENING:
            return
        self._transition(Event.SPEECH_END)
        transcript = self._stt.finish()
        await self._transport.send_text(encode_transcript_final(transcript))
        if not transcript.strip():
            self._transition(Event.RESPONSE_READY)
            self._transition(Event.TTS_DONE)
            await self._transport.send_text(encode_turn_end())
            return
        self._spoken = []
        self._turn_task = asyncio.create_task(self._run_turn(transcript))

    async def _interrupt(self) -> None:
        interrupt_received = time.monotonic()
        await self._cancel_turn(record_spoken=True)
        self._stt.reset()
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
            # itself finished being cancelled (expected — swallow it) and
            # when cancellation was aimed at *this* coroutine instead (e.g.
            # the connection handler being cancelled during shutdown while
            # sitting at this await). Only the first case leaves the turn
            # task actually done; in the second, re-raise so the caller's
            # own cancellation isn't silently absorbed.
            if not task.cancelled():
                raise
        if record_spoken and self._spoken:
            self._conversation.add_agent(" ".join(self._spoken), interrupted=True)
        self._spoken = []

    async def _run_turn(self, transcript: str) -> None:
        try:
            self._conversation.add_child(transcript)
            messages = self._conversation.to_messages(self._system_prompt)

            parts: list[str] = []
            async for chunk in self._llm.stream_reply(messages):
                parts.append(chunk)
            reply = safety.filter_reply("".join(parts).strip())

            await self._transport.send_text(encode_response_text(reply))
            self._transition(Event.RESPONSE_READY)

            for sentence in split_sentences(reply):
                async for pcm in self._tts.synthesize(sentence):
                    await self._transport.send_bytes(pcm)
                # Recorded only once fully sent, so an interrupt attributes to
                # the agent exactly what the child actually heard.
                self._spoken.append(sentence)

            self._conversation.add_agent(reply)
            self._spoken = []
            self._transition(Event.TTS_DONE)
            await self._transport.send_text(encode_turn_end())
        except asyncio.CancelledError:
            raise
        except EngineError as exc:
            logger.error("engine failure during turn: %s", exc)
            await self._fail_turn(str(exc))
        except Exception as exc:  # noqa: BLE001 - a session must survive one bad turn
            logger.exception("unexpected failure during turn")
            await self._fail_turn(f"internal error: {exc}")

    async def _fail_turn(self, message: str) -> None:
        # Restore state before sending: if the transport is dead (closed
        # socket mid-turn) send_text can raise, and the exception must not
        # leave the state machine stuck outside IDLE.
        self._spoken = []
        if self._machine.state is State.THINKING:
            self._transition(Event.RESPONSE_READY)
        if self._machine.state is State.SPEAKING:
            self._transition(Event.TTS_DONE)
        await self._transport.send_text(encode_error(message))

    def _transition(self, event: Event) -> None:
        try:
            self._machine.handle(event)
        except InvalidTransition as exc:
            # Races are expected here (an interrupt landing as a turn ends);
            # log and keep the session alive rather than tearing it down.
            logger.debug("ignoring invalid transition: %s", exc)
