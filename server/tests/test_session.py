import asyncio
import logging
import json
from pathlib import Path

from conftest import FailingLlm, FakeLlm, FakeStt, FakeTransport, FakeTts
from tinytalk.conversation import INTERRUPTED_MARKER
from tinytalk.engines import EngineError
from tinytalk.safety import SAFE_FALLBACK
from tinytalk.session import SessionRunner
from tinytalk.state import Event, State

SPEECH_START = '{"type": "speech_start", "turn_id": 1}'
SPEECH_END = '{"type": "speech_end"}'
INTERRUPT = '{"type": "interrupt", "turn_id": 2}'

# _run_rewrite() (session.py) hands storybook.build_and_attach() the
# session's own LLM engine, so anything that lets a fake rewrite complete
# with zero genuine suspension can run to full completion inside the very
# next event-loop iteration after the concluding turn's own task finishes
# -- before a test's own `await wait_for_turn()`/`handle_text(...)` call
# ever gets scheduled back in. That races out of existence exactly what
# several tests below need to observe (REWRITING still in progress) -- not
# because the REWRITING gate is broken, but because nothing gave the
# rewrite task a genuine suspension point to still be parked at. A real
# LLM call always takes real wall-clock time, so this can't happen outside
# tests; _fake_build_and_attach() below uses this as its default delay to
# restore that realism wherever a test needs it.
_REWRITE_LLM_DELAY = 0.05

# server/data/stories/ is the REAL directory the Library screen (Task
# 10/11) will read from in production. story_store.save_story()'s
# `stories_dir` default -- and storybook.build_and_attach()'s, and
# story_store.update_story_rewrite()'s -- are all bound to STORIES_DIR at
# their *function-definition* time (module import), so
# monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path) does nothing
# for already-defined functions: every test below that reaches a
# conclusion must instead replace save_story/build_and_attach themselves
# (the same pattern test_reaching_story_done_saves_and_resets_conversation_and_arc
# already uses above), or it writes real files into that real directory.
_FAKE_SAVED_PATH = Path("20260101T000000-fakestory0.json")


def _fake_save_story(conversation, **kwargs):
    return _FAKE_SAVED_PATH


def _stories_dir_list_stories(stories_dir):
    """A stand-in for story_store.list_stories that closes over
    stories_dir, for the same reason _fake_save_story exists above:
    list_stories()'s own `stories_dir` default is bound to the real
    STORIES_DIR at story_store's *function-definition* time, so
    monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path) does
    nothing for it -- the function itself must be replaced. Captures the
    real function up front (rather than looking up story_store.list_stories
    again inside the lambda) because the caller immediately monkeypatches
    that very attribute to be this lambda -- a late lookup would resolve
    to itself and recurse with the wrong signature."""
    from tinytalk import story_store

    original = story_store.list_stories
    return lambda: original(stories_dir=stories_dir)


def _stories_dir_load_story(stories_dir):
    """Same fix as _stories_dir_list_stories above, for load_story."""
    from tinytalk import story_store

    original = story_store.load_story
    return lambda story_id: original(story_id, stories_dir=stories_dir)


def _fake_build_and_attach(delay: float = _REWRITE_LLM_DELAY):
    """A stand-in for storybook.build_and_attach, for tests that need the
    REWRITING gate's real lifecycle (a background task genuinely in
    flight, then releasing on completion) without it ever calling
    story_store.update_story_rewrite for real. `delay` keeps the task
    genuinely suspended (a real asyncio.sleep, not a call_soon-only no-op)
    for as long as a test needs to observe REWRITING before it completes
    -- see _REWRITE_LLM_DELAY's own comment above for why that matters;
    pass delay=0 for a test that only cares about the eventual release,
    already awaited via wait_for_rewrite()."""

    async def _fake(*args, **kwargs):
        if delay:
            await asyncio.sleep(delay)

    return _fake


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
        "arc_stage",
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

    assert transport.types() == ["transcript_final", "arc_stage", "response_text", "turn_end"]
    for kind in ("transcript_final", "arc_stage", "response_text", "turn_end"):
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
            "You're at the very start of the story. Introduce the setting "
            "and characters.",
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
    assert transport.types() == ["transcript_final", "arc_stage", "response_text", "turn_end"]
    assert transport.messages_of_type("transcript_final")[0]["text"] == "   "


