"""Turn-budget-driven narrative staging and end-of-story detection.

Deliberately deterministic (regex + turn counting), like safety.py -- no
LLM calls, given STT+LLM+TTS already run concurrently under real memory
pressure on the M1/16GB server (see the voice/dialog pipeline design
spec's risks section). See
docs/superpowers/specs/2026-08-24-story-generation-engine-design.md for
the full rationale, including why the stage-boundary fractions below
(round(target/4), round(target*2/3)) were chosen over the spec's
originally-stated ceil(0.2*target)/ceil(0.7*target), which didn't
actually reproduce its own example turn ranges.

A story can end three independent ways, any one of which can fire first:
turn count passes a grace ceiling past the target (forced conclusion),
the child asks to stop (record_turn steers that turn's reply toward
wrapping up), or the agent's own reply concludes naturally on its own
(record_reply notices and marks the story done -- no extra prompting
needed).

Per-stage guidance also steers toward a real narrative arc, not just a
timer: INTRO (turn 1 only) introduces the setting and characters with no
conflict yet, SETUP (turn 2 onward, up to setup_end) then instructs
introducing a problem/challenge/conflict right away (confirmed by real
on-device testing that without this, stories stayed conflict-free and
unengaging), RISING_ACTION and CLIMAX keep developing it, and
RESOLUTION/the forced ending both explicitly resolve it and instruct
ending with the literal words "The end." -- both for the child's sense
of closure and because "the end" is already one of _CONCLUSION_PHRASES
below, making natural-conclusion detection far more reliable than
hoping the model happens to phrase things that way on its own.

Note on interrupts: if a story-concluding turn is interrupted before it
completes normally (see session.py's _run_turn), is_done stays latched
True (record_reply already ran before the interrupt could land), but the
actual save+reset only happens at the end of a turn that completes
normally -- so the save+reset is simply deferred to the next such turn,
never lost or duplicated.
"""

from __future__ import annotations

import re
from enum import Enum

from . import config


class Stage(Enum):
    INTRO = "intro"
    SETUP = "setup"
    RISING_ACTION = "rising_action"
    CLIMAX = "climax"
    RESOLUTION = "resolution"
    DONE = "done"


_FORCED_GUIDANCE = (
    "This must be the last reply. Resolve the problem from earlier in "
    "the story and bring it to a warm, complete ending right now. Do not "
    "ask what should happen next. The story is over. End your reply "
    "with the words \"The end.\""
)

_GUIDANCE: dict[Stage, str] = {
    Stage.INTRO: (
        "You're at the very start of the story. Introduce the setting and "
        "characters."
    ),
    Stage.SETUP: (
        "You're at the start of the story. Continue introducing the setting "
        "and characters, and introduce a problem, challenge, or conflict for "
        "them to face. Every good story needs something for the "
        "characters to overcome -- don't wait to introduce it."
    ),
    Stage.RISING_ACTION: (
        "The story is building. Keep developing the problem or "
        "challenge from the start of the story, raise the stakes a "
        "little, and let the child's ideas shape what happens next."
    ),
    Stage.CLIMAX: (
        "The story is nearing its big moment. Build toward an exciting "
        "(but still gentle) turning point where the problem or challenge "
        "comes to a head."
    ),
    Stage.RESOLUTION: (
        "It's time to resolve the problem from earlier in the story and "
        "wrap up the story warmly and happily in this reply or the next "
        "one. If you conclude it now, do not ask what should happen "
        "next. Instead, end your reply with the words \"The end.\""
    ),
}

_CHILD_STOP_PHRASES = (
    "the end",
    "i'm done",
    "im done",
    "stop the story",
    "that's enough",
    "thats enough",
    "no more story",
    "i want to stop",
)

# "happily ever after"/"the end" etc. said BY THE AGENT signal a natural
# conclusion -- deliberately a different (though overlapping) list from
# _CHILD_STOP_PHRASES, since these are checked against different
# speakers' text for different purposes.
_CONCLUSION_PHRASES = (
    "the end",
    "happily ever after",
    "lived happily",
    "the story is over",
)


def _phrase_pattern(phrases: tuple[str, ...]) -> re.Pattern[str]:
    return re.compile(
        r"\b(?:" + "|".join(re.escape(phrase) for phrase in phrases) + r")\b",
        re.IGNORECASE,
    )


_CHILD_STOP_PATTERN = _phrase_pattern(_CHILD_STOP_PHRASES)
_CONCLUSION_PATTERN = _phrase_pattern(_CONCLUSION_PHRASES)


class StoryArc:
    def __init__(self, target_turns: int = config.STORY_TARGET_TURNS) -> None:
        self._target_turns = target_turns
        self._grace_ceiling = target_turns + 3
        self._turn_count = 0
        self._is_done = False

    @property
    def stage(self) -> Stage:
        if self._is_done:
            return Stage.DONE
        return self._stage_for_turn(self._turn_count)

    @property
    def is_done(self) -> bool:
        return self._is_done

    @property
    def has_started(self) -> bool:
        """True once record_turn has ever run -- i.e. this is a real story
        in progress, not a fresh arc waiting for its first turn."""
        return self._turn_count > 0

    def _stage_for_turn(self, turn: int) -> Stage:
        # turn <= 0 is the pre-first-turn state (a fresh arc, before
        # record_turn has ever been called) -- treated the same as turn 1
        # itself, since that's the turn it's about to produce guidance for.
        if turn <= 1:
            return Stage.INTRO
        setup_end = round(self._target_turns / 4)
        rising_end = round(self._target_turns * 2 / 3)
        if turn <= setup_end:
            return Stage.SETUP
        if turn <= rising_end:
            return Stage.RISING_ACTION
        if turn <= self._target_turns:
            return Stage.CLIMAX
        return Stage.RESOLUTION

    def record_turn(self, child_text: str) -> str:
        self._turn_count += 1
        if self._turn_count > self._grace_ceiling:
            return _FORCED_GUIDANCE
        if _CHILD_STOP_PATTERN.search(child_text):
            return _GUIDANCE[Stage.RESOLUTION]
        return _GUIDANCE[self._stage_for_turn(self._turn_count)]

    def record_reply(self, reply_text: str) -> None:
        if self._turn_count > self._grace_ceiling:
            self._is_done = True
            return
        if _CONCLUSION_PATTERN.search(reply_text):
            self._is_done = True

    def force_conclude_guidance(self) -> str:
        """Guidance for an explicitly-requested conclusion (the "Finish
        this story" action) -- the same wording already used when a
        story hits its turn-budget grace ceiling. Deliberately does NOT
        touch _turn_count: this is an out-of-band final turn, not the
        next turn of the normal budget."""
        return _FORCED_GUIDANCE

    def mark_done(self) -> None:
        """Unconditionally marks the story done, independent of
        record_reply()'s phrase-detection -- for the explicit-conclude
        path, where the story must end regardless of the model's exact
        wording."""
        self._is_done = True
