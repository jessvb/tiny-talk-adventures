"""Placeholder safety filter for LLM output.

STUB. This is a keyword denylist standing in for real safety scaffolding,
which is a separate sub-project. It exists so the pipeline has the right
shape — a checkpoint between the LLM and the child's ears — not because a
denylist is adequate protection. Do not mistake this for the real thing.
"""

from __future__ import annotations

import re

SAFE_FALLBACK = "Hmm, let's take the story somewhere else! What should happen next?"

_BLOCKED_WORDS = (
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
)

# Word boundaries keep "begun" and "knifemaker" from tripping the filter.
_BLOCKED_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(word) for word in _BLOCKED_WORDS) + r")\b",
    re.IGNORECASE,
)


def is_safe(text: str) -> bool:
    return _BLOCKED_PATTERN.search(text) is None


def filter_reply(text: str) -> str:
    return text if is_safe(text) else SAFE_FALLBACK
