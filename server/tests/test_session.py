import asyncio
import json

from conftest import FailingLlm, FakeLlm, FakeStt, FakeTransport, FakeTts
from storyadventure.conversation import INTERRUPTED_MARKER
from storyadventure.engines import EngineError
from storyadventure.safety import SAFE_FALLBACK
from storyadventure.session import SessionRunner
from storyadventure.state import State

SPEECH_START = '{"type": "speech_start"}'
SPEECH_END = '{"type": "speech_end"}'
INTERRUPT = '{"type": "interrupt"}'


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
        {"role": "system", "content": "be a kind storyteller"},
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


async def test_empty_transcript_ends_the_turn_without_calling_the_llm(transport):
    llm = FakeLlm()
    session = make_session(transport, stt=FakeStt(transcript="   "), llm=llm)

    await run_full_turn(session)

    assert llm.calls == []
    assert session.state is State.IDLE
    assert "turn_end" in transport.types()


async def test_aclose_cancels_an_in_flight_turn(transport):
    tts = FakeTts(delay=0.05)
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.aclose()

    assert tts.cancelled is True


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
