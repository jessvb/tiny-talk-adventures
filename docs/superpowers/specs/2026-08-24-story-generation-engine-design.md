# Story Generation Engine — Design Spec

Status: Approved (design confirmed by user 2026-08-24)

## Context

Second sub-project of Tiny Talk Adventures, following the now-complete
voice/dialog pipeline (server + iOS phone client). See
`docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md` for the
full project decomposition; this spec covers item (2) from that list:
"the story generation engine (narrative arc + safety scaffolding)."

The server today (`server/tinytalk/session.py`) already runs a working
LLM-backed conversation loop: the child speaks, `SessionRunner` transcribes
it, sends the running conversation to a local LLM (Qwen 3.5 9B via Ollama,
or Groq as a swappable backend) with a fixed system prompt, and speaks the
reply back. Two things are explicitly placeholders in that loop, called out
directly in the code:

- There is no story structure. The conversation just continues turn by turn
  forever — nothing ever builds toward or reaches an ending.
- `server/tinytalk/safety.py`'s module docstring says outright: "STUB...
  standing in for real safety scaffolding, which is a separate sub-project."
  It is a single 12-word denylist covering only violence.

This spec replaces both placeholders. Personal pet project, single
household — see root `CLAUDE.md` for the constraints that apply project-wide
(free/local models only, privacy-first, kid-safe content, no production
concerns beyond what this family's use actually needs).

## Goals

- Give stories real shape: a beginning that establishes the scene, a middle
  that builds, and a wrap-up that actually concludes — instead of the current
  open-ended chat that never ends on its own.
- Detect three independent ways a story can end: a turn-count budget is
  reached, the child says they want to stop, or the model concludes the
  story naturally on its own — and steer the LLM toward a warm conclusion
  once any of them fires.
- Replace the safety stub with a meaningfully broader deterministic filter
  (more categories, not just violence), while keeping it zero-latency —
  no additional model calls, given STT+LLM+TTS already run concurrently
  under real memory pressure on the M1/16GB server (documented in the
  voice/dialog pipeline spec's risks section).
- Save each completed story to disk in a shape the future storybook
  persistence sub-project can read directly, without building any
  read/list/browse API in this spec.

## Non-goals (deferred to later specs)

- A storybook read/list/browse API or UI — this spec only writes completed
  stories to disk. Retrieving and presenting them is the storybook
  persistence sub-project's job (see the voice/dialog pipeline spec's
  decomposition list).
- Animal facts integration, environment-based inspiration, illustration
  sourcing — later, independent sub-projects.
- A second-pass LLM/classifier safety gate. Considered and explicitly
  rejected for this spec given the existing memory-pressure constraint;
  may be revisited later if the deterministic filter proves insufficient
  in real use.
- Filtering or moderating what the *child* says. Kid-safe scaffolding here
  is about what gets generated and spoken *to* the child (per `CLAUDE.md`'s
  "Kid-safe content" principle), not policing the child's own speech.
- Any change to the voice/dialog pipeline's interrupt/barge-in/latency
  mechanics — this spec only changes what's sent to the LLM and what
  happens once a story concludes.

## Architecture

Three new, independently-testable modules, mirroring the existing split
between `conversation.py` and `safety.py` rather than growing
`session.py` (already a multi-concern file) further:

- **`story_arc.py`** — turn-count-budget-driven story staging plus
  deterministic end-of-story detection. No LLM calls.
- **`safety.py`** (expanded, not rewritten) — same external contract
  (`is_safe`, `filter_reply`), broader categorized word/phrase lists.
- **`story_store.py`** — writes a completed story's transcript to a JSON
  file on disk. No read path.

`SessionRunner` wires these into the existing per-turn flow: `StoryArc`
guidance gets appended to the system prompt sent to the LLM each turn, and
reaching `done` triggers a save plus a fresh `Conversation`/`StoryArc` pair
for the next story.

## Components

### `story_arc.py`

```python
class Stage(Enum):
    SETUP = "setup"
    RISING_ACTION = "rising_action"
    CLIMAX = "climax"
    RESOLUTION = "resolution"
    DONE = "done"

class StoryArc:
    def __init__(self, target_turns: int = config.STORY_TARGET_TURNS) -> None: ...

    @property
    def stage(self) -> Stage: ...

    @property
    def is_done(self) -> bool: ...

    def record_turn(self, child_text: str) -> str:
        """Call once per turn, before generating the reply (i.e. right
        after the child's transcript is known). Increments the turn
        counter, checks child_text against the "wants to stop" pattern,
        and returns the guidance string to append to the system prompt
        for this turn's LLM call."""

    def record_reply(self, reply_text: str) -> None:
        """Call once per turn, after the reply is generated. Checks
        reply_text against the "natural conclusion" pattern and the
        grace-ceiling turn count; sets is_done if either fires."""
```

- `config.STORY_TARGET_TURNS` defaults to **12** (one turn = one child
  utterance + one agent reply) — roughly matched to a young child's
  attention span. Stage boundaries, as fractions of the target:
  - `setup`: turns 1 through `ceil(0.2 * target)` (turns 1-3 at the default)
  - `rising_action`: through `ceil(0.7 * target)` (turns 4-8)
  - `climax`: through `target` (turns 9-12)
  - `resolution`: turn `target + 1` through a grace ceiling of
    `target + 3` (turns 13-15) — after the ceiling, the *next* reply is
    forced to conclude regardless of anything else.
- **Three independent end triggers**, any one of which can fire first:
  1. Turn count passes the grace ceiling → forced conclusion.
  2. The child's transcript matches a "wants to stop" pattern (e.g. "the
     end", "I'm done", "stop the story", "that's enough", "no more story")
     → `record_turn` returns resolution-stage guidance for *this* turn's
     reply, regardless of the current stage.
  3. The agent's own reply naturally contains a conclusion phrase (e.g.
     "the end", "happily ever after", "the story is over") → `is_done`
     becomes true right after that reply is sent; no extra prompting
     needed since the model already concluded on its own.
