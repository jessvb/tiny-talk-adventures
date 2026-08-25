import asyncio
import json

from conftest import FailingLlm, FakeLlm, FakeStt, FakeTransport, FakeTts
from tinytalk.conversation import INTERRUPTED_MARKER
from tinytalk.engines import EngineError
from tinytalk.safety import SAFE_FALLBACK
from tinytalk.session import SessionRunner
from tinytalk.state import Event, State

SPEECH_START = '{"type": "speech_start", "turn_id": 1}'
SPEECH_END = '{"type": "speech_end"}'
INTERRUPT = '{"type": "interrupt", "turn_id": 2}'


def make_session(transport, *, stt=None, llm=None, tts=None) -> SessionRunner:
    return SessionRunner(
        transport=transport,
        stt=stt or FakeStt(),
        llm=llm or FakeLlm(),
        tts=tts or FakeTts(),
        system_prompt="be a kind storyteller",
    )


async def run_full_turn(session) -> None:
    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()


async def test_full_turn_emits_transcript_response_audio_and_turn_end(transport):
    tts = FakeTts()
    session = make_session(transport, tts=tts)

    await run_full_turn(session)

    assert transport.types() == [
        "transcript_final",
        "response_text",
        "turn_end",
    ]
    assert transport.messages_of_type("transcript_final")[0]["text"] == "tell me about a fox"
    assert transport.messages_of_type("response_text")[0]["text"] == "Once upon a time. A fox ran."
    assert tts.spoken == ["Once upon a time.", "A fox ran."]
    assert transport.audio == [b"<audio:Once upon a time.>", b"<audio:A fox ran.>"]
    assert session.state is State.IDLE


async def test_every_event_in_a_turn_carries_the_speech_starts_turn_id(transport):
    # The whole point of turn_id: the client must be able to tell which
    # utterance a given reply actually belongs to. Every event this turn
    # produces should carry the same id the client sent on speech_start.
    session = make_session(transport)

    await session.handle_text('{"type": "speech_start", "turn_id": 42}')
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    assert transport.types() == ["transcript_final", "response_text", "turn_end"]
    for kind in ("transcript_final", "response_text", "turn_end"):
        assert transport.messages_of_type(kind)[0]["turn_id"] == 42
    assert session.current_turn_id == 42


async def test_a_new_speech_start_after_a_completed_turn_gets_a_new_turn_id(transport):
    session = make_session(transport)

    await session.handle_text('{"type": "speech_start", "turn_id": 1}')
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    await session.handle_text('{"type": "speech_start", "turn_id": 2}')
    await session.handle_audio(b"\x03\x04")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    turn_ends = transport.messages_of_type("turn_end")
    assert [event["turn_id"] for event in turn_ends] == [1, 2]


async def test_interrupt_updates_the_turn_id_for_the_next_turns_events(transport):
    session = make_session(transport)

    await session.handle_text('{"type": "speech_start", "turn_id": 1}')
    await session.handle_text('{"type": "interrupt", "turn_id": 2}')
    assert session.current_turn_id == 2

    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    assert transport.messages_of_type("turn_end")[0]["turn_id"] == 2


async def test_audio_is_forwarded_to_stt_while_listening(transport):
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")

    assert stt.fed == [b"\x01\x02"]


async def test_audio_is_ignored_when_not_listening(transport):
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_audio(b"\x01\x02")

    assert stt.fed == []


async def test_turn_records_both_sides_in_conversation(transport):
    session = make_session(transport)

    await run_full_turn(session)

    turns = session.conversation.turns
    assert [(turn.speaker, turn.text) for turn in turns] == [
        ("child", "tell me about a fox"),
        ("agent", "Once upon a time. A fox ran."),
    ]


