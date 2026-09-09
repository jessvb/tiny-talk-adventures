# Parent-Adjustable Story Length Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a parent adjust turns-per-story (4–12) and pages-in-the-storybook (3–10) from the Settings screen, applying to the next story only.

**Architecture:** A new `update_settings` wire message (client → server, no response) carries both values. The server keeps them as per-session instance state on `SessionRunner` (defaulting to `config.py`'s existing constants, clamped to range on receipt), replacing the three call sites that currently read the config constants directly. The client persists both values in `UserDefaults` (matching `serverAddress`'s existing pattern) and re-sends them on every connect plus immediately on every change while connected.

**Tech Stack:** Python 3.12 (server, pytest), Swift 6 (iOS, XCTest via `swift test` for the `TinyTalkCore` SwiftPM package; SwiftUI for the app target).

**Spec:** `docs/superpowers/specs/2026-09-09-story-length-settings-design.md`

## Global Constraints

- Turn-count range: **4–12** (inclusive). Page-count range: **3–10** (inclusive). Values outside this range are clamped, never rejected with an error.
- Defaults (used until a client ever sends `update_settings`, and as `UserDefaults`' fresh-install default): **7 turns, 5 pages** — matching `config.STORY_TARGET_TURNS`/`config.STORYBOOK_PAGE_COUNT`'s own current defaults exactly.
- A changed setting applies to *the next* story only — never retroactively to one already in progress. This falls out of the architecture (see spec's "Architecture" section) and needs no special-casing in any task below.
- Settings UI must include a caption stating the "next story" behavior explicitly (parent-facing requirement, confirmed during brainstorming).

---

### Task 1: Server — `UpdateSettings` wire message

**Files:**
- Modify: `server/tinytalk/protocol.py`
- Test: `server/tests/test_protocol.py`

**Interfaces:**
- Consumes: nothing new (this task is self-contained within `protocol.py`).
- Produces: `UpdateSettings(target_turns: int, page_count: int)` dataclass, decodable via `decode_client_message()`. Task 2 consumes this type.

- [ ] **Step 1: Write the failing tests**

In `server/tests/test_protocol.py`, add `UpdateSettings` to the existing import block (alphabetical, matching the file's own ordering):

```python
from tinytalk.protocol import (
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
    UpdateSettings,
    decode_client_message,
    encode_arc_stage,
    encode_error,
    encode_page_audio_done,
    encode_response_text,
    encode_rewriting_done,
    encode_rewriting_started,
    encode_story_detail,
    encode_story_list,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)
```

Add one row to the existing `test_decodes_each_client_message_type` parametrize table (append after the `conclude_story` row):

```python
        ('{"type": "conclude_story", "turn_id": 5}', ConcludeStory(turn_id=5)),
        ('{"type": "update_settings", "target_turns": 8, "page_count": 6}',
         UpdateSettings(target_turns=8, page_count=6)),
    ],
)
```

Add three new standalone tests, right after `test_decode_rejects_conclude_story_missing_turn_id`:

```python
def test_decode_rejects_update_settings_missing_target_turns():
    with pytest.raises(ProtocolError, match="target_turns"):
        decode_client_message('{"type": "update_settings", "page_count": 5}')


def test_decode_rejects_update_settings_missing_page_count():
    with pytest.raises(ProtocolError, match="page_count"):
        decode_client_message('{"type": "update_settings", "target_turns": 7}')


def test_decode_rejects_update_settings_non_integer_target_turns():
    with pytest.raises(ProtocolError, match="target_turns"):
        decode_client_message(
            '{"type": "update_settings", "target_turns": "seven", "page_count": 5}'
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_protocol.py -v`
Expected: FAIL — `ImportError: cannot import name 'UpdateSettings'` (the import at the top of the test file fails before any individual test can even run).

- [ ] **Step 3: Write minimal implementation**

In `server/tinytalk/protocol.py`, add the dataclass right after `ConcludeStory`'s definition (before the `ClientMessage = (...)` union):

```python
@dataclass(frozen=True)
class UpdateSettings:
    """Parent-adjustable story-length settings from the Settings screen --
    persisted client-side, sent once after connecting and again whenever
    changed while connected. Applied to the next story construction, not
    retroactively to one already in progress -- see SessionRunner's
    handle_update_settings()."""

    target_turns: int
    page_count: int
```

Update the `ClientMessage` union to include it:

```python
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
    | UpdateSettings
)
```

Add the type-string mapping:

```python
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
    "update_settings": UpdateSettings,
}
```

(`_TYPES_REQUIRING_TURN_ID` stays unchanged — `UpdateSettings` carries no `turn_id`.)

Add a new branch in `decode_client_message`, right after the existing `if message_type is SynthesizePage:` block and before `return message_type()`:

```python
    if message_type is UpdateSettings:
        target_turns = payload.get("target_turns")
        page_count = payload.get("page_count")
        if not isinstance(target_turns, int):
            raise ProtocolError(
                f"update_settings requires an integer target_turns: {raw!r}"
            )
        if not isinstance(page_count, int):
            raise ProtocolError(
                f"update_settings requires an integer page_count: {raw!r}"
            )
        return UpdateSettings(target_turns=target_turns, page_count=page_count)
    return message_type()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_protocol.py -v`
Expected: PASS (all tests in the file, including the new ones).

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/protocol.py server/tests/test_protocol.py
git commit -m "feat(server): add update_settings wire message"
```

---

### Task 2: Server — per-session settings state in `SessionRunner`

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `UpdateSettings` from Task 1 (`from .protocol import UpdateSettings` — already imported as part of the existing `from .protocol import (...)` block; add it there).
- Produces: `SessionRunner._target_turns: int`, `SessionRunner._page_count: int` (instance state), `SessionRunner.handle_update_settings(target_turns: int, page_count: int) -> None`. Nothing outside this file consumes these directly — the iOS-side tasks are wire-compatible via Task 1's message shape, not a shared type.

- [ ] **Step 1: Write the failing tests**

In `server/tests/test_session.py`, add tests after `test_new_story_says_so_in_the_log` (or any convenient point after `make_session` is defined — exact position doesn't matter, this project's test files aren't ordered strictly by call site):

```python
async def test_new_session_defaults_to_config_target_turns_and_page_count(transport):
    from tinytalk import config

    session = make_session(transport)
    assert session._target_turns == config.STORY_TARGET_TURNS
    assert session._page_count == config.STORYBOOK_PAGE_COUNT


async def test_handle_update_settings_changes_the_next_storys_target_turns(transport):
    session = make_session(transport)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 4, "page_count": 3}'
    )
    await session.handle_new_story()
    assert session._story_arc._target_turns == 4
    assert session._page_count == 3


async def test_handle_update_settings_clamps_values_above_the_range(transport):
    session = make_session(transport)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 999, "page_count": 999}'
    )
    assert session._target_turns == 12
    assert session._page_count == 10


