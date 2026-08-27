"""Deterministic safety filter for LLM output.

A word/phrase denylist across five categories, checked in one regex pass.
This is deliberately NOT semantic content understanding -- it can miss
paraphrased unsafe content and can false-positive on an unlucky
substring -- but it is zero-latency and adds no model calls, which
matters given STT+LLM+TTS already run concurrently under real memory
pressure on the M1/16GB server (see the voice/dialog pipeline design
spec's risks section). See
docs/superpowers/specs/2026-08-24-story-generation-engine-design.md for
the full rationale. Do not mistake this for the real thing -- it is a
meaningfully broader net than the original 12-word stub, not exhaustive
content moderation.
"""

from __future__ import annotations

import re

SAFE_FALLBACK = "Hmm, let's take the story somewhere else! What should happen next?"

_VIOLENCE = (
    "blood",
    "gun",
    "guns",
    "knife",
    "knives",
    "kill",
    "kills",
    "killed",
    "dead",
    "die",
    "dies",
    "died",
    "fight",
    "fights",
    "fighting",
    "hurt",
    "hurts",
    "hurting",
    "stab",
    "stabbed",
    "stabbing",
    "shoot",
    "shoots",
    "shooting",
)

_FRIGHTENING = (
    "monster attacking",
    "terrifying",
    "nightmare",
    "screamed in terror",
    "trapped forever",
    "pure evil",
    "demon",
    "demons",
)

# Deliberately does NOT include "kiss" -- a fairy-tale kiss (true love's
# kiss, a goodnight kiss) is a completely normal, wholesome element in
# children's stories; blocking the bare word would over-trigger
# constantly. See test_innocent_fairy_tale_kiss_stays_safe.
_ADULT_THEMES = (
    "drunk",
    "alcohol",
    "cigarette",
    "naked",
)

_REAL_WORLD_DANGER = (
    "play with matches",
    "playing with matches",
    "played with matches",
    "play with a lighter",
    "playing with a lighter",
    "played with a lighter",
    "poison",
    "drown",
    "drowned",  # verb-form variants of "drown", same reasoning as _VIOLENCE below
    "drowning",
    "jump off a cliff",
)

# Real animal facts mention this far more often than ordinary story
# dialogue ever does -- confirmed, while designing this feature, that
# none of the existing five categories had any coverage for it.
_REPRODUCTION = (
    "mating",
    "breeding",
    "pregnant",
    "pregnancy",
    "reproduce",
    "reproduces",
    "reproducing",
    "reproduction",
)

_PROFANITY = (
    "damn",
    "hell",
    "shit",
    "fuck",
    "ass",
    "asshole",
    "bitch",
    "crap",
    "bastard",
    "piss",
    "dick",
    "whore",
    "slut",
)

_ALL_BLOCKED = _VIOLENCE + _FRIGHTENING + _ADULT_THEMES + _REAL_WORLD_DANGER + _REPRODUCTION + _PROFANITY

# Word boundaries keep "begun" and "knifemaker" from tripping the filter.
_BLOCKED_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(word) for word in _ALL_BLOCKED) + r")\b",
    re.IGNORECASE,
)

# Known-safe phrases that would otherwise trip a blocked word above --
# masked out of the text BEFORE the blocked-word check runs, so a
# genuinely dangerous use of the same word elsewhere in the same
# sentence (e.g. "wished on a shooting star while shooting arrows at
# the target") still gets caught -- only the exact safe phrase is
# removed, nothing else. More general and reusable than narrowing every
# over-broad word into its own contextual phrases (see git history for
# how "matches"/"lighter"/"evil" were each handled individually before
# this existed) -- add a new entry here whenever a newly-added blocked
# word turns out to have a common innocent usage.
_SAFE_PHRASES = (
    "shooting star",
    "shooting stars",
)

_SAFE_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(phrase) for phrase in _SAFE_PHRASES) + r")\b",
    re.IGNORECASE,
)


def is_safe(text: str) -> bool:
    masked = _SAFE_PATTERN.sub("", text)
    return _BLOCKED_PATTERN.search(masked) is None


def filter_reply(text: str) -> str:
    return text if is_safe(text) else SAFE_FALLBACK
