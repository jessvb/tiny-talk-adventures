# Animal Facts Retrieval — Design Spec

Status: Approved (design confirmed by user 2026-08-27)

## Context

Fourth sub-project of Tiny Talk Adventures, following the voice/dialog
pipeline (server + iOS phone client) and the story generation engine — see
`docs/superpowers/specs/2026-08-24-story-generation-engine-design.md`'s
"Non-goals" section, which explicitly deferred "animal facts integration"
to its own spec. This is that spec.

The server today (`server/tinytalk/session.py`) runs a working LLM-backed
storytelling loop: `StoryArc` steers narrative shape, `safety.py` filters
what gets spoken, `story_store.py` persists finished stories. The LLM's
replies are otherwise free-form fiction with no connection to the real
world. The motivating idea, from the household's own words during an
earlier session: *"I'm looking forward to seeing how real facts will
ground the responses!"*

Personal pet project, single household — see root `CLAUDE.md` for the
constraints that apply project-wide (free/local models only,
privacy-first, kid-safe content, no production concerns beyond what this
family's use actually needs).

## Goals

- When an animal the child or agent mentions is a recognized one, weave one
  real fact about it naturally into the *action* of the story — not stated
  as a "did you know" aside, but as part of what the animal character does
  or experiences (e.g. "the fox heard a mouse squeak over the hill, a
  hundred feet away — foxes have incredible hearing" rather than "did you
  know foxes have great hearing?").
- Keep the whole story grounded in the real world as a standing rule, not
  just where facts are woven in: no magic, no talking plants or objects,
  no impossible physics. Animal characters may still talk and think like
  people — that's the one deliberate exception.
- If the child hasn't mentioned any animal by the time the story is just
  getting started, nudge them to pick one, rather than letting the story
  proceed with nothing to ground.
- Retrieve facts from a free public API on first mention of a given
  animal, then cache them to disk — every later story, for any child in
  the household, gets that animal's facts as an instant local lookup with
  no network call.
- Never let a missing fact, a slow API, or a network failure block or
  degrade the core storytelling turn — this is strictly an enrichment on
  top of the existing pipeline, not a new dependency it can fail on.

## Non-goals (deferred or explicitly out of scope)

- Open-ended "any animal" detection. Detection matches against a curated,
  hand-maintained list of animal names (with common aliases/plurals), the
  same style as `safety.py`'s word lists — not free-text NLP.
- On-device object recognition, illustration sourcing, storybook
  persistence UI — later, independent sub-projects per the project
  roadmap.
- A second LLM call to extract or rephrase facts. The same `stream_reply`
  call that generates the story reply also weaves the fact in, via
  guidance text appended to the system prompt — identical mechanism to
  how `StoryArc` already injects per-turn guidance, adding no extra
  latency or model calls.
- Semantic/AI content moderation of facts. Facts are filtered by the same
  deterministic `safety.py` word-list approach as everything else — see
  Components below for the new category this spec adds to it.
- Automatic refreshing of already-cached facts. Once an animal has been
  fetched, it is never re-queried; if richer or updated data is wanted
  later, deleting that animal's entry from the cache file forces a
  re-fetch next time it's mentioned. No scheduled refresh job.

## Architecture

One new module, mirroring `story_arc.py`/`safety.py`'s existing pattern —
deterministic detection and cache lookup logic, no LLM calls of its own:

- **`animal_facts.py`** — the curated animal name/alias table, the
  stateful per-story `AnimalFactTracker` (parallel to `StoryArc`), the
  on-disk fact cache, and the API Ninjas client used only on a cache miss.
- **`safety.py`** (extended) — one new word-list category for
  reproductive/mating content, and both `is_safe`/`filter_reply` get
  reused directly against raw fact text, not just LLM replies.
- **`config.py`** (extended) — `ANIMAL_FACTS_API_KEY`, resolved from the
  environment the same way `GROQ_API_KEY` already is.

`SessionRunner` wires `AnimalFactTracker` into the existing per-turn flow
exactly where `StoryArc` is already wired in: its guidance is appended to
the system prompt alongside (not instead of) `StoryArc`'s own guidance.

## Components

### `animal_facts.py`

```python
# Canonical name -> all recognized surface forms (aliases, plurals,
# regional spellings). Detection matches any alias; the cache and API
# query always use the canonical (dict key) name.
_KNOWN_ANIMALS: dict[str, tuple[str, ...]] = {
    "fox": ("fox", "foxes"),
    "rabbit": ("rabbit", "rabbits", "bunny", "bunnies"),
    "ladybug": ("ladybug", "ladybugs", "ladybird", "ladybirds"),
    "elephant": ("elephant", "elephants"),
    "owl": ("owl", "owls"),
    "dolphin": ("dolphin", "dolphins"),
    # ... full curated list decided during implementation; not meaningful
    # design content, same reasoning as the story generation engine
    # spec's deferred profanity word list.
}

class AnimalFactTracker:
    def __init__(self) -> None: ...

    def record_turn(self, transcript: str, stage: Stage) -> str:
        """Call once per turn, alongside StoryArc.record_turn(), with that
        same turn's StoryArc.stage. Returns guidance to append to the
        system prompt for this turn -- empty string if there's nothing to
        add. Behavior:

        1. Scan transcript for a known animal alias not yet facted this
           story. If found: get_fact(canonical_name) (cache or API,
           safety-filtered); if a fact comes back, mark this animal
           facted and return weave-in guidance containing it.
        2. Otherwise, if stage is SETUP and no animal has been facted (or
           detected) yet this story: return guidance asking the agent to
           invite the child to pick an animal for the story.
        3. Otherwise: return "".
        """

def get_fact(canonical_name: str) -> str | None:
    """Cache lookup; on miss, calls the API, extracts fact strings from
    the response, safety-filters each, caches the surviving set, and
    returns one at random. Returns None if nothing safe/usable is
    available (cache miss AND API failure/no data AND nothing left after
    filtering)."""
```

- **Fact extraction, one API call per animal, ever:** on a cache miss, one
  call to API Ninjas' Animals endpoint (`GET /v1/animals?name=<canonical
  name>`) returns a structured record (diet, habitat, most-distinctive-
  feature, and similar fields). Each populated field becomes its own fact
  string. All of them are safety-filtered and cached together in one
  write — this is what gives an animal multiple facts without ever
  needing to call the API again for it. `get_fact` picks one at random on
  each call, so repeated stories over time don't repeat the identical
  fact.
- **Weave-in guidance** (case 1 above), e.g.:
  > "The story just mentioned a fox. Weave this real fact about foxes
  > naturally into what happens next, as part of the action -- don't just
  > state it as trivia: foxes can hear a mouse squeak from 100 feet away."
- **First-animal nudge guidance** (case 2 above), e.g.:
  > "No animal has been part of the story yet. Before continuing, warmly
  > ask the child what animal should be in the story."
- `AnimalFactTracker` is constructed fresh in `SessionRunner.__init__`
  alongside `StoryArc`, and replaced (like `StoryArc`) whenever a story
  finishes and a new `Conversation`/`StoryArc` pair is created — so "not
  yet facted this story" always means *this* story, not a household-wide
  history.

### `safety.py` (extended)

Adds one new category to the existing five, combined into the same single
compiled pattern (still zero-latency, still one regex pass):

- **Reproduction/mating**: mate, mates, mating, breed, breeds, breeding,
  pregnant, pregnancy, reproduce, reproduction. Chosen because real animal
  facts mention this far more often than ordinary story dialogue ever
  does — confirmed, during this spec's design review, that the existing
  five categories had no coverage for it at all.

Both `is_safe(text)` and `filter_reply(text)` keep their existing
signatures — no caller changes needed. `animal_facts.py`'s `get_fact`
calls `is_safe()` directly on each candidate fact string before it's ever
cached or used as guidance (never on the whole reply — that's
`filter_reply`'s job downstream, unchanged). A fact that fails this check
is dropped, not stored, not retried; if every field from a given API
response fails, `get_fact` caches an empty list for that animal (so it's
correctly remembered as "no usable facts", not repeatedly re-fetched) and
returns `None`.

### `config.py` (extended)

```python
ANIMAL_FACTS_API_KEY = os.environ.get("ANIMAL_FACTS_API_KEY", "")
```

Resolved at call time inside `animal_facts.py`'s API client, not bound as
a constructor default — same reasoning, and same bug this pattern avoids,
as `GroqLlm`'s existing `api_key` handling in `llm_groq.py`. Free sign-up
at api-ninjas.com; free tier is 100 requests/hour, no commercial use (not
applicable here) — more than enough for a single household, since each
animal is only ever queried once, ever.

### `SessionRunner` integration

- Construction gains `self._animal_facts = AnimalFactTracker()` alongside
  `self._story_arc = StoryArc()`.
- In `_run_turn`, right after `guidance = self._story_arc.record_turn(transcript)`
  (the existing call, before `to_messages()` builds the LLM prompt): also
  call
  `fact_guidance = self._animal_facts.record_turn(transcript, self._story_arc.stage)`
  and append it to the existing guidance when non-empty —
  `guidance = f"{guidance}\n\n{fact_guidance}"` — before it's passed into
  `to_messages()` the same way it already is today.
- Wherever `self._conversation`/`self._story_arc` are replaced with fresh
  instances on story completion: `self._animal_facts = AnimalFactTracker()`
  gets replaced there too.
- `config.SYSTEM_PROMPT` gains one new standing rule in its existing
  bullet list: *"Keep the story grounded in the real world: no magic, no
  talking plants or objects, no impossible physics. Animal characters can
  talk and think like people, but everything else about the world should
  be realistic."*

## Data flow

```
child speaks
  -> STT transcript
  -> StoryArc.record_turn(transcript)          [unchanged]
     -> story guidance
  -> AnimalFactTracker.record_turn(transcript, stage)
     -> scan for a known animal alias not yet facted this story
     -> if found: get_fact(canonical_name)
          -> cache hit: pick one fact at random
          -> cache miss: call API Ninjas, extract fields into fact
             strings, safety.is_safe() each, cache the surviving set,
             pick one at random (or None if nothing usable)
     -> fact guidance (weave-in, first-animal nudge, or "")
  -> LLM call with system_prompt + story guidance + fact guidance
  -> reply text
  -> safety.filter_reply(reply)                 [unchanged, second safety net]
  -> StoryArc.record_reply(filtered reply)       [unchanged]
  -> TTS + send to child                         [unchanged]
```

## Error handling

- Any API Ninjas failure (network error, timeout, non-200, empty/
  unrecognized response) is caught inside `get_fact`, logged, and treated
  as "no fact available" — `AnimalFactTracker.record_turn` returns `""`
  for that turn and the story continues exactly as it does today. This
  mirrors this session's own recent fix for empty LLM replies: an
  enrichment failing must never degrade or block the core turn.
- The API call is on the turn's critical path (its result feeds the
  system prompt before the LLM call starts), so it uses a short timeout
  (~4s) — but only on an animal's first-ever mention; every subsequent
  mention, in any story, is an instant local cache lookup with no network
  call at all.
- A failed cache write (disk full, permissions) is logged and swallowed,
  not raised — same reasoning, and same precedent, as `story_store.py`'s
  existing `save_story` error handling. The fetched fact is still used
  for this turn's guidance even if persisting it for next time failed.
- A malformed/corrupt cache file on disk is treated as an empty cache
  (logged, not raised) rather than crashing server startup.

## Testing approach

- `test_animal_facts.py`: alias matching (including plurals and regional
  spellings) resolving to the correct canonical name; `AnimalFactTracker`
  not re-facting the same animal twice in one story; the first-animal
  nudge firing only during `SETUP` with nothing facted yet, and never
  again once an animal has been mentioned; `get_fact` cache-hit path
  (no HTTP call made); `get_fact` cache-miss path against a fake/injected
  HTTP client (same pattern `test_llm_groq.py` already uses for
  `GroqLlm`) covering success, non-200, timeout, and malformed-response
  cases; an unsafe candidate fact being dropped and not cached; a corrupt
  cache file being treated as empty rather than raising.
- `test_safety.py`: extend the existing parametrized cases with the new
  reproduction/mating category, same wholesome-text-passes /
  blocked-word-fails pattern already there.
- `test_session.py`: integration coverage — fact guidance text actually
  appears in the messages sent to the LLM when a known animal is
  mentioned; the first-animal nudge appears on an animal-free turn one;
  a turn with no recognized animal and no nudge condition sends no fact
  guidance at all (baseline behavior unchanged for stories that don't
  trigger this feature).

## Open questions / risks

- The curated animal list's actual contents (which species, which
  aliases) are decided during implementation, not enumerated here — same
  reasoning as the story generation engine spec's deferred profanity word
  list: the exact entries aren't meaningful design content, only the
  mechanism for using them is.
- API Ninjas' exact response schema (which fields are always present vs.
  sometimes empty, whether a name query can return multiple matching
  records for one animal) needs verifying against the real API during
  implementation — this spec's design doesn't depend on the exact field
  list, only on "some structured fields come back and get turned into
  fact strings," so this is a low-risk detail to confirm while building,
  not a blocker to starting.
- The deterministic reproduction/mating word list, like the rest of
  `safety.py`, can miss paraphrased content or false-positive on an
  unlucky phrase — same accepted limitation as the rest of that module,
  not a new risk this spec introduces.
- Real on-device testing may find the weave-in guidance's exact wording
  needs tuning (e.g. the LLM stating the fact too baldly despite being
  asked not to) — expect to adjust the guidance string's phrasing after
  first real use, same as `StoryArc`'s stage guidance was already tuned
  this way.