async def test_empty_transcript_does_not_add_a_child_turn_to_conversation_history(transport):
    llm = FakeLlm(chunks=["Just then, "])
    session = make_session(transport, stt=FakeStt(transcript=""), llm=llm)

    await run_full_turn(session)

    speakers = [turn.speaker for turn in session.conversation.turns]
    assert speakers == ["agent"], "an empty transcript must not be recorded as a child turn"


async def test_llm_returning_an_empty_reply_still_gets_a_spoken_fallback(transport):
    # Real on-device bug, distinct from the empty-transcript case above:
    # the LLM can return a genuinely empty completion for a normal,
    # non-empty transcript (confirmed: happened even with
    # _STT_FAILURE_GUIDANCE already covering the empty-transcript case) --
    # previously this reached turn_end with zero audio synthesized and no
    # indication anything happened.
    tts = FakeTts()
    llm = FakeLlm(chunks=[])
    session = make_session(transport, llm=llm, tts=tts)

    await run_full_turn(session)

    assert transport.messages_of_type("response_text")[0]["text"] == SAFE_FALLBACK
    assert tts.spoken, "a fallback reply must still be synthesized and spoken, not silently skipped"
    assert transport.types() == ["transcript_final", "arc_stage", "response_text", "turn_end"]
    assert session.state is State.IDLE


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
    assert transport.types() == ["transcript_final", "arc_stage", "response_text", "turn_end"]
    assert session.state is State.IDLE


async def test_replay_last_turn_resends_the_buffered_reply_on_a_fresh_transport(transport):
    other_transport = FakeTransport()
    session = make_session(transport)

    await run_full_turn(session)
    session.rebind_transport(other_transport)
    await session.replay_last_turn()

    assert other_transport.types() == ["arc_stage", "response_text", "turn_end"]
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
    assert other_transport.types() == ["arc_stage", "response_text", "turn_end"]

    yet_another_transport = FakeTransport()
    session.rebind_transport(yet_another_transport)
    await session.replay_last_turn()

    assert yet_another_transport.types() == ["arc_stage", "response_text", "turn_end"], (
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
    # The turn's transcript ("tell me about a fox", FakeStt's default) mentions
    # an animal, so a non-reset tracker would still have _any_animal_mentioned
    # set to True here.
    assert session._animal_facts._any_animal_mentioned is False, "the animal fact tracker must be a fresh instance too"


async def test_new_story_mid_turn_cancels_it_and_resets_everything(transport):
    # New "reset" debug affordance -- the child/parent explicitly wants to
    # abandon the current story and start over, without a full reconnect.
    llm = FakeLlm(chunks=["Once ", "upon ", "a time."], delay=0.05)
    session = make_session(transport, llm=llm)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)  # turn genuinely in flight (THINKING)

    await session.handle_text('{"type": "new_story"}')

    assert session.state is State.IDLE
    assert llm.cancelled is True
    assert transport.messages_of_type("response_text") == []
    assert session.conversation.turns == ()
    assert session._story_arc.is_done is False
    assert session._animal_facts._any_animal_mentioned is False


async def test_new_story_after_a_completed_turn_clears_the_replay_buffer(transport):
    # A finished-but-unheard reply from the OLD story must never be
    # replayed to a later connection under a turn_id the new story reuses.
    session = make_session(transport)
    await run_full_turn(session)
    assert transport.messages_of_type("turn_end")  # sanity: a turn did complete

    await session.handle_text('{"type": "new_story"}')

    assert session._turn_replay_buffer == []


