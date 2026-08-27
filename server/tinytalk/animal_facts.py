"""Deterministic animal detection, on-disk fact caching, and API Ninjas
retrieval -- weaves one real fact about a mentioned animal into the
story's action, via guidance text appended to the same turn's LLM call
(no extra model call), the same mechanism story_arc.py already uses for
narrative-stage guidance. See
docs/superpowers/specs/2026-08-27-animal-facts-retrieval-design.md for
the full design.
"""

from __future__ import annotations

import json
import logging
import random
import re
from pathlib import Path

import httpx

from . import config, safety
from .story_arc import Stage

logger = logging.getLogger(__name__)

FACTS_CACHE_PATH = Path(__file__).resolve().parent.parent / "data" / "animal_facts.json"

# Canonical name -> all recognized surface forms (aliases, plurals,
# regional spellings). Detection matches any alias; the cache and API
# query always use the canonical (dict key) name -- so "ladybird" and
# "ladybug" share one cache entry instead of two. Deliberately a curated,
# fixed vocabulary (same style as safety.py's word lists), not free-text
# animal-name NLP.
_KNOWN_ANIMALS: dict[str, tuple[str, ...]] = {
    "fox": ("fox", "foxes"),
    "rabbit": ("rabbit", "rabbits", "bunny", "bunnies"),
    "ladybug": ("ladybug", "ladybugs", "ladybird", "ladybirds"),
    "elephant": ("elephant", "elephants"),
    "owl": ("owl", "owls"),
    "dolphin": ("dolphin", "dolphins"),
    "bear": ("bear", "bears"),
    "lion": ("lion", "lions"),
    "tiger": ("tiger", "tigers"),
    "wolf": ("wolf", "wolves"),
    "deer": ("deer", "deers"),
    "squirrel": ("squirrel", "squirrels"),
    "turtle": ("turtle", "turtles"),
    "frog": ("frog", "frogs"),
    "penguin": ("penguin", "penguins"),
    "dog": ("dog", "dogs", "puppy", "puppies"),
    "cat": ("cat", "cats", "kitten", "kittens"),
    "horse": ("horse", "horses"),
    "duck": ("duck", "ducks"),
    "butterfly": ("butterfly", "butterflies"),
    "bee": ("bee", "bees"),
    "giraffe": ("giraffe", "giraffes"),
    "monkey": ("monkey", "monkeys"),
    "whale": ("whale", "whales"),
    "shark": ("shark", "sharks"),
    "eagle": ("eagle", "eagles"),
}

# One compiled pattern per canonical name -- a few dozen entries at most,
# so this is not a hot loop worth optimizing further. Word boundaries
# keep "foxglove" from matching "fox".
_ANIMAL_PATTERNS: dict[str, re.Pattern[str]] = {
    canonical: re.compile(
        r"\b(?:" + "|".join(re.escape(alias) for alias in aliases) + r")\b",
        re.IGNORECASE,
    )
    for canonical, aliases in _KNOWN_ANIMALS.items()
}


def find_new_animal(transcript: str, already_facted: set[str]) -> str | None:
    """Returns the canonical name of the first known animal mentioned in
    transcript that isn't already in already_facted, or None if there
    isn't one. Iteration order follows _KNOWN_ANIMALS' definition order,
    so this is deterministic given the same transcript and already_facted."""
    for canonical, pattern in _ANIMAL_PATTERNS.items():
        if canonical in already_facted:
            continue
        if pattern.search(transcript):
            return canonical
    return None
