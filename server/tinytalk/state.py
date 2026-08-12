"""The turn-taking state machine.

Pure logic, no I/O — this is the piece that decides what a session is allowed
to do next, and it is where interrupt handling is defined. Side effects
(cancelling work, resetting STT) live in the session orchestrator.
"""

from __future__ import annotations

from enum import Enum, auto


class State(Enum):
    IDLE = auto()
    LISTENING = auto()
    THINKING = auto()
    SPEAKING = auto()


class Event(Enum):
    SPEECH_START = auto()
    SPEECH_END = auto()
    RESPONSE_READY = auto()
    TTS_DONE = auto()
    INTERRUPT = auto()


class InvalidTransition(RuntimeError):
    """Raised when an event arrives that the current state cannot handle."""


# An interrupt is legal from every state and always lands in LISTENING: the
# child has started talking, so whatever we were doing no longer matters.
_TRANSITIONS: dict[tuple[State, Event], State] = {
    (State.IDLE, Event.SPEECH_START): State.LISTENING,
    (State.LISTENING, Event.SPEECH_END): State.THINKING,
    (State.THINKING, Event.RESPONSE_READY): State.SPEAKING,
    (State.SPEAKING, Event.TTS_DONE): State.IDLE,
    (State.IDLE, Event.INTERRUPT): State.LISTENING,
    (State.LISTENING, Event.INTERRUPT): State.LISTENING,
    (State.THINKING, Event.INTERRUPT): State.LISTENING,
    (State.SPEAKING, Event.INTERRUPT): State.LISTENING,
}


class TurnStateMachine:
    def __init__(self) -> None:
        self._state = State.IDLE

    @property
    def state(self) -> State:
        return self._state

    def handle(self, event: Event) -> State:
        next_state = _TRANSITIONS.get((self._state, event))
        if next_state is None:
            raise InvalidTransition(
                f"cannot handle {event.name} while in {self._state.name}"
            )
        self._state = next_state
        return self._state
