# Animal Facts Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Weave real animal facts naturally into story action when a
known animal is mentioned, keep the whole story grounded in reality, and
nudge the child to pick an animal if the story starts without one.

**Architecture:** One new module, `animal_facts.py`, mirroring
`story_arc.py`/`safety.py`'s existing deterministic-logic-plus-guidance-
string pattern: a curated animal/alias table, an on-disk JSON fact cache,
an API Ninjas client used only on a cache miss, and a stateful
`AnimalFactTracker` (parallel to `StoryArc`) that `SessionRunner` calls
once per turn. `safety.py` gains one new word category and its
`is_safe()` is reused directly on raw fact candidates before they're ever
offered to the LLM, in addition to its existing use on the final reply.

**Tech Stack:** Python 3.12, `httpx` (already a dependency, used the same
way `llm_groq.py` already uses it), stdlib `json`/`pathlib`/`random`/`re`.

## Global Constraints

- Full spec: `docs/superpowers/specs/2026-08-27-animal-facts-retrieval-design.md`.
- Free/local models only; the one exception is the animal facts API
  itself, which is a plain data lookup (not an AI/generation service) and
  is explicitly approved in the spec, same category as Groq being an
  approved *testing-only* exception elsewhere in this codebase — this one
  is approved for real use, not testing-only.
- No extra LLM/model calls anywhere in this plan — fact weaving happens
  via guidance text appended to the existing per-turn `stream_reply` call,
  never a second generation call.
- `server/data/` (where the fact cache lives) is already gitignored by the
  story generation engine plan — no new `.gitignore` entry needed.
- Every fact is checked with `safety.is_safe()` before being cached or
  used as guidance, in addition to the existing `filter_reply()` check on
  the final reply.
- Before running any `pytest`/`python` command: confirm the venv is
  active (`which python` resolves inside `server/.venv`, not a pyenv shim
  or system path) and run commands from the `server/` directory.
- `ANIMAL_FACTS_API_KEY` is resolved from the environment at call time
  (inside the function that uses it), not bound as a function/constructor
  default — same reasoning as `GroqLlm`'s existing `api_key` handling in
  `llm_groq.py`: a default value would freeze whatever the env var held
  at first import, not pick up a key set later.
- A missing `ANIMAL_FACTS_API_KEY`, a failed API call, or any other
  failure in this feature must never raise out to `SessionRunner` or
  block/degrade the core turn — always a soft "no fact this turn",
  logged, never raised.

---

### Task 1: Expand `safety.py` with a reproduction/mating category

**Files:**
- Modify: `server/tinytalk/safety.py`
- Test: `server/tests/test_safety.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature changes — `is_safe(text: str) -> bool` and
  `filter_reply(text: str) -> str` are unchanged; only the internal
  word list grows. Task 2 depends on `is_safe` existing (it already does
  today) but not on this task specifically completing first — the two
  tasks can be done in either order.

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_safety.py`, alongside the existing
`test_blocked_words_are_unsafe`/similar tests (check the top of the file
for its existing imports — it already imports `is_safe` and
`filter_reply` from `tinytalk.safety`):

```python
@pytest.mark.parametrize(
    "text",
    [
        "The two foxes will mate in the spring.",
        "Foxes are mating right now.",
        "The rabbits started breeding early this year.",
        "She is pregnant with a litter of kittens.",
        "The pregnancy lasts about two months.",
        "Animals reproduce in many different ways.",
        "This is how animals reproduction works.",
    ],
)
def test_reproduction_content_is_unsafe(text):
    assert is_safe(text) is False


def test_filter_replaces_reproduction_content_with_fallback():
    assert filter_reply("The two foxes will mate in the spring.") == SAFE_FALLBACK
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_safety.py -k reproduction -v`
Expected: FAIL — `test_reproduction_content_is_unsafe` fails for every
parametrized case (none of these words are blocked yet).

- [ ] **Step 3: Add the new category**

In `server/tinytalk/safety.py`, add a new tuple after `_REAL_WORLD_DANGER`
and before `_PROFANITY`:

