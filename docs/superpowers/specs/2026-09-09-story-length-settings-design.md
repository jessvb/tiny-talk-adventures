# Parent-Adjustable Story Length — Design Notes

Status: Approved, not yet implemented (brainstormed 2026-09-09)

## Context

`config.py`'s `STORY_TARGET_TURNS` (default 7) and `STORYBOOK_PAGE_COUNT`
(default 5) are process-wide environment variables, read once at server
startup. There is no way for a parent to adjust either without editing the
server's launch environment and restarting it. `SettingsView.swift`'s own
doc comment already names this gap: the design mock's "Story length" row
was deliberately omitted because "none are backed by any
client-controllable setting today (those are server env vars, not
wire-protocol-exposed)," per this repo's "no fabricated toggles that don't
do anything" convention.

This spec closes that gap for exactly the two values a parent asked to
adjust: turns per story, and pages in the resulting storybook. It does not
touch the design mock's other omitted rows ("Elsie's voice speed," "Real
animal facts," "Camera inspiration") — those are unrelated, separate gaps.

## Goals

- A parent can adjust story length (turns) and storybook length (pages)
  from Settings, within a validated range.
- The setting persists across app launches (same device), the same way
  `serverAddress` already does.
- A changed setting applies to *the next* story — never retroactively to
  one already in progress — and the UI says so explicitly, so a parent
  doesn't wonder why a change didn't visibly do anything to the story
  currently running.

## Non-goals

- No per-story override (e.g. "just this once, make it longer") — one
  setting, changed in Settings, applies going forward.
- No server-side persistence of the setting across server restarts beyond
  what the client re-sends on reconnect — the client is the source of
  truth, matching `serverAddress`'s existing pattern. If a future
  multi-child household need arises, that's new scope, not this.
- No change to `story_arc.py`'s stage-boundary formulas themselves
  (`round(target/4)`, `round(target*2/3)`) — they already scale with
  `target_turns` as a parameter; this spec only makes that parameter
  configurable per-session instead of fixed at process startup.

## Architecture

