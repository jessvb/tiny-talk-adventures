"""Deterministic tracking of a single "object the child just showed the
camera" -- weaves creative inspiration from a recognized household object
into the story's action, via guidance text appended to the same turn's LLM
call (no extra model call), the same mechanism story_arc.py/
animal_facts.py already use. Unlike animal_facts.py, there is no cache and
no external API here: an arbitrary household object has no "real fact" to
look up, and the point is creative inspiration, not grounding in reality.
See docs/superpowers/specs/2026-08-29-object-recognition-design.md for the
full design.
"""

from __future__ import annotations

from . import safety

_WEAVE_IN_TEMPLATE = (
    "The child just showed you a photo of a {label}. Let it inspire what "
    "happens next -- it doesn't have to appear literally. A toy could "
    "become a real character, furniture could become part of the setting, "
    "everyday objects could become magical artifacts. Weave something "
    "inspired by it naturally into the action, not as an aside."
)


class ObjectTracker:
    """Per-story tracker, constructed fresh alongside StoryArc/
    AnimalFactTracker and replaced whenever a story finishes and a new
    Conversation/StoryArc pair is created -- so a label seen in a
    finished story never leaks into the next one."""

    def __init__(self) -> None:
        self._pending_label: str | None = None

    def record_seen(self, label: str) -> None:
        """Called when an object_seen message arrives. Runs label through
        safety.is_safe(); if it passes, stores it as the pending label --
        overwriting any earlier still-unconsumed one, since only the most
        recent photo matters if the child snaps two before either gets
        woven in. A label that FAILS the safety check is discarded on its
        own -- it does not clear an already-pending safe label from an
        earlier photo. No error is surfaced either way: a confusing
        "that's not allowed" message to a five-year-old is worse than the
        story just continuing with no object reference (same reasoning as
        animal_facts.py's "no fact available" case)."""
        if safety.is_safe(label):
            self._pending_label = label

    def consume_guidance(self) -> str:
        """Call once per turn, alongside StoryArc.record_turn()/
        AnimalFactTracker.record_turn(). Returns guidance to append to the
        system prompt for this turn, clearing the pending label -- "" if
        nothing is pending."""
        if self._pending_label is None:
            return ""
        guidance = _WEAVE_IN_TEMPLATE.format(label=self._pending_label)
        self._pending_label = None
        return guidance