```python
# Real animal facts mention this far more often than ordinary story
# dialogue ever does -- confirmed, while designing this feature, that
# none of the existing five categories had any coverage for it.
_REPRODUCTION = (
    "mate",
    "mates",
    "mating",
    "breed",
    "breeds",
    "breeding",
    "pregnant",
    "pregnancy",
    "reproduce",
    "reproduces",
    "reproducing",
    "reproduction",
)
```

Then update `_ALL_BLOCKED` to include it:

```python
_ALL_BLOCKED = _VIOLENCE + _FRIGHTENING + _ADULT_THEMES + _REAL_WORLD_DANGER + _REPRODUCTION + _PROFANITY
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_safety.py -v`
Expected: PASS — all tests, including the new ones and every existing
one (nothing else in the file should be affected).

- [ ] **Step 5: Commit**

```bash
cd server
git add tinytalk/safety.py tests/test_safety.py
git commit -m "feat(server): add reproduction/mating category to safety filter"
```

---

### Task 2: `animal_facts.py` — detection, cache, API client, and `AnimalFactTracker`

**Files:**
- Create: `server/tinytalk/animal_facts.py`
- Modify: `server/tinytalk/config.py` (add `ANIMAL_FACTS_API_KEY`)
- Test: `server/tests/test_animal_facts.py`

**Interfaces:**
- Consumes:
  - `config.ANIMAL_FACTS_API_KEY: str` (this task adds it, empty string
    default).
  - `safety.is_safe(text: str) -> bool` (already exists).
  - `story_arc.Stage` (already exists: `SETUP`, `RISING_ACTION`,
    `CLIMAX`, `RESOLUTION`, `DONE`).
- Produces (used by Task 4):
  - `class AnimalFactTracker`:
    - `__init__(self) -> None`
    - `async def record_turn(self, transcript: str, stage: Stage) -> str`
      — call once per turn, alongside `StoryArc.record_turn()`, passing
      that same turn's `story_arc.stage`. Returns guidance to append to
      the system prompt for this turn, or `""` if there's nothing to add.
  - `FACTS_CACHE_PATH: Path` — the default on-disk cache location, for
    tests and for anyone wanting to point at a different path.

- [ ] **Step 1: Add the API key config constant**

Add this to `server/tinytalk/config.py`, immediately after the
`GROQ_MODEL` line:

```python
# Free sign-up at https://api-ninjas.com (100 requests/hour free tier) --
# used only on the first-ever mention of a given animal; every later
# mention, in any story, is an instant local cache lookup with no network
# call. See animal_facts.py.
ANIMAL_FACTS_API_KEY = os.environ.get("ANIMAL_FACTS_API_KEY", "")
```

- [ ] **Step 2: Write the failing tests for animal detection**

Create `server/tests/test_animal_facts.py`:

```python
from tinytalk.animal_facts import find_new_animal


def test_find_new_animal_matches_a_known_animal():
    assert find_new_animal("tell me a story about a fox", set()) == "fox"


def test_find_new_animal_matches_plural_form():
    assert find_new_animal("there were two foxes in the den", set()) == "fox"


def test_find_new_animal_matches_an_alias():
    assert find_new_animal("I saw a ladybird on the leaf", set()) == "ladybug"


def test_find_new_animal_is_case_insensitive():
    assert find_new_animal("A FOX ran past", set()) == "fox"


def test_find_new_animal_returns_none_when_no_known_animal_mentioned():
    assert find_new_animal("the sun was warm and bright", set()) is None


def test_find_new_animal_skips_already_facted_animals():
    assert find_new_animal("the fox and the rabbit ran", {"fox"}) == "rabbit"


def test_find_new_animal_returns_none_if_only_mentioned_animal_already_facted():
    assert find_new_animal("the fox ran fast", {"fox"}) is None


def test_find_new_animal_does_not_match_substrings():
    # "foxglove" contains "fox" but is a plant, not an animal mention.
    assert find_new_animal("the foxglove flowers bloomed", set()) is None
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.animal_facts'`.

- [ ] **Step 4: Create the module with the animal table and detection**

Create `server/tinytalk/animal_facts.py`:

```python
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: PASS — all 8 tests.

- [ ] **Step 6: Commit**

```bash
cd server
git add tinytalk/animal_facts.py tinytalk/config.py tests/test_animal_facts.py
git commit -m "feat(server): animal detection against a curated alias table"
```

- [ ] **Step 7: Write the failing tests for the on-disk cache**

Add to `server/tests/test_animal_facts.py`:

```python
import json