async def test_llm_receives_system_prompt_and_history(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert llm.calls[0] == [
        {
            "role": "system",
            "content": "be a kind storyteller\n\n"
            "You're at the start of the story -- introduce the setting and "
            "characters, and introduce a problem, challenge, or conflict for "
            "them to face. Every good story needs something for the "
            "characters to overcome -- don't wait to introduce it.",
        },
        {"role": "user", "content": "tell me about a fox"},
    ]


async def test_unsafe_reply_is_replaced_with_the_fallback(transport):
    llm = FakeLlm(chunks=["He picked up the knife."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert transport.messages_of_type("response_text")[0]["text"] == SAFE_FALLBACK


async def test_interrupt_during_speaking_stops_the_turn(transport):
    tts = FakeTts(delay=0.05)
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.handle_text(INTERRUPT)

    assert session.state is State.LISTENING
    assert tts.cancelled is True
    assert "turn_end" not in transport.types()


async def test_interrupt_during_llm_generation_cancels_it(transport):
    llm = FakeLlm(chunks=["Once ", "upon ", "a time."], delay=0.05)
    session = make_session(transport, llm=llm)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.handle_text(INTERRUPT)

    assert session.state is State.LISTENING
    assert llm.cancelled is True
    assert transport.messages_of_type("response_text") == []


async def test_interrupt_records_spoken_text_as_an_interrupted_turn(transport):
    tts = FakeTts(delay=0.03)
    llm = FakeLlm(chunks=["Once upon a time. ", "A fox ran."])
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.045)  # first sentence spoken, second still synthesizing
    await session.handle_text(INTERRUPT)

    agent_turns = [turn for turn in session.conversation.turns if turn.speaker == "agent"]
    assert len(agent_turns) == 1
    assert agent_turns[0].text == "Once upon a time."
    assert agent_turns[0].interrupted is True


async def test_interrupt_excludes_sentences_sent_but_not_yet_actually_heard(transport):
    # Regression test for a real bug: sending is network/compute-bound and
    # much faster than real-time playback, so a sentence can finish SENDING
    # (and, pre-fix, get unconditionally recorded as "spoken") well before
    # the child has actually finished HEARING it -- confirmed on real
    # hardware as later story content (e.g. a character introduced in a
    # sentence that was sent but not yet played) leaking into the
    # conversation history as if the child had heard it.
    #
    # Three sentences, each with its own delay (fast, fast, slow):
    # sentence 1 and 2 are both fully SENT within ~40ms (delays[0]/[1] =
    # 20ms each) -- proving the bug isn't just "wasn't sent yet". Each still
    # carries its own ESTIMATED real-world playback duration
    # (seconds_per_sentence=100ms), independent of how fast it was sent:
    # sentence 1's estimated completion is ~120ms (first_audio_at ~20ms +
    # 100ms), sentence 2's is ~220ms (same start + 200ms cumulative).
    # Sentence 3's long delay (300ms, delays[2]) is a deliberate keep-alive:
    # it holds _run_turn()'s task genuinely in flight (not yet task.done(),
    # so the normal-completion path hasn't recorded anything yet) long
    # enough for the interrupt below to land in the real window between
    # sentence 1's and sentence 2's estimated completions -- at 170ms.
    tts = FakeTts(delays=[0.02, 0.02, 0.3], seconds_per_sentence=0.1)
    llm = FakeLlm(
        chunks=[
            "The fox found a key. ",
            "Then a ladybug landed on its nose. ",
            "Wait, don't say anything yet.",
        ]
    )
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.17)
    await session.handle_text(INTERRUPT)

    agent_turns = [turn for turn in session.conversation.turns if turn.speaker == "agent"]
    assert len(agent_turns) == 1
    assert agent_turns[0].text == "The fox found a key.", (
        "only the sentence actually finished playing by interrupt time may be recorded -- "
        "the ladybug sentence was already fully SENT, but its audio had not actually "
        "finished playing yet, and must still be excluded"
    )
    assert agent_turns[0].interrupted is True


async def test_interrupt_before_anything_has_actually_been_heard_records_nothing(transport):
    # The other edge of the same fix: if the interrupt lands before even
    # the FIRST sentence's estimated playback has finished, nothing should
    # be recorded as an interrupted agent turn at all -- not "everything
    # sent so far", which pre-fix would have included the whole first
    # sentence the instant its bytes finished sending. The second sentence
    # is a keep-alive (see the test above) so the interrupt at 50ms -- well
    # before sentence 1's ~120ms estimated completion -- lands while the
    # task is still genuinely in flight.
    tts = FakeTts(delays=[0.02, 0.3], seconds_per_sentence=0.1)
    llm = FakeLlm(chunks=["The fox found a key. ", "Wait, don't say anything yet."])
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.05)
    await session.handle_text(INTERRUPT)

    agent_turns = [turn for turn in session.conversation.turns if turn.speaker == "agent"]
    assert agent_turns == []


