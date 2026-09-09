# Storybook Persistence — Design Notes

Status: Approved, not yet implemented (brainstormed 2026-09-08)

## Context

The kid-facing iOS UI (`2026-09-05-kid-facing-ui-design.md`) shipped only
Onboarding, Landing, the live Story screen, and Settings in PR #9. Library,
Reading, and The End were deliberately deferred because the server had no
supporting data or actions for them:

- No arc-stage wire message (the design's "big moment" progress dots have
  no real data source).
- No story-conclude action (the design's "Finish this story" menu item has
  nothing to call).
- No story list/read API — `story_store.py`'s own docstring says it's
  "deliberately minimal ... no read/list/browse API," explicitly left for
  this sub-project.

This spec is that sub-project: the server-side work needed to unblock all
three screens.

## Scope decisions made during brainstorming

Reading the actual Claude Design canvas (`Tiny Talk Adventures.dc.html`,
project `d19c0d00-d971-4dc6-ac5b-1a06aaf11025`) directly, rather than
assuming from the earlier spec's three bullet points, found the real
ambition is considerably bigger than "expose three gaps":

- **The End** shows a generated book cover: title, byline, page count, and
  a one-line factual epilogue ("And one true thing we learned: foxes
  really do have over forty sounds").
- **Library** shows a grid of saved stories: title, relative date, page
  count.
- **Reading** is a paginated illustrated storybook, not a transcript
  viewer: each page has art (or, in one mock page, the child's own
  object-recognition photo), a "Page N" label, a rewritten prose
  paragraph, and a per-page 🔊 replay button.

None of that data (titles, pages, illustrations) exists today —
`save_story()` only persists raw `{speaker, text, interrupted}` turns.

Confirmed with the user before designing further:

- **Illustration is out of scope for this sub-project, full stop.** Real
  AI-generated per-page art is its own sub-project given the free/local-
  only, M1/16GB constraint, and the object-recognition photo tie-in seen
  in one mock page was considered and explicitly declined too — pages
  carry text only. No image generation, no photo association, is built
  here.
- **Pages are produced by an LLM rewrite pass**, not a 1:1 mapping of
  agent turns to pages. **The rewrite targets a fixed page count**
  (a configured target, the same pattern `story_arc.py`'s own
  `STORY_TARGET_TURNS` already uses — not "one page per turn," and not
  left to vary freely with story length). The rewrite gets both
  speakers' full turn history (not just the agent's own lines) and is
  explicitly prompted to produce continuous third-person storybook prose
  covering the same beats/facts/content — not a chopped-up transcript of
  who-said-what. **The raw transcript is always kept alongside the
  rewrite, never replaced by it** — both live in the same saved story
  file permanently.
- **The rewrite runs in the background**, after the story's own final
  reply has already played, not synchronously as part of that turn. This
  pipeline already runs STT+LLM+TTS per turn on modest hardware and is
  measured slower than its own 1-2s target; adding a fourth local-model
  call to the hot path the child is actively waiting on was rejected.
- **Page read-aloud is in scope now, synthesized on demand** (not
  pre-generated and stored) — a page's 🔊 tap triggers a fresh
  `KokoroTts.synthesize()` call streamed the same way live replies
  already are. No new audio storage, no staleness if page text is ever
  regenerated.
- **New-story creation is gated while a rewrite is in flight, for every
  path — including the child simply talking again** — not just the
  Library's explicit "+ New story" button. This is a deliberate,
  structural fix for LLM resource contention: this server runs one Ollama
  process on one M1/16GB machine, and if a rewrite pass and a new story's
  live turns could ever run concurrently, they'd compete for the same
  hardware. Gating every path to a new story means a live story and a
  background rewrite can never coexist, which removes the contention
  scenario entirely rather than just documenting it as a risk.

## Data model: extending `story_store.py`

The persisted JSON schema gains four new fields, all nullable, alongside
the existing `id`/`created_at`/`turns` (which are unchanged):

```json
{
  "id": "...",
  "created_at": "...",
  "turns": [...],
  "title": "Pip the Noisy Fox" | null,
  "pages": [{"text": "..."}] | null,
  "epilogue": "And one true thing we learned: ..." | null,
  "rewrite_status": "pending" | "done" | "failed"
}
```