from tinytalk.animal_facts import _load_cache, _save_cache


def test_load_cache_returns_empty_dict_when_file_does_not_exist(tmp_path):
    assert _load_cache(tmp_path / "does_not_exist.json") == {}


def test_save_then_load_round_trips(tmp_path):
    path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["foxes are great listeners"]}, path)
    assert _load_cache(path) == {"fox": ["foxes are great listeners"]}


def test_save_cache_creates_parent_directory(tmp_path):
    path = tmp_path / "nested" / "animal_facts.json"
    _save_cache({"fox": []}, path)
    assert path.exists()


def test_load_cache_treats_corrupt_json_as_empty(tmp_path):
    path = tmp_path / "animal_facts.json"
    path.write_text("{not valid json")
    assert _load_cache(path) == {}


def test_load_cache_treats_non_object_json_as_empty(tmp_path):
    path = tmp_path / "animal_facts.json"
    path.write_text("[1, 2, 3]")
    assert _load_cache(path) == {}
```

- [ ] **Step 8: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -k cache -v`
Expected: FAIL with `ImportError: cannot import name '_load_cache'`.

- [ ] **Step 9: Add the cache functions**

Append to `server/tinytalk/animal_facts.py`:

```python
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
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: PASS — all tests so far (13 total).

- [ ] **Step 11: Commit**

```bash
cd server
git add tinytalk/animal_facts.py tests/test_animal_facts.py
git commit -m "feat(server): on-disk JSON cache for animal facts"
```

- [ ] **Step 12: Write the failing tests for fact extraction and safety filtering**

Add to `server/tests/test_animal_facts.py`:

```python
from tinytalk.animal_facts import _extract_facts


def test_extract_facts_pulls_from_curated_fields():
    record = {
        "characteristics": {
            "most_distinctive_feature": "large pointed ears",
            "diet": "Omnivore",
            "top_speed": "30 mph",
        }
    }
    facts = _extract_facts(record)
    assert "its most distinctive feature is large pointed ears" in facts
    assert "its diet is Omnivore" in facts
    assert "it can move as fast as 30 mph" in facts


def test_extract_facts_skips_missing_and_empty_fields():
    record = {"characteristics": {"most_distinctive_feature": "", "diet": "Omnivore"}}
    facts = _extract_facts(record)
    assert facts == ["its diet is Omnivore"]


def test_extract_facts_ignores_fields_outside_the_curated_allowlist():
    # gestation_period/age_of_sexual_maturity/biggest_threat etc. are
    # deliberately not in _FACT_FIELD_TEMPLATES -- their raw values (e.g.
    # "63 days", "Humans") wouldn't be caught by the word-list safety
    # filter, so exclusion at extraction time is the real protection.
    record = {
        "characteristics": {
            "gestation_period": "63 days",
            "diet": "Omnivore",
        }
    }
    facts = _extract_facts(record)
    assert facts == ["its diet is Omnivore"]


def test_extract_facts_drops_unsafe_candidates():
    record = {"characteristics": {"slogan": "Known for its violent mating rituals"}}
    assert _extract_facts(record) == []


def test_extract_facts_returns_empty_list_when_no_characteristics():
    assert _extract_facts({"name": "Fox"}) == []
```

- [ ] **Step 13: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -k extract -v`
Expected: FAIL with `ImportError: cannot import name '_extract_facts'`.

- [ ] **Step 14: Add fact extraction**

Append to `server/tinytalk/animal_facts.py`:

```python
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
```

- [ ] **Step 15: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: PASS — all tests so far (18 total).

- [ ] **Step 16: Commit**

```bash
cd server
git add tinytalk/animal_facts.py tests/test_animal_facts.py
git commit -m "feat(server): extract safety-filtered facts from an API Ninjas record"
```

- [ ] **Step 17: Write the failing tests for the API client**

Add to `server/tests/test_animal_facts.py`:

```python
import httpx
import pytest

from tinytalk import config
from tinytalk.animal_facts import _fetch_facts_from_api


async def test_fetch_facts_from_api_returns_extracted_facts(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["name"] == "fox"
        assert request.headers["X-Api-Key"] == "test-key"
        return httpx.Response(
            200,
            json=[{"characteristics": {"diet": "Omnivore"}}],
        )

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts == ["its diet is Omnivore"]


async def test_fetch_facts_from_api_returns_empty_list_for_no_matches(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    facts = await _fetch_facts_from_api("nonexistent", transport=httpx.MockTransport(handler))
    assert facts == []


async def test_fetch_facts_from_api_returns_none_on_non_200(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(429, text="rate limited")

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts is None


async def test_fetch_facts_from_api_returns_none_on_network_error(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts is None


async def test_fetch_facts_from_api_returns_none_without_an_api_key(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    facts = await _fetch_facts_from_api("fox")
    assert facts is None
```

- [ ] **Step 18: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -k fetch -v`
Expected: FAIL with `ImportError: cannot import name '_fetch_facts_from_api'`.

- [ ] **Step 19: Add the API client**

Append to `server/tinytalk/animal_facts.py`:

```python
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
```

- [ ] **Step 20: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: PASS — all tests so far (23 total).

- [ ] **Step 21: Commit**

```bash
cd server
git add tinytalk/animal_facts.py tests/test_animal_facts.py
git commit -m "feat(server): API Ninjas client for animal facts, cache-miss only"
```

- [ ] **Step 22: Write the failing tests for `get_fact` (cache + API tied together)**

Add to `server/tests/test_animal_facts.py`:

```python
from tinytalk.animal_facts import get_fact


async def test_get_fact_returns_cached_fact_without_calling_the_api(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["foxes have excellent hearing"]}, cache_path)

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("API must not be called on a cache hit")

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact == "foxes have excellent hearing"


async def test_get_fact_fetches_and_caches_on_a_miss(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[{"characteristics": {"diet": "Omnivore"}}])

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact == "its diet is Omnivore"
    assert _load_cache(cache_path) == {"fox": ["its diet is Omnivore"]}


async def test_get_fact_returns_none_and_caches_empty_when_api_has_no_data(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact is None
    assert _load_cache(cache_path) == {"fox": []}


async def test_get_fact_does_not_cache_on_api_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="server error")

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact is None
    assert _load_cache(cache_path) == {}


async def test_get_fact_picks_randomly_among_multiple_cached_facts(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["fact one", "fact two", "fact three"]}, cache_path)

    seen = set()
    for _ in range(20):
        fact = await get_fact("fox", cache_path=cache_path, transport=None)
        seen.add(fact)
    assert seen == {"fact one", "fact two", "fact three"}
```

- [ ] **Step 23: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -k get_fact -v`
Expected: FAIL with `ImportError: cannot import name 'get_fact'`.

- [ ] **Step 24: Add `get_fact`**

Append to `server/tinytalk/animal_facts.py`:

```python
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
```

- [ ] **Step 25: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: PASS — all tests so far (28 total).

- [ ] **Step 26: Commit**

```bash
cd server
git add tinytalk/animal_facts.py tests/test_animal_facts.py
git commit -m "feat(server): get_fact ties the cache and API together"
```

- [ ] **Step 27: Write the failing tests for `AnimalFactTracker`**

Add to `server/tests/test_animal_facts.py`:

```python
from tinytalk.animal_facts import AnimalFactTracker
from tinytalk.story_arc import Stage


async def test_tracker_returns_weave_in_guidance_for_a_known_animal(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("tell me about a fox", Stage.SETUP)

    assert "fox" in guidance
    assert "foxes have excellent hearing" in guidance


async def test_tracker_does_not_refact_the_same_animal_twice(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    await tracker.record_turn("tell me about a fox", Stage.SETUP)
    guidance = await tracker.record_turn("the fox ran through the forest", Stage.RISING_ACTION)

    assert guidance == ""


async def test_tracker_nudges_for_an_animal_during_setup_with_none_mentioned(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("let's make up a story", Stage.SETUP)

    assert "animal" in guidance.lower()


async def test_tracker_does_not_nudge_once_an_animal_has_been_mentioned(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    await tracker.record_turn("tell me about a fox", Stage.SETUP)
    guidance = await tracker.record_turn("what happens next", Stage.SETUP)

    assert guidance == ""


async def test_tracker_does_not_nudge_outside_setup(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("let's keep going", Stage.RISING_ACTION)

    assert guidance == ""


async def test_tracker_returns_empty_string_when_no_fact_is_available(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("tell me about a fox", Stage.SETUP)

    # No API key configured -- get_fact returns None, so no weave-in
    # guidance, but the animal was still detected/mentioned, so the nudge
    # must not fire either.
    assert guidance == ""
```