async def test_interrupted_turn_is_visible_to_the_next_llm_call(transport):
    tts = FakeTts(delay=0.03)
    llm = FakeLlm(chunks=["Once upon a time. ", "A fox ran."])
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.045)
    await session.handle_text(INTERRUPT)

    llm.chunks = ["A dragon then!"]
    await session.handle_audio(b"\x03")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    second_call = llm.calls[1]
    assert second_call[2]["role"] == "assistant"
    assert second_call[2]["content"].endswith(INTERRUPTED_MARKER)

    # The session must fully recover after the barge-in, not just accept the
    # next transcript: the second turn has to actually complete cleanly.
    assert session.state is State.IDLE
    assert "turn_end" in transport.types()


async def test_interrupt_resets_stt_so_old_audio_is_discarded(transport):
    stt = FakeStt()
    tts = FakeTts(delay=0.05)
    session = make_session(transport, stt=stt, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01")
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.handle_text(INTERRUPT)

    assert stt.resets == 1
    assert stt.fed == []


async def test_interrupt_while_idle_just_starts_listening(transport):
    session = make_session(transport)

    await session.handle_text(INTERRUPT)

    assert session.state is State.LISTENING
    assert transport.messages_of_type("error") == []


async def test_engine_failure_is_reported_as_an_error_message(transport):
    session = make_session(transport, llm=FailingLlm(EngineError("Ollama is not running")))

    await run_full_turn(session)

    errors = transport.messages_of_type("error")
    assert len(errors) == 1
    assert "Ollama is not running" in errors[0]["message"]
    assert session.state is State.IDLE


async def test_malformed_control_frame_is_reported_without_killing_the_session(transport):
    session = make_session(transport)

    await session.handle_text("{not json")

    assert transport.messages_of_type("error")
    assert session.state is State.IDLE


async def test_empty_transcript_still_gets_a_graceful_llm_reply_instead_of_silence(transport):
    # Real on-device bug: the VAD can fire on background noise/rustling
    # long enough to start a turn, but STT then transcribes nothing --
    # previously this ended the turn with dead silence, no reply at all.
    llm = FakeLlm(chunks=["Just then, "])
    session = make_session(transport, stt=FakeStt(transcript="   "), llm=llm)

    await run_full_turn(session)

    assert len(llm.calls) == 1, "an empty transcript must still get a real LLM reply, not silence"
    system_message = llm.calls[0][0]
    assert system_message["role"] == "system"
    assert "didn't hear anything new" in system_message["content"]
    # No fake child utterance was added to history for the empty transcript.
    assert not any(turn.speaker == "child" for turn in session.conversation.turns)
    assert session.state is State.IDLE
    assert transport.types() == ["transcript_final", "response_text", "turn_end"]
    assert transport.messages_of_type("transcript_final")[0]["text"] == "   "


async def test_empty_transcript_does_not_add_a_child_turn_to_conversation_history(transport):
    llm = FakeLlm(chunks=["Just then, "])
    session = make_session(transport, stt=FakeStt(transcript=""), llm=llm)

    await run_full_turn(session)

    speakers = [turn.speaker for turn in session.conversation.turns]
    assert speakers == ["agent"], "an empty transcript must not be recorded as a child turn"


async def test_aclose_cancels_an_in_flight_turn(transport):
    tts = FakeTts(delay=0.05)
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.aclose()

    assert tts.cancelled is True


async def test_aclose_resets_stt_so_a_dropped_connection_cannot_leak_audio(transport):
    # aclose() is for full session teardown (e.g. server shutdown), not an
    # ordinary reconnect-expected disconnect -- see handle_disconnect()
    # for that path. Engines are shared across connections in production
    # (app.py) for loading cost reasons, so even a final teardown must not
    # leave stale buffered audio in the STT engine behind.
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.aclose()

    assert stt.resets == 1
    assert stt.fed == []


async def test_handle_disconnect_mid_utterance_resets_stt_and_returns_to_idle(transport):
    # A disconnect landing while still LISTENING (before speech_end ever
    # arrived) means STT's own per-utterance reset -- normally triggered
    # by finish() -- never fired. Unlike aclose(), this is the path an
    # ordinary WebSocket drop takes (app.py's handle_connection), and it
    # must still leave the session able to start a fresh utterance once
    # the client reconnects.
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_disconnect()

    assert stt.resets == 1
    assert stt.fed == []
    assert session.state is State.IDLE

    # The session must be able to start a genuinely new utterance afterward.
    await session.handle_text(SPEECH_START)
    assert session.state is State.LISTENING


async def test_handle_disconnect_while_waiting_for_reply_lets_the_turn_keep_running(transport):
    # The core behavior this whole feature exists for: backgrounding the
    # iOS app while waiting for a reply disconnects the client, but the
    # reply must keep generating rather than being cancelled -- see
    # replay_last_turn() for how it reaches the child later.
    tts = FakeTts(delay=0.05)
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await session.handle_disconnect()

    assert tts.cancelled is False
    await session.wait_for_turn()
    assert transport.types() == ["transcript_final", "response_text", "turn_end"]
    assert session.state is State.IDLE


async def test_replay_last_turn_resends_the_buffered_reply_on_a_fresh_transport(transport):
    other_transport = FakeTransport()
    session = make_session(transport)

    await run_full_turn(session)
    session.rebind_transport(other_transport)
    await session.replay_last_turn()

    assert other_transport.types() == ["response_text", "turn_end"]
    assert other_transport.audio == transport.audio


async def test_replay_last_turn_is_a_no_op_when_nothing_is_buffered(transport):
    session = make_session(transport)

    await session.replay_last_turn()  # must not raise

    assert transport.types() == []


async def test_replay_last_turn_can_replay_to_multiple_reconnects_in_a_row(transport):
    # Deliberate: replay_last_turn() does NOT consume the buffer. Real bug,
    # found on real hardware, from an earlier version that DID consume it:
    # a reconnect that itself dies quickly (e.g. the child backgrounding
    # the app twice in a row) would use up the one replay attempt without
    # the child ever actually hearing it -- silently losing the reply for
    # good, since no later connection would get a turn at it. There is no
    # reliable server-side signal for "the child genuinely heard this" (a
    # send not raising doesn't mean it reached a live listener), so it's
    # safer to keep replaying on every reconnect until a genuinely new
    # utterance starts (see test_a_new_turn_clears_the_previous_turns_replay_buffer)
    # than to risk losing a reply the child is actively still trying to
    # catch up on.
    other_transport = FakeTransport()
    session = make_session(transport)

    await run_full_turn(session)
    session.rebind_transport(other_transport)
    await session.replay_last_turn()
    assert other_transport.types() == ["response_text", "turn_end"]

    yet_another_transport = FakeTransport()
    session.rebind_transport(yet_another_transport)
    await session.replay_last_turn()

    assert yet_another_transport.types() == ["response_text", "turn_end"], (
        "a second reconnect (e.g. the first one died before the child could "
        "actually hear it) must still get the reply replayed"
    )


async def test_a_new_turn_clears_the_previous_turns_replay_buffer(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    other_transport = FakeTransport()
    session.rebind_transport(other_transport)

    llm.chunks = ["A dragon then!"]
    await session.handle_text('{"type": "speech_start", "turn_id": 2}')
    await session.handle_audio(b"\x03\x04")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    # A fresh reconnect at this point must replay only the SECOND turn, not
    # a stale copy of the first one prepended to it.
    yet_another_transport = FakeTransport()
    session.rebind_transport(yet_another_transport)
    await session.replay_last_turn()

    assert yet_another_transport.messages_of_type("response_text")[0]["text"] == "A dragon then!"
    assert len(yet_another_transport.messages_of_type("response_text")) == 1


async def test_speech_start_mid_turn_is_treated_as_an_interrupt(transport):
    # Regression test for review finding 1: a speech_start arriving while a
    # turn is in flight (THINKING or SPEAKING) must not wedge the session in
    # a non-IDLE state. It should behave exactly like an interrupt.
    stt = FakeStt()
    tts = FakeTts(delay=0.05)
    session = make_session(transport, stt=stt, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)  # LLM is instant; turn is now SPEAKING, mid-TTS

    await session.handle_text(SPEECH_START)

    assert session.state is State.LISTENING
    assert tts.cancelled is True

    # The session must not be deaf afterwards: audio should still reach STT.
    await session.handle_audio(b"\x09")
    assert stt.fed == [b"\x09"]


async def test_cancel_turn_propagates_the_callers_own_cancellation(transport):
    # Regression test: `_cancel_turn` always calls `task.cancel()` on the
    # turn task itself before `await task`, so `task.cancelled()` is True on
    # every path and can't be used to tell "the turn task we just cancelled
    # finished being cancelled" (must swallow) apart from "our own caller
    # was cancelled while sitting at `await task`" (must propagate). This
    # exercises the second case directly, via deterministic
    # asyncio.sleep(0) interleaving rather than real-time delays, so it
    # cannot flake.
    class HangingTts:
        def __init__(self) -> None:
            self.cancelled = False

        async def synthesize(self, text: str):
            try:
                while True:
                    await asyncio.sleep(0)
            except asyncio.CancelledError:
                self.cancelled = True
                raise
            yield b""  # pragma: no cover - unreachable, marks this a generator

    tts = HangingTts()
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)

    # Let the turn task run up to its first real suspension point, inside
    # HangingTts.synthesize's `await asyncio.sleep(0)`.
    for _ in range(5):
        await asyncio.sleep(0)

    # Simulate the connection handler calling aclose() as its own task, then
    # being cancelled itself while suspended at `await task` inside
    # _cancel_turn -- exactly the shutdown race the removed comment claimed
    # to handle correctly.
    outer = asyncio.create_task(session.aclose())
    await asyncio.sleep(0)  # let outer reach `task.cancel(); await task`
    outer.cancel()

    propagated = False
    try:
        await outer
    except asyncio.CancelledError:
        propagated = True

    assert propagated, "the caller's own cancellation must propagate, not be swallowed"
    assert tts.cancelled is True


async def test_stt_finish_failure_walks_the_state_back_to_idle(transport):
    # Regression test for review finding 2: stt.finish() raising EngineError
    # (e.g. a real Kyutai model failure) must not leave the session wedged in
    # THINKING -- it should be reported as an error and walked back to IDLE,
    # the same as any other engine failure during a turn.
    class BoomStt(FakeStt):
        def finish(self) -> str:
            raise EngineError("stt exploded")

    session = make_session(transport, stt=BoomStt())

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)

    errors = transport.messages_of_type("error")
    assert len(errors) == 1
    assert "stt exploded" in errors[0]["message"]
    assert session.state is State.IDLE