- Both patterns are deterministic word/phrase regexes, same style and
  same file-local list-of-strings approach as `safety.py` — not a
  separate module, since they're small and specific to `StoryArc`.
- Guidance strings, one per stage, are what `record_turn()` returns; the
  caller appends the returned string to `config.SYSTEM_PROMPT` for that
  turn only (`system_prompt + "\n\n" + guidance`):
  - setup: "You're at the start of the story — introduce the setting and
    characters, and get the adventure going."
  - rising_action: "The story is building — keep it exciting and let the
    child's ideas shape what happens next."
  - climax: "The story is nearing its big moment — build toward an
    exciting (but still gentle) high point."
  - resolution: "It's time to wrap up the story warmly and happily in
    this reply or the next one."
  - forced (turn number is exactly one past the grace ceiling — not a
    separate `Stage` value, just a stronger guidance string returned by
    `record_turn` for that one turn instead of the resolution text): "This
    must be the last reply — bring the story to a warm, complete ending
    right now." `record_reply` then sets `is_done` unconditionally once
    this turn's reply is generated, regardless of its text, since there is
    no turn after this one — the arc resets before a "turn 17" could ever
    happen.

### `safety.py` (expanded)

Same public functions (`is_safe(text) -> bool`, `filter_reply(text) ->
str`, `SAFE_FALLBACK`) — callers (`session.py`) don't change at all. The
single `_BLOCKED_WORDS` tuple becomes five named category tuples, combined
into one compiled pattern (still one regex pass, still zero added
latency):

- **Violence**: blood, gun(s), knife/knives, kill(s)/killed, dead, die(s)/
  died, fight, hurt, stab, shoot.
- **Frightening/scary peril**: monster attacking, terrifying, nightmare,
  screamed in terror, trapped forever, evil, demon.
- **Adult themes**: kiss (romantic), drunk, alcohol, cigarette, naked.
- **Real-world danger**: matches, lighter, poison, drown, cliff (jump off
  a...).
- **Profanity/crude language**: common swear words and crude
  body-function language.

This remains an explicitly deterministic word/phrase filter, not true
content understanding — same caveat the current docstring states, just a
meaningfully wider net than 12 words in one bucket.

### `story_store.py`

```python
def save_story(conversation: Conversation) -> Path:
    """Writes conversation.turns to server/data/stories/<timestamp>-<id>.json.
    Creates the directory if needed. Returns the written path."""
```

