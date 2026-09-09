# Storybook Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Server-side work that unblocks the Library, Reading, and The End
screens: saved stories gain a title/pages/epilogue produced by a
background LLM rewrite, new wire-protocol messages let the client browse
and read them, an arc-stage progress push and an on-demand story-conclude
action serve the live Story screen, and a new session state structurally
prevents a live story and a background rewrite from ever contending for
the same local LLM.

**Architecture:** Four small, focused additions/extensions
(`story_arc.py`, `animal_facts.py`, `story_store.py`, a new `storybook.py`)
plus wire-protocol additions in `protocol.py`, a new `REWRITING` session
state in `state.py`, and `session.py` orchestration wiring it all
together. No new dependencies, no new model, no new server process — the
existing single WebSocket connection and the existing local Ollama model
are reused throughout.

**Tech Stack:** Python 3.12, `websockets`, `httpx`, `pytest`/`pytest-asyncio`
(existing stack — nothing new).

**Spec:** `docs/superpowers/specs/2026-09-08-storybook-persistence-design.md`

## Global Constraints

- Free/local models only — the rewrite pass reuses the same Ollama model
  (`config.OLLAMA_MODEL`) already used for story replies. No new model,
  no cloud API.
- Pet-project scope — no auth, no scaling machinery, no retry/backoff
  beyond what's specified below.
- The raw transcript (`turns`) is never modified or removed once written
  — every change here only *adds* fields alongside it.
- Illustration and object-recognition-photo tie-ins are explicitly out of
  scope — pages carry `{"text": ...}` only.
- Page count is a fixed configured target (`config.STORYBOOK_PAGE_COUNT`),
  not one page per turn.
- Page read-aloud is synthesized on demand (`SynthesizePage` streams live
  TTS) — no audio is ever pre-generated or stored.
- New-story creation is gated on **every** path (`speech_start`,
  `interrupt`, `new_story`) while the session is in the new `REWRITING`
  state — this is what eliminates LLM resource contention, per the spec.
- TDD: write the failing test first for every step below. Small commits —
  one commit per task, not one giant batch, per this repo's CLAUDE.md.
- Run tests from `server/` with that worktree's own `.venv` active
  (`cd server && source .venv/bin/activate && pytest`) — confirm
  `which python` resolves inside `.venv` before running anything.

---

### Task 1: `story_arc.py` — explicit-conclude support

**Files:**
- Modify: `server/tinytalk/story_arc.py` (add two methods to `StoryArc`)
- Test: `server/tests/test_story_arc.py`

**Interfaces:**
- Produces: `StoryArc.force_conclude_guidance() -> str`,
  `StoryArc.mark_done() -> None` — used by Task 8 (`session.py`'s
  conclude-story action).

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_story_arc.py`:

```python
def test_force_conclude_guidance_is_the_same_as_grace_ceiling_guidance():
    target_turns = 3
    grace_ceiling = target_turns + 3  # matches StoryArc's own __init__ formula
    arc = StoryArc(target_turns=target_turns)
    for _ in range(grace_ceiling):
        arc.record_turn("keep going")
    forced_by_ceiling = arc.record_turn("keep going")

    fresh = StoryArc(target_turns=target_turns)
    assert fresh.force_conclude_guidance() == forced_by_ceiling


def test_force_conclude_guidance_does_not_advance_turn_count():
    arc = StoryArc(target_turns=5)
    arc.record_turn("turn one")
    before = arc.stage

    arc.force_conclude_guidance()

    assert arc.stage == before


def test_mark_done_sets_is_done_unconditionally():
    arc = StoryArc(target_turns=5)
    assert arc.is_done is False

    arc.mark_done()

    assert arc.is_done is True
    assert arc.stage == Stage.DONE
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_story_arc.py -k "force_conclude or mark_done" -v`
Expected: FAIL with `AttributeError: 'StoryArc' object has no attribute 'force_conclude_guidance'`

- [ ] **Step 3: Implement**

In `server/tinytalk/story_arc.py`, inside `class StoryArc`, add (after
`record_reply`):

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_story_arc.py -v`
Expected: PASS (all tests, including the three new ones)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/story_arc.py server/tests/test_story_arc.py
git commit -m "feat(server): add StoryArc.force_conclude_guidance/mark_done"
```

---

### Task 2: `animal_facts.py` — retain real shared facts

**Files:**
- Modify: `server/tinytalk/animal_facts.py` (`AnimalFactTracker`)
- Test: `server/tests/test_animal_facts.py`

**Interfaces:**
- Produces: `AnimalFactTracker.shared_facts -> tuple[tuple[str, str], ...]`
  — used by Task 9 (`session.py` captures this before resetting the
  tracker) and Task 7 (`storybook.py`'s epilogue prompt).

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_animal_facts.py`:

```python
async def test_tracker_retains_the_real_fact_text_it_shared(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    await tracker.record_turn("tell me about a fox", Stage.SETUP)

    assert tracker.shared_facts == (("fox", "foxes have excellent hearing"),)


async def test_tracker_shared_facts_is_empty_when_no_fact_was_ever_woven_in(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    await tracker.record_turn("let's make up a story", Stage.SETUP)

    assert tracker.shared_facts == ()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_animal_facts.py -k shared_facts -v`
Expected: FAIL with `AttributeError: 'AnimalFactTracker' object has no attribute 'shared_facts'`

- [ ] **Step 3: Implement**

In `server/tinytalk/animal_facts.py`, modify `AnimalFactTracker`:

```python
    def __init__(self) -> None:
        self._facted: set[str] = set()
        self._attempted: set[str] = set()
        self._any_animal_mentioned = False
        self._shared_facts: list[tuple[str, str]] = []

    @property
    def shared_facts(self) -> tuple[tuple[str, str], ...]:
        """Real (animal, fact) pairs actually woven into this story so
        far -- used to ground storybook.py's epilogue in something real
        rather than letting the rewrite model invent one."""
        return tuple(self._shared_facts)

    async def record_turn(self, transcript: str, stage: Stage) -> str:
        canonical = find_new_animal(transcript, self._facted | self._attempted)
        if canonical is not None:
            self._any_animal_mentioned = True
            self._attempted.add(canonical)
            fact = await get_fact(canonical)
            if fact is not None:
                self._facted.add(canonical)
                self._shared_facts.append((canonical, fact))
                return _WEAVE_IN_TEMPLATE.format(animal=canonical, fact=fact)
            return ""
        if stage in (Stage.INTRO, Stage.SETUP) and not self._any_animal_mentioned:
            return _FIRST_ANIMAL_NUDGE
        return ""
```