async def test_fail_turn_restores_state_even_if_sending_the_error_fails(transport):
    # Regression test for review finding 3: if the transport itself is dead
    # (closed socket) the error-send can raise. The state walk-back must
    # already have happened by then, or the session is left wedged.
    class ErrorSendFailsTransport(FakeTransport):
        async def send_text(self, payload: str) -> None:
            if json.loads(payload)["type"] == "error":
                raise RuntimeError("socket closed")
            await super().send_text(payload)

    failing_transport = ErrorSendFailsTransport()
    session = make_session(
        failing_transport, llm=FailingLlm(EngineError("Ollama is not running"))
    )

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    assert session.state is State.IDLE


async def test_finish_listening_discards_stale_transcript_if_interrupted_mid_await(
    transport,
):
    # Regression test for the final review finding: _finish_listening awaits
    # stt.finish() via asyncio.to_thread, which is a genuine await point that
    # didn't used to exist. If an interrupt is processed while that await is
    # in flight -- moving state to LISTENING -- the resumed _finish_listening
    # must notice and discard the now-stale transcript instead of building a
    # reply, generating audio, and sending it all for an utterance the child
    # has already interrupted; and it must not clobber the state the
    # interrupt already set.
    #
    # This isn't reachable today (app.py's read loop awaits each message
    # handler serially, so nothing can interleave with _finish_listening
    # mid-flight yet) but is exercised directly here, deterministically,
    # rather than relying on real concurrency/timing.
    class InterruptDuringFinishStt(FakeStt):
        """Stands in for the STT engine during the to_thread(finish) await.
        When finish() runs, it flips the state machine straight to
        LISTENING -- exactly what a concurrently-processed interrupt would
        have done -- before handing back a transcript, simulating the race
        without needing real concurrency."""

        def __init__(self, session_holder: list) -> None:
            super().__init__()
            self._session_holder = session_holder

        def finish(self) -> str:
            session = self._session_holder[0]
            session._machine.handle(Event.INTERRUPT)
            return super().finish()

    session_holder: list = []
    stt = InterruptDuringFinishStt(session_holder)
    session = make_session(transport, stt=stt)
    session_holder.append(session)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    assert session.state is State.LISTENING
    assert transport.types() == []