- [ ] **Step 28: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -k tracker -v`
Expected: FAIL with `ImportError: cannot import name 'AnimalFactTracker'`.

- [ ] **Step 29: Add `AnimalFactTracker`**

Append to `server/tinytalk/animal_facts.py`:

```python
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
```

- [ ] **Step 30: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_animal_facts.py -v`
Expected: PASS — all tests (34 total).

- [ ] **Step 31: Commit**

```bash
cd server
git add tinytalk/animal_facts.py tests/test_animal_facts.py
git commit -m "feat(server): AnimalFactTracker weaves facts in and nudges for an animal"
```

---

### Task 3: Add the realism rule to `config.SYSTEM_PROMPT`

**Files:**
- Modify: `server/tinytalk/config.py`
- Create: `server/tests/test_config.py` (does not exist yet — `config.py`
  is currently just constants with no dedicated test file)

**Interfaces:**
- Consumes: nothing new.
- Produces: `config.SYSTEM_PROMPT` gains one more bullet line. No
  signature/type change — still a plain `str`.

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_config.py`:

```python
from tinytalk import config


def test_system_prompt_requires_the_story_stay_grounded_in_reality():
    prompt = config.SYSTEM_PROMPT.lower()
    assert "grounded in the real world" in prompt
    assert "animal characters can talk" in prompt
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd server && .venv/bin/python -m pytest tests/test_config.py -v`
Expected: FAIL — the assertions don't find this text in the current prompt.

- [ ] **Step 3: Add the rule to `SYSTEM_PROMPT`**

In `server/tinytalk/config.py`, `SYSTEM_PROMPT`'s bullet list currently
ends with:

```python
    "- Write plain spoken words only: no emoji, no asterisks, no stage "
    "directions, no narration about yourself."
)
```

Insert a new bullet immediately before that final one (so the list reads
in the same "Rules you always follow" block, unchanged everywhere else):

```python
    "- Keep the story grounded in the real world: no magic, no talking "
    "plants or objects, no impossible physics. Animal characters can "
    "talk and think like people, but everything else about the world "
    "should be realistic.\n"
    "- Write plain spoken words only: no emoji, no asterisks, no stage "
    "directions, no narration about yourself."
)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd server && .venv/bin/python -m pytest tests/test_config.py -v`
Expected: PASS.

- [ ] **Step 5: Run the full test suite to check nothing else depends on the exact prompt text**

Run: `cd server && .venv/bin/python -m pytest -v`
Expected: PASS. If any test in `test_session.py` asserts the exact,
complete system prompt string (rather than checking it contains
particular guidance substrings), update that assertion to match the new
text — check `test_llm_receives_system_prompt_and_history` specifically,
since story_arc's own plan added guidance the same way and that test
already exists.

- [ ] **Step 7: Commit**

```bash
cd server
git add tinytalk/config.py tests/test_config.py
git commit -m "feat(server): require the story stay grounded in reality"
```

---

### Task 4: Wire `AnimalFactTracker` into `SessionRunner`

**Files:**
- Modify: `server/tinytalk/session.py`
- Modify: `server/tests/conftest.py` (new autouse fixture)
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `AnimalFactTracker` (Task 2) and `config.SYSTEM_PROMPT`'s new
  rule (Task 3) — both already in place.
- Produces: no new public interface — this task only changes
  `SessionRunner`'s internal turn flow.

- [ ] **Step 1: Protect the whole test suite from the real, on-disk fact cache**

`FakeStt`'s default transcript (`server/tests/conftest.py`) is literally
`"tell me about a fox"`, used by many existing tests across the suite
that don't pass their own `stt=` override. Once `AnimalFactTracker` is
wired into `SessionRunner` in this task, every one of those tests would
call `get_fact("fox")` — which, unless redirected, reads (and could
write) the real `server/data/animal_facts.json` a developer may have
already populated by running the actual server. Without this fixture,
whether the full suite passes would depend on that developer's local
machine state, not on the code — add this fixture to `server/tests/conftest.py`
now, before this task's own wiring step, so it's protecting the suite
the moment that wiring lands. Add it near the top of the file, alongside
the existing fixtures:

```python
@pytest.fixture(autouse=True)
def isolated_animal_facts_cache(tmp_path, monkeypatch):
    """Redirects the on-disk animal facts cache to an isolated temp path
    for every test in the suite -- without this, a pre-existing "fox"
    cache entry on a developer's machine (from running the real server)
    would silently change what tests using the default transcript
    ("tell me about a fox") send to the LLM."""
    path = tmp_path / "animal_facts.json"
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", path)
    return path