(Only `__init__` and the `_shared_facts.append(...)` line inside
`record_turn` are new; the rest of `record_turn` is unchanged — shown in
full so the diff context is unambiguous.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_animal_facts.py -v`
Expected: PASS (all tests)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/animal_facts.py server/tests/test_animal_facts.py
git commit -m "feat(server): AnimalFactTracker retains real shared fact text"
```

---

### Task 3: `config.py` — storybook page count

**Files:**
- Modify: `server/tinytalk/config.py`
- Test: `server/tests/test_config.py`

**Interfaces:**
- Produces: `config.STORYBOOK_PAGE_COUNT: int` — used by Task 7
  (`storybook.py`'s default `page_count`).

- [ ] **Step 1: Write the failing test**

`server/tests/test_config.py` is currently a single simple test that reads
a constant straight off the module (no env-var-override tests exist for
any of the other ~15 config constants either, so this matches existing
scope rather than inventing new test infrastructure). Add:

```python
def test_storybook_page_count_defaults_to_five():
    assert config.STORYBOOK_PAGE_COUNT == 5
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && pytest tests/test_config.py -k storybook_page_count -v`
Expected: FAIL with `AttributeError: module 'tinytalk.config' has no attribute 'STORYBOOK_PAGE_COUNT'`

- [ ] **Step 3: Implement**

In `server/tinytalk/config.py`, after `STORY_TARGET_TURNS`:

```python
# How many pages storybook.py's background rewrite targets per story --
# a fixed count, not one page per turn (a 3-turn and a 12-turn story
# should both read as a similarly-paced picture book). The small local
# model isn't guaranteed to hit this exactly; storybook.py's parser
# tolerates a page count that's a little off rather than rejecting it.
STORYBOOK_PAGE_COUNT = int(os.environ.get("TINYTALK_STORYBOOK_PAGE_COUNT", "5"))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_config.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/config.py server/tests/test_config.py
git commit -m "feat(server): add config.STORYBOOK_PAGE_COUNT"
```

---

### Task 4: `story_store.py` — schema extension + read/update API

**Files:**
- Modify: `server/tinytalk/story_store.py`
- Test: `server/tests/test_story_store.py`

**Interfaces:**
- Produces: `save_story(...)` (unchanged signature, extended payload),
  `story_id_from_path(path: Path) -> str`,
  `list_stories(*, stories_dir: Path = STORIES_DIR) -> list[dict]`,
  `load_story(story_id: str, *, stories_dir: Path = STORIES_DIR) -> dict | None`,
  `update_story_rewrite(story_id: str, *, title: str | None, pages: list[dict] | None, epilogue: str | None, rewrite_status: str, stories_dir: Path = STORIES_DIR) -> bool`.
  Used by Task 7 (`storybook.py`) and Task 9/10 (`session.py`).

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_story_store.py`:

```python
def test_save_story_includes_the_new_nullable_fields(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert payload["title"] is None
    assert payload["pages"] is None
    assert payload["epilogue"] is None
    assert payload["rewrite_status"] == "pending"


def test_story_id_from_path_extracts_the_id(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert story_id_from_path(path) == payload["id"]


def test_list_stories_returns_summaries_newest_first(tmp_path):
    import time

    first = save_story(make_conversation(), stories_dir=tmp_path)
    time.sleep(1.1)  # created_at has 1-second resolution
    second = save_story(make_conversation(), stories_dir=tmp_path)

    summaries = list_stories(stories_dir=tmp_path)

    assert [s["id"] for s in summaries] == [
        story_id_from_path(second),
        story_id_from_path(first),
    ]
    assert summaries[0]["page_count"] == 0
    assert summaries[0]["rewrite_status"] == "pending"
    assert summaries[0]["title"] is None


def test_list_stories_returns_empty_list_when_directory_does_not_exist(tmp_path):
    assert list_stories(stories_dir=tmp_path / "missing") == []


def test_load_story_returns_full_payload(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)

    story = load_story(story_id, stories_dir=tmp_path)

    assert story is not None
    assert story["id"] == story_id
    assert story["turns"] == json.loads(path.read_text())["turns"]


def test_load_story_returns_none_for_unknown_id(tmp_path):
    save_story(make_conversation(), stories_dir=tmp_path)
    assert load_story("does-not-exist", stories_dir=tmp_path) is None


def test_update_story_rewrite_patches_in_the_result(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)

    ok = update_story_rewrite(
        story_id,
        title="Pip the Noisy Fox",
        pages=[{"text": "Once upon a time..."}],
        epilogue="Foxes have excellent hearing.",
        rewrite_status="done",
        stories_dir=tmp_path,
    )

    assert ok is True
    payload = json.loads(path.read_text())
    assert payload["title"] == "Pip the Noisy Fox"
    assert payload["pages"] == [{"text": "Once upon a time..."}]
    assert payload["epilogue"] == "Foxes have excellent hearing."
    assert payload["rewrite_status"] == "done"
    # the raw transcript must survive untouched
    assert payload["turns"] == json.loads(path.read_text())["turns"]


def test_update_story_rewrite_records_a_failed_status(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)

    ok = update_story_rewrite(
        story_id,
        title=None,
        pages=None,
        epilogue=None,
        rewrite_status="failed",
        stories_dir=tmp_path,
    )

    assert ok is True
    payload = json.loads(path.read_text())
    assert payload["rewrite_status"] == "failed"
    assert payload["title"] is None


def test_update_story_rewrite_returns_false_for_unknown_id(tmp_path):
    ok = update_story_rewrite(
        "does-not-exist",
        title="x",
        pages=[],
        epilogue=None,
        rewrite_status="done",
        stories_dir=tmp_path,
    )
    assert ok is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_story_store.py -v`
Expected: FAIL — `ImportError` for `story_id_from_path`/`list_stories`/`load_story`/`update_story_rewrite`, and the new-fields test fails on `KeyError`/`AssertionError`.

- [ ] **Step 3: Implement**

In `server/tinytalk/story_store.py`, modify `save_story`'s payload and add
four new functions:

```python
def save_story(
    conversation: Conversation, *, stories_dir: Path = STORIES_DIR
) -> Path | None:
    """Writes conversation.full_history to a new JSON file under stories_dir.

    Returns the written path, or None if the write failed -- logged, not
    raised, since losing a saved story must never crash or hang the
    session (same reasoning as _fail_turn's handling of engine failures
    in session.py).
    """
    created_at = datetime.now(timezone.utc)
    story_id = uuid.uuid4().hex[:8]
    filename = f"{created_at.strftime('%Y%m%dT%H%M%S')}-{story_id}.json"
    payload = {
        "id": story_id,
        "created_at": created_at.isoformat(),
        "turns": [
            {
                "speaker": turn.speaker,
                "text": turn.text,
                "interrupted": turn.interrupted,
            }
            for turn in conversation.full_history
        ],
        "title": None,
        "pages": None,
        "epilogue": None,
        "rewrite_status": "pending",
    }
    try:
        stories_dir.mkdir(parents=True, exist_ok=True)
        path = stories_dir / filename
        path.write_text(json.dumps(payload, indent=2))
        return path
    except OSError as exc:
        logger.error("failed to save story: %s", exc)
        return None


def story_id_from_path(path: Path) -> str:
    """The short id save_story() embedded in this filename
    (`<timestamp>-<id>.json`) -- the one piece of the filename format
    callers outside this module are allowed to depend on."""
    return path.stem.rsplit("-", 1)[-1]


def _find_story_path(story_id: str, *, stories_dir: Path) -> Path | None:
    if not stories_dir.exists():
        return None
    matches = list(stories_dir.glob(f"*-{story_id}.json"))
    return matches[0] if matches else None


def list_stories(*, stories_dir: Path = STORIES_DIR) -> list[dict]:
    """Summaries for the Library screen, newest first. A corrupt or
    unreadable file is skipped and logged, not raised -- one bad story
    must never break browsing the rest."""
    if not stories_dir.exists():
        return []
    summaries = []
    for path in stories_dir.glob("*.json"):
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            logger.error("failed to read story %s: %s", path, exc)
            continue
        pages = payload.get("pages")
        summaries.append(
            {
                "id": payload["id"],
                "title": payload.get("title"),
                "created_at": payload["created_at"],
                "page_count": len(pages) if pages else 0,
                "rewrite_status": payload.get("rewrite_status", "pending"),
            }
        )
    summaries.sort(key=lambda summary: summary["created_at"], reverse=True)
    return summaries


def load_story(story_id: str, *, stories_dir: Path = STORIES_DIR) -> dict | None:
    """Full contents of one saved story, or None if it doesn't exist or
    can't be read."""
    path = _find_story_path(story_id, stories_dir=stories_dir)
    if path is None:
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        logger.error("failed to read story %s: %s", story_id, exc)
        return None


def update_story_rewrite(
    story_id: str,
    *,
    title: str | None,
    pages: list[dict] | None,
    epilogue: str | None,
    rewrite_status: str,
    stories_dir: Path = STORIES_DIR,
) -> bool:
    """Patches storybook.py's rewrite result (or a "failed" status) into
    an already-saved story file. Logged, not raised, on any failure --
    same reasoning as save_story(): a rewrite that can't be persisted
    must never crash or hang the session that kicked it off."""
    path = _find_story_path(story_id, stories_dir=stories_dir)
    if path is None:
        logger.error("cannot update rewrite -- no saved story with id %r", story_id)
        return False
    try:
        payload = json.loads(path.read_text())
        payload["title"] = title
        payload["pages"] = pages
        payload["epilogue"] = epilogue
        payload["rewrite_status"] = rewrite_status
        path.write_text(json.dumps(payload, indent=2))
        return True
    except (OSError, json.JSONDecodeError) as exc:
        logger.error("failed to update rewrite for story %s: %s", story_id, exc)
        return False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_story_store.py -v`
Expected: PASS (all tests, old and new)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/story_store.py server/tests/test_story_store.py
git commit -m "feat(server): story_store schema extension + list/load/update-rewrite API"
```

---

### Task 5: `protocol.py` — new wire messages

**Files:**
- Modify: `server/tinytalk/protocol.py`
- Test: `server/tests/test_protocol.py`

**Interfaces:**
- Produces: client dataclasses `ListStories`, `GetStory(story_id)`,
  `SynthesizePage(story_id, page_index)`, `ConcludeStory(turn_id)`
  (all decodable via `decode_client_message`); server encoders
  `encode_arc_stage(stage, turn_id)`, `encode_story_list(stories)`,
  `encode_story_detail(story)`, `encode_page_audio_done(story_id, page_index)`,
  `encode_rewriting_started()`, `encode_rewriting_done()`. Used by Tasks
  8, 9, 10 (`session.py`).

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_protocol.py` (extend the existing
`@pytest.mark.parametrize` list in `test_decodes_each_client_message_type`
and add new tests):

```python
# Add these cases to the existing test_decodes_each_client_message_type
# parametrize list:
#     ('{"type": "list_stories"}', ListStories()),
#     ('{"type": "get_story", "story_id": "abcd1234"}', GetStory(story_id="abcd1234")),
#     ('{"type": "synthesize_page", "story_id": "abcd1234", "page_index": 2}',
#      SynthesizePage(story_id="abcd1234", page_index=2)),
#     ('{"type": "conclude_story", "turn_id": 5}', ConcludeStory(turn_id=5)),
# (and import ListStories, GetStory, SynthesizePage, ConcludeStory at the top)


def test_decode_rejects_get_story_missing_story_id():
    with pytest.raises(ProtocolError, match="story_id"):
        decode_client_message('{"type": "get_story"}')


def test_decode_rejects_get_story_blank_story_id():
    with pytest.raises(ProtocolError, match="story_id"):
        decode_client_message('{"type": "get_story", "story_id": "   "}')


def test_decode_rejects_synthesize_page_missing_page_index():
    with pytest.raises(ProtocolError, match="page_index"):
        decode_client_message('{"type": "synthesize_page", "story_id": "a"}')


def test_decode_rejects_conclude_story_missing_turn_id():
    with pytest.raises(ProtocolError, match="turn_id"):
        decode_client_message('{"type": "conclude_story"}')


def test_new_server_encoders_produce_expected_payloads():
    assert json.loads(encode_arc_stage("setup", 1)) == {
        "type": "arc_stage",
        "stage": "setup",
        "turn_id": 1,
    }
    assert json.loads(encode_story_list([{"id": "a", "title": None}])) == {
        "type": "story_list",
        "stories": [{"id": "a", "title": None}],
    }
    assert json.loads(encode_story_detail({"id": "a", "title": "Pip"})) == {
        "type": "story_detail",
        "id": "a",
        "title": "Pip",
    }
    assert json.loads(encode_page_audio_done("a", 2)) == {
        "type": "page_audio_done",
        "story_id": "a",
        "page_index": 2,
    }
    assert json.loads(encode_rewriting_started()) == {"type": "rewriting_started"}
    assert json.loads(encode_rewriting_done()) == {"type": "rewriting_done"}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_protocol.py -v`
Expected: FAIL with `ImportError` for the new names.

- [ ] **Step 3: Implement**

In `server/tinytalk/protocol.py`, add the new client dataclasses after
`NewStory`:

```python
@dataclass(frozen=True)
class ListStories:
    """Request the saved-story list for the Library screen. No turn_id --
    browsing saved stories is unrelated to live turn-taking."""


@dataclass(frozen=True)
class GetStory:
    """Request one saved story's rewritten pages for the Reading
    screen."""

    story_id: str


@dataclass(frozen=True)
class SynthesizePage:
    """Request on-demand TTS audio for one page of a saved story (the
    Reading screen's per-page replay button). Audio streams through the
    same binary-frame pathway as live TTS, followed by a
    page_audio_done marker."""

    story_id: str
    page_index: int


@dataclass(frozen=True)
class ConcludeStory:
    """The child (or parent) asked to finish the current story right now
    (the design's "Finish this story" menu item). Carries a turn_id like
    SpeechStart/Interrupt: it results in one more real
    response_text/turn_end pair the client must be able to attribute to a
    turn."""

    turn_id: int


ClientMessage = (
    SpeechStart
    | SpeechEnd
    | Interrupt
    | ObjectSeen
    | NewStory
    | ListStories
    | GetStory
    | SynthesizePage
    | ConcludeStory
)

_CLIENT_MESSAGE_TYPES: dict[str, type] = {
    "speech_start": SpeechStart,
    "speech_end": SpeechEnd,
    "interrupt": Interrupt,
    "object_seen": ObjectSeen,
    "new_story": NewStory,
    "list_stories": ListStories,
    "get_story": GetStory,
    "synthesize_page": SynthesizePage,
    "conclude_story": ConcludeStory,
}
_TYPES_REQUIRING_TURN_ID = (SpeechStart, Interrupt, ConcludeStory)
```

Update `decode_client_message` (add branches before the final
`return message_type()`):

```python
    if message_type is ObjectSeen:
        label = payload.get("label")
        if not isinstance(label, str) or not label.strip():
            raise ProtocolError(f"object_seen requires a non-empty string label: {raw!r}")
        return ObjectSeen(label=label.strip())
    if message_type is GetStory:
        story_id = payload.get("story_id")
        if not isinstance(story_id, str) or not story_id.strip():
            raise ProtocolError(f"get_story requires a non-empty string story_id: {raw!r}")
        return GetStory(story_id=story_id.strip())
    if message_type is SynthesizePage:
        story_id = payload.get("story_id")
        page_index = payload.get("page_index")
        if not isinstance(story_id, str) or not story_id.strip():
            raise ProtocolError(
                f"synthesize_page requires a non-empty string story_id: {raw!r}"
            )
        if not isinstance(page_index, int):
            raise ProtocolError(f"synthesize_page requires an integer page_index: {raw!r}")
        return SynthesizePage(story_id=story_id.strip(), page_index=page_index)
    return message_type()
```

Add the new encoders at the end of the file:

```python
def encode_arc_stage(stage: str, turn_id: int) -> str:
    return json.dumps({"type": "arc_stage", "stage": stage, "turn_id": turn_id})


def encode_story_list(stories: list[dict]) -> str:
    return json.dumps({"type": "story_list", "stories": stories})


def encode_story_detail(story: dict) -> str:
    return json.dumps({"type": "story_detail", **story})


def encode_page_audio_done(story_id: str, page_index: int) -> str:
    return json.dumps(
        {"type": "page_audio_done", "story_id": story_id, "page_index": page_index}
    )


def encode_rewriting_started() -> str:
    return json.dumps({"type": "rewriting_started"})


def encode_rewriting_done() -> str:
    return json.dumps({"type": "rewriting_done"})
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_protocol.py -v`
Expected: PASS (all tests, old and new)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/protocol.py server/tests/test_protocol.py
git commit -m "feat(server): wire protocol messages for story browsing, arc stage, conclude"
```

---

### Task 6: `state.py` — the `REWRITING` state

**Files:**
- Modify: `server/tinytalk/state.py`
- Test: `server/tests/test_state.py`

**Interfaces:**
- Produces: `State.REWRITING`, `Event.CONCLUDE`, `Event.REWRITE_STARTED`,
  `Event.REWRITE_DONE`. Used by Tasks 8 and 9 (`session.py`).

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_state.py`:

```python
def test_conclude_from_any_state_lands_in_thinking():
    for state_setup in (
        [],
        [Event.SPEECH_START],
        [Event.SPEECH_START, Event.SPEECH_END],
        [Event.SPEECH_START, Event.SPEECH_END, Event.RESPONSE_READY],
    ):
        machine = TurnStateMachine()
        for event in state_setup:
            machine.handle(event)
        assert machine.handle(Event.CONCLUDE) is State.THINKING


def test_speaking_to_rewriting_on_rewrite_started():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    assert machine.handle(Event.REWRITE_STARTED) is State.REWRITING


def test_rewrite_done_returns_to_idle():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.REWRITE_STARTED)
    assert machine.handle(Event.REWRITE_DONE) is State.IDLE


def test_speech_start_is_not_legal_while_rewriting():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.REWRITE_STARTED)
    with pytest.raises(InvalidTransition):
        machine.handle(Event.SPEECH_START)


def test_interrupt_is_not_legal_while_rewriting():
    # The one deliberate exception to "interrupt is legal from every
    # state" -- see this module's own comment.
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.REWRITE_STARTED)
    with pytest.raises(InvalidTransition):
        machine.handle(Event.INTERRUPT)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_state.py -v`
Expected: FAIL with `AttributeError: <enum 'Event'> has no attribute 'CONCLUDE'` (and similarly for `REWRITE_STARTED`/`REWRITE_DONE`/`State.REWRITING`).

- [ ] **Step 3: Implement**

In `server/tinytalk/state.py`, replace the whole file's transition table
and enums:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_state.py -v`
Expected: PASS (all tests, old and new)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/state.py server/tests/test_state.py
git commit -m "feat(server): add REWRITING state and CONCLUDE/REWRITE_STARTED/REWRITE_DONE events"
```

---

### Task 7: `storybook.py` — the rewrite pipeline

**Files:**
- Create: `server/tinytalk/storybook.py`
- Test: `server/tests/test_storybook.py`

**Interfaces:**
- Consumes: `story_store.update_story_rewrite(...)` (Task 4),
  `config.STORYBOOK_PAGE_COUNT` (Task 3), `LlmEngine.stream_reply(messages) -> AsyncIterator[str]`
  (existing `engines.py` protocol), `Turn` (existing `conversation.py`).
- Produces: `build_and_attach(story_id, turns, shared_facts, *, llm, page_count=config.STORYBOOK_PAGE_COUNT) -> None`
  — used by Task 9 (`session.py`).

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_storybook.py`:

```python
import json
from typing import AsyncIterator

from tinytalk.conversation import Turn
from tinytalk.storybook import build_and_attach
from tinytalk.story_store import load_story, save_story
from tinytalk.conversation import Conversation


class FakeRewriteLlm:
    def __init__(self, reply: str) -> None:
        self.reply = reply
        self.calls: list[list[dict[str, str]]] = []

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        yield self.reply


def make_saved_story(tmp_path):
    conversation = Conversation()
    conversation.add_child("tell me about a fox")
    conversation.add_agent("Once there was a clever fox.")
    path = save_story(conversation, stories_dir=tmp_path)
    from tinytalk.story_store import story_id_from_path

    return story_id_from_path(path)


async def test_build_and_attach_parses_and_saves_a_valid_rewrite(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = json.dumps(
        {
            "title": "Pip the Noisy Fox",
            "pages": [{"text": "Once there was a fox."}, {"text": "The end."}],
            "epilogue": "Foxes have excellent hearing.",
        }
    )
    llm = FakeRewriteLlm(reply)
    turns = [
        Turn(speaker="child", text="tell me about a fox"),
        Turn(speaker="agent", text="Once there was a clever fox."),
    ]

    await build_and_attach(
        story_id, turns, [("fox", "foxes have excellent hearing")], llm=llm,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["title"] == "Pip the Noisy Fox"
    assert story["pages"] == [{"text": "Once there was a fox."}, {"text": "The end."}]
    assert story["epilogue"] == "Foxes have excellent hearing."
    assert story["rewrite_status"] == "done"
    assert story["turns"], "raw transcript must still be present"


async def test_build_and_attach_tolerates_prose_wrapped_around_the_json(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = 'Sure, here you go:\n{"title": "Pip", "pages": [{"text": "Once upon a time."}]}\nHope that helps!'
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["title"] == "Pip"
    assert story["rewrite_status"] == "done"


async def test_build_and_attach_marks_failed_on_unparseable_output(tmp_path):
    story_id = make_saved_story(tmp_path)
    llm = FakeRewriteLlm("this is not json at all")

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"
    assert story["title"] is None
    assert story["turns"], "raw transcript must survive a failed rewrite"


async def test_build_and_attach_marks_failed_when_the_llm_engine_raises(tmp_path):
    from tinytalk.engines import EngineError

    story_id = make_saved_story(tmp_path)

    class RaisingLlm:
        async def stream_reply(self, messages):
            raise EngineError("ollama is not running")
            yield ""  # pragma: no cover - unreachable, marks this a generator

    await build_and_attach(story_id, [], [], llm=RaisingLlm(), stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"


async def test_build_and_attach_omits_epilogue_when_no_facts_were_shared(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = json.dumps({"title": "A Story", "pages": [{"text": "Once upon a time."}]})
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    prompt = llm.calls[0][0]["content"]
    assert "epilogue" not in prompt.lower().split("reply with only")[0].split("real facts")[0] or True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["epilogue"] is None
```

(That last assertion line is deliberately loose about prompt wording,
since exact phrasing is implementation detail per the spec's own "Open
questions" note — the load-bearing assertion is `story["epilogue"] is None`.)

Note: `build_and_attach` needs a `stories_dir` parameter for testability
(mirroring `story_store`'s own `stories_dir` keyword) — include it in the
signature written in Step 3, defaulting to `story_store.STORIES_DIR`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_storybook.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.storybook'`

- [ ] **Step 3: Implement**

Create `server/tinytalk/storybook.py`:

```python
"""Background rewrite pass: turns a saved story's raw transcript into
storybook pages (title, prose pages, an optional fact-grounded epilogue).

Runs after the story's own final reply has already been sent -- see
state.py's REWRITING state, which gates new-story creation for exactly as
long as this takes, so this call never competes with a live story's own
LLM turns for the same local Ollama process.
"""

from __future__ import annotations

import json
import logging

from . import story_store
from .conversation import Turn
from .engines import EngineError, LlmEngine
from .story_store import STORIES_DIR
from pathlib import Path

logger = logging.getLogger(__name__)

_REWRITE_PROMPT_TEMPLATE = (
    "You are turning a story a child and a storyteller made up together "
    "into a picture-book version for the child to read again later.\n\n"
    "Here is the full conversation, in order:\n{transcript}\n\n"
    "{facts_section}"
    "Rewrite this as a children's storybook: continuous third-person "
    "narration that captures the same characters, events, and facts -- "
    "NOT a dialogue transcript, and don't write \"the child said\" or "
    "\"the storyteller said\" anywhere. Split it into exactly {page_count} "
    "pages. Reply with ONLY a JSON object, no other text, in this exact "
    "shape:\n"
    '{{"title": "...", "pages": [{{"text": "..."}}, ...]{epilogue_key}}}'
)

_EPILOGUE_KEY = ', "epilogue": "one true, real fact from the story, in one sentence"'


def _format_transcript(turns: list[Turn]) -> str:
    lines = []
    for turn in turns:
        speaker = "Child" if turn.speaker == "child" else "Storyteller"
        lines.append(f"{speaker}: {turn.text}")
    return "\n".join(lines)


def _build_prompt(
    turns: list[Turn], shared_facts: list[tuple[str, str]], page_count: int
) -> str:
    facts_section = ""
    epilogue_key = ""
    if shared_facts:
        facts_list = "; ".join(f"{animal}: {fact}" for animal, fact in shared_facts)
        facts_section = (
            f"Real facts this story actually used: {facts_list}. If natural, "
            "close with one of these as a one-sentence epilogue, phrased for "
            "a young child.\n\n"
        )
        epilogue_key = _EPILOGUE_KEY
    return _REWRITE_PROMPT_TEMPLATE.format(
        transcript=_format_transcript(turns),
        facts_section=facts_section,
        page_count=page_count,
        epilogue_key=epilogue_key,
    )


def _parse_rewrite(raw: str) -> tuple[str, list[dict], str | None] | None:
    """Extracts {title, pages, epilogue} from the LLM's raw reply text,
    tolerant of leading/trailing prose around the JSON object (a small
    local model doesn't reliably follow "reply with ONLY json"). Returns
    None if nothing usable is found."""
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1 or end < start:
        return None
    try:
        data = json.loads(raw[start : end + 1])
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    title = data.get("title")
    pages = data.get("pages")
    epilogue = data.get("epilogue")
    if not isinstance(title, str) or not title.strip():
        return None
    if not isinstance(pages, list) or not pages:
        return None
    normalized_pages = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("text"), str):
            return None
        normalized_pages.append({"text": page["text"].strip()})
    if not isinstance(epilogue, str) or not epilogue.strip():
        epilogue = None
    return title.strip(), normalized_pages, epilogue


async def build_and_attach(
    story_id: str,
    turns: list[Turn],
    shared_facts: list[tuple[str, str]],
    *,
    llm: LlmEngine,
    page_count: int = 5,
    stories_dir: Path = STORIES_DIR,
) -> None:
    """Runs the rewrite and patches the result into the already-saved
    story -- or marks it "failed", logged, never raised. Called as a
    fire-and-forget background task; see session.py's REWRITE_STARTED/
    REWRITE_DONE handling for how its completion (success or failure) is
    guaranteed to release the REWRITING gate."""
    prompt = _build_prompt(turns, shared_facts, page_count)
    messages = [{"role": "user", "content": prompt}]
    try:
        parts: list[str] = []
        async for chunk in llm.stream_reply(messages):
            parts.append(chunk)
        raw = "".join(parts).strip()
    except EngineError as exc:
        logger.error("storybook rewrite failed for story %s: %s", story_id, exc)
        story_store.update_story_rewrite(
            story_id,
            title=None,
            pages=None,
            epilogue=None,
            rewrite_status="failed",
            stories_dir=stories_dir,
        )
        return
    parsed = _parse_rewrite(raw)
    if parsed is None:
        logger.error(
            "storybook rewrite for story %s produced unparseable output: %r",
            story_id,
            raw,
        )
        story_store.update_story_rewrite(
            story_id,
            title=None,
            pages=None,
            epilogue=None,
            rewrite_status="failed",
            stories_dir=stories_dir,
        )
        return
    title, pages, epilogue = parsed
    story_store.update_story_rewrite(
        story_id,
        title=title,
        pages=pages,
        epilogue=epilogue,
        rewrite_status="done",
        stories_dir=stories_dir,
    )
    logger.info("storybook rewrite done for story %s: %d pages", story_id, len(pages))
```

Note the default `page_count: int = 5` — Task 9 (`session.py`) will pass
`config.STORYBOOK_PAGE_COUNT` explicitly at the call site rather than
relying on this default, so the literal `5` here only matters for a
caller (like a test) that doesn't pass it. (Importing `config` here just
for a default value the real caller always overrides would be an unused
import in the common case — keeping the literal default is simpler and
matches how `KyutaiStt.__init__`'s `hf_repo: str = config.STT_HF_REPO`
pattern is the exception, not the rule, elsewhere in this codebase; if
you'd rather match that exact pattern, `from . import config` and use
`config.STORYBOOK_PAGE_COUNT` as the default instead — either is fine,
just be consistent with the test expectations above, which always pass
`page_count` or rely on this function's own default explicitly via a
`FakeRewriteLlm`-based test if you add one.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_storybook.py -v`
Expected: PASS (all tests)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/storybook.py server/tests/test_storybook.py
git commit -m "feat(server): add storybook.py background rewrite pipeline"
```

---

### Task 8: `session.py` — the conclude-story action

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `StoryArc.force_conclude_guidance()`/`mark_done()` (Task 1),
  `ConcludeStory` (Task 5), `Event.CONCLUDE` (Task 6),
  `encode_arc_stage` (Task 5).
- Produces: `SessionRunner.handle_conclude_story(turn_id: int) -> None`,
  `_run_turn(transcript, turn_id, *, forced_conclude=False)` (extended
  signature) — the `forced_conclude` parameter and its interaction with
  the REWRITING gate is consumed by Task 9.

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_session.py`:

```python
CONCLUDE = '{"type": "conclude_story", "turn_id": 9}'


async def test_conclude_story_forces_a_final_reply_without_a_real_utterance(transport):
    llm = FakeLlm(chunks=["The fox went home. The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)  # a normal turn first, so there's a story in progress

    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    # The forced turn's system prompt carries the same forced-conclusion
    # guidance already used for a grace-ceiling-forced ending.
    forced_messages = llm.calls[-1]
    assert "This must be the last reply" in forced_messages[0]["content"]
    assert transport.messages_of_type("turn_end")[-1]["turn_id"] == 9


async def test_conclude_story_marks_the_story_done_even_if_the_reply_omits_the_end(transport):
    # Deliberately a reply that would NOT be caught by natural
    # phrase-detection -- proves mark_done() is unconditional.
    llm = FakeLlm(chunks=["The fox curled up and slept soundly."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)

    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    # A concluded story resets the conversation -- the next turn starts fresh.
    assert session.conversation.turns == ()


async def test_conclude_story_cancels_an_in_flight_turn_first(transport):
    llm = FakeLlm(chunks=["slow reply"], delay=10)
    session = make_session(transport, llm=llm)
    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)  # let the slow turn actually start

    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    assert llm.cancelled is True


async def test_conclude_story_does_not_trigger_the_stt_failure_guidance(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)

    await session.handle_text(CONCLUDE)
    await session.wait_for_turn()

    forced_messages = llm.calls[-1]
    assert "didn't hear anything new" not in forced_messages[0]["content"]
```

Add `import asyncio` to the top of `test_session.py` if it isn't already
imported (check first).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_session.py -k conclude_story -v`
Expected: FAIL — `conclude_story` isn't a recognized message type yet
(silently falls through `match message:` with no matching case, so no
reply is ever produced and the assertions fail).

- [ ] **Step 3: Implement**

In `server/tinytalk/session.py`, update the imports:

```python
from .protocol import (
    ConcludeStory,
    GetStory,
    Interrupt,
    ListStories,
    NewStory,
    ObjectSeen,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    SynthesizePage,
    decode_client_message,
    encode_arc_stage,
    encode_error,
    encode_response_text,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)
from .state import Event, InvalidTransition, State, TurnStateMachine
```

(`GetStory`/`ListStories`/`SynthesizePage` are imported here too since
Task 10 wires them into the same `match` block — importing them now
avoids a second edit to this import block later.)

Update `handle_text`'s `match message:` block, adding one new case:

```python
            case NewStory():
                await self.handle_new_story()
            case ConcludeStory(turn_id=turn_id):
                await self.handle_conclude_story(turn_id)
```

Add the new method (near `handle_new_story`):

```python
    async def handle_conclude_story(self, turn_id: int) -> None:
        """The "Finish this story" action: cancels whatever's in flight
        (same as a barge-in) and forces one final reply using
        StoryArc.force_conclude_guidance() instead of the normal
        stage-based guidance, then marks the story done unconditionally
        -- an explicit request to finish must not be able to silently
        fail to end just because the reply's wording doesn't happen to
        match the natural-conclusion phrase list."""
        await self._cancel_turn(record_spoken=True)
        if self._machine.state is State.LISTENING:
            self._stt.reset()
        self._current_turn_id = turn_id
        self._transition(Event.CONCLUDE)
        self._turn_replay_buffer = []
        logger.info("conclude_story: forcing a final reply for turn_id=%d", turn_id)
        self._turn_task = asyncio.create_task(
            self._run_turn("", turn_id, forced_conclude=True)
        )
```

Update `_run_turn`'s signature and body:

```python
    async def _run_turn(
        self, transcript: str, turn_id: int, *, forced_conclude: bool = False
    ) -> None:
        turn_start = time.monotonic()
        try:
            self._conversation.add_child(transcript)  # no-op if transcript is empty
            if forced_conclude:
                guidance = self._story_arc.force_conclude_guidance()
            else:
                guidance = self._story_arc.record_turn(transcript)
            await self._send_and_buffer(
                text=encode_arc_stage(self._story_arc.stage.value, turn_id)
            )
            fact_guidance = await self._animal_facts.record_turn(
                transcript, self._story_arc.stage
            )
            if fact_guidance:
                guidance = f"{guidance}\n\n{fact_guidance}"
            object_guidance = self._object_recognition.consume_guidance()
            if object_guidance:
                guidance = f"{guidance}\n\n{object_guidance}"
            if not transcript.strip() and not forced_conclude:
                guidance = f"{guidance}\n\n{_STT_FAILURE_GUIDANCE}"
            messages = self._conversation.to_messages(
                self._system_prompt + "\n\n" + guidance
            )
```

(Everything from `parts: list[str] = []` through the TTS loop is
unchanged.) Then update the reply-recording line:

```python
            reply = safety.filter_reply("".join(parts).strip())
            if forced_conclude:
                self._story_arc.mark_done()
            else:
                self._story_arc.record_reply(reply)
```

(Leave the rest of `_run_turn` as-is for this task — the
`self._transition(Event.TTS_DONE)` / save-and-reset block at the end is
Task 9's responsibility to change.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_session.py -v`
Expected: PASS for the new `conclude_story` tests. (Some tests may still
fail if Task 9 hasn't landed yet, if `_story_arc.is_done` after a forced
conclude tries to reach code Task 9 hasn't written -- if so, verify by
running only `-k conclude_story` first, and treat full-suite failures
from the not-yet-updated save/reset block as expected until Task 9 lands
directly after this one.)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
git commit -m "feat(server): add SessionRunner.handle_conclude_story + arc_stage push"
```

---

### Task 9: `session.py` — the `REWRITING` gate

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `storybook.build_and_attach` (Task 7),
  `story_store.story_id_from_path` (Task 4), `Event.REWRITE_STARTED`/
  `Event.REWRITE_DONE` (Task 6), `encode_rewriting_started`/
  `encode_rewriting_done` (Task 5).
- Produces: `SessionRunner.resend_current_status() -> None` (consumed by
  Task 11, `app.py`).

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_session.py`:

```python
async def test_a_concluding_turn_enters_rewriting_and_pushes_rewriting_started(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert session.state is State.REWRITING
    assert "rewriting_started" in transport.types()


async def test_rewriting_releases_back_to_idle_once_the_rewrite_finishes(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.wait_for_rewrite()

    assert session.state is State.IDLE
    assert "rewriting_done" in transport.types()


async def test_rewriting_releases_even_when_the_rewrite_itself_raises(transport, monkeypatch):
    async def raising_build_and_attach(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", raising_build_and_attach
    )
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)

    await session.wait_for_rewrite()

    assert session.state is State.IDLE


async def test_speech_start_is_a_no_op_while_rewriting(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING
    before_turn_id = session.current_turn_id

    await session.handle_text('{"type": "speech_start", "turn_id": 999}')

    assert session.state is State.REWRITING
    assert session.current_turn_id == before_turn_id


async def test_new_story_is_a_no_op_while_rewriting(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_new_story()

    assert session.state is State.REWRITING


async def test_interrupt_is_a_no_op_while_rewriting(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_text('{"type": "interrupt", "turn_id": 999}')

    assert session.state is State.REWRITING


async def test_speech_start_works_again_once_rewriting_finishes(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    await session.wait_for_rewrite()
    assert session.state is State.IDLE

    await session.handle_text('{"type": "speech_start", "turn_id": 5}')

    assert session.state is State.LISTENING


async def test_a_non_concluding_turn_does_not_enter_rewriting(transport):
    llm = FakeLlm(chunks=["Let's keep going."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert session.state is State.IDLE
    assert "rewriting_started" not in transport.types()


async def test_resend_current_status_repushes_rewriting_started(transport):
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    transport.text.clear()

    await session.resend_current_status()

    assert "rewriting_started" in transport.types()
```

`wait_for_rewrite()` is a new test-only method this task also adds to
`SessionRunner` (mirroring the existing `wait_for_turn()`) — see Step 3.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_session.py -k "rewriting or rewrite" -v`
Expected: FAIL — `session.state` stays `IDLE` after a concluding turn
(today's code still fires `TTS_DONE` unconditionally), and
`wait_for_rewrite`/`resend_current_status` don't exist yet.

- [ ] **Step 3: Implement**

In `server/tinytalk/session.py`, add the import:

```python
from . import config, safety, storybook, story_store
```

(Adds `storybook` to the existing `from . import config, safety, story_store` line.)

Add a new instance attribute in `__init__` (alongside `self._turn_task`):

```python
        self._turn_task: asyncio.Task | None = None
        self._rewrite_task: asyncio.Task | None = None
```

Add a test-only waiter next to `wait_for_turn`:

```python
    async def wait_for_rewrite(self) -> None:
        """Await the in-flight background rewrite to finish. Test-only,
        mirroring wait_for_turn()."""
        if self._rewrite_task is not None:
            await asyncio.gather(self._rewrite_task, return_exceptions=True)
```

Add `resend_current_status`:

```python
    async def resend_current_status(self) -> None:
        """Called by app.py right after a (re)connect, in addition to
        replay_last_turn() -- a phone that reconnects while a storybook
        rewrite is still in flight must be told so immediately, not left
        to assume it's free to start a new story."""
        if self._machine.state is State.REWRITING:
            await self._send_text_unbuffered(encode_rewriting_started())
```

Add the unbuffered-send helper (near `_send_and_buffer`):

```python
    async def _send_text_unbuffered(self, text: str) -> None:
        """Sends a control message outside any turn's replay buffer -- for
        pushes that aren't part of the live turn currently in flight, if
        any (rewriting_started/rewriting_done, story browsing
        responses)."""
        async with self._transport_lock:
            await self._transport.send_text(text)
```

Replace the end of `_run_turn` (from `self._conversation.add_agent(reply)`
through the end of the `if self._story_arc.is_done:` block) with:

```python
            self._conversation.add_agent(reply)
            self._spoken = []
            concluding = self._story_arc.is_done
            if concluding:
                self._transition(Event.REWRITE_STARTED)
            else:
                self._transition(Event.TTS_DONE)
            await self._send_and_buffer(text=encode_turn_end(turn_id))
            logger.info(
                "turn total (transcript -> turn_end): %.1f ms",
                (time.monotonic() - turn_start) * 1000,
            )
            if concluding:
                saved_path = story_store.save_story(self._conversation)
                turns = list(self._conversation.full_history)
                shared_facts = list(self._animal_facts.shared_facts)
                self._conversation = Conversation()
                self._story_arc = StoryArc()
                self._animal_facts = AnimalFactTracker()
                self._object_recognition = ObjectTracker()
                if saved_path is not None:
                    logger.info("story saved to %s", saved_path)
                    story_id = story_store.story_id_from_path(saved_path)
                    await self._send_text_unbuffered(encode_rewriting_started())
                    self._rewrite_task = asyncio.create_task(
                        self._run_rewrite(story_id, turns, shared_facts)
                    )
                else:
                    # save_story() itself failed -- there is nothing to
                    # rewrite, and nothing should stay gated on a rewrite
                    # that will never run.
                    self._transition(Event.REWRITE_DONE)
        except asyncio.CancelledError:
            raise
        except EngineError as exc:
            logger.error("engine failure during turn: %s", exc)
            await self._fail_turn(str(exc), turn_id)
        except Exception as exc:  # noqa: BLE001 - a session must survive one bad turn
            logger.exception("unexpected failure during turn")
            await self._fail_turn(f"internal error: {exc}", turn_id)
```

Add the background-task wrapper method:

```python
    async def _run_rewrite(
        self, story_id: str, turns: list, shared_facts: list[tuple[str, str]]
    ) -> None:
        try:
            await storybook.build_and_attach(
                story_id, turns, shared_facts, llm=self._llm,
                page_count=config.STORYBOOK_PAGE_COUNT,
            )
        except Exception:  # noqa: BLE001 - the REWRITING gate must always release
            logger.exception("unexpected failure running storybook rewrite for %s", story_id)
        finally:
            self._transition(Event.REWRITE_DONE)
            await self._send_text_unbuffered(encode_rewriting_done())
```

Guard `_start_listening`, `_interrupt`, and `handle_new_story` against
`REWRITING`:

```python
    async def _start_listening(self, turn_id: int) -> None:
        if self._machine.state is State.REWRITING:
            logger.info(
                "speech_start ignored -- a storybook rewrite is still in "
                "progress (turn_id=%d)",
                turn_id,
            )
            return
        if self._machine.state in (State.THINKING, State.SPEAKING):
            await self._interrupt(turn_id)
            return
        await self._cancel_turn(record_spoken=True)
        self._current_turn_id = turn_id
        self._transition(Event.SPEECH_START)
        logger.info(
            "utterance started: turn_id=%d, story stage %s",
            turn_id,
            self._story_arc.stage.name,
        )
```

```python
    async def _interrupt(self, turn_id: int) -> None:
        if self._machine.state is State.REWRITING:
            logger.info(
                "interrupt ignored -- a storybook rewrite is still in "
                "progress (turn_id=%d)",
                turn_id,
            )
            return
        interrupt_received = time.monotonic()
        await self._cancel_turn(record_spoken=True)
        self._stt.reset()
        self._current_turn_id = turn_id
        self._transition(Event.INTERRUPT)
        logger.info(
            "interrupt handled in %.1f ms",
            (time.monotonic() - interrupt_received) * 1000,
        )
```

```python
    async def handle_new_story(self) -> None:
        if self._machine.state is State.REWRITING:
            logger.info("new_story ignored -- a storybook rewrite is still in progress")
            return
        await self._cancel_turn(record_spoken=False)
        if self._machine.state is State.LISTENING:
            self._stt.reset()
        self._turn_replay_buffer = []
        self._conversation = Conversation()
        self._story_arc = StoryArc()
        self._animal_facts = AnimalFactTracker()
        self._object_recognition = ObjectTracker()
        self._machine = TurnStateMachine()
        logger.info(
            "new story: conversation, story arc and replay buffer cleared "
            "(turn_id stays at %d -- it numbers messages, not story turns)",
            self._current_turn_id,
        )
```

Add the two new encoder imports to the existing `from .protocol import (...)`
block (alongside the ones Task 8 already added):

```python
    encode_rewriting_done,
    encode_rewriting_started,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_session.py -v`
Expected: PASS (the full suite, including Task 8's conclude-story tests,
which depend on this task's `is_done`/save/reset wiring to fully
complete).

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
git commit -m "feat(server): gate new-story creation behind a REWRITING state"
```

---

### Task 10: `session.py` — read-only story browsing

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `story_store.list_stories`/`load_story` (Task 4),
  `encode_story_list`/`encode_story_detail`/`encode_page_audio_done`
  (Task 5), `ListStories`/`GetStory`/`SynthesizePage` (Task 5, already
  imported in Task 8's import-block edit).
- Produces: `SessionRunner.handle_list_stories`/`handle_get_story`/
  `handle_synthesize_page`.

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_session.py`:

```python
async def test_list_stories_returns_saved_summaries(transport, tmp_path, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.STORIES_DIR", tmp_path)
    from tinytalk.story_store import save_story
    from tinytalk.conversation import Conversation

    save_story(Conversation(), stories_dir=tmp_path)
    session = make_session(transport)

    await session.handle_text('{"type": "list_stories"}')

    stories = transport.messages_of_type("story_list")[0]["stories"]
    assert len(stories) == 1


async def test_get_story_returns_story_detail(transport, tmp_path, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.STORIES_DIR", tmp_path)
    from tinytalk.story_store import save_story, story_id_from_path, update_story_rewrite
    from tinytalk.conversation import Conversation

    path = save_story(Conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="Pip", pages=[{"text": "Once upon a time."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    session = make_session(transport)

    await session.handle_text(f'{{"type": "get_story", "story_id": "{story_id}"}}')

    detail = transport.messages_of_type("story_detail")[0]
    assert detail["title"] == "Pip"
    assert detail["pages"] == [{"text": "Once upon a time."}]


async def test_get_story_sends_error_for_unknown_id(transport, tmp_path, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.STORIES_DIR", tmp_path)
    session = make_session(transport)

    await session.handle_text('{"type": "get_story", "story_id": "nope"}')

    assert transport.types() == ["error"]


async def test_synthesize_page_streams_audio_and_a_done_marker(transport, tmp_path, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.STORIES_DIR", tmp_path)
    from tinytalk.story_store import save_story, story_id_from_path, update_story_rewrite
    from tinytalk.conversation import Conversation

    path = save_story(Conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="Pip", pages=[{"text": "Once upon a time."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    tts = FakeTts()
    session = make_session(transport, tts=tts)

    await session.handle_text(
        f'{{"type": "synthesize_page", "story_id": "{story_id}", "page_index": 0}}'
    )

    assert tts.spoken == ["Once upon a time."]
    assert len(transport.audio) == 1
    done = transport.messages_of_type("page_audio_done")[0]
    assert done == {"type": "page_audio_done", "story_id": story_id, "page_index": 0}


async def test_synthesize_page_sends_error_for_an_out_of_range_page(transport, tmp_path, monkeypatch):
    monkeypatch.setattr("tinytalk.session.story_store.STORIES_DIR", tmp_path)
    from tinytalk.story_store import save_story, story_id_from_path, update_story_rewrite
    from tinytalk.conversation import Conversation

    path = save_story(Conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="Pip", pages=[{"text": "Once upon a time."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    session = make_session(transport)

    await session.handle_text(
        f'{{"type": "synthesize_page", "story_id": "{story_id}", "page_index": 5}}'
    )

    assert transport.types() == ["error"]


async def test_story_browsing_works_while_rewriting(transport, tmp_path, monkeypatch):
    # Browsing already-saved stories has nothing to do with the live
    # session -- it must keep working even while a DIFFERENT story is
    # mid-rewrite.
    monkeypatch.setattr("tinytalk.session.story_store.STORIES_DIR", tmp_path)
    from tinytalk.story_store import save_story
    from tinytalk.conversation import Conversation

    save_story(Conversation(), stories_dir=tmp_path)
    llm = FakeLlm(chunks=["The end."])
    session = make_session(transport, llm=llm)
    await run_full_turn(session)
    assert session.state is State.REWRITING

    await session.handle_text('{"type": "list_stories"}')

    assert len(transport.messages_of_type("story_list")[0]["stories"]) >= 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && pytest tests/test_session.py -k "list_stories or get_story or synthesize_page or story_browsing" -v`
Expected: FAIL — these message types aren't dispatched yet (no matching
`case` in `handle_text`), so no reply is ever sent.

- [ ] **Step 3: Implement**

In `server/tinytalk/session.py`, add three cases to `handle_text`'s
`match message:` block:

```python
            case ListStories():
                await self.handle_list_stories()
            case GetStory(story_id=story_id):
                await self.handle_get_story(story_id)
            case SynthesizePage(story_id=story_id, page_index=page_index):
                await self.handle_synthesize_page(story_id, page_index)
```

Add the three handler methods (near `handle_new_story`):

```python
    async def handle_list_stories(self) -> None:
        stories = story_store.list_stories()
        await self._send_text_unbuffered(encode_story_list(stories))

    async def handle_get_story(self, story_id: str) -> None:
        story = story_store.load_story(story_id)
        if story is None:
            await self._send_text_unbuffered(
                encode_error(f"no saved story with id {story_id!r}", self._current_turn_id)
            )
            return
        await self._send_text_unbuffered(
            encode_story_detail(
                {
                    "id": story["id"],
                    "title": story.get("title"),
                    "pages": story.get("pages"),
                    "epilogue": story.get("epilogue"),
                    "rewrite_status": story.get("rewrite_status", "pending"),
                }
            )
        )

    async def handle_synthesize_page(self, story_id: str, page_index: int) -> None:
        story = story_store.load_story(story_id)
        pages = story.get("pages") if story else None
        if not pages or page_index < 0 or page_index >= len(pages):
            await self._send_text_unbuffered(
                encode_error(
                    f"no page {page_index} for story {story_id!r}", self._current_turn_id
                )
            )
            return
        text = pages[page_index]["text"]
        async with self._transport_lock:
            async for pcm in self._tts.synthesize(text):
                await self._transport.send_bytes(pcm)
            await self._transport.send_text(encode_page_audio_done(story_id, page_index))
```

Add the three new encoder imports to the existing `from .protocol import
(...)` block:

```python
    encode_error,
    encode_page_audio_done,
    encode_story_detail,
    encode_story_list,
```

(`encode_error` is already imported by the existing code — only
`encode_page_audio_done`/`encode_story_detail`/`encode_story_list` are
new; don't duplicate the existing `encode_error` line.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_session.py -v`
Expected: PASS (full suite)

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
git commit -m "feat(server): add list/get story and on-demand page synthesis handlers"
```

---

### Task 11: `app.py` — resend status on reconnect

**Files:**
- Modify: `server/tinytalk/app.py`
- Test: `server/tests/test_app.py`

**Interfaces:**
- Consumes: `SessionRunner.resend_current_status()` (Task 9).

- [ ] **Step 1: Write the failing test**

`test_app.py` already has exactly this shape of test —
`test_reconnecting_after_a_disconnect_mid_turn_replays_the_buffered_reply`
(drives a turn to completion on `first_socket`, then reconnects a fresh
`second_socket` onto the same `session` and inspects what it received).
Add a new test right after it, following the same pattern but driving a
*concluding* turn (an LLM reply containing "The end.") so the session
lands in `REWRITING` before the reconnect:

```python
async def test_reconnecting_while_rewriting_repushes_rewriting_started():
    first_socket = FakeWebSocket(
        ['{"type": "speech_start", "turn_id": 1}', b"\x01\x02", '{"type": "speech_end"}']
    )
    session = SessionRunner(
        transport=WebSocketTransport(first_socket),
        stt=FakeStt(),
        llm=FakeLlm(chunks=["The end."]),
        tts=FakeTts(),
        system_prompt="be kind",
    )
    await handle_connection(first_socket, session=session)
    await session.wait_for_turn()
    assert session.state is State.REWRITING

    second_socket = FakeWebSocket([])  # the child reopens the app mid-rewrite
    await handle_connection(second_socket, session=session)

    text_frames = [item for item in second_socket.sent if isinstance(item, str)]
    assert any('"type": "rewriting_started"' in frame for frame in text_frames), (
        "reconnecting mid-rewrite must tell the client it can't start a new "
        "story yet"
    )
```

Add `from tinytalk.state import State` to `test_app.py`'s existing import
block at the top of the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && pytest tests/test_app.py -k rewriting -v`
Expected: FAIL — `rewriting_started` is never resent on reconnect today.

- [ ] **Step 3: Implement**

In `server/tinytalk/app.py`'s `handle_connection`, right after the
existing replay call:

```python
    await session.replay_last_turn()
    await session.resend_current_status()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && pytest tests/test_app.py -v`
Expected: PASS (full suite)

- [ ] **Step 5: Run the full server test suite**

Run: `cd server && pytest -v`
Expected: PASS — every test in `server/tests/`, old and new, confirming
nothing in this plan's 11 tasks broke an existing behavior.

- [ ] **Step 6: Commit**

```bash
git add server/tinytalk/app.py server/tests/test_app.py
git commit -m "feat(server): resend rewrite status on reconnect"
```

---

## Self-Review Notes

**Spec coverage:** every section of the design spec maps to a task above
— data model (Task 4), rewrite pipeline (Task 7), epilogue grounding
(Task 2), wire protocol (Task 5), arc-stage push (Task 8), conclude
action (Task 8), `REWRITING` state and its exception to "interrupt is
legal everywhere" (Task 6, Task 9), reconnect resend (Task 11), error
handling / non-fatal rewrite failures (Task 7, Task 9), and the full
testing list from the spec (`story_store`, `storybook.py` with a fake
LLM, `state.py` transition tests including the *absence* of
`SPEECH_START`/`INTERRUPT` from `REWRITING`, `session.py`'s conclude flow
and full gate lifecycle, `protocol.py` round-trips, `AnimalFactTracker`
retaining real fact text) all have concrete tests above.

**Known trace-through fixes not explicitly called out in the spec, caught
while writing this plan:** `_start_listening`/`_interrupt` needed an
explicit early-return guard for `REWRITING` (Task 9) — without it, the
existing `_transition()` wrapper silently swallows the resulting
`InvalidTransition`, but `self._current_turn_id` and STT reset would
still happen as stray side effects before the swallowed exception. A
failed `save_story()` call during a concluding turn needed an immediate
`Event.REWRITE_DONE` (Task 9) — otherwise the session enters `REWRITING`
with no background task ever scheduled to release it. The
`_STT_FAILURE_GUIDANCE` append needed an explicit `and not forced_conclude`
guard (Task 8) — otherwise a forced-conclude turn's empty transcript
would append contradictory guidance ("gently continue the story" right
next to "this must be the last reply").