async def test_new_story_while_listening_resets_stt_and_returns_to_idle(transport):
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_text(SPEECH_START)
    assert session.state is State.LISTENING

    await session.handle_text('{"type": "new_story"}')

    assert session.state is State.IDLE
    assert stt.resets == 1


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


async def test_animal_mention_adds_fact_guidance_to_the_llm_call(transport, monkeypatch, tmp_path):
    from tinytalk.animal_facts import _save_cache

    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")
    llm = FakeLlm()
    session = make_session(transport, stt=FakeStt(transcript="tell me about a fox"), llm=llm)

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert system_message["role"] == "system"
    assert "foxes have excellent hearing" in system_message["content"]


async def test_no_animal_mentioned_sends_no_fact_guidance(transport, monkeypatch, tmp_path):
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    llm = FakeLlm()
    session = make_session(
        transport, stt=FakeStt(transcript="what is your favorite color"), llm=llm
    )

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "Weave this real fact" not in system_message["content"]


async def test_animal_free_first_turn_gets_the_nudge(transport, monkeypatch, tmp_path):
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    llm = FakeLlm()
    session = make_session(
        transport, stt=FakeStt(transcript="let's make up a story"), llm=llm
    )

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "what animal should be in the story" in system_message["content"]


OBJECT_SEEN = '{"type": "object_seen", "label": "teddy bear"}'


async def test_object_seen_adds_weave_in_guidance_to_the_next_turns_llm_call(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await session.handle_text(OBJECT_SEEN)
    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "teddy bear" in system_message["content"]
    assert "inspire" in system_message["content"].lower()


async def test_object_seen_guidance_is_only_used_once(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await session.handle_text(OBJECT_SEEN)
    await run_full_turn(session)

    llm.chunks = ["A dragon then!"]
    await session.handle_text('{"type": "speech_start", "turn_id": 2}')
    await session.handle_audio(b"\x03\x04")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    second_system_message = llm.calls[1][0]
    assert "teddy bear" not in second_system_message["content"]


async def test_no_object_seen_message_sends_no_object_guidance(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "showed you a photo" not in system_message["content"]


async def test_unsafe_object_label_is_discarded(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await session.handle_text('{"type": "object_seen", "label": "a bloody knife"}')
    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "knife" not in system_message["content"]


async def test_reaching_story_done_resets_the_object_tracker(transport, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: None,
    )
    llm = FakeLlm(chunks=["And they all lived ", "happily ever after."])
    session = make_session(transport, llm=llm)

    await session.handle_text(OBJECT_SEEN)
    old_tracker = session._object_recognition
    await run_full_turn(session)

    assert session._object_recognition is not old_tracker, (
        "a story-ending turn must reset the object tracker to a fresh instance, "
        "same as _conversation/_story_arc/_animal_facts"
    )


async def test_rebinding_the_transport_bumps_the_generation(transport):
    """app.py's handle_connection uses this to tell whether it still owns
    the session -- see rebind_transport()'s docstring."""
    session = SessionRunner(transport=transport, stt=FakeStt(), llm=FakeLlm(), tts=FakeTts())

    assert session.transport_generation == 0
    session.rebind_transport(FakeTransport())
    assert session.transport_generation == 1
    session.rebind_transport(FakeTransport())
    assert session.transport_generation == 2


async def test_starting_an_utterance_records_which_turn_id_and_story_stage_it_belongs_to(
    caplog, transport
):
    """Two different counters both get called "turn" in this codebase, and
    confusing them is easy: turn_id is a protocol message-routing id that
    deliberately never resets (the app shows it as "Turn: N"), while the
    story arc's own stage is what actually advances through a story and
    DOES reset on new_story. A real session left no way to tell which was
    which -- the server logged neither -- so "the app still says turn 2
    after New Story" could not be answered from the log at all.
    """
    session = make_session(transport)

    with caplog.at_level(logging.INFO, logger="tinytalk.session"):
        await session.handle_text(SPEECH_START)

    messages = [record.getMessage() for record in caplog.records]
    assert any("turn_id=1" in message and "story stage" in message for message in messages), (
        f"an utterance must say which turn_id and story stage it belongs to; got {messages}"
    )


async def test_new_story_says_so_in_the_log(caplog, transport):
    """handle_new_story() resets the conversation, the story arc and the
    replay buffer, and logged not one word about it. From a real session's
    log there was no way to tell whether the child's New Story tap had even
    reached the server, let alone taken effect."""
    session = make_session(transport)
    await session.handle_text(SPEECH_START)

    with caplog.at_level(logging.INFO, logger="tinytalk.session"):
        await session.handle_new_story()

    messages = [record.getMessage() for record in caplog.records]
    assert any("new story" in message.lower() for message in messages), (
        f"starting a new story must be visible in the log; got {messages}"
    )


async def test_new_session_defaults_to_config_target_turns_and_page_count(transport):
    from tinytalk import config

    session = make_session(transport)
    assert session._target_turns == config.STORY_TARGET_TURNS
    assert session._page_count == config.STORYBOOK_PAGE_COUNT


async def test_handle_update_settings_changes_the_next_storys_target_turns(transport):
    session = make_session(transport)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 4, "page_count": 3}'
    )
    await session.handle_new_story()
    assert session._story_arc._target_turns == 4
    assert session._page_count == 3


async def test_handle_update_settings_clamps_values_above_the_range(transport):
    session = make_session(transport)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 999, "page_count": 999}'
    )
    assert session._target_turns == 12
    assert session._page_count == 10