```

This runs automatically for every test (`autouse=True`) — individual
tests in Step 2 below still explicitly redirect `FACTS_CACHE_PATH`
themselves too, which is harmless (both point into the same per-test
`tmp_path`, just naming the file differently); the explicit version in
each test is what makes that test's own intent clear to a reader, while
this fixture is the safety net for every test that never mentions
animals at all.

- [ ] **Step 2: Write the failing integration tests**

Add to `server/tests/test_session.py`, using the file's existing
`make_session`/`run_full_turn`/`FakeLlm`/`FakeStt`/`transport`
fixtures/helpers (all defined at the top of the file already) and
pytest's built-in `tmp_path` fixture (provided automatically for any
test function that takes it as a parameter — no import needed) for an
isolated, per-test cache location:

```python
async def test_animal_mention_adds_fact_guidance_to_the_llm_call(transport, monkeypatch, tmp_path):
    from tinytalk.animal_facts import _save_cache

    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")
    llm = FakeLlm()
    session = make_session(transport, stt=FakeStt(transcript="tell me about a fox"), llm=llm)

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert system_message["role"] == "system"
    assert "foxes have excellent hearing" in system_message["content"]


async def test_no_animal_mentioned_sends_no_fact_guidance(transport, monkeypatch, tmp_path):
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    llm = FakeLlm()
    session = make_session(
        transport, stt=FakeStt(transcript="what is your favorite color"), llm=llm
    )

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "Weave this real fact" not in system_message["content"]


async def test_animal_free_first_turn_gets_the_nudge(transport, monkeypatch, tmp_path):
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    llm = FakeLlm()
    session = make_session(
        transport, stt=FakeStt(transcript="let's make up a story"), llm=llm
    )

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "what animal should be in the story" in system_message["content"]
```

(`make_session`, `run_full_turn`, `FakeLlm`, `FakeStt`, and the
`transport` fixture are all defined at the top of `server/tests/test_session.py`
already, from the story generation engine plan's own equivalent tests.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_session.py -k animal -v`
Expected: FAIL — `AnimalFactTracker` isn't wired in yet, so no fact
guidance ever appears in any system message.

- [ ] **Step 4: Wire `AnimalFactTracker` into `SessionRunner`**

In `server/tinytalk/session.py`:

Add the import near the top, alongside the existing `from .story_arc
import StoryArc`:

```python
from .animal_facts import AnimalFactTracker
```

In `__init__`, immediately after `self._story_arc = StoryArc()`:

```python
        self._animal_facts = AnimalFactTracker()
```

In `_run_turn`, immediately after the existing line
`guidance = self._story_arc.record_turn(transcript)`, insert:

```python
            fact_guidance = await self._animal_facts.record_turn(
                transcript, self._story_arc.stage
            )
            if fact_guidance:
                guidance = f"{guidance}\n\n{fact_guidance}"
```

Wherever `self._conversation = Conversation()` and `self._story_arc =
StoryArc()` are both reset together on story completion, add the third
line immediately after them:

```python
                self._animal_facts = AnimalFactTracker()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_session.py -v`
Expected: PASS — the three new tests, and every existing test in this
file (nothing about the existing turn flow should have changed for a
transcript that doesn't mention a known animal).

- [ ] **Step 6: Run the full server test suite**

Run: `cd server && .venv/bin/python -m pytest -v`
Expected: PASS, all tests across every file.

- [ ] **Step 7: Commit**

```bash
cd server
git add tinytalk/session.py tests/conftest.py tests/test_session.py
git commit -m "feat(server): wire AnimalFactTracker into the per-turn flow"
```