A new wire message, `update_settings`, client → server, no response
expected. The server keeps the two values as per-session instance state
(defaulting to `config.py`'s existing constants until told otherwise) and
reads from that state everywhere it previously read the config constants
directly. Because `StoryArc()` is only ever constructed at the start of a
story (initial connection, "New Story," and the post-conclusion reset) and
`page_count` is only read once, when a concluding story's rewrite begins,
a changed setting takes effect at the next such point with no extra
bookkeeping — there is no in-flight story state to migrate or special-case.

```
Settings screen (parent adjusts a stepper)
        │
        ▼
AppModel.storyTurnCount / storybookPageCount   (@Published, UserDefaults-backed)
        │  sent immediately if connected, otherwise on the next connect()
        ▼
SessionCoordinator.updateSettings(targetTurns:pageCount:)
        │
        ▼  {"type": "update_settings", "target_turns": N, "page_count": M}
SessionRunner.handle_update_settings()   (clamps to [4,12] / [3,10])
        │
        ▼
self._target_turns / self._page_count   (replaces config.STORY_TARGET_TURNS /
                                           config.STORYBOOK_PAGE_COUNT at their
                                           three call sites in session.py)
```

## Components

### `server/tinytalk/protocol.py`

New client message:

```python
@dataclass(frozen=True)
class UpdateSettings:
    """Parent-adjustable story-length settings from the Settings screen --
    persisted client-side, sent once after connecting and again whenever
    changed while connected. Applied to the next story construction, not
    retroactively to one already in progress."""
    target_turns: int
    page_count: int
```

Decoded the same lenient way other numeric fields already are; values
outside `[4, 12]` / `[3, 10]` are clamped, not rejected — a stale or
malformed client value degrades gracefully instead of erroring the
session (matches this file's existing tolerant-decode style).

### `server/tinytalk/session.py`

- `SessionRunner.__init__` gains `self._target_turns = config.STORY_TARGET_TURNS`
  and `self._page_count = config.STORYBOOK_PAGE_COUNT`.
- New `handle_update_settings(target_turns, page_count)`, mirroring the
  existing `handle_new_story()`/`handle_list_stories()` handler style:
  clamps both values and assigns them.
- The three `StoryArc()` construction sites (`__init__`, `handle_new_story`,
  the post-conclusion reset in `_run_turn`) pass `target_turns=self._target_turns`
  instead of relying on `StoryArc`'s own default parameter.
- The rewrite call site (`_run_rewrite`) passes `page_count=self._page_count`
  instead of `config.STORYBOOK_PAGE_COUNT`.

### iOS: `TinyTalkCore/Protocol.swift` / `SessionCoordinator.swift`

- `ClientMessage.updateSettings(targetTurns: Int, pageCount: Int)`,
  encoding to the same JSON shape as the Python dataclass above.
- `SessionCoordinator.updateSettings(targetTurns:pageCount:)` — fire-and-
  forget, same pattern as `sendObjectSeen`/`listStories`.

### iOS: `AppModel.swift`

- `@Published var storyTurnCount: Int` / `@Published var storybookPageCount: Int`,
  initialized from `UserDefaults` (keys `"storyTurnCount"`/`"storybookPageCount"`,
  defaulting to 7/5 — matching `config.py`'s own defaults), persisted on
  every change — same pattern as `serverAddress`.
- A new method, `updateStorySettings()`, writes both to `UserDefaults` and,
  if `isConnected`, sends `coordinator.updateSettings(...)` immediately.
  If not connected, the values simply go out on the next `connect()` (a
  small addition to `connect()`'s existing setup sequence, sent once
  `isConnected` flips true).

### iOS: `SettingsView.swift`

A new card, "STORY LENGTH" (matching the existing all-caps section-header
style), between `serverCard` and `underTheHoodCard`:

- Two stepper rows, "Turns per story" (4–12) and "Pages in the storybook"
  (3–10), each a `− N +` control (`Stepper` with a visible current value,
  not a bare SwiftUI `Stepper`'s default `+`/`−` styling — matches this
  app's existing chunky, large-tap-target design language).
- A caption below both, in the same explanatory style as the server
  card's own ("Your Mac on the home WiFi..."): **"Changes apply to your
  next story, not the one you're in now."** This is the parent-facing
  requirement confirmed during brainstorming — the UI must say this
  explicitly, not leave it implicit.

## Data flow

1. App launches → `AppModel.init()` reads `storyTurnCount`/`storybookPageCount`
   from `UserDefaults` (defaulting to 7/5 on first launch).
2. `connect()` succeeds → client sends `update_settings` once, so the
   server's per-session state matches the client's persisted preference
   from the very first story of this connection, not just from the second
   one onward.
3. Parent adjusts a stepper in Settings (whether connected or not) →
   `UserDefaults` updated immediately; if connected, `update_settings`
   sent immediately too.
4. Next story starts (fresh connect, "New Story," or a natural/forced
   conclusion resetting for the next one) → server's already-current
   `self._target_turns`/`self._page_count` are used, no extra signaling
   needed.

## Error handling

- Out-of-range values (however they'd arise — a bug, a manually-edited
  `UserDefaults` plist) are clamped server-side to `[4, 12]`/`[3, 10]`,
  never rejected with an error frame — this is a low-stakes preference,
  not a safety-relevant input, so silent clamping (matching this file's
  existing lenient-decode convention elsewhere) is proportionate.
- No new error paths on the client: `updateSettings()` is fire-and-forget,
  same as `sendObjectSeen()`/`listStories()`.

## Testing approach

- Server: `test_protocol.py` gains encode/decode tests for
  `UpdateSettings` (including out-of-range clamping); `test_session.py`
  (or wherever `SessionRunner` is tested) gains a test confirming
  `handle_update_settings()` changes what the next `StoryArc()`/rewrite
  call actually uses.
- iOS: TDD as usual — `ProtocolTests.swift` for the new encode case,
  `SessionCoordinatorTests.swift` for `updateSettings()` sending the right
  frame. `AppModel`'s `UserDefaults` persistence and `SettingsView`'s
  stepper UI are simple enough to verify with a quick on-device pass
  rather than dedicated unit tests, consistent with how this app's other
  UI-only changes have been tested.

## Open questions / risks

None outstanding — this is a small, additive change with no untested
architecture (the update_settings message follows the exact shape of
every other control message in `protocol.py`, and the range [4,12]/[3,10]
was chosen conservatively around the empirically-tuned defaults).