async def test_handle_update_settings_clamps_values_below_the_range(transport):
    session = make_session(transport)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 0, "page_count": 1}'
    )
    assert session._target_turns == 4
    assert session._page_count == 3


async def test_update_settings_does_not_change_the_currently_in_progress_story(transport):
    """Confirms the spec's "applies to the next story, never retroactively"
    requirement: an already-constructed StoryArc keeps its original
    target_turns even after update_settings arrives mid-story."""
    session = make_session(transport)
    original_target = session._story_arc._target_turns
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 4, "page_count": 3}'
    )
    assert session._story_arc._target_turns == original_target


CONCLUDE = '{"type": "conclude_story", "turn_id": 9}'


async def test_conclude_story_forces_a_final_reply_without_a_real_utterance(transport, monkeypatch):
    # The first ("normal") turn's reply must NOT itself contain a natural
    # conclusion phrase (see story_arc._CONCLUSION_PHRASES) -- otherwise
    # run_full_turn() would already conclude/reset/enter REWRITING before
    # CONCLUDE is even sent, defeating "a normal turn first, so there's a
    # story in progress" below. The forced-conclude reply is swapped in
    # afterward. save_story is faked -> None: this test only cares about
    # the forced turn's own LLM call and its turn_end, not the REWRITING
    # gate's own lifecycle, so a real save (and the real background
    # rewrite it would kick off) has nothing to do with what's being
    # tested here -- see _fake_save_story's comment above.
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story", lambda conversation, **kwargs: None
    )
    llm = FakeLlm(chunks=["The fox found a shiny red apple."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)  # a normal turn first, so there's a story in progress

    llm.chunks = ["The fox went home. The end."]
    calls_before = len(llm.calls)
    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    # The forced turn's system prompt carries the same forced-conclusion
    # guidance already used for a grace-ceiling-forced ending. Indexed by
    # calls_before, not [-1], as defense in depth: with save_story faked
    # to return None here, no background rewrite is ever scheduled for
    # the forced-conclude turn either (see _run_turn's `saved_path is
    # None` branch), so llm.calls never grows past what this turn itself
    # adds -- but indexing by count avoids relying on that as an implicit
    # assumption of what this assertion is checking.
    forced_messages = llm.calls[calls_before]
    assert "This must be the last reply" in forced_messages[0]["content"]
    assert transport.messages_of_type("turn_end")[-1]["turn_id"] == 9


async def test_conclude_story_marks_the_story_done_even_if_the_reply_omits_the_end(transport, monkeypatch):
    # Deliberately a reply that would NOT be caught by natural
    # phrase-detection -- proves mark_done() is unconditional.
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story", lambda conversation, **kwargs: None
    )
    llm = FakeLlm(chunks=["The fox curled up and slept soundly."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)

    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    # A concluded story resets the conversation -- the next turn starts fresh.
    assert session.conversation.turns == ()


async def test_conclude_story_cancels_an_in_flight_turn_first(transport, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story", lambda conversation, **kwargs: None
    )
    llm = FakeLlm(chunks=["slow reply"], delay=10)
    session = make_session(transport, llm=llm)
    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)  # let the slow turn actually start

    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    assert llm.cancelled is True