- Filename: `<ISO-8601 timestamp>-<short id>.json` — sorts naturally by
  creation time, human-browsable without any tooling.
- JSON schema:
  ```json
  {
    "id": "...",
    "created_at": "2026-08-24T15:30:00",
    "turns": [
      {"speaker": "child", "text": "...", "interrupted": false},
      {"speaker": "agent", "text": "...", "interrupted": false}
    ]
  }
  ```
  A direct serialization of `Conversation.turns` plus an id/timestamp —
  deliberately not a "real" storage API, so the storybook sub-project can
  read these files directly without this spec having guessed wrong about
  its needs.
- `server/data/` is added to `.gitignore` — personal story content, not
  code.

### `SessionRunner` integration

- Construction gains a `self._story_arc = StoryArc()` alongside the
  existing `self._conversation = Conversation()`.
- In `_finish_listening`, after the transcript is known: call
  `guidance = self._story_arc.record_turn(transcript)` and pass
  `self._system_prompt + "\n\n" + guidance` to `to_messages()` instead of
  the bare system prompt.
- In `_run_turn`, after the reply is generated (same place `_spoken` is
  currently populated): call `self._story_arc.record_reply(reply)`.
- After the turn fully completes (`turn_end` sent), check
  `self._story_arc.is_done`. If true: call `story_store.save_story(self
  ._conversation)`, then replace `self._conversation = Conversation()` and
  `self._story_arc = StoryArc()` — the next child utterance starts a
  brand new story with no memory of the old one.

## Data flow

```
child speaks
  -> STT transcript
  -> StoryArc.record_turn(transcript)   [turn count++, check "wants to stop"]
     -> guidance string for this turn
  -> LLM call with system_prompt + guidance
  -> reply text
  -> safety.filter_reply(reply)         [unchanged integration point]
  -> StoryArc.record_reply(filtered reply)   [check "natural conclusion", grace ceiling]
  -> TTS + send to child                [unchanged]
  -> if arc.is_done:
       story_store.save_story(conversation)
       conversation = Conversation()   [fresh story]
       story_arc = StoryArc()
```

## Error handling

- A failed save (disk full, permissions, etc.) is logged and swallowed,
  not raised — losing a saved story is unfortunate but must never crash
  or hang the session, matching how `_fail_turn` already treats engine
  failures elsewhere in `session.py`.
- `StoryArc`'s pattern matching and stage computation are pure/synchronous
  with no I/O — no new failure modes introduced there.
- The safety filter's existing failure mode (a blocked reply becomes
  `SAFE_FALLBACK`) is unchanged; broadening the category lists doesn't
  change that mechanism, only what triggers it.

## Testing approach

- `test_story_arc.py`: stage boundaries at exact turn counts (including
  off-by-one at each threshold), child-stop-phrase detection forcing
  resolution guidance mid-story, agent-conclusion-phrase detection
  setting `is_done`, forced conclusion once the grace ceiling is passed.
- `test_safety.py`: extend the existing parametrized cases with the new
  categories, including profanity — following the same
  wholesome-text-passes / blocked-word-fails pattern already there.
- `test_story_store.py`: correct JSON shape and field values, unique
  filenames across repeated calls, directory auto-creation on first
  write, a simulated write failure not raising.
- `test_session.py`: integration coverage — arc guidance text actually
  appears in the messages sent to the LLM for a given stage, and reaching
  `done` triggers both a save call and fresh `Conversation`/`StoryArc`
  instances (i.e. the next turn has no memory of the finished story).

## Open questions / risks

- The turn-count budget (12) and grace ceiling (+3) are best-effort
  starting numbers, not measured against real sessions with a child yet —
  expect to tune both after actual use, same as the voice pipeline's VAD
  timings were tuned this session.
- Phrase-based end detection (both child-stop and natural-conclusion) can
  false-positive on a child who says "the end" mid-sentence about
  something unrelated, or false-negative on a story that wraps up without
  using any of the listed phrases. Accepted for v1 given the zero-latency
  constraint; a future revision could reconsider a lightweight
  classifier if this proves too unreliable in practice.
- The profanity/crude-language category needs an actual word list decided
  during implementation — this spec doesn't enumerate it (the specific
  words aren't meaningful design content, unlike the other categories'
  representative examples above).