async def test_story_arc_setup_guidance_is_included_in_the_llm_system_prompt(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert system_message["role"] == "system"
    assert "start of the story" in system_message["content"].lower()


async def test_reaching_story_done_saves_and_resets_conversation_and_arc(transport, monkeypatch):
    saved: list = []
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: saved.append(conversation) or None,
    )
    llm = FakeLlm(chunks=["And they all lived ", "happily ever after."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert len(saved) == 1
    # The conversation passed to save_story had this turn's content...
    assert saved[0].turns[-1].text == "And they all lived happily ever after."
    # ...but session.conversation is now a FRESH one: the next story has
    # no memory of the finished one.
    assert session.conversation.turns == ()
    assert session._story_arc.is_done is False, "the story arc must be a fresh instance, not the same already-done one"


async def test_interrupting_a_concluding_turn_defers_save_and_reset_to_the_next_completed_turn(transport, monkeypatch):
    # record_reply() runs BEFORE the TTS loop, so a turn that WOULD
    # conclude the story can still be interrupted mid-playback -- is_done
    # is already True by then, but the done-check (save + reset) only
    # runs at the very end of a turn that completes normally. An
    # interrupted concluding turn must NOT save or reset immediately; see
    # story_arc.py's module docstring for the documented deferred-save
    # behavior this pins.
    saved: list = []
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: saved.append(conversation) or None,
    )
    tts = FakeTts(delay=0.05)  # slow enough to interrupt mid-playback
    llm = FakeLlm(chunks=["And they all lived ", "happily ever after."])
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.02)  # let the turn task reach record_reply() and start TTS playback

    await session.handle_text(INTERRUPT)  # barge in mid-playback, before turn_end
    await session.wait_for_turn()

    assert saved == [], "an interrupted concluding turn must not save the story"
    assert session.conversation.turns != (), "an interrupted concluding turn must not reset the conversation"


async def test_story_not_done_does_not_save_or_reset_conversation(transport, monkeypatch):
    saved: list = []
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: saved.append(conversation) or None,
    )
    session = make_session(transport)  # default FakeLlm reply has no conclusion phrase

    await run_full_turn(session)

    assert saved == []
    assert len(session.conversation.turns) == 2  # child + agent turn both retained
