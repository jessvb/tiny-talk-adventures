# Story Generation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give stories a real beginning/middle/end (instead of open-ended
chat that never concludes), replace the safety stub with a broader
deterministic filter, and save each completed story to disk.

**Architecture:** Three new, independently-testable modules alongside the
existing `conversation.py`/`safety.py` split: `story_arc.py` (turn-budget
staging + end-of-story detection, no LLM calls), an expanded `safety.py`
(same public contract, categorized word lists), and `story_store.py`
(writes a completed story's transcript to one JSON file, no read path).
`SessionRunner` wires `StoryArc` into its existing per-turn flow.

**Tech Stack:** Python 3.12, no new dependencies (stdlib `re`, `json`,
`pathlib`, `uuid`, `datetime`, `enum`).

## Global Constraints

- Full spec: `docs/superpowers/specs/2026-08-24-story-generation-engine-design.md`.
- Free/local models only, no new external dependencies (per root `CLAUDE.md`).
- No extra model/LLM calls anywhere in this plan — all new logic is
  deterministic (regex/turn-count), per the spec's explicit latency/memory
  constraint (STT+LLM+TTS already run concurrently under real memory
  pressure on the M1/16GB server).
- `server/data/` (where completed stories are saved) must be gitignored —
  personal story content, not code.
- Before running any `pytest`/`python` command: confirm the venv is active
  (`which python` resolves inside `server/.venv`, not a pyenv shim or
  system path) and run commands from the `server/` directory.
- This spec/plan does not filter or moderate anything the *child* says —
  only what gets generated and spoken to them.

---

### Task 1: `story_arc.py` — turn-budget staging and end-of-story detection

**Files:**
- Create: `server/tinytalk/story_arc.py`
- Modify: `server/tinytalk/config.py` (add `STORY_TARGET_TURNS`)
- Test: `server/tests/test_story_arc.py`

**Interfaces:**
- Consumes: `config.STORY_TARGET_TURNS: int` (this task adds it).
- Produces (used by Task 4):
  - `class Stage(Enum)` with values `SETUP`, `RISING_ACTION`, `CLIMAX`,
    `RESOLUTION`, `DONE`.
  - `class StoryArc`:
    - `__init__(self, target_turns: int = config.STORY_TARGET_TURNS) -> None`
    - `stage: Stage` (property)
    - `is_done: bool` (property)
    - `record_turn(self, child_text: str) -> str` — call once per turn,
      right after the child's transcript is known and before building the
      LLM messages. Returns the guidance string to append to the system
      prompt for that turn.
    - `record_reply(self, reply_text: str) -> None` — call once per turn,
      after the (safety-filtered) reply is generated.

- [ ] **Step 1: Add the turn-budget config constant**

Add this to `server/tinytalk/config.py`, immediately before the
`SYSTEM_PROMPT = (` line:

```python
# One turn = one child utterance + one agent reply. Roughly matched to a
# young child's attention span -- see story_arc.py's module docstring for
# how this drives narrative staging.
STORY_TARGET_TURNS = int(os.environ.get("TINYTALK_STORY_TARGET_TURNS", "12"))

```

- [ ] **Step 2: Write the failing tests**

Create `server/tests/test_story_arc.py`:

```python
import pytest

from tinytalk.story_arc import Stage, StoryArc


def test_new_arc_starts_at_setup_stage_and_is_not_done():
    arc = StoryArc()
    assert arc.stage is Stage.SETUP
    assert arc.is_done is False


def test_stage_progresses_through_all_boundaries_for_default_target():
    # target_turns=12: setup 1-3, rising_action 4-8, climax 9-12,
    # resolution 13-15.
    arc = StoryArc()
    expected = (
        [Stage.SETUP] * 3
        + [Stage.RISING_ACTION] * 5
        + [Stage.CLIMAX] * 4
        + [Stage.RESOLUTION] * 3
    )
    for turn_number, expected_stage in enumerate(expected, start=1):
        arc.record_turn("we walked into the forest")
        assert arc.stage is expected_stage, f"turn {turn_number}"


def test_custom_target_turns_scales_boundaries():
    # target_turns=8: setup 1-2, rising_action 3-5, climax 6-8.
    arc = StoryArc(target_turns=8)
    expected = [Stage.SETUP] * 2 + [Stage.RISING_ACTION] * 3 + [Stage.CLIMAX] * 3
    for expected_stage in expected:
        arc.record_turn("a squirrel found an acorn")
        assert arc.stage is expected_stage


def test_record_turn_returns_guidance_matching_current_stage():
    arc = StoryArc()
    guidance = arc.record_turn("we walked into the forest")
    assert "start of the story" in guidance.lower()


@pytest.mark.parametrize(
    "phrase",
    [
        "the end",
        "I'm done",
        "im done",
        "stop the story",
        "that's enough",
        "no more story",
        "i want to stop",
    ],
)
def test_child_stop_phrases_force_resolution_guidance_even_during_setup(phrase):
    arc = StoryArc()
    guidance = arc.record_turn(phrase)  # turn 1 -- would normally be setup
    assert "wrap up the story" in guidance.lower()


def test_agent_reply_with_conclusion_phrase_sets_is_done():
    arc = StoryArc()
    arc.record_turn("we walked into the forest")
    arc.record_reply("And they all lived happily ever after.")
    assert arc.is_done is True
    assert arc.stage is Stage.DONE


def test_agent_reply_without_conclusion_phrase_does_not_set_is_done():
    arc = StoryArc()
    arc.record_turn("we walked into the forest")
    arc.record_reply("A friendly fox appeared and waved hello.")
    assert arc.is_done is False


def test_turn_count_past_grace_ceiling_forces_guidance_then_marks_done():
    arc = StoryArc()  # target=12, grace ceiling=15
    for _ in range(15):
        arc.record_turn("something happens")
        arc.record_reply("something else happens, with no trigger phrase")
    assert arc.is_done is False  # still within the grace ceiling

    guidance = arc.record_turn("something happens")  # turn 16, past ceiling
    assert guidance == (
        "This must be the last reply -- bring the story to a warm, "
        "complete ending right now."
    )
    arc.record_reply("anything at all, even without a conclusion phrase")
    assert arc.is_done is True
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd server && python -m pytest tests/test_story_arc.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.story_arc'`

- [ ] **Step 4: Implement `story_arc.py`**

Create `server/tinytalk/story_arc.py`:

```python
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
"""

from __future__ import annotations

import re
from enum import Enum

from . import config


class Stage(Enum):
    SETUP = "setup"
    RISING_ACTION = "rising_action"
    CLIMAX = "climax"
    RESOLUTION = "resolution"
    DONE = "done"


_FORCED_GUIDANCE = (
    "This must be the last reply -- bring the story to a warm, complete "
    "ending right now."
)

_GUIDANCE: dict[Stage, str] = {
    Stage.SETUP: (
        "You're at the start of the story -- introduce the setting and "
        "characters, and get the adventure going."
    ),
    Stage.RISING_ACTION: (
        "The story is building -- keep it exciting and let the child's "
        "ideas shape what happens next."
    ),
    Stage.CLIMAX: (
        "The story is nearing its big moment -- build toward an exciting "
        "(but still gentle) high point."
    ),
    Stage.RESOLUTION: (
        "It's time to wrap up the story warmly and happily in this reply "
        "or the next one."
    ),
    # Only reachable if record_turn() is somehow called again after
    # is_done is already true (not expected in normal use -- SessionRunner
    # replaces this instance once done) -- kept so that path can't KeyError.
    Stage.DONE: _FORCED_GUIDANCE,
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

    def _stage_for_turn(self, turn: int) -> Stage:
        if turn <= 0:
            return Stage.SETUP
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd server && python -m pytest tests/test_story_arc.py -v`
Expected: PASS (all tests green)

- [ ] **Step 6: Commit**

```bash
cd server
git add tinytalk/story_arc.py tinytalk/config.py tests/test_story_arc.py
git commit -m "feat(server): add StoryArc for turn-budget narrative staging and end-of-story detection"
```

---

### Task 2: Expand `safety.py` into categorized filters

**Files:**
- Modify: `server/tinytalk/safety.py` (full rewrite of the word-list section; `is_safe`/`filter_reply`/`SAFE_FALLBACK` keep their exact signatures)
- Test: `server/tests/test_safety.py` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: no change to the public contract (`is_safe(text: str) -> bool`,
  `filter_reply(text: str) -> str`, `SAFE_FALLBACK: str`) — `session.py`'s
  existing call site (`safety.filter_reply(...)`) needs no changes at all.

- [ ] **Step 1: Write the failing tests**

Add these cases to `server/tests/test_safety.py` (append after the
existing tests, keep the existing ones unchanged):

```python
@pytest.mark.parametrize(
    "text",
    [
        "The monster attacking the village was terrifying.",
        "It was a nightmare full of evil demons.",
        "She screamed in terror, trapped forever in the tower.",
    ],
)
def test_frightening_content_is_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "He was drunk on alcohol and lit a cigarette.",
        "She stood there completely naked.",
    ],
)
def test_adult_themes_are_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "He played with matches and a lighter near the poison.",
        "She almost drowned after deciding to jump off a cliff.",
    ],
)
def test_real_world_danger_is_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "What the hell is going on, damn it.",
        "That little shit ruined everything, the bastard.",
    ],
)
def test_profanity_is_unsafe(text):
    assert is_safe(text) is False


def test_innocent_fairy_tale_kiss_stays_safe():
    # A regression guard on scope, not just a passing test: "kiss" itself
    # must NOT be a blocked word -- fairy-tale kisses (true love's kiss,
    # a goodnight kiss) are a completely normal, wholesome element in
    # children's stories, and blocking the bare word would over-trigger
    # constantly. Only a more explicit phrase should be blocked.
    assert is_safe("The prince gave the sleeping princess a gentle kiss.") is True
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && python -m pytest tests/test_safety.py -v`
Expected: FAIL — the four new `test_*_is_unsafe` tests fail (categories
don't exist yet); `test_innocent_fairy_tale_kiss_stays_safe` passes
already (nothing blocks "kiss" yet) but run the whole file anyway to
confirm the new failures are the expected ones.

- [ ] **Step 3: Implement the expanded categories**

Replace `server/tinytalk/safety.py` in full:

```python
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
    "hurt",
    "stab",
    "shoot",
)

_FRIGHTENING = (
    "monster attacking",
    "terrifying",
    "nightmare",
    "screamed in terror",
    "trapped forever",
    "evil",
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
    "matches",
    "lighter",
    "poison",
    "drown",
    "jump off a cliff",
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

_ALL_BLOCKED = _VIOLENCE + _FRIGHTENING + _ADULT_THEMES + _REAL_WORLD_DANGER + _PROFANITY

# Word boundaries keep "begun" and "knifemaker" from tripping the filter.
_BLOCKED_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(word) for word in _ALL_BLOCKED) + r")\b",
    re.IGNORECASE,
)


def is_safe(text: str) -> bool:
    return _BLOCKED_PATTERN.search(text) is None


def filter_reply(text: str) -> str:
    return text if is_safe(text) else SAFE_FALLBACK
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd server && python -m pytest tests/test_safety.py -v`
Expected: PASS (all tests green, including the original pre-existing ones)

- [ ] **Step 5: Commit**

```bash
cd server
git add tinytalk/safety.py tests/test_safety.py
git commit -m "feat(server): expand safety filter into five categories, including profanity"
```

---

### Task 3: `story_store.py` — save completed stories to disk

**Files:**
- Create: `server/tinytalk/story_store.py`
- Test: `server/tests/test_story_store.py`
- Modify: `.gitignore` (repo root — add `server/data/`)

**Interfaces:**
- Consumes: `Conversation` from `tinytalk.conversation` (its `.turns`
  property — a tuple of `Turn(speaker: str, text: str, interrupted: bool)`).
- Produces (used by Task 4):
  `save_story(conversation: Conversation, *, stories_dir: Path = STORIES_DIR) -> Path | None`
  — writes one JSON file, returns the written path, or `None` (logged, not
  raised) if the write failed.

- [ ] **Step 1: Add the gitignore entry**

Add this line to the repo-root `.gitignore` (alongside the existing
entries):

```
server/data/
```

- [ ] **Step 2: Write the failing tests**

Create `server/tests/test_story_store.py`:

```python
import json

from tinytalk.conversation import Conversation
from tinytalk.story_store import save_story


def make_conversation() -> Conversation:
    conversation = Conversation()
    conversation.add_child("tell me about a fox")
    conversation.add_agent("Once there was a clever fox.")
    return conversation


def test_save_story_writes_a_json_file_with_expected_shape(tmp_path):
    conversation = make_conversation()

    path = save_story(conversation, stories_dir=tmp_path)

    assert path is not None
    assert path.exists()
    assert path.parent == tmp_path
    payload = json.loads(path.read_text())
    assert payload["turns"] == [
        {"speaker": "child", "text": "tell me about a fox", "interrupted": False},
        {"speaker": "agent", "text": "Once there was a clever fox.", "interrupted": False},
    ]
    assert "id" in payload
    assert "created_at" in payload


def test_save_story_creates_the_directory_if_missing(tmp_path):
    stories_dir = tmp_path / "nested" / "stories"
    assert not stories_dir.exists()

    path = save_story(make_conversation(), stories_dir=stories_dir)

    assert path is not None
    assert stories_dir.exists()


def test_repeated_saves_produce_unique_filenames(tmp_path):
    first = save_story(make_conversation(), stories_dir=tmp_path)
    second = save_story(make_conversation(), stories_dir=tmp_path)

    assert first != second
    assert len(list(tmp_path.glob("*.json"))) == 2


def test_save_failure_is_logged_and_returns_none_instead_of_raising(tmp_path):
    # A regular FILE sitting where the stories directory needs to go makes
    # mkdir() genuinely fail with a real OSError (FileExistsError), no
    # monkeypatching needed.
    blocked_path = tmp_path / "blocked"
    blocked_path.write_text("not a directory")

    result = save_story(make_conversation(), stories_dir=blocked_path)

    assert result is None
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd server && python -m pytest tests/test_story_store.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.story_store'`

- [ ] **Step 4: Implement `story_store.py`**

Create `server/tinytalk/story_store.py`:

```python
"""Persists a completed story's transcript to disk.

Deliberately minimal: one JSON file per story, no read/list/browse API.
The future storybook persistence sub-project reads these files directly
-- this module exists so nothing is lost between now and then, in a
shape that sub-project can build on without reworking this one. See
docs/superpowers/specs/2026-08-24-story-generation-engine-design.md.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .conversation import Conversation

logger = logging.getLogger(__name__)

STORIES_DIR = Path(__file__).resolve().parent.parent / "data" / "stories"


def save_story(
    conversation: Conversation, *, stories_dir: Path = STORIES_DIR
) -> Path | None:
    """Writes conversation.turns to a new JSON file under stories_dir.

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
            for turn in conversation.turns
        ],
    }
    try:
        stories_dir.mkdir(parents=True, exist_ok=True)
        path = stories_dir / filename
        path.write_text(json.dumps(payload, indent=2))
        return path
    except OSError as exc:
        logger.error("failed to save story: %s", exc)
        return None
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd server && python -m pytest tests/test_story_store.py -v`
Expected: PASS (all tests green)

- [ ] **Step 6: Commit**

```bash
cd server
git add tinytalk/story_store.py tests/test_story_store.py ../.gitignore
git commit -m "feat(server): save completed stories to disk as JSON"
```

---

### Task 4: Wire `StoryArc` and `story_store` into `SessionRunner`

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py` (extend)

**Interfaces:**
- Consumes:
  - `StoryArc` and `Stage` from Task 1 (`tinytalk.story_arc`).
  - `save_story` from Task 3 (`tinytalk.story_store`).
- Produces: no new public interface — this task only changes
  `SessionRunner`'s internal behavior (the system prompt sent to the LLM
  each turn, and what happens once a story concludes).

- [ ] **Step 1: Write the failing tests**

Add these to `server/tests/test_session.py` (append after the existing
tests; the file already imports `FakeLlm`, `FakeStt`, `FakeTransport`,
`FakeTts`, `make_session`, and `run_full_turn` — reuse them):

```python
def test_story_arc_setup_guidance_is_included_in_the_llm_system_prompt(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert system_message["role"] == "system"
    assert "start of the story" in system_message["content"].lower()


def test_reaching_story_done_saves_and_resets_conversation_and_arc(transport, monkeypatch):
    saved: list = []
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: saved.append(conversation) or None,
    )
    llm = FakeLlm(chunks=["And they all lived ", "happily ever after."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert len(saved) == 1
    # The conversation passed to save_story had this turn's content...
    assert saved[0].turns[-1].text == "And they all lived happily ever after."
    # ...but session.conversation is now a FRESH one: the next story has
    # no memory of the finished one.
    assert session.conversation.turns == ()


def test_story_not_done_does_not_save_or_reset_conversation(transport, monkeypatch):
    saved: list = []
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: saved.append(conversation) or None,
    )
    session = make_session(transport)  # default FakeLlm reply has no conclusion phrase

    await run_full_turn(session)

    assert saved == []
    assert len(session.conversation.turns) == 2  # child + agent turn both retained
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && python -m pytest tests/test_session.py -v -k "story"`
Expected: FAIL — `test_story_arc_setup_guidance_is_included_in_the_llm_system_prompt`
fails because the system prompt has no guidance appended yet;
`test_reaching_story_done_saves_and_resets_conversation_and_arc` fails
because nothing calls `story_store.save_story` yet, so `saved` stays
empty and `session.conversation.turns == ()` is false (the turns are
still there, not reset).

- [ ] **Step 3: Wire `StoryArc`/`story_store` into `session.py`**

In `server/tinytalk/session.py`, add these imports alongside the existing
ones (after the `from .protocol import (...)` block, before `from .state
import ...`):

```python
from . import story_store
from .story_arc import StoryArc
```

In `SessionRunner.__init__` (currently lines 43-73), add the arc
alongside the existing `self._conversation` line:

```python
        self._conversation = conversation or Conversation()
        self._story_arc = StoryArc()
```

In `_run_turn` (currently lines 261-337), make three changes:

1. Right after `self._conversation.add_child(transcript)`, get the
   guidance and use it when building messages:

```python
            self._conversation.add_child(transcript)
            guidance = self._story_arc.record_turn(transcript)
            messages = self._conversation.to_messages(
                self._system_prompt + "\n\n" + guidance
            )
```

   (this replaces the existing `messages =
   self._conversation.to_messages(self._system_prompt)` line)

2. Right after `reply = safety.filter_reply(...)` (and before the
   `logger.info("llm stream_reply: ...")` call, order doesn't matter
   between those two, but it must come after `reply` is assigned), record
   the reply:

```python
            reply = safety.filter_reply("".join(parts).strip())
            self._story_arc.record_reply(reply)
```

3. At the very end of the `try` block, right after the existing
   `logger.info("turn total (transcript -> turn_end): ...")` call, add
   the done-check:

```python
            logger.info(
                "turn total (transcript -> turn_end): %.1f ms",
                (time.monotonic() - turn_start) * 1000,
            )
            if self._story_arc.is_done:
                saved_path = story_store.save_story(self._conversation)
                if saved_path is not None:
                    logger.info("story saved to %s", saved_path)
                self._conversation = Conversation()
                self._story_arc = StoryArc()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd server && python -m pytest tests/test_session.py -v`
Expected: PASS (all tests in the file green, including the pre-existing
ones — confirms this didn't regress the turn_id/interrupt/latency
behavior already covered there)

- [ ] **Step 5: Run the full server test suite**

Run: `cd server && python -m pytest tests -v`
Expected: PASS (every test in the project, not just this file)

- [ ] **Step 6: Commit**

```bash
cd server
git add tinytalk/session.py tests/test_session.py
git commit -m "feat(server): wire StoryArc guidance and story persistence into SessionRunner"
```
