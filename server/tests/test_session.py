import asyncio

from conftest import FailingLlm, FakeLlm, FakeStt, FakeTts
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
