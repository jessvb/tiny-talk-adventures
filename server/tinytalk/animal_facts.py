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


def _load_cache(path: Path | None = None) -> dict[str, list[str]]:
    """Returns the on-disk fact cache, or an empty dict if the file
    doesn't exist yet or is corrupt -- logged, not raised, since a bad
    cache file must never crash server startup or a turn.

    path defaults to the CURRENT value of the module-level
    FACTS_CACHE_PATH, resolved inside the function body rather than
    bound as a parameter default -- a parameter default is frozen at
    first import, so it would not pick up a test's
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", ...)
    (same reasoning as llm_groq.py's GroqLlm resolving api_key at call
    time, not as a constructor default)."""
    if path is None:
        path = FACTS_CACHE_PATH
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        logger.error("failed to read animal facts cache at %s: %s", path, exc)
        return {}
    if not isinstance(data, dict):
        logger.error("animal facts cache at %s is not a JSON object -- ignoring", path)
        return {}
    return data


def _save_cache(cache: dict[str, list[str]], path: Path | None = None) -> None:
    """Writes the cache to disk. A failed write is logged and swallowed,
    not raised -- same reasoning as story_store.py's save_story: losing a
    cache write is unfortunate but must never crash or hang a turn. The
    fact already fetched this turn is still used for guidance regardless
    of whether persisting it for next time succeeded.

    path defaults to FACTS_CACHE_PATH, resolved at call time -- see
    _load_cache's doc comment for why this can't be a parameter default."""
    if path is None:
        path = FACTS_CACHE_PATH
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(cache, indent=2))
    except OSError as exc:
        logger.error("failed to write animal facts cache at %s: %s", path, exc)


# Curated allowlist of API Ninjas' "characteristics" fields -- the full
# set includes many more (gestation_period, age_of_sexual_maturity,
# average_litter_size, name_of_young, biggest_threat,
# estimated_population_size, and others), deliberately excluded here.
# Their raw values ("63 days", "Humans") don't contain any word
# safety.is_safe() would catch, so this allowlist -- not the safety
# filter -- is the real protection against reproduction/population/
# threat-related content leaking through. safety.is_safe() is still
# applied to every field below as a second layer, in case a field's
# free-text value (e.g. slogan) happens to contain something unsafe.
_FACT_FIELD_TEMPLATES: dict[str, str] = {
    "most_distinctive_feature": "its most distinctive feature is {value}",
    "top_speed": "it can move as fast as {value}",
    "diet": "its diet is {value}",
    "habitat": "it lives in {value}",
    "slogan": "{value}",
    "color": "its coloring is {value}",
    "group_behavior": "its group behavior is {value}",
    "lifespan": "its lifespan is {value}",
}


def _extract_facts(record: dict) -> list[str]:
    """Turns one API Ninjas animal record's characteristics into a list
    of safety-filtered fact strings, using only the curated field
    allowlist above. Order follows _FACT_FIELD_TEMPLATES' definition
    order for determinism; a missing, empty, or non-string field value is
    skipped."""
    characteristics = record.get("characteristics")
    if not isinstance(characteristics, dict):
        return []
    facts = []
    for field, template in _FACT_FIELD_TEMPLATES.items():
        value = characteristics.get(field)
        if not isinstance(value, str) or not value.strip():
            continue
        fact = template.format(value=value.strip())
        if safety.is_safe(fact):
            facts.append(fact)
        else:
            logger.info("dropping unsafe animal fact candidate: %r", fact)
    return facts


_API_HOST = "https://api.api-ninjas.com"


async def _fetch_facts_from_api(
    canonical_name: str,
    *,
    transport: httpx.BaseTransport | None = None,
    timeout: float = 4.0,
) -> list[str] | None:
    """Calls API Ninjas' Animals endpoint for canonical_name. Returns a
    list of safety-filtered fact strings extracted from the first
    matching record -- possibly empty, if the API found the animal but
    had no usable characteristics (this IS safe to cache, since it's a
    definitive answer). Returns None on any failure: missing API key,
    network error, timeout, non-200, or an unexpected response shape --
    distinct from an empty list, since a failure must NOT be cached, so a
    transient issue can be retried later rather than permanently
    remembering this animal as having no facts."""
    api_key = config.ANIMAL_FACTS_API_KEY
    if not api_key:
        logger.info("ANIMAL_FACTS_API_KEY not set -- skipping animal fact lookup")
        return None
    try:
        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            response = await client.get(
                f"{_API_HOST}/v1/animals",
                params={"name": canonical_name},
                headers={"X-Api-Key": api_key},
            )
            if response.status_code != 200:
                logger.warning(
                    "animal facts API returned %d for %r", response.status_code, canonical_name
                )
                return None
            records = response.json()
    except (httpx.HTTPError, json.JSONDecodeError) as exc:
        logger.warning("animal facts API call failed for %r: %s", canonical_name, exc)
        return None
    if not isinstance(records, list):
        logger.warning("animal facts API returned an unexpected shape for %r", canonical_name)
        return None
    if not records:
        return []
    return _extract_facts(records[0])


async def get_fact(
    canonical_name: str,
    *,
    cache_path: Path | None = None,
    transport: httpx.BaseTransport | None = None,
) -> str | None:
    """Returns one random fact about canonical_name, or None if none is
    available. Checks the on-disk cache first; on a miss, calls the API
    and writes a definitive result (even an empty list, so a "no usable
    facts" animal isn't re-queried every time it comes up) back to the
    cache. An API failure is never cached -- see _fetch_facts_from_api's
    own doc comment.

    cache_path defaults to FACTS_CACHE_PATH, resolved at call time inside
    _load_cache/_save_cache (passing None through to them), not bound
    here as a parameter default -- critical for AnimalFactTracker below,
    which calls get_fact(canonical) with no cache_path argument at all:
    a frozen-at-import default would silently ignore any test's
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", ...)."""
    cache = _load_cache(cache_path)
    if canonical_name not in cache:
        facts = await _fetch_facts_from_api(canonical_name, transport=transport)
        if facts is None:
            return None
        cache[canonical_name] = facts
        _save_cache(cache, cache_path)
    facts = cache[canonical_name]
    if not facts:
        return None
    return random.choice(facts)


_WEAVE_IN_TEMPLATE = (
    "The story just mentioned a {animal}. Weave this real fact about "
    "{animal}s naturally into what happens next, as part of the action -- "
    "don't just state it as trivia: {fact}"
)

_FIRST_ANIMAL_NUDGE = (
    "No animal has been part of the story yet. Before continuing, warmly "
    "ask the child what animal should be in the story."
)


class AnimalFactTracker:
    """Per-story tracker, constructed fresh alongside StoryArc and
    replaced whenever a story finishes and a new Conversation/StoryArc
    pair is created -- so "already facted" always means *this* story."""

    def __init__(self) -> None:
        self._facted: set[str] = set()
        self._any_animal_mentioned = False

    async def record_turn(self, transcript: str, stage: Stage) -> str:
        """Call once per turn, alongside StoryArc.record_turn(), with
        that same turn's story_arc.stage. Returns guidance to append to
        the system prompt for this turn -- "" if there's nothing to add."""
        canonical = find_new_animal(transcript, self._facted)
        if canonical is not None:
            self._any_animal_mentioned = True
            fact = await get_fact(canonical)
            if fact is not None:
                self._facted.add(canonical)
                return _WEAVE_IN_TEMPLATE.format(animal=canonical, fact=fact)
            return ""
        if stage is Stage.SETUP and not self._any_animal_mentioned:
            return _FIRST_ANIMAL_NUDGE
        return ""