async def test_handle_update_settings_clamps_values_below_the_range(transport):
    session = make_session(transport)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 0, "page_count": 1}'
    )
    assert session._target_turns == 4
    assert session._page_count == 3


async def test_update_settings_does_not_change_the_currently_in_progress_story(transport):
    """Confirms the spec's "applies to the next story, never retroactively"
    requirement: an already-constructed StoryArc keeps its original
    target_turns even after update_settings arrives mid-story."""
    session = make_session(transport)
    original_target = session._story_arc._target_turns
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 4, "page_count": 3}'
    )
    assert session._story_arc._target_turns == original_target
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_session.py -k "target_turns or update_settings or page_count" -v`
Expected: FAIL — `AttributeError: 'SessionRunner' object has no attribute '_target_turns'` (or `no case for message` from the `match` statement not yet handling `UpdateSettings`).

- [ ] **Step 3: Write minimal implementation**

In `server/tinytalk/session.py`, the top-of-file import block (lines 29–52) reads:

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
    ...
)
```

Add `UpdateSettings` alphabetically among the message-type names, right after `SynthesizePage`:

```python
    SpeechStart,
    SynthesizePage,
    UpdateSettings,
    decode_client_message,
```

In `__init__` (around line 110), replace the existing `self._story_arc = StoryArc()` line with these three lines — the new instance attributes defined first, so `StoryArc(...)` can reference `self._target_turns` instead of relying on its own default parameter:

```python
        self._target_turns = config.STORY_TARGET_TURNS
        self._page_count = config.STORYBOOK_PAGE_COUNT
        self._story_arc = StoryArc(target_turns=self._target_turns)
```

In `handle_new_story` (around line 231), change:

```python
        self._story_arc = StoryArc()
```

to:

```python
        self._story_arc = StoryArc(target_turns=self._target_turns)
```

In `_run_turn`'s post-conclusion reset (around line 718), change:

```python
                self._story_arc = StoryArc()
```

to:

```python
                self._story_arc = StoryArc(target_turns=self._target_turns)
```

In `_run_rewrite` (around line 748), change:

```python
                page_count=config.STORYBOOK_PAGE_COUNT,
```

to:

```python
                page_count=self._page_count,
```

Add the new handler, right after `handle_list_stories` (around line 249):

```python
    async def handle_update_settings(self, target_turns: int, page_count: int) -> None:
        """Parent-adjustable story-length settings from the Settings
        screen -- see protocol.py's UpdateSettings and this project's
        story-length-settings design spec. Clamped here (not at decode
        time in protocol.py) since this is a semantic/business-rule
        bound, not a protocol-validity concern -- an out-of-range value
        is well-formed, just outside what this app supports. Takes
        effect for the next story only: StoryArc()/_page_count are only
        ever read at the start of a story (see __init__, handle_new_story,
        and _run_turn's post-conclusion reset), so there is nothing
        in-flight to migrate."""
        self._target_turns = max(4, min(12, target_turns))
        self._page_count = max(3, min(10, page_count))
        logger.info(
            "update_settings: target_turns=%d, page_count=%d (will apply to the next story)",
            self._target_turns,
            self._page_count,
        )
```

Add the dispatch case in `handle_text`'s `match message:` block, right after the existing `case SynthesizePage(story_id=story_id, page_index=page_index):` case (which reads `await self.handle_synthesize_page(story_id, page_index)`):

```python
            case SynthesizePage(story_id=story_id, page_index=page_index):
                await self.handle_synthesize_page(story_id, page_index)
            case UpdateSettings(target_turns=target_turns, page_count=page_count):
                await self.handle_update_settings(target_turns, page_count)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_session.py -v`
