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
    # Entered right after a story concludes (naturally, forced, or via
    # Event.CONCLUDE), for as long as storybook.py's background rewrite
    # of that story is running. See the _TRANSITIONS comment below for
    # why this state is a deliberate exception to "interrupt is legal
    # everywhere".
    REWRITING = auto()


class Event(Enum):
    SPEECH_START = auto()
    SPEECH_END = auto()
    RESPONSE_READY = auto()
    TTS_DONE = auto()
    INTERRUPT = auto()
    ABANDON = auto()
    # The "Finish this story" action -- legal from any state except
    # REWRITING, always forces a fresh THINKING turn with
    # forced-conclusion guidance. See session.py's handle_conclude_story().
    CONCLUDE = auto()
    # Fired by session.py INSTEAD OF TTS_DONE when the turn that just
    # finished speaking concluded the story -- see session.py's _run_turn.
    REWRITE_STARTED = auto()
    REWRITE_DONE = auto()


class InvalidTransition(RuntimeError):
    """Raised when an event arrives that the current state cannot handle."""


# An interrupt is legal from every state EXCEPT REWRITING and always lands
# in LISTENING: the child has started talking, so whatever we were doing
# no longer matters. REWRITING is the one deliberate exception -- the
# whole point of that state is that the child talking again must not be
# able to pre-empt a background rewrite already in flight (see
# session.py's REWRITING gate and the design spec's resource-contention
# discussion). SPEECH_START is similarly absent from REWRITING for the
# same reason.
_TRANSITIONS: dict[tuple[State, Event], State] = {
    (State.IDLE, Event.SPEECH_START): State.LISTENING,
    (State.LISTENING, Event.SPEECH_END): State.THINKING,
    (State.THINKING, Event.RESPONSE_READY): State.SPEAKING,
    (State.SPEAKING, Event.TTS_DONE): State.IDLE,
    (State.IDLE, Event.INTERRUPT): State.LISTENING,
    (State.LISTENING, Event.INTERRUPT): State.LISTENING,
    (State.THINKING, Event.INTERRUPT): State.LISTENING,
    (State.SPEAKING, Event.INTERRUPT): State.LISTENING,
    # A WebSocket disconnect landing mid-utterance (before speech_end ever
    # arrived) means the child's partial utterance was simply abandoned --
    # there is nothing to resume, so this walks back to IDLE rather than
    # leaving the session stuck in LISTENING with no legal way to start a
    # fresh utterance once the client reconnects. Deliberately not defined
    # for THINKING/SPEAKING: a disconnect there is expected to leave a turn
    # running/held for later replay, not abandoned. See
    # SessionRunner.handle_disconnect().
    (State.LISTENING, Event.ABANDON): State.IDLE,
    (State.IDLE, Event.CONCLUDE): State.THINKING,
    (State.LISTENING, Event.CONCLUDE): State.THINKING,
    (State.THINKING, Event.CONCLUDE): State.THINKING,
    (State.SPEAKING, Event.CONCLUDE): State.THINKING,
    (State.SPEAKING, Event.REWRITE_STARTED): State.REWRITING,
    (State.REWRITING, Event.REWRITE_DONE): State.IDLE,
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
