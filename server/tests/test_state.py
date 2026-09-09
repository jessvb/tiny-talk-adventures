import pytest

from tinytalk.state import Event, InvalidTransition, State, TurnStateMachine


def test_starts_idle():
    assert TurnStateMachine().state is State.IDLE


def test_happy_path_cycles_back_to_idle():
    machine = TurnStateMachine()
    assert machine.handle(Event.SPEECH_START) is State.LISTENING
    assert machine.handle(Event.SPEECH_END) is State.THINKING
    assert machine.handle(Event.RESPONSE_READY) is State.SPEAKING
    assert machine.handle(Event.TTS_DONE) is State.IDLE


@pytest.mark.parametrize(
    "state_setup",
    [
        [],
        [Event.SPEECH_START],
        [Event.SPEECH_START, Event.SPEECH_END],
        [Event.SPEECH_START, Event.SPEECH_END, Event.RESPONSE_READY],
    ],
    ids=["idle", "listening", "thinking", "speaking"],
)
def test_interrupt_from_any_state_lands_in_listening(state_setup):
    machine = TurnStateMachine()
    for event in state_setup:
        machine.handle(event)
    assert machine.handle(Event.INTERRUPT) is State.LISTENING


def test_barge_in_during_speaking_then_completes_a_new_turn():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.INTERRUPT)
    assert machine.handle(Event.SPEECH_END) is State.THINKING
    assert machine.handle(Event.RESPONSE_READY) is State.SPEAKING
    assert machine.handle(Event.TTS_DONE) is State.IDLE


def test_rejects_nonsense_transition():
    machine = TurnStateMachine()
    with pytest.raises(InvalidTransition):
        machine.handle(Event.TTS_DONE)


def test_rejected_transition_leaves_state_unchanged():
    machine = TurnStateMachine()
    with pytest.raises(InvalidTransition):
        machine.handle(Event.RESPONSE_READY)
    assert machine.state is State.IDLE


def test_conclude_from_any_state_lands_in_thinking():
    for state_setup in (
        [],
        [Event.SPEECH_START],
        [Event.SPEECH_START, Event.SPEECH_END],
        [Event.SPEECH_START, Event.SPEECH_END, Event.RESPONSE_READY],
    ):
        machine = TurnStateMachine()
        for event in state_setup:
            machine.handle(event)
        assert machine.handle(Event.CONCLUDE) is State.THINKING


def test_speaking_to_rewriting_on_rewrite_started():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    assert machine.handle(Event.REWRITE_STARTED) is State.REWRITING


def test_rewrite_done_returns_to_idle():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.REWRITE_STARTED)
    assert machine.handle(Event.REWRITE_DONE) is State.IDLE


def test_speech_start_is_not_legal_while_rewriting():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.REWRITE_STARTED)
    with pytest.raises(InvalidTransition):
        machine.handle(Event.SPEECH_START)


def test_interrupt_is_not_legal_while_rewriting():
    # The one deliberate exception to "interrupt is legal from every
    # state" -- see this module's own comment.
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.REWRITE_STARTED)
    with pytest.raises(InvalidTransition):
        machine.handle(Event.INTERRUPT)