async def test_conclude_story_does_not_trigger_the_stt_failure_guidance(transport, monkeypatch):
    # Same latent issue as test_conclude_story_forces_a_final_reply_without_a_real_utterance
    # above, fixed the same way: the first ("normal") turn's reply must not
    # itself already conclude the story, and llm.calls is indexed by a
    # captured count rather than [-1] (see that test's comment for the
    # full reasoning). save_story is faked -> None for the same
    # not-what's-being-tested-here reason.
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story", lambda conversation, **kwargs: None
    )
    llm = FakeLlm(chunks=["The fox found a shiny red apple."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)

    llm.chunks = ["The end."]
    calls_before = len(llm.calls)
    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    forced_messages = llm.calls[calls_before]
    assert "didn't hear anything new" not in forced_messages[0]["content"]


async def test_conclude_story_pushes_the_done_arc_stage_regardless_of_actual_progress(
    transport, monkeypatch
):
    """force_conclude_guidance() deliberately does NOT advance the story
    arc's turn count/stage (see StoryArc.force_conclude_guidance's own
    docstring) -- but this exact reply IS the story's ending. The Story
    screen's progress-dots UI (arc_stage's whole reason for existing) must
    show "done" for this turn, not whatever mid-story stage the arc
    happened to be sitting at when the conclude was requested."""
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story", lambda conversation, **kwargs: None
    )
    llm = FakeLlm(chunks=["The fox found a shiny red apple."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)  # a normal turn first -- arc is mid-story, not done
    # Confirms the setup: the arc is genuinely NOT done yet -- if it were,
    # this test wouldn't distinguish "always pushes the arc's real stage"
    # from "always pushes done" and would be a false positive either way.
    assert transport.messages_of_type("arc_stage")[-1]["stage"] != "done"

    llm.chunks = ["The fox went home."]
    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    assert transport.messages_of_type("arc_stage")[-1]["stage"] == "done"


async def test_a_concluding_turn_enters_rewriting_and_pushes_rewriting_started(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert session.state is State.REWRITING
    assert "rewriting_started" in transport.types()


async def test_rewriting_releases_back_to_idle_once_the_rewrite_finishes(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.wait_for_rewrite()

    assert session.state is State.IDLE
    assert "rewriting_done" in transport.types()


async def test_rewriting_releases_even_when_the_rewrite_itself_raises(transport, monkeypatch):
    async def raising_build_and_attach(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", raising_build_and_attach
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)

    await session.wait_for_rewrite()

    assert session.state is State.IDLE


async def test_speech_start_is_a_no_op_while_rewriting(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING
    before_turn_id = session.current_turn_id

    await session.handle_text('{"type": "speech_start", "turn_id": 999}')

    assert session.state is State.REWRITING
    assert session.current_turn_id == before_turn_id


async def test_new_story_is_a_no_op_while_rewriting(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_new_story()

    assert session.state is State.REWRITING


async def test_interrupt_is_a_no_op_while_rewriting(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_text('{"type": "interrupt", "turn_id": 999}')

    assert session.state is State.REWRITING


async def test_conclude_story_is_a_no_op_while_rewriting(transport, monkeypatch):
    # Not part of the brief's own Step 1 list, but the same gate applies
    # for the same reason: handle_conclude_story() unconditionally spawns
    # a forced-conclude _run_turn task (a real LLM call) once _transition()
    # runs, and (State.REWRITING, Event.CONCLUDE) isn't a defined
    # transition -- so without this early guard, _transition()'s existing
    # swallow-and-log behavior would leave the state stuck at REWRITING
    # while STILL letting a competing LLM turn start, defeating the whole
    # point of this task (see storybook.py's module docstring: "this call
    # never competes with a live story's own LLM turns for the same local
    # Ollama process").
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_text('{"type": "conclude_story", "turn_id": 999}')

    assert session.state is State.REWRITING
    assert session._turn_task is None or session._turn_task.done()


async def test_speech_start_works_again_once_rewriting_finishes(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach(delay=0)
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    await session.wait_for_rewrite()
    assert session.state is State.IDLE

    await session.handle_text('{"type": "speech_start", "turn_id": 5}')

    assert session.state is State.LISTENING


async def test_a_non_concluding_turn_does_not_enter_rewriting(transport):
    llm = FakeLlm(chunks=["Let's keep going."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert session.state is State.IDLE
    assert "rewriting_started" not in transport.types()


async def test_resend_current_status_repushes_rewriting_started(transport, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    transport.text.clear()

    await session.resend_current_status()

    assert "rewriting_started" in transport.types()


async def test_rewriting_gate_releases_if_turn_end_send_fails(transport):
    # Regression test: between _transition(Event.REWRITE_STARTED) and
    # _rewrite_task's own creation, _run_turn still has two sends that can
    # raise (encode_turn_end here, encode_rewriting_started in the test
    # below) -- if either does (e.g. a dead transport), it lands in
    # _fail_turn with state already REWRITING but no rewrite task ever
    # scheduled to release it. Without _fail_turn's own REWRITING
    # handling, that's a permanent lockout: every action handler now
    # gates on REWRITING, so nothing could ever recover the session short
    # of a server restart.
    class TurnEndFailsTransport(FakeTransport):
        async def send_text(self, payload: str) -> None:
            if json.loads(payload)["type"] == "turn_end":
                raise RuntimeError("socket closed")
            await super().send_text(payload)

    llm = FakeLlm(chunks=["The end."])
    session = make_session(TurnEndFailsTransport(), llm=llm)

    await run_full_turn(session)

    assert session.state is State.IDLE


async def test_rewriting_gate_releases_if_rewriting_started_send_fails(transport, monkeypatch):
    # The second (later, more dangerous) of the two failure points named
    # above: this one lands after the story is already saved and
    # conversation/arc/animal-facts/object-tracker are already reset, but
    # still before _rewrite_task is created -- so without _fail_turn's fix,
    # the session would be stuck REWRITING with no story data left AND no
    # rewrite task that could ever release it.
    class RewritingStartedFailsTransport(FakeTransport):
        async def send_text(self, payload: str) -> None:
            if json.loads(payload)["type"] == "rewriting_started":
                raise RuntimeError("socket closed")
            await super().send_text(payload)

    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    llm = FakeLlm(chunks=["The end."])
    session = make_session(RewritingStartedFailsTransport(), llm=llm)

    await run_full_turn(session)

    assert session.state is State.IDLE


# Read-only story browsing (Library/Reading screens) -- list_stories/
# get_story/synthesize_page have nothing to do with the live turn-taking
# state machine and must work regardless of session state. Every test here
# redirects story_store.list_stories/load_story via
# _stories_dir_list_stories/_stories_dir_load_story rather than
# monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path) -- see those
# helpers' docstrings above for why the latter silently does nothing.


async def test_list_stories_returns_saved_summaries(transport, tmp_path, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.list_stories", _stories_dir_list_stories(tmp_path)
    )
    from tinytalk.story_store import save_story
    from tinytalk.conversation import Conversation

    save_story(Conversation(), stories_dir=tmp_path)
    session = make_session(transport)

    await session.handle_text('{"type": "list_stories"}')

    stories = transport.messages_of_type("story_list")[0]["stories"]
    assert len(stories) == 1


async def test_get_story_returns_story_detail(transport, tmp_path, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.load_story", _stories_dir_load_story(tmp_path)
    )
    from tinytalk.story_store import save_story, story_id_from_path, update_story_rewrite
    from tinytalk.conversation import Conversation

    path = save_story(Conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="Pip", pages=[{"text": "Once upon a time."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    session = make_session(transport)

    await session.handle_text(f'{{"type": "get_story", "story_id": "{story_id}"}}')

    detail = transport.messages_of_type("story_detail")[0]
    # Full expected shape, not just title/pages -- locks in the "exactly
    # these 5 payload keys (id, title, pages, epilogue, rewrite_status),
    # plus the wire message's own type" guarantee, so a stray extra key
    # (e.g. accidentally leaking the raw `turns`) would fail this test.
    assert detail == {
        "type": "story_detail",
        "id": story_id,
        "title": "Pip",
        "pages": [{"text": "Once upon a time."}],
        "epilogue": None,
        "rewrite_status": "done",
    }


async def test_get_story_sends_error_for_unknown_id(transport, tmp_path, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.load_story", _stories_dir_load_story(tmp_path)
    )
    session = make_session(transport)

    await session.handle_text('{"type": "get_story", "story_id": "nope"}')

    assert transport.types() == ["error"]


async def test_synthesize_page_streams_audio_and_a_done_marker(transport, tmp_path, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.load_story", _stories_dir_load_story(tmp_path)
    )
    from tinytalk.story_store import save_story, story_id_from_path, update_story_rewrite
    from tinytalk.conversation import Conversation

    path = save_story(Conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="Pip", pages=[{"text": "Once upon a time."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    tts = FakeTts()
    session = make_session(transport, tts=tts)

    await session.handle_text(
        f'{{"type": "synthesize_page", "story_id": "{story_id}", "page_index": 0}}'
    )

    assert tts.spoken == ["Once upon a time."]
    assert len(transport.audio) == 1
    done = transport.messages_of_type("page_audio_done")[0]
    assert done == {"type": "page_audio_done", "story_id": story_id, "page_index": 0}


async def test_synthesize_page_sends_error_for_an_out_of_range_page(transport, tmp_path, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.load_story", _stories_dir_load_story(tmp_path)
    )
    from tinytalk.story_store import save_story, story_id_from_path, update_story_rewrite
    from tinytalk.conversation import Conversation

    path = save_story(Conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="Pip", pages=[{"text": "Once upon a time."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    session = make_session(transport)

    await session.handle_text(
        f'{{"type": "synthesize_page", "story_id": "{story_id}", "page_index": 5}}'
    )

    assert transport.types() == ["error"]


async def test_story_browsing_works_while_rewriting(transport, tmp_path, monkeypatch):
    # Browsing already-saved stories has nothing to do with the live
    # session -- it must keep working even while a DIFFERENT story is
    # mid-rewrite. save_story/build_and_attach are faked (the established
    # pattern above, e.g. test_a_concluding_turn_enters_rewriting_and_
    # pushes_rewriting_started) so reaching REWRITING here neither writes
    # a real file into server/data/stories/ nor races the fake rewrite to
    # completion before the assertion below runs.
    # NOTE: the real save (below) must run before save_story gets
    # monkeypatched to _fake_save_story -- `from tinytalk.story_store
    # import save_story` re-reads the module attribute at import-execution
    # time, so importing it after the patch would silently bind the fake
    # instead of the real function, and no file would ever reach tmp_path.
    from tinytalk.story_store import save_story
    from tinytalk.conversation import Conversation

    save_story(Conversation(), stories_dir=tmp_path)

    monkeypatch.setattr(
        "tinytalk.session.story_store.list_stories", _stories_dir_list_stories(tmp_path)
    )
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", _fake_build_and_attach()
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_text('{"type": "list_stories"}')

    assert len(transport.messages_of_type("story_list")[0]["stories"]) >= 1