`save_story()` writes `turns` immediately with `rewrite_status: "pending"`
and the other new fields `null` — this is exactly what happens today, plus
the new fields. A new function patches the rewrite result (or a `"failed"`
status) into the existing file once the background pass finishes. New
read functions (`list_stories()`, `load_story()`) support the Library/
Reading screens; no separate index file — a household's story count is
small enough that scanning the directory is fine.

## The rewrite pipeline: new `storybook.py`

A new module, kept separate from `story_store.py` (which stays pure
persistence, per its own docstring) and from `session.py` (which
orchestrates but shouldn't own prompt construction). One `stream_reply()`
call to the same local LLM already used for story replies (`qwen3.5:9b`
via Ollama — no new model, no change to the `LlmEngine` protocol or
`GroqLlm`). The prompt:

- Includes the full turn history from both speakers (the child's own
  suggestions are plot content, not dialogue to quote).
- Includes any real animal facts this story actually used (see below).
- Asks for a JSON object: `title`, `pages` (each an object with `text`),
  and optionally an `epilogue` line — explicitly instructed to write
  continuous third-person storybook narration, not a dialogue transcript.

The response is parsed as JSON out of the streamed text (tolerant of
minor formatting slop), the same way `session.py` already treats a
streamed reply as plain text once fully collected. A parse failure marks
`rewrite_status: "failed"` — logged, never raised.

**Epilogue grounding.** `AnimalFactTracker` currently tracks only *which*
animals got a fact woven in (`_facted: set[str]`), not the fact text
itself. It gains a small addition — retaining the actual `(animal, fact)`
pairs it successfully used — so the epilogue is always a real fact this
story actually shared, never something the small model invents fresh. If
no facts were shared, the epilogue is simply omitted, not fabricated.

**Data capture, not live references.** `session.py`'s turn-completion path
resets `self._conversation`/`self._story_arc`/`self._animal_facts` for the
next story immediately after a concluding turn. The rewrite task must be
handed the turns and shared facts as plain arguments before that reset
happens, not references to those objects — otherwise it would silently
end up rewriting whatever the *next* story's live objects contain by the
time it actually runs.

## Wire protocol additions

**State-independent reads** (work regardless of session state, including
while `REWRITING` — browsing already-saved stories has nothing to do with
the live session):

- `ListStories` → `story_list`: `[{id, title, created_at, page_count,
  rewrite_status}, ...]`. Includes `pending`/`failed` entries so the
  Library can render an accurate "still preparing" or degraded state
  rather than silently omitting a story.
- `GetStory(story_id)` → `story_detail`: `{title, pages, epilogue,
  rewrite_status}`.
- `SynthesizePage(story_id, page_index)` → streams audio through the
  existing binary-frame pathway already used for live TTS, followed by a
  small completion marker.

**Arc-stage push**: a new `arc_stage` server message, sent every turn
alongside the existing `transcript_final`/`response_text`/`turn_end`,
tagged with the same `turn_id` — the Story screen's progress dots read
whatever arrived most recently, same pattern as everything else in the
protocol.

**Rewrite-status push**: two small server messages, `rewriting_started`
and `rewriting_done`, sent exactly when the session enters/leaves the new
`REWRITING` state (see below) — this is what drives the client's "Elsie is
busy creating your storybook!" loading state and greyed-out
new-story affordances.

**`ConcludeStory(turn_id)`** — the "Finish this story" action. Legal from
any state, like `Interrupt`: cancels whatever's in flight first (the same
cancellation `_interrupt()` already does for barge-in — including an STT
reset if a child utterance was mid-flight), then runs a turn with no real
transcript and forced-conclusion guidance (the same guidance already used
when a story hits its turn-budget grace ceiling) instead of the normal
stage-based guidance. Afterward, the story is marked done
**unconditionally** — not by hoping the reply happens to contain "the
end." Natural endings rely on phrase-detection; an explicit request to
finish shouldn't be able to silently fail to end. This flows into the same
save + rewrite-kickoff path as any other conclusion.

## Session integration: the `REWRITING` state

`state.py` gains a new state and two new events:

```
State: IDLE, LISTENING, THINKING, SPEAKING, REWRITING

(SPEAKING, REWRITE_STARTED) -> REWRITING
(REWRITING, REWRITE_DONE)   -> IDLE
```

`session.py` decides which event to fire when a turn's reply finishes
sending — `TTS_DONE` for an ordinary turn, `REWRITE_STARTED` instead when
that turn concluded the story — keeping `state.py` itself a plain
(state, event) → state lookup, per its own "pure logic, no I/O" design.

**`REWRITING` deliberately has no transition for `SPEECH_START` or
`INTERRUPT`.** This is a real, intentional exception to an existing
invariant: `state.py`'s own comment currently says "an interrupt is legal
from every state." A `speech_start` or `interrupt` arriving while
`REWRITING` is dropped as a no-op and logged, the same pattern already
used for a duplicate `speech_start` while already `LISTENING`. That
comment needs updating so a future reader isn't confused about why this
one state is the exception — the whole point of `REWRITING` is that the
child talking again must not pre-empt it.

**`REWRITE_DONE` fires in a `finally`, unconditionally** — whether the
rewrite succeeded or produced `rewrite_status: "failed"`. A failed rewrite
still has to release the gate, or one bad Ollama response would
permanently brick the session (stuck in `REWRITING` until a server
restart).

**Reconnects need to resend current status.** If the phone briefly
disconnects and reconnects while still `REWRITING`, the reconnect handling
needs to re-push `rewriting_started` (or whatever the current state is) so
a reconnecting client doesn't assume it's free to start a story it
actually can't yet.

## Error handling

- A rewrite that fails to parse, or whose Ollama call fails outright, is
  logged and marked `rewrite_status: "failed"` — never raised into the
  live session, and never leaves `REWRITING` stuck (see `REWRITE_DONE`
  above). The raw transcript was already saved before the rewrite even
  started, so nothing is ever lost even in the failure case.
- The LLM-resource-contention risk that would otherwise exist between a
  live story's turns and a background rewrite is eliminated structurally
  by the `REWRITING` gate above, not mitigated by locking/scheduling
  inside the Ollama client.

## Testing

- `story_store.py`: round-trip tests (raw turns preserved verbatim, new
  fields default `null`, a patch-in-place update for the rewrite result,
  new `list_stories()`/`load_story()` reads).
- `storybook.py`: tests with a fake/injectable LLM engine (same pattern as
  `KyutaiStt`'s `recognizer_factory`) covering the JSON-parse success path
  and malformed output being handled, not raised.
- `animal_facts.py`: `AnimalFactTracker` retains real shared fact text,
  not just animal names.
- `state.py`: transition tests for `REWRITE_STARTED`/`REWRITE_DONE`,
  including asserting `SPEECH_START`/`INTERRUPT` are *not* legal from
  `REWRITING`.
- `session.py`: the conclude-action flow (cancels in-flight work, forces
  guidance, marks done unconditionally), and the full gate lifecycle —
  story ends → `REWRITING` entered → a `speech_start` during it is a
  no-op → `REWRITE_DONE` fires even on a simulated rewrite failure →
  `IDLE` → `speech_start` works again.
- `protocol.py`: encode/decode round-trip tests for every new message
  type (`ListStories`, `GetStory`, `SynthesizePage`, `ConcludeStory`,
  `story_list`, `story_detail`, `arc_stage`, `rewriting_started`,
  `rewriting_done`).

## Open questions / risks

- Client-side behavior (greying out "New story" affordances, the "Elsie
  is busy creating your storybook!" loading treatment, rendering pages,
  per-page 🔊 playback) is iOS work for a future sub-project — this spec
  is server-only. The wire messages above are designed to make that
  client work straightforward once it's picked up.
- No automatic retry for a failed rewrite in this pass — a `"failed"`
  story just stays failed, visibly, with its raw transcript intact. Worth
  revisiting if it proves to matter in practice.
- The rewrite prompt's actual wording (how strongly to push "storybook
  voice, not dialogue," how many pages to aim for) is implementation
  detail for the plan/implementation phase, not fixed here — expect some
  on-device iteration, the same way `_WEAVE_IN_TEMPLATE` and the stage
  guidance in `story_arc.py` were both tuned against real output before
  landing.