Expected: PASS (full file — confirms this didn't break any existing session test).

Then run the full server suite to confirm no regressions anywhere:

Run: `cd server && .venv/bin/pytest -q`
Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
git commit -m "feat(server): apply update_settings to the next story's turn/page count"
```

---

### Task 3: iOS — encode `update_settings` in `TinyTalkCore`

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ClientMessage.updateSettings(targetTurns: Int, pageCount: Int)`, with `.encode()` producing `{"type":"update_settings","target_turns":N,"page_count":M}`. Task 4 consumes this case.

- [ ] **Step 1: Write the failing test**

In `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`, add after `testConcludeStoryEncodesTheTurnId`:

```swift
    func testUpdateSettingsEncodesBothValues() {
        XCTAssertEqual(
            ClientMessage.updateSettings(targetTurns: 8, pageCount: 6).encode(),
            #"{"type":"update_settings","target_turns":8,"page_count":6}"#
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter testUpdateSettingsEncodesBothValues`
Expected: FAIL — compile error, `type 'ClientMessage' has no member 'updateSettings'`.

- [ ] **Step 3: Write minimal implementation**

In `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`, add the new case to `ClientMessage` (right after `case newStory`, which reads `case newStory` with a doc comment above it — this is currently the last case in the enum):

```swift
    case newStory
    /// Parent-adjustable story-length settings from the Settings screen --
    /// see protocol.py's UpdateSettings. Sent once after connecting and
    /// again whenever changed while connected.
    case updateSettings(targetTurns: Int, pageCount: Int)
```

Add the matching encode case (in `encode()`'s `switch self`, right after `case .newStory:`, which currently reads `return #"{"type":"new_story"}"#` and is the switch's last case):

```swift
        case .newStory:
            return #"{"type":"new_story"}"#
        case .updateSettings(let targetTurns, let pageCount):
            return #"{"type":"update_settings","target_turns":\#(targetTurns),"page_count":\#(pageCount)}"#
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter testUpdateSettingsEncodesBothValues`
Expected: PASS.

Then run the full package suite:

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, all tests (confirms the new `ClientMessage` case didn't break any exhaustive switch elsewhere in this package).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift
git commit -m "feat(ios): encode update_settings client message"
```

---

### Task 4: iOS — `SessionCoordinator.updateSettings(targetTurns:pageCount:)`

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ClientMessage.updateSettings` from Task 3.
- Produces: `SessionCoordinator.updateSettings(targetTurns: Int, pageCount: Int) async -> Void`. Task 5 (`AppModel`) consumes this.

- [ ] **Step 1: Write the failing test**

In `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`, add after `testListStoriesAndGetStoryUpdatePolledState`:

```swift
    func testUpdateSettingsSendsTheControlFrame() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.updateSettings(targetTurns: 9, pageCount: 4)
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(connection.sentMessages, [.updateSettings(targetTurns: 9, pageCount: 4)])

        runLoop.cancel()
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter testUpdateSettingsSendsTheControlFrame`
Expected: FAIL — compile error, `value of type 'SessionCoordinator' has no member 'updateSettings'`.

- [ ] **Step 3: Write minimal implementation**

In `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`, add a new public method right after `sendObjectSeen(label:)` (which ends with `try? await connection.send(.objectSeen(label: label))` and a closing brace):

```swift
    /// Sends the parent's current story-length preference to the server --
    /// see protocol.py's UpdateSettings and this project's
    /// story-length-settings design spec. Fire-and-forget, same pattern
    /// as listStories()/getStory(storyId:): applies to the next story
    /// only, no response expected, no local state to update here (the
    /// values themselves live in AppModel/UserDefaults, not this actor).
    public func updateSettings(targetTurns: Int, pageCount: Int) async {
        try? await connection.send(.updateSettings(targetTurns: targetTurns, pageCount: pageCount))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter testUpdateSettingsSendsTheControlFrame`
Expected: PASS.

Then run the full package suite:

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift
git commit -m "feat(ios): SessionCoordinator.updateSettings sends the control frame"
```

---

### Task 5: iOS — `AppModel` persistence and connect-time sync

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`

**Interfaces:**
- Consumes: `SessionCoordinator.updateSettings(targetTurns:pageCount:)` from Task 4.
- Produces: `AppModel.storyTurnCount: Int` (`@Published`), `AppModel.storybookPageCount: Int` (`@Published`), `AppModel.updateStorySettings(turnCount: Int, pageCount: Int)`. Task 6 (`SettingsView`) consumes both properties and the method.

This task has no dedicated automated test — per the design spec's "Testing approach," `UserDefaults` persistence and connect-time wiring are simple enough to verify with the on-device pass covering Task 6 below, consistent with how this app's other `AppModel`-only changes (e.g. `serverAddress`) have been tested. Verify by building the full app target after this task (Step 3 below) rather than skipping straight to Task 6.

- [ ] **Step 1: Add the persisted properties**

In `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`, add two new `@Published` properties right after `serverAddress` (near the top of the `@Published` block):

```swift
    @Published var serverAddress: String
    /// Parent-adjustable story length -- see docs/superpowers/specs/
    /// 2026-09-09-story-length-settings-design.md. Persisted the same
    /// way serverAddress is; sent to the server on every connect() and
    /// immediately on every change while connected (updateStorySettings()
    /// below). Applies to the NEXT story only -- never retroactively.
    @Published var storyTurnCount: Int
    @Published var storybookPageCount: Int
```

In `init()`, initialize both from `UserDefaults` right after `serverAddress`'s own initialization, defaulting to 7/5 (matching `config.py`'s own defaults):

```swift
    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
        let storedTurnCount = UserDefaults.standard.integer(forKey: "storyTurnCount")
        storyTurnCount = storedTurnCount == 0 ? 7 : storedTurnCount
        let storedPageCount = UserDefaults.standard.integer(forKey: "storybookPageCount")
        storybookPageCount = storedPageCount == 0 ? 5 : storedPageCount
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        screen = hasOnboarded ? .landing : .onboarding
    }
```

(`UserDefaults.integer(forKey:)` returns `0` when the key has never been set — same reason this can't just be `?? 7` the way the `String` case above uses `??`: `Int` isn't optional-returning from that accessor. The `== 0 ? default : stored` check is the standard `UserDefaults` idiom for an integer with a non-zero default.)

- [ ] **Step 2: Add `updateStorySettings()` and send on connect**

Add a new method, right after `toggleMute()`:

```swift
    /// What Settings' story-length steppers call on every change -- see
    /// storyTurnCount's doc comment. Persists immediately regardless of
    /// connection state; sends to the server immediately only if already
    /// connected (otherwise the persisted values go out via connect()'s
    /// own send below, on the next connection).
    func updateStorySettings(turnCount: Int, pageCount: Int) {
        storyTurnCount = turnCount
        storybookPageCount = pageCount
        UserDefaults.standard.set(turnCount, forKey: "storyTurnCount")
        UserDefaults.standard.set(pageCount, forKey: "storybookPageCount")
        guard isConnected, let coordinator else { return }
        Task { await coordinator.updateSettings(targetTurns: turnCount, pageCount: pageCount) }
    }
```

In `connect(resumingTurnId:)`, send the current persisted settings once the connection is established. Find the line `isConnected = true` near the end of that method (just before `startPollingState()`), and add the send immediately after it:

```swift
        isConnected = true
        // The server's per-session settings default to its own config
        // constants until told otherwise -- send the parent's current
        // preference now so even the very first story of this connection
        // uses it, not just the second one onward.
        Task { await coordinator.updateSettings(targetTurns: storyTurnCount, pageCount: storybookPageCount) }
        startPollingState()
```

- [ ] **Step 3: Verify the app target still builds**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -sdk iphonesimulator -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. (If `Local.xcconfig` doesn't exist yet in this worktree, `cp ios/TinyTalkApp/Local.xcconfig.example ios/TinyTalkApp/Local.xcconfig` first — see `CLAUDE.md`'s fresh-worktree gotcha.)

- [ ] **Step 4: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift
git commit -m "feat(ios): persist and sync story-length settings from AppModel"
```

---

### Task 6: iOS — `SettingsView` story-length steppers

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.storyTurnCount`, `AppModel.storybookPageCount`, `AppModel.updateStorySettings(turnCount:pageCount:)` from Task 5.
- Produces: nothing consumed by a later task — this is the final task in the plan.

No dedicated automated test for this task either, for the same reason as Task 5 — verify via the on-device test script at the end of this task.

- [ ] **Step 1: Add the new card**

In `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`, add `storyLengthCard` to the `VStack` in `body`, between `serverCard` and `underTheHoodCard`:

```swift
                    VStack(spacing: 18) {
                        serverCard
                        storyLengthCard
                        underTheHoodCard
                        storybookPreviewCard
                        replayButton
                    }
```

Add the new card as a computed property, right after `serverCard`'s closing brace:

```swift
    private var storyLengthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STORY LENGTH")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)

            storyLengthStepperRow(
                label: "Turns per story",
                value: model.storyTurnCount,
                range: 4...12
            ) { newValue in
                model.updateStorySettings(turnCount: newValue, pageCount: model.storybookPageCount)
            }

            storyLengthStepperRow(
                label: "Pages in the storybook",
                value: model.storybookPageCount,
                range: 3...10
            ) { newValue in
                model.updateStorySettings(turnCount: model.storyTurnCount, pageCount: newValue)
            }

            Text("Changes apply to your next story, not the one you're in now.")
                .font(TTA.Typography.body(12.5))
                .foregroundColor(TTA.Palette.inkSoft)
        }
        .padding(16)
        .background(TTA.Palette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A "− N +" row: two round tap-target buttons flanking the current
    /// value, matching this app's chunky, large-tap-target design
    /// language (see ChunkyButtonStyle/IconButtonStyle in DesignSystem.swift)
    /// rather than a bare SwiftUI Stepper's small default +/− controls.
    private func storyLengthStepperRow(
        label: String,
        value: Int,
        range: ClosedRange<Int>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .font(TTA.Typography.body(14, weight: .semibold))
                .foregroundColor(TTA.Palette.ink)

            Spacer()

            HStack(spacing: 14) {
                Button {
                    onChange(max(range.lowerBound, value - 1))
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.ttaIcon)
                .disabled(value <= range.lowerBound)

                Text("\(value)")
                    .font(TTA.Typography.display(17))
                    .foregroundColor(TTA.Palette.ink)
                    .frame(minWidth: 24)

                Button {
                    onChange(min(range.upperBound, value + 1))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.ttaIcon)
                .disabled(value >= range.upperBound)
            }
        }
    }
```

- [ ] **Step 2: Verify the app target still builds**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -sdk iphonesimulator -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
git commit -m "feat(ios): add story-length steppers to Settings"
```

- [ ] **Step 4: On-device verification (do this before considering the plan done)**

From this worktree's `server/` (restart if it was already running, to pick up Task 1/2's server changes) and a fresh Xcode Build & Run (this plan touches `ios/`, so a rebuild is required):

1. Open Settings — confirm a new "STORY LENGTH" card appears between the server address card and "Under the hood," showing "Turns per story: 7" and "Pages in the storybook: 5" (the defaults), with the "Changes apply to your next story..." caption visible.
2. Tap `+`/`−` on each — confirm the number updates immediately and stays within 4–12 / 3–10 (the button at each end should visibly disable at the boundary).
3. With the server running, connect and check the server's log output for a line like `update_settings: target_turns=N, page_count=M` — confirms the value actually reached the server, both on the initial connect and immediately after tapping a stepper while connected.
4. Set turns to 4 (the minimum) and start a story — confirm it wraps up noticeably sooner than the default 7-turn pacing.
5. Force-quit and relaunch the app — confirm Settings still shows your last-chosen values (persistence survived a fresh launch).
