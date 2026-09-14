# Away-From-Home Demo Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the phone run a full, safety-filtered, multi-turn story conversation directly against Groq (LLM + Whisper STT) with on-device TTS, with no home Mac server reachable, gated behind a hidden parental toggle, syncing completed stories into the real library once back home.

**Architecture:** A new `DemoConnection` (iOS, `TinyTalkCore`) conforms to the existing `ServerConnecting` protocol, so `SessionCoordinator`'s entire turn-state machine, VAD wiring, barge-in, and debug log are reused unmodified — only the "brain" behind it changes. Four server-side subsystems (`safety.py`, `story_arc.py`, `object_recognition.py`, `animal_facts.py`) get ported to Swift, deterministic logic first, then network clients (Groq chat, Groq Whisper, on-device TTS, API Ninjas), then the orchestrator. A small server-side addition (`SyncDemoStories`) lets the phone hand completed stories to the existing, unmodified storybook rewrite pipeline once reconnected.

**Tech Stack:** Swift 6 (TinyTalkCore/TinyTalkPlatform SwiftPM targets, XCTest), Python 3.12 (pytest), Groq's OpenAI-compatible chat completions + Whisper transcription REST APIs, API Ninjas' Animals REST API, `AVSpeechSynthesizer`/`AVAudioConverter` (AVFoundation), iOS Keychain (Security framework).

**Spec:** `docs/superpowers/specs/2026-09-09-away-from-home-demo-mode-design.md` — read both; this plan argues from that spec but does not restate its rationale.

## Global Constraints

- No paid cloud API anywhere in this feature. Groq's TTS (Orpheus/PlayAI) is explicitly rejected — see spec's Non-goals.
- Groq API key and API Ninjas (animal facts) key are stored in iOS Keychain, never `UserDefaults` or plaintext.
- The away-from-home toggle in `SettingsView.swift` is reachable only via the same hidden long-press gesture that already reveals "UNDER THE HOOD" — no new discovery surface.
- Every ported Swift module (`Safety`, `StoryArc`, `ObjectTracker`, `AnimalFactTracker`) must produce the same decisions as its Python counterpart for the same input — verified by mirroring the existing Python test cases, not just "looks equivalent."
- No change to the real (LAN) server/client path's behavior. The one server-side addition (`SyncDemoStories`) is strictly additive to `protocol.py`/`session.py`/`story_store.py`.
- Animal-facts lookups are optional at runtime (no key → silent no-op), exactly matching `config.ANIMAL_FACTS_API_KEY`'s existing behavior server-side. Only the Groq key is required to enable the toggle.
- Known, disclosed simplification (not a bug to fix in this plan): unlike the real server, `DemoConnection` has no persistent session that survives the app being backgrounded mid-turn — a reply in flight when the app backgrounds is lost, not resumed. Flagged in Task 16.

---

## Task 1: Server — accept synced demo stories and feed them into the existing rewrite pipeline

**Files:**
- Modify: `server/tinytalk/protocol.py`
- Modify: `server/tinytalk/story_store.py`
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_protocol.py`
- Test: `server/tests/test_story_store.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Produces: `protocol.SyncDemoStories(stories: tuple[dict, ...])` (added to the `ClientMessage` union), `story_store.save_synced_story(payload: dict, *, stories_dir: Path = STORIES_DIR) -> Path | None`, `SessionRunner.handle_sync_demo_stories(stories: tuple[dict, ...]) -> None` (async).
- Consumes: existing `SessionRunner._run_rewrite(story_id: str, turns: list[Turn], shared_facts: list[tuple[str, str]]) -> None` (unmodified), `conversation.Turn`, `story_store.story_id_from_path`.

No structured acknowledgment is sent back to the phone — this mirrors the existing `object_seen` handling's "best effort, log server-side on failure" style, and avoids adding a new `ServerEvent` case to the shared iOS/server wire vocabulary for something Task-14/15's fire-and-forget send doesn't need.

- [ ] **Step 1: Write the failing protocol tests**

```python
# server/tests/test_protocol.py -- add near the other decode_client_message tests
def test_decode_sync_demo_stories():
    raw = json.dumps({
        "type": "sync_demo_stories",
        "stories": [
            {"id": "abc12345", "created_at": "2026-09-09T12:00:00+00:00", "turns": [], "shared_facts": []},
        ],
    })
    message = decode_client_message(raw)
    assert message == SyncDemoStories(
        stories=({"id": "abc12345", "created_at": "2026-09-09T12:00:00+00:00", "turns": [], "shared_facts": []},)
    )


def test_decode_sync_demo_stories_rejects_non_list_stories():
    raw = json.dumps({"type": "sync_demo_stories", "stories": "not-a-list"})
    with pytest.raises(ProtocolError):
        decode_client_message(raw)


def test_decode_sync_demo_stories_rejects_non_dict_entries():
    raw = json.dumps({"type": "sync_demo_stories", "stories": ["not-a-dict"]})
    with pytest.raises(ProtocolError):
        decode_client_message(raw)
```

Add the needed imports at the top of the test file if not already present: `import pytest` and `from tinytalk.protocol import SyncDemoStories, ProtocolError, decode_client_message`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_protocol.py -k sync_demo_stories -v`
Expected: FAIL with `ImportError` / `NameError: name 'SyncDemoStories' is not defined`.

- [ ] **Step 3: Add `SyncDemoStories` to `protocol.py`**

In `server/tinytalk/protocol.py`, add the dataclass near the other `ClientMessage` variants (after `ConcludeStory`):

```python
@dataclass(frozen=True)
class SyncDemoStories:
    """The phone hands over stories completed away from home (see
    docs/superpowers/specs/2026-09-09-away-from-home-demo-mode-design.md)
    once it reconnects to the home server. No turn_id -- this isn't part
    of live turn-taking, same reasoning as ListStories/GetStory."""

    stories: tuple[dict, ...]
```

Add it to the `ClientMessage` union:

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
    | SyncDemoStories
)
```

Add it to `_CLIENT_MESSAGE_TYPES`:

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
    "sync_demo_stories": SyncDemoStories,
}
```

Add its decode branch in `decode_client_message`, alongside the `GetStory`/`SynthesizePage` branches:

```python
    if message_type is SyncDemoStories:
        stories = payload.get("stories")
        if not isinstance(stories, list) or not all(isinstance(s, dict) for s in stories):
            raise ProtocolError(f"sync_demo_stories requires a list of story objects: {raw!r}")
        return SyncDemoStories(stories=tuple(stories))
```

- [ ] **Step 4: Run the protocol tests again to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_protocol.py -v`
Expected: PASS (all tests, including the pre-existing ones — nothing else in this file should have changed behavior).

- [ ] **Step 5: Write the failing story_store test**

```python
# server/tests/test_story_store.py -- add near the other save_* tests
from tinytalk.story_store import save_synced_story


def test_save_synced_story_writes_the_payload_as_pending(tmp_path):
    payload = {
        "id": "deadbeef",
        "created_at": "2026-09-09T12:00:00+00:00",
        "turns": [{"speaker": "child", "text": "hi", "interrupted": False}],
    }

    path = save_synced_story(payload, stories_dir=tmp_path)

    assert path is not None
    stored = json.loads(path.read_text())
    assert stored["id"] == "deadbeef"
    assert stored["created_at"] == "2026-09-09T12:00:00+00:00"
    assert stored["turns"] == payload["turns"]
    assert stored["title"] is None
    assert stored["pages"] is None
    assert stored["epilogue"] is None
    assert stored["rewrite_status"] == "pending"


def test_save_synced_story_rejects_missing_id_or_created_at(tmp_path):
    assert save_synced_story({"turns": []}, stories_dir=tmp_path) is None
    assert save_synced_story({"id": "x"}, stories_dir=tmp_path) is None


def test_save_synced_story_round_trips_with_story_id_from_path(tmp_path):
    payload = {"id": "cafef00d", "created_at": "2026-09-09T12:00:00+00:00", "turns": []}
    path = save_synced_story(payload, stories_dir=tmp_path)
    assert story_id_from_path(path) == "cafef00d"
```

- [ ] **Step 6: Run the story_store tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_story_store.py -k synced -v`
Expected: FAIL with `ImportError`.

- [ ] **Step 7: Add `save_synced_story` to `story_store.py`**

```python
def save_synced_story(payload: dict, *, stories_dir: Path = STORIES_DIR) -> Path | None:
    """Persists a story JSON payload the phone completed away from home
    (see SessionRunner.handle_sync_demo_stories) -- the phone already
    computed id/created_at/turns in the same shape save_story() writes,
    so this just persists it as-is. rewrite_status is forced to
    "pending" regardless of what the phone sent, so a synced story goes
    through the exact same rewrite pipeline a live one does."""
    story_id = payload.get("id")
    created_at = payload.get("created_at")
    if not isinstance(story_id, str) or not story_id or not isinstance(created_at, str) or not created_at:
        logger.error("refusing to sync a story with missing id/created_at: %r", payload)
        return None
    safe_timestamp = "".join(ch for ch in created_at if ch.isalnum())
    filename = f"{safe_timestamp}-{story_id}.json"
    stored = {
        "id": story_id,
        "created_at": created_at,
        "turns": payload.get("turns", []),
        "title": None,
        "pages": None,
        "epilogue": None,
        "rewrite_status": "pending",
    }
    try:
        stories_dir.mkdir(parents=True, exist_ok=True)
        path = stories_dir / filename
        path.write_text(json.dumps(stored, indent=2))
        return path
    except OSError as exc:
        logger.error("failed to save synced story %s: %s", story_id, exc)
        return None
```

- [ ] **Step 8: Run the story_store tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_story_store.py -v`
Expected: PASS (all tests).

- [ ] **Step 9: Write the failing session test**

Add near the other `SessionRunner` action-handler tests in `server/tests/test_session.py`, using the file's existing `make_session`/`FakeTransport` fixtures and the `_fake_build_and_attach`/`monkeypatch` pattern already used for rewrite-related tests above in that file:

```python
def test_handle_sync_demo_stories_saves_and_schedules_rewrite(tmp_path, monkeypatch):
    from tinytalk import story_store

    monkeypatch.setattr(
        story_store, "save_synced_story", lambda payload, **kw: tmp_path / f"20260909T120000-{payload['id']}.json"
    )
    # save_synced_story is monkeypatched to return a path without writing a
    # real file, matching this file's existing _fake_save_story pattern --
    # story_id_from_path only needs the path's name, not real content.
    (tmp_path).mkdir(exist_ok=True)

    build_calls = []

    async def fake_build_and_attach(story_id, turns, shared_facts, **kwargs):
        build_calls.append((story_id, turns, shared_facts))

    monkeypatch.setattr("tinytalk.session.storybook.build_and_attach", fake_build_and_attach)

    transport = FakeTransport()
    session = make_session(transport)

    stories = (
        {
            "id": "abc12345",
            "created_at": "2026-09-09T12:00:00+00:00",
            "turns": [
                {"speaker": "child", "text": "tell me about a fox", "interrupted": False},
                {"speaker": "agent", "text": "Once there was a fox.", "interrupted": False},
            ],
            "shared_facts": [["fox", "foxes are clever"]],
        },
    )
    await session.handle_text(json.dumps({"type": "sync_demo_stories", "stories": list(stories)}))
    await asyncio.sleep(0.01)  # let the fire-and-forget rewrite task run

    assert len(build_calls) == 1
    story_id, turns, shared_facts = build_calls[0]
    assert story_id == "abc12345"
    assert turns[0].speaker == "child"
    assert turns[0].text == "tell me about a fox"
    assert shared_facts == [("fox", "foxes are clever")]


def test_handle_sync_demo_stories_skips_a_story_that_fails_to_save(monkeypatch):
    from tinytalk import story_store

    monkeypatch.setattr(story_store, "save_synced_story", lambda payload, **kw: None)
    build_calls = []

    async def fake_build_and_attach(*args, **kwargs):
        build_calls.append(args)

    monkeypatch.setattr("tinytalk.session.storybook.build_and_attach", fake_build_and_attach)

    transport = FakeTransport()
    session = make_session(transport)
    await session.handle_text(json.dumps({
        "type": "sync_demo_stories",
        "stories": [{"id": "x", "created_at": "2026-09-09T12:00:00+00:00", "turns": []}],
    }))
    await asyncio.sleep(0.01)

    assert build_calls == []
```

- [ ] **Step 10: Run the session tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_session.py -k sync_demo_stories -v`
Expected: FAIL with `AttributeError: 'SessionRunner' object has no attribute 'handle_sync_demo_stories'` (or the `case SyncDemoStories` not matching, since `handle_text`'s `match` falls through silently today).

- [ ] **Step 11: Add `handle_sync_demo_stories` to `session.py`**

Add `SyncDemoStories` to the `protocol` import block at the top of `server/tinytalk/session.py`, and add `Turn` to the existing `from .conversation import Conversation` line (making it `from .conversation import Conversation, Turn`).

Add a case to `handle_text`'s `match` statement, after the `ConcludeStory` case:

```python
            case SyncDemoStories(stories=stories):
                await self.handle_sync_demo_stories(stories)
```

Add the handler method, placed near `handle_list_stories`/`handle_get_story`:

```python
    async def handle_sync_demo_stories(self, stories: tuple[dict, ...]) -> None:
        """Persists each story the phone completed away from home, then
        kicks off the same background rewrite pipeline a live story
        triggers -- see story_store.save_synced_story() and
        _run_rewrite(). Runs independent of self._machine's state
        (unlike the live-turn actions above): a synced batch has no
        relationship to whatever live story is or isn't in flight."""
        for payload in stories:
            saved_path = story_store.save_synced_story(payload)
            if saved_path is None:
                continue
            story_id = story_store.story_id_from_path(saved_path)
            try:
                turns = [
                    Turn(
                        speaker=turn["speaker"],
                        text=turn["text"],
                        interrupted=turn.get("interrupted", False),
                    )
                    for turn in payload.get("turns", [])
                ]
            except (KeyError, TypeError) as exc:
                logger.error(
                    "skipping rewrite for synced story %s: malformed turns (%s)", story_id, exc
                )
                continue
            shared_facts = [
                (pair[0], pair[1])
                for pair in payload.get("shared_facts", [])
                if isinstance(pair, list) and len(pair) == 2
            ]
            asyncio.create_task(self._run_rewrite(story_id, turns, shared_facts))
```

- [ ] **Step 12: Run the session tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_session.py -v`
Expected: PASS (all tests, including every pre-existing one in this file).

- [ ] **Step 13: Run the full server test suite**

Run: `cd server && source .venv/bin/activate && pytest`
Expected: PASS, no regressions.

- [ ] **Step 14: Commit**

```bash
git add server/tinytalk/protocol.py server/tinytalk/story_store.py server/tinytalk/session.py server/tests/test_protocol.py server/tests/test_story_store.py server/tests/test_session.py
git commit -m "$(cat <<'EOF'
feat(server): accept synced away-from-home stories into the rewrite pipeline

Adds SyncDemoStories to the wire protocol and a handler that persists
each story (story_store.save_synced_story) and feeds it into the
existing, unmodified storybook rewrite pipeline -- no server-side
awareness of demo mode itself, just a new story source.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Swift port — `DemoConversation` (conversation.py)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoConversation.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConversationTests.swift`

**Interfaces:**
- Produces: `ConversationSpeaker` (enum: `.child`, `.agent`), `ConversationTurn` (struct: `speaker`, `text`, `interrupted`), `DemoConversation` (class: `addChild(_:)`, `addAgent(_:interrupted:)`, `fullHistory: [ConversationTurn]`, `toMessages(systemPrompt:) -> [[String: String]]`).
- Consumes: nothing new (Foundation only).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class DemoConversationTests: XCTestCase {
    func testEmptyTextIsNotAdded() {
        let conversation = DemoConversation()
        conversation.addChild("  ")
        conversation.addAgent("")
        XCTAssertTrue(conversation.fullHistory.isEmpty)
    }

    func testAddedTextIsTrimmed() {
        let conversation = DemoConversation()
        conversation.addChild("  hello  ")
        XCTAssertEqual(conversation.fullHistory.first?.text, "hello")
    }

    func testToMessagesIncludesSystemPromptFirst() {
        let conversation = DemoConversation()
        conversation.addChild("hi")
        let messages = conversation.toMessages(systemPrompt: "be kind")
        XCTAssertEqual(messages.first, ["role": "system", "content": "be kind"])
        XCTAssertEqual(messages[1], ["role": "user", "content": "hi"])
    }

    func testInterruptedAgentTurnGetsMarkerAppended() {
        let conversation = DemoConversation()
        conversation.addAgent("once upon a", interrupted: true)
        let messages = conversation.toMessages(systemPrompt: "x")
        XCTAssertEqual(messages[1]["content"], "once upon a \(DemoConversation.interruptedMarker)")
        XCTAssertEqual(messages[1]["role"], "assistant")
    }

    func testFullHistoryKeepsEverythingBeyondTheWindow() {
        let conversation = DemoConversation(maxTurns: 20)
        for i in 0..<15 {
            conversation.addChild("turn \(i)")
            conversation.addAgent("reply \(i)")
        }
        XCTAssertEqual(conversation.fullHistory.count, 30)
        XCTAssertEqual(conversation.fullHistory.first?.text, "turn 0")
    }

    func testToMessagesOnlyUsesTheRecentWindow() {
        let conversation = DemoConversation(maxTurns: 2)
        conversation.addChild("first")
        conversation.addAgent("first reply")
        conversation.addChild("second")
        let messages = conversation.toMessages(systemPrompt: "x")
        // system + 2 windowed turns, not 3
        XCTAssertEqual(messages.count, 3)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter DemoConversationTests`
Expected: FAIL — `DemoConversation` does not exist.

- [ ] **Step 3: Implement `DemoConversation.swift`**

```swift
import Foundation

public enum ConversationSpeaker: String, Sendable {
    case child
    case agent
}

public struct ConversationTurn: Sendable, Equatable {
    public let speaker: ConversationSpeaker
    public let text: String
    public let interrupted: Bool

    public init(speaker: ConversationSpeaker, text: String, interrupted: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.interrupted = interrupted
    }
}

/// Swift port of server/tinytalk/conversation.py's Conversation, for
/// DemoConnection's turn loop -- named DemoConversation (not
/// Conversation) to keep it unambiguous alongside AppModel's own
/// display-only StoryTurn.
public final class DemoConversation: @unchecked Sendable {
    public static let interruptedMarker = "[interrupted by the child]"
    private static let roles: [ConversationSpeaker: String] = [.child: "user", .agent: "assistant"]

    private let lock = NSLock()
    private let maxTurns: Int
    private var windowed: [ConversationTurn] = []
    private var _fullHistory: [ConversationTurn] = []

    public init(maxTurns: Int = 20) {
        self.maxTurns = maxTurns
    }

    public var fullHistory: [ConversationTurn] {
        lock.lock(); defer { lock.unlock() }
        return _fullHistory
    }

    public func addChild(_ text: String) {
        add(ConversationTurn(speaker: .child, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public func addAgent(_ text: String, interrupted: Bool = false) {
        add(ConversationTurn(
            speaker: .agent,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            interrupted: interrupted
        ))
    }

    private func add(_ turn: ConversationTurn) {
        guard !turn.text.isEmpty else { return }
        lock.lock()
        windowed.append(turn)
        if windowed.count > maxTurns {
            windowed.removeFirst(windowed.count - maxTurns)
        }
        _fullHistory.append(turn)
        lock.unlock()
    }

    public func toMessages(systemPrompt: String) -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for turn in windowed {
            var content = turn.text
            if turn.interrupted {
                content += " \(Self.interruptedMarker)"
            }
            messages.append(["role": Self.roles[turn.speaker]!, "content": content])
        }
        return messages
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter DemoConversationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/DemoConversation.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConversationTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add DemoConversation, a Swift port of conversation.py

First piece of the away-from-home demo-mode turn loop -- tracks
turn history in the exact shape the LLM/JSON-persistence expect,
independent of any server connection.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Swift port — `Safety` (safety.py)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/Safety.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SafetyTests.swift`

**Interfaces:**
- Produces: `Safety.isSafe(_ text: String) -> Bool`, `Safety.filterReply(_ text: String) -> String`, `Safety.safeFallback: String`.
- Consumes: nothing new.

This must make the same decisions as `server/tinytalk/safety.py` for the same input — the test cases below are a direct port of that file's own test cases (`server/tests/test_safety.py`), not a fresh design.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class SafetyTests: XCTestCase {
    func testPlainWholesomeTextIsSafe() {
        XCTAssertTrue(Safety.isSafe("The fox went for a walk in the sunny meadow."))
    }

    func testViolentWordIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("The knight had to kill the dragon."))
    }

    func testProfanityIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("What the hell is that."))
    }

    func testReproductionWordIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("The rabbits started breeding."))
    }

    func testFrighteningPhraseIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("It was pure evil."))
    }

    func testRealWorldDangerPhraseIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("The kids were playing with matches."))
    }

    func testWordBoundaryDoesNotFalsePositive() {
        // "begun" contains "gun" as a substring but must not match.
        XCTAssertTrue(Safety.isSafe("The adventure had begun."))
    }

    func testShootingStarIsSafeButShootingAloneIsNot() {
        XCTAssertTrue(Safety.isSafe("She wished on a shooting star."))
        XCTAssertFalse(Safety.isSafe("He kept shooting at the target."))
    }

    func testSafePhraseDoesNotMaskADangerousUseElsewhereInTheSameSentence() {
        XCTAssertFalse(Safety.isSafe("She wished on a shooting star while shooting arrows at the target."))
    }

    func testInnocentFairyTaleKissStaysSafe() {
        XCTAssertTrue(Safety.isSafe("The prince gave the princess a goodnight kiss."))
    }

    func testFilterReplyPassesThroughSafeText() {
        XCTAssertEqual(Safety.filterReply("A gentle story about a fox."), "A gentle story about a fox.")
    }

    func testFilterReplyReplacesUnsafeText() {
        XCTAssertEqual(Safety.filterReply("Someone got killed."), Safety.safeFallback)
    }

    func testFilterReplyReplacesEmptyText() {
        XCTAssertEqual(Safety.filterReply(""), Safety.safeFallback)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter SafetyTests`
Expected: FAIL — `Safety` does not exist.

- [ ] **Step 3: Implement `Safety.swift`**

Port every word list verbatim from `server/tinytalk/safety.py` (same words, same order, same six categories) — do not invent or drop any entry.

```swift
import Foundation

/// Swift port of server/tinytalk/safety.py. Deliberately NOT semantic
/// content understanding -- see that file's module docstring for the
/// full rationale (zero-latency denylist, not exhaustive moderation).
public enum Safety {
    public static let safeFallback = "Hmm, let's take the story somewhere else! What should happen next?"

    private static let violence = [
        "blood", "gun", "guns", "knife", "knives", "kill", "kills", "killed",
        "dead", "die", "dies", "died", "fight", "fights", "fighting",
        "hurt", "hurts", "hurting", "stab", "stabbed", "stabbing",
        "shoot", "shoots", "shooting",
    ]

    private static let frightening = [
        "monster attacking", "terrifying", "nightmare", "screamed in terror",
        "trapped forever", "pure evil", "demon", "demons",
    ]

    private static let adultThemes = ["drunk", "alcohol", "cigarette", "naked"]

    private static let realWorldDanger = [
        "play with matches", "playing with matches", "played with matches",
        "play with a lighter", "playing with a lighter", "played with a lighter",
        "poison", "drown", "drowned", "drowning", "jump off a cliff",
    ]

    private static let reproduction = [
        "mating", "breeding", "pregnant", "pregnancy", "reproduce", "reproduces",
        "reproducing", "reproduction", "sex", "sexual", "porn", "porno",
        "pornography", "pornographic", "nude", "nudity", "erotic",
        "masturbate", "masturbation", "orgasm",
    ]

    private static let profanity = [
        "damn", "hell", "shit", "fuck", "ass", "asshole", "bitch", "crap",
        "bastard", "piss", "dick", "whore", "slut",
    ]

    private static let allBlocked =
        violence + frightening + adultThemes + realWorldDanger + reproduction + profanity

    // Deliberately does NOT include "kiss" -- see safety.py's own comment.
    private static let safePhrases = ["shooting star", "shooting stars"]

    private static let blockedPattern: NSRegularExpression = {
        let escaped = allBlocked.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // swiftlint:disable:next force_try -- a fixed, compile-time-known pattern; a failure here is a bug in this file, not runtime input.
        return try! NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
    }()

    private static let safePattern: NSRegularExpression = {
        let escaped = safePhrases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
    }()

    public static func isSafe(_ text: String) -> Bool {
        let fullRange = NSRange(text.startIndex..., in: text)
        let masked = safePattern.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        let maskedRange = NSRange(masked.startIndex..., in: masked)
        return blockedPattern.firstMatch(in: masked, range: maskedRange) == nil
    }

    public static func filterReply(_ text: String) -> String {
        (!text.isEmpty && isSafe(text)) ? text : safeFallback
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter SafetyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/Safety.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/SafetyTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add Safety, a Swift port of safety.py

Same six-category denylist, same safe-phrase masking, same
word-boundary matching -- verified against the same cases
server/tests/test_safety.py already covers.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Swift port — `StoryArc` (story_arc.py)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/StoryArc.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/StoryArcTests.swift`

**Interfaces:**
- Produces: `StoryStage` (enum: `.intro`, `.setup`, `.risingAction`, `.climax`, `.resolution`, `.done`), `StoryArc` (class: `init(targetTurns:)`, `stage: StoryStage`, `isDone: Bool`, `recordTurn(childText:) -> String`, `recordReply(replyText:) -> Void`, `forceConcludeGuidance() -> String`, `markDone() -> Void`).
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class StoryArcTests: XCTestCase {
    func testFirstTurnIsIntro() {
        let arc = StoryArc(targetTurns: 7)
        XCTAssertEqual(arc.stage, .intro)
    }

    func testStageAdvancesWithTurnCount() {
        let arc = StoryArc(targetTurns: 7)
        // setupEnd = round(7/4) = 2, risingEnd = round(7*2/3) = 5
        _ = arc.recordTurn(childText: "turn 1") // -> INTRO's own guidance, turnCount now 1
        XCTAssertEqual(arc.stage, .intro) // stageForTurn(1) == intro
        _ = arc.recordTurn(childText: "turn 2") // turnCount 2 <= setupEnd(2) -> setup
        XCTAssertEqual(arc.stage, .setup)
        _ = arc.recordTurn(childText: "turn 3") // turnCount 3 > 2, <= risingEnd(5) -> risingAction
        XCTAssertEqual(arc.stage, .risingAction)
        _ = arc.recordTurn(childText: "t4")
        _ = arc.recordTurn(childText: "t5") // turnCount 5 <= risingEnd(5) -> still risingAction
        XCTAssertEqual(arc.stage, .risingAction)
        _ = arc.recordTurn(childText: "t6") // turnCount 6 <= targetTurns(7) -> climax
        XCTAssertEqual(arc.stage, .climax)
        _ = arc.recordTurn(childText: "t7") // turnCount 7 <= targetTurns(7) -> still climax
        XCTAssertEqual(arc.stage, .climax)
        _ = arc.recordTurn(childText: "t8") // turnCount 8 > targetTurns -> resolution
        XCTAssertEqual(arc.stage, .resolution)
    }

    func testChildStopPhraseForcesResolutionGuidance() {
        let arc = StoryArc(targetTurns: 7)
        let guidance = arc.recordTurn(childText: "I'm done, that's enough")
        XCTAssertTrue(guidance.contains("wrap up the story"))
    }

    func testGraceCeilingForcesConclusion() {
        let arc = StoryArc(targetTurns: 3) // graceCeiling = 6
        for i in 1...6 {
            _ = arc.recordTurn(childText: "turn \(i)")
        }
        let forced = arc.recordTurn(childText: "turn 7") // turnCount 7 > graceCeiling(6)
        XCTAssertTrue(forced.contains("This must be the last reply"))
        arc.recordReply(replyText: "anything at all")
        XCTAssertTrue(arc.isDone)
    }

    func testNaturalConclusionPhraseMarksDone() {
        let arc = StoryArc(targetTurns: 7)
        _ = arc.recordTurn(childText: "turn 1")
        arc.recordReply(replyText: "And they all lived happily ever after. The end.")
        XCTAssertTrue(arc.isDone)
        XCTAssertEqual(arc.stage, .done)
    }

    func testOrdinaryReplyDoesNotMarkDone() {
        let arc = StoryArc(targetTurns: 7)
        _ = arc.recordTurn(childText: "turn 1")
        arc.recordReply(replyText: "The fox kept walking through the meadow.")
        XCTAssertFalse(arc.isDone)
    }

    func testForceConcludeGuidanceDoesNotAdvanceTurnCount() {
        let arc = StoryArc(targetTurns: 7)
        _ = arc.recordTurn(childText: "turn 1")
        let stageBefore = arc.stage
        let guidance = arc.forceConcludeGuidance()
        XCTAssertTrue(guidance.contains("This must be the last reply"))
        XCTAssertEqual(arc.stage, stageBefore)
    }

    func testMarkDoneIsUnconditional() {
        let arc = StoryArc(targetTurns: 7)
        arc.markDone()
        XCTAssertTrue(arc.isDone)
        XCTAssertEqual(arc.stage, .done)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter StoryArcTests`
Expected: FAIL — `StoryArc` does not exist.

- [ ] **Step 3: Implement `StoryArc.swift`**

```swift
import Foundation

public enum StoryStage: Sendable, Equatable {
    case intro, setup, risingAction, climax, resolution, done
}

/// Swift port of server/tinytalk/story_arc.py. Deliberately
/// deterministic (regex + turn counting), same reasoning as that file's
/// module docstring.
public final class StoryArc: @unchecked Sendable {
    private static let forcedGuidance =
        "This must be the last reply. Resolve the problem from earlier in " +
        "the story and bring it to a warm, complete ending right now. Do not " +
        "ask what should happen next. The story is over. End your reply " +
        "with the words \"The end.\""

    private static let guidance: [StoryStage: String] = [
        .intro: "You're at the very start of the story. Introduce the setting and characters.",
        .setup: "You're at the start of the story. Continue introducing the setting " +
            "and characters, and introduce a problem, challenge, or conflict for " +
            "them to face. Every good story needs something for the " +
            "characters to overcome -- don't wait to introduce it.",
        .risingAction: "The story is building. Keep developing the problem or " +
            "challenge from the start of the story, raise the stakes a " +
            "little, and let the child's ideas shape what happens next.",
        .climax: "The story is nearing its big moment. Build toward an exciting " +
            "(but still gentle) turning point where the problem or challenge " +
            "comes to a head.",
        .resolution: "It's time to resolve the problem from earlier in the story and " +
            "wrap up the story warmly and happily in this reply or the next " +
            "one. If you conclude it now, do not ask what should happen " +
            "next. Instead, end your reply with the words \"The end.\"",
    ]

    private static let childStopPhrases = [
        "the end", "i'm done", "im done", "stop the story",
        "that's enough", "thats enough", "no more story", "i want to stop",
    ]

    private static let conclusionPhrases = [
        "the end", "happily ever after", "lived happily", "the story is over",
    ]

    private let lock = NSLock()
    private let targetTurns: Int
    private let graceCeiling: Int
    private var turnCount = 0
    private var _isDone = false

    public init(targetTurns: Int = 7) {
        self.targetTurns = targetTurns
        self.graceCeiling = targetTurns + 3
    }

    public var stage: StoryStage {
        lock.lock(); defer { lock.unlock() }
        return _isDone ? .done : stageForTurn(turnCount)
    }

    public var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isDone
    }

    private func stageForTurn(_ turn: Int) -> StoryStage {
        if turn <= 1 { return .intro }
        let setupEnd = Int((Double(targetTurns) / 4).rounded())
        let risingEnd = Int((Double(targetTurns) * 2 / 3).rounded())
        if turn <= setupEnd { return .setup }
        if turn <= risingEnd { return .risingAction }
        if turn <= targetTurns { return .climax }
        return .resolution
    }

    public func recordTurn(childText: String) -> String {
        lock.lock(); defer { lock.unlock() }
        turnCount += 1
        if turnCount > graceCeiling { return Self.forcedGuidance }
        if Self.matches(childText, any: Self.childStopPhrases) { return Self.guidance[.resolution]! }
        return Self.guidance[stageForTurn(turnCount)]!
    }

    public func recordReply(replyText: String) {
        lock.lock(); defer { lock.unlock() }
        if turnCount > graceCeiling { _isDone = true; return }
        if Self.matches(replyText, any: Self.conclusionPhrases) { _isDone = true }
    }

    /// Guidance for an explicitly-requested conclusion -- deliberately
    /// does NOT touch turnCount, same reasoning as story_arc.py's
    /// force_conclude_guidance().
    public func forceConcludeGuidance() -> String { Self.forcedGuidance }

    public func markDone() {
        lock.lock(); defer { lock.unlock() }
        _isDone = true
    }

    private static func matches(_ text: String, any phrases: [String]) -> Bool {
        let lower = text.lowercased()
        return phrases.contains { wordBoundaryContains(lower, phrase: $0) }
    }

    private static func wordBoundaryContains(_ text: String, phrase: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
        ) else { return text.contains(phrase) }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter StoryArcTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/StoryArc.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/StoryArcTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add StoryArc, a Swift port of story_arc.py

Same turn-budget staging, same child-stop/natural-conclusion
detection, same force-conclude/mark-done semantics as the server's
version -- verified against ported test cases from
server/tests/test_story_arc.py.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Swift port — `ObjectTracker` (object_recognition.py)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/ObjectTracking.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ObjectTrackingTests.swift`

**Interfaces:**
- Produces: `ObjectTracker` (class: `recordSeen(label:)`, `consumeGuidance() -> String`).
- Consumes: `Safety.isSafe(_:)` (Task 3).

This is the "cheap addition" identified during design: the camera → Vision classification pipeline (`VisionObjectRecognizer`, `AppModel.handlePhotoTaken`, `SessionCoordinator.sendObjectSeen`, `ClientMessage.objectSeen(label:)`) is already fully on-device and connection-agnostic — `DemoConnection` (Task 13) just needs somewhere to receive and weave in that label, exactly mirroring the real server's `ObjectTracker`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class ObjectTrackingTests: XCTestCase {
    func testNoPendingLabelReturnsEmptyGuidance() {
        let tracker = ObjectTracker()
        XCTAssertEqual(tracker.consumeGuidance(), "")
    }

    func testSafeLabelProducesWeaveInGuidance() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "teddy bear")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.contains("teddy bear"))
    }

    func testUnsafeLabelIsDiscarded() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a gun")
        XCTAssertEqual(tracker.consumeGuidance(), "")
    }

    func testConsumingClearsThePendingLabel() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a couch")
        _ = tracker.consumeGuidance()
        XCTAssertEqual(tracker.consumeGuidance(), "")
    }

    func testANewerLabelOverwritesAnOlderUnconsumedOne() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a couch")
        tracker.recordSeen(label: "a robot toy")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.contains("robot toy"))
        XCTAssertFalse(guidance.contains("a couch"))
    }

    func testAnUnsafeLabelDoesNotClearAnEarlierPendingSafeOne() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a couch")
        tracker.recordSeen(label: "a gun")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.contains("a couch"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter ObjectTrackingTests`
Expected: FAIL — `ObjectTracker` does not exist.

- [ ] **Step 3: Implement `ObjectTracking.swift`**

```swift
import Foundation

/// Swift port of server/tinytalk/object_recognition.py.
public final class ObjectTracker: @unchecked Sendable {
    private static let weaveInTemplate =
        "The child just showed you a photo of a %@. Let it inspire what " +
        "happens next -- it doesn't have to appear literally, but something " +
        "recognizable about it (its species, size, color, shape, or " +
        "personality) must carry through to whatever you introduce. A teddy " +
        "bear could become a real bear character, a couch could become a " +
        "mountain shaped like one, a computer could become a robot -- each " +
        "keeps a clear thread back to the original. If the child's own words " +
        "call for a new character, creature, or animal, make THIS the one " +
        "that shows up, rather than inventing an unrelated one."

    private let lock = NSLock()
    private var pendingLabel: String?

    public init() {}

    public func recordSeen(label: String) {
        guard Safety.isSafe(label) else { return }
        lock.lock(); defer { lock.unlock() }
        pendingLabel = label
    }

    public func consumeGuidance() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let label = pendingLabel else { return "" }
        pendingLabel = nil
        return String(format: Self.weaveInTemplate, label)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter ObjectTrackingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/ObjectTracking.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ObjectTrackingTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add ObjectTracker, a Swift port of object_recognition.py

The camera/Vision classification pipeline is already fully on-device
and connection-agnostic; this is the missing piece that lets
DemoConnection (later task) weave a recognized object into guidance
the same way the real server already does.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Swift port — `AnimalFacts` (animal_facts.py, detection + extraction only)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/AnimalFacts.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/AnimalFactsTests.swift`

**Interfaces:**
- Produces: `AnimalFacts.findNewAnimal(in:excluding:) -> String?`, `AnimalFacts.extractFacts(from:) -> [String]`, `AnimalRecordCharacteristics` (struct mirroring API Ninjas' `characteristics` object).
- Consumes: `Safety.isSafe(_:)` (Task 3).

This task covers only the **deterministic** parts of `animal_facts.py` (the alias dictionary, detection, and the field-extraction/safety-filtering logic) — the network call, on-disk cache, and per-story tracker (`AnimalFactTracker`, which needs both of those) are Task 11, once the network-client pattern established in Tasks 8-10 exists to build on.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class AnimalFactsTests: XCTestCase {
    func testDetectsAKnownAnimal() {
        XCTAssertEqual(AnimalFacts.findNewAnimal(in: "tell me about a fox", excluding: []), "fox")
    }

    func testDetectsAnAliasAndReturnsTheCanonicalName() {
        XCTAssertEqual(AnimalFacts.findNewAnimal(in: "look at the bunny", excluding: []), "rabbit")
    }

    func testAlreadyFactedAnimalsAreExcluded() {
        XCTAssertNil(AnimalFacts.findNewAnimal(in: "the fox again", excluding: ["fox"]))
    }

    func testNoKnownAnimalReturnsNil() {
        XCTAssertNil(AnimalFacts.findNewAnimal(in: "a beautiful castle", excluding: []))
    }

    func testWordBoundaryDoesNotFalsePositive() {
        // "foxglove" contains "fox" as a substring but must not match.
        XCTAssertNil(AnimalFacts.findNewAnimal(in: "a field of foxglove", excluding: []))
    }

    func testMultiWordAliasWinsOverAGenericSingleWordEntry() {
        XCTAssertEqual(AnimalFacts.findNewAnimal(in: "a sea turtle swam by", excluding: []), "sea turtle")
    }

    func testExtractFactsUsesOnlyTheAllowlistedFields() {
        let characteristics = AnimalRecordCharacteristics(
            mostDistinctiveFeature: "its bushy tail",
            topSpeed: "30 mph",
            diet: "small mammals",
            habitat: "forests",
            slogan: nil,
            color: "reddish orange",
            groupBehavior: nil,
            lifespan: "3 to 4 years"
        )
        let facts = AnimalFacts.extractFacts(from: characteristics)
        XCTAssertEqual(facts.count, 5)
        XCTAssertTrue(facts.contains("its most distinctive feature is its bushy tail"))
        XCTAssertTrue(facts.contains("it can move as fast as 30 mph"))
    }

    func testExtractFactsDropsAnUnsafeField() {
        let characteristics = AnimalRecordCharacteristics(
            mostDistinctiveFeature: nil, topSpeed: nil, diet: nil, habitat: nil,
            slogan: "known for a killing spree", color: nil, groupBehavior: nil, lifespan: nil
        )
        XCTAssertEqual(AnimalFacts.extractFacts(from: characteristics), [])
    }

    func testExtractFactsSkipsEmptyOrMissingFields() {
        let characteristics = AnimalRecordCharacteristics(
            mostDistinctiveFeature: "  ", topSpeed: nil, diet: nil, habitat: nil,
            slogan: nil, color: nil, groupBehavior: nil, lifespan: nil
        )
        XCTAssertEqual(AnimalFacts.extractFacts(from: characteristics), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter AnimalFactsTests`
Expected: FAIL — `AnimalFacts` does not exist.

- [ ] **Step 3: Implement `AnimalFacts.swift`**

The alias dictionary below (`_knownAnimals`) is a direct, complete transcription of `server/tinytalk/animal_facts.py`'s `_KNOWN_ANIMALS` dict (all ~190 entries) — copy every `"canonical": ("alias1", "alias2", ...)` line from that file, translating Python's `"canonical": (aliases...)` tuple syntax into Swift's `"canonical": [aliases...]` array syntax verbatim, same canonical names, same aliases, same entries, none added or dropped. Only the four entries below are reproduced here as a worked example of the exact translation to apply to the rest of that file's table:

```swift
import Foundation

public struct AnimalRecordCharacteristics: Sendable {
    public let mostDistinctiveFeature: String?
    public let topSpeed: String?
    public let diet: String?
    public let habitat: String?
    public let slogan: String?
    public let color: String?
    public let groupBehavior: String?
    public let lifespan: String?

    public init(
        mostDistinctiveFeature: String?, topSpeed: String?, diet: String?, habitat: String?,
        slogan: String?, color: String?, groupBehavior: String?, lifespan: String?
    ) {
        self.mostDistinctiveFeature = mostDistinctiveFeature
        self.topSpeed = topSpeed
        self.diet = diet
        self.habitat = habitat
        self.slogan = slogan
        self.color = color
        self.groupBehavior = groupBehavior
        self.lifespan = lifespan
    }
}

/// Swift port of server/tinytalk/animal_facts.py's detection and
/// extraction logic (the network call and cache are AnimalFactsAPIClient
/// and AnimalFactTracker, Task 11 -- this file has no I/O).
public enum AnimalFacts {
    // TRANSCRIBE THE FULL TABLE FROM animal_facts.py's _KNOWN_ANIMALS HERE
    // -- these four entries are a worked example of the exact translation,
    // not the complete set. Every canonical name in that file must appear
    // as a key here with the same aliases, translating Python's
    // "canonical": ("a", "b") into Swift's "canonical": ["a", "b"].
    static let knownAnimals: [String: [String]] = [
        "fox": ["fox", "foxes"],
        "rabbit": ["rabbit", "rabbits", "bunny", "bunnies"],
        "sea turtle": ["sea turtle", "sea turtles"],
        "turtle": ["turtle", "turtles"],
        // ... every remaining entry from _KNOWN_ANIMALS, verbatim ...
    ]

    private static let patterns: [String: NSRegularExpression] = {
        var result: [String: NSRegularExpression] = [:]
        for (canonical, aliases) in knownAnimals {
            let escaped = aliases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            result[canonical] = try? NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
        }
        return result
    }()

    /// Multi-word aliases must be checked before single-word ones (see
    /// animal_facts.py's _DETECTION_ORDER) -- "sea turtle" must not
    /// resolve to the generic "turtle" entry.
    private static let detectionOrder: [String] = knownAnimals.keys.sorted { lhs, rhs in
        let lhsSpecificity = knownAnimals[lhs]!.map { $0.split(separator: " ").count }.max() ?? 1
        let rhsSpecificity = knownAnimals[rhs]!.map { $0.split(separator: " ").count }.max() ?? 1
        if lhsSpecificity != rhsSpecificity { return lhsSpecificity > rhsSpecificity }
        return lhs < rhs // stable, deterministic tiebreaker (Python relies on dict definition order instead)
    }

    public static func findNewAnimal(in transcript: String, excluding alreadyFacted: Set<String>) -> String? {
        for canonical in detectionOrder {
            if alreadyFacted.contains(canonical) { continue }
            guard let pattern = patterns[canonical] else { continue }
            let range = NSRange(transcript.startIndex..., in: transcript)
            if pattern.firstMatch(in: transcript, range: range) != nil {
                return canonical
            }
        }
        return nil
    }

    public static func extractFacts(from characteristics: AnimalRecordCharacteristics) -> [String] {
        var facts: [String] = []
        func addFact(_ value: String?, _ template: (String) -> String) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            let fact = template(value)
            if Safety.isSafe(fact) { facts.append(fact) }
        }
        addFact(characteristics.mostDistinctiveFeature) { "its most distinctive feature is \($0)" }
        addFact(characteristics.topSpeed) { "it can move as fast as \($0)" }
        addFact(characteristics.diet) { "its diet is \($0)" }
        addFact(characteristics.habitat) { "it lives in \($0)" }
        addFact(characteristics.slogan) { $0 }
        addFact(characteristics.color) { "its coloring is \($0)" }
        addFact(characteristics.groupBehavior) { "its group behavior is \($0)" }
        addFact(characteristics.lifespan) { "its lifespan is \($0)" }
        return facts
    }
}
```

Note the one deliberate deviation from `_DETECTION_ORDER`'s exact tie-break: Python's stable sort falls back to `_KNOWN_ANIMALS`' dict definition order for equally-specific entries; a Swift `Dictionary` has no defined iteration order, so this uses alphabetical order as the tiebreaker instead. This only matters for the (rare, and today nonexistent per the source table) case of two equally-specific aliases both matching the same transcript — verify this hasn't silently changed any of the four-word/multi-word disambiguation cases transcribed above once the full table is in place.

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter AnimalFactsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/AnimalFacts.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/AnimalFactsTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add AnimalFacts, a Swift port of animal_facts.py's detection/extraction

Full alias table transcribed from _KNOWN_ANIMALS, same word-boundary
detection with multi-word-alias precedence, same curated
characteristics-field allowlist and safety filtering. Network fetch
and per-story tracking are a later task, once the Groq client pattern
exists to follow.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Swift — `DemoInterfaces` protocols and `PendingDemoStoryPayload`

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoInterfaces.swift`
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStory.swift`

**Interfaces:**
- Produces: `ChatCompleting` (protocol: `complete(messages:) async throws -> String`), `SpeechTranscribing` (protocol: `transcribe(_:) async throws -> String`), `SpeechSynthesizing` (protocol: `synthesize(_:) -> AsyncStream<Data>`), `AnimalFactFetching` (protocol: `fetchFacts(for:) async -> [String]?`), `DemoConnectionError` (error enum), `PendingDemoStoryTurn` / `PendingDemoStoryPayload` (Codable structs).
- Consumes: nothing new.

Pure interface/data-type definitions, mirroring `Interfaces.swift`'s existing role for `SessionCoordinator`'s own dependencies (see that file's header comment: "Protocol seams... so it can be tested with fakes"). No dedicated test file — matching this codebase's existing convention (there is no `InterfacesTests.swift` either); behavior is verified by the concrete conformers' own tests in later tasks.

- [ ] **Step 1: Implement `DemoInterfaces.swift`**

```swift
import Foundation

/// Protocol seams DemoConnection depends on, mirroring Interfaces.swift's
/// existing role for SessionCoordinator -- so it can be tested with
/// fakes, no real network calls.
public protocol ChatCompleting: Sendable {
    func complete(messages: [[String: String]]) async throws -> String
}

public protocol SpeechTranscribing: Sendable {
    func transcribe(_ pcm: Data) async throws -> String
}

public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ text: String) -> AsyncStream<Data>
}

public protocol AnimalFactFetching: Sendable {
    func fetchFacts(for canonicalName: String) async -> [String]?
}

public enum DemoConnectionError: Error, Sendable, Equatable {
    case groqError(String)
}
```

- [ ] **Step 2: Implement `PendingDemoStory.swift`**

```swift
import Foundation

public struct PendingDemoStoryTurn: Codable, Sendable, Equatable {
    public let speaker: String
    public let text: String
    public let interrupted: Bool

    public init(speaker: String, text: String, interrupted: Bool) {
        self.speaker = speaker
        self.text = text
        self.interrupted = interrupted
    }
}

/// One story completed away from home, pending sync to the home server
/// -- see DemoConnection (Task 13, writes these) and PendingDemoStore
/// (Task 13, persists them) and AppModel (Task 15, sends them once
/// reconnected).
public struct PendingDemoStoryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let createdAt: String
    public let turns: [PendingDemoStoryTurn]
    /// [[animal, fact], ...] -- matches AnimalFactTracker.sharedFacts()'s
    /// (animal, fact) pairs, in the shape the wire message sends them.
    public let sharedFacts: [[String]]

    public init(id: String, createdAt: String, turns: [PendingDemoStoryTurn], sharedFacts: [[String]]) {
        self.id = id
        self.createdAt = createdAt
        self.turns = turns
        self.sharedFacts = sharedFacts
    }
}
```

- [ ] **Step 3: Confirm the package still builds**

Run: `cd ios/TinyTalkCore && swift build`
Expected: builds cleanly (no tests to run for this task — see rationale above).

- [ ] **Step 4: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/DemoInterfaces.swift ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStory.swift
git commit -m "$(cat <<'EOF'
feat(ios): add demo-mode protocol seams and PendingDemoStoryPayload

Defines the dependency boundaries DemoConnection (later task) is
built against -- ChatCompleting/SpeechTranscribing/SpeechSynthesizing/
AnimalFactFetching -- plus the Codable shape a completed away-from-home
story is stored and synced in.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Swift — `KeychainStore`

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/KeychainStore.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Produces: `KeychainStore.set(_:forKey:)`, `KeychainStore.get(_:) -> String?`, `KeychainStore.delete(_:)`.
- Consumes: nothing new (Security framework).

Per the spec: the Groq and API Ninjas keys are credentials, however low-stakes, and must live in Keychain, never `UserDefaults` (which is what `serverAddress` uses today, and is not appropriate here).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class KeychainStoreTests: XCTestCase {
    private let testKey = "com.tinytalk.test.keychainStoreTests"

    override func tearDown() {
        KeychainStore.delete(testKey)
        super.tearDown()
    }

    func testGetReturnsNilWhenNothingIsStored() {
        XCTAssertNil(KeychainStore.get(testKey))
    }

    func testSetThenGetRoundTrips() {
        KeychainStore.set("gsk_abc123", forKey: testKey)
        XCTAssertEqual(KeychainStore.get(testKey), "gsk_abc123")
    }

    func testSetOverwritesAnExistingValue() {
        KeychainStore.set("first", forKey: testKey)
        KeychainStore.set("second", forKey: testKey)
        XCTAssertEqual(KeychainStore.get(testKey), "second")
    }

    func testDeleteRemovesTheValue() {
        KeychainStore.set("gsk_abc123", forKey: testKey)
        KeychainStore.delete(testKey)
        XCTAssertNil(KeychainStore.get(testKey))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter KeychainStoreTests`
Expected: FAIL — `KeychainStore` does not exist.

- [ ] **Step 3: Implement `KeychainStore.swift`**

```swift
import Foundation
import Security

/// Minimal Keychain wrapper for the two away-from-home API keys
/// (Groq, API Ninjas) -- generic-password items, one per named key.
public enum KeychainStore {
    public static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter KeychainStoreTests`
Expected: PASS. (Keychain access works under `swift test`/XCTest on a real device or simulator; if it fails in a headless CI-style run with `errSecInteractionNotAllowed` or similar, this must be run via Xcode/simulator rather than bare `swift test` — note this in the task if it comes up, but it is not expected to be needed for a normal on-device or simulator run.)

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/KeychainStore.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/KeychainStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add KeychainStore for the away-from-home API keys

Generic-password Keychain wrapper -- set/get/delete by key name.
Groq and API Ninjas keys must never live in UserDefaults.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Swift — `GroqChatClient` (ChatCompleting via Groq)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/GroqChatClient.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/GroqChatClientTests.swift`

**Interfaces:**
- Produces: `GroqChatClient` (class, conforms to `ChatCompleting`).
- Consumes: `ChatCompleting`, `DemoConnectionError` (Task 7).

Deliberately **non-streaming** (`"stream": false`), unlike `llm_groq.py`'s SSE-parsing approach — that choice existed there specifically to measure time-to-first-token for A/B latency testing. `DemoConnection` (Task 13) needs the full reply text before it can safety-filter and synthesize it anyway (mirroring `_run_turn`'s `"".join(parts)` before `safety.filter_reply`), so a single non-streaming JSON response is simpler and equally correct, with no SSE line-parser to port.

Tested via `URLProtocol` stubbing (a standard, dependency-free way to intercept `URLSession` requests in tests) rather than a live network call.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class GroqChatClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testCompleteReturnsTheAssistantMessageContent() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = #"{"choices":[{"message":{"role":"assistant","content":"Once upon a time."}}]}"#
            return (200, body.data(using: .utf8)!)
        }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        let reply = try await client.complete(messages: [["role": "user", "content": "hi"]])
        XCTAssertEqual(reply, "Once upon a time.")
    }

    func testCompleteThrowsOnNon200() async {
        StubURLProtocol.handler = { _ in (429, "rate limited".data(using: .utf8)!) }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.complete(messages: [])
            XCTFail("expected an error")
        } catch DemoConnectionError.groqError {
            // expected
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testCompleteThrowsWhenThereAreNoChoices() async {
        StubURLProtocol.handler = { _ in (200, #"{"choices":[]}"#.data(using: .utf8)!) }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.complete(messages: [])
            XCTFail("expected an error")
        } catch DemoConnectionError.groqError {
            // expected
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter GroqChatClientTests`
Expected: FAIL — `GroqChatClient` does not exist.

- [ ] **Step 3: Implement `GroqChatClient.swift`**

```swift
import Foundation

private struct GroqChatRequest: Encodable {
    let model: String
    let messages: [[String: String]]
    let stream: Bool
}

private struct GroqChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

/// ChatCompleting backed by Groq's hosted, OpenAI-compatible chat
/// completions API -- see server/tinytalk/llm_groq.py for the sibling
/// server-side implementation this mirrors (non-streaming here; see
/// this file's task notes for why).
public final class GroqChatClient: ChatCompleting, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let host: String
    private let session: URLSession

    /// Model default matches config.py's GROQ_MODEL. Groq's free-tier
    /// model lineup changes over time -- verify this is still current at
    /// https://console.groq.com before relying on it, same caveat as
    /// that file's own comment.
    public init(
        apiKey: String,
        model: String = "llama-3.1-8b-instant",
        host: String = "https://api.groq.com",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.host = host
        self.session = session
    }

    public func complete(messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: URL(string: "\(host)/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GroqChatRequest(model: model, messages: messages, stream: false)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DemoConnectionError.groqError("Groq chat completion returned an error: \(detail)")
        }
        let decoded = try JSONDecoder().decode(GroqChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw DemoConnectionError.groqError("Groq chat completion returned no choices")
        }
        return content
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter GroqChatClientTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/GroqChatClient.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/GroqChatClientTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add GroqChatClient, ChatCompleting via Groq's chat API

Non-streaming (unlike llm_groq.py's SSE parsing) -- DemoConnection
needs the full reply before safety-filtering it regardless, so this
skips porting an SSE line parser. Tested via URLProtocol stubbing,
no live network calls.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Swift — `GroqWhisperClient` (SpeechTranscribing via Groq Whisper)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/GroqWhisperClient.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/GroqWhisperClientTests.swift`

**Interfaces:**
- Produces: `GroqWhisperClient` (class, conforms to `SpeechTranscribing`), `wavData(fromPCM16:sampleRate:channels:)` (internal helper).
- Consumes: `SpeechTranscribing`, `DemoConnectionError` (Task 7).

Packages the mic's raw 24kHz mono PCM16LE (see `protocol.py`'s module docstring for the wire format this mirrors) into a minimal valid WAV container, then uploads it as `multipart/form-data` to Groq's OpenAI-compatible audio transcription endpoint. Reuses the `StubURLProtocol` fixture from Task 9's test file (same target, same file visibility via `@testable import`).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkCore

final class GroqWhisperClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testTranscribeReturnsTheTextField() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data"))
            return (200, #"{"text":"tell me a story about a fox"}"#.data(using: .utf8)!)
        }
        let client = GroqWhisperClient(apiKey: "test-key", session: makeSession())
        let text = try await client.transcribe(Data(repeating: 0, count: 4_800)) // 100ms of silence
        XCTAssertEqual(text, "tell me a story about a fox")
    }

    func testTranscribeThrowsOnNon200() async {
        StubURLProtocol.handler = { _ in (500, "server error".data(using: .utf8)!) }
        let client = GroqWhisperClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.transcribe(Data(repeating: 0, count: 100))
            XCTFail("expected an error")
        } catch DemoConnectionError.groqError {
            // expected
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testWavDataProducesAValidRIFFHeader() {
        let pcm = Data(repeating: 0, count: 480) // 10ms of silence @24kHz/16-bit/mono
        let wav = wavData(fromPCM16: pcm, sampleRate: 24_000, channels: 1)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter GroqWhisperClientTests`
Expected: FAIL — `GroqWhisperClient` does not exist.

- [ ] **Step 3: Implement `GroqWhisperClient.swift`**

```swift
import Foundation

func wavData(fromPCM16 pcm: Data, sampleRate: Int = 24_000, channels: Int = 1) -> Data {
    func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
    let byteRate = sampleRate * channels * 2
    let blockAlign = channels * 2
    var header = Data()
    header.append(contentsOf: "RIFF".utf8)
    header.append(contentsOf: littleEndianBytes(UInt32(36 + pcm.count)))
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    header.append(contentsOf: littleEndianBytes(UInt32(16)))
    header.append(contentsOf: littleEndianBytes(UInt16(1))) // PCM
    header.append(contentsOf: littleEndianBytes(UInt16(channels)))
    header.append(contentsOf: littleEndianBytes(UInt32(sampleRate)))
    header.append(contentsOf: littleEndianBytes(UInt32(byteRate)))
    header.append(contentsOf: littleEndianBytes(UInt16(blockAlign)))
    header.append(contentsOf: littleEndianBytes(UInt16(16))) // bits per sample
    header.append(contentsOf: "data".utf8)
    header.append(contentsOf: littleEndianBytes(UInt32(pcm.count)))
    return header + pcm
}

private struct GroqTranscriptionResponse: Decodable { let text: String }

/// SpeechTranscribing backed by Groq's OpenAI-compatible Whisper
/// transcription endpoint.
public final class GroqWhisperClient: SpeechTranscribing, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let host: String
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "whisper-large-v3-turbo",
        host: String = "https://api.groq.com",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.host = host
        self.session = session
    }

    public func transcribe(_ pcm: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(host)/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, wav: wavData(fromPCM16: pcm), model: model)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DemoConnectionError.groqError("Groq transcription returned an error: \(detail)")
        }
        return try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data).text
    }

    private func multipartBody(boundary: String, wav: Data, model: String) -> Data {
        var body = Data()
        func appendUTF8(_ string: String) { body.append(Data(string.utf8)) }
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        appendUTF8("\(model)\r\n")
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\n")
        appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter GroqWhisperClientTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/GroqWhisperClient.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/GroqWhisperClientTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add GroqWhisperClient, SpeechTranscribing via Groq Whisper

Wraps the mic's raw 24kHz mono PCM16LE in a minimal WAV container and
uploads it as multipart/form-data to Groq's transcription endpoint.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Swift — `AnimalFactsAPIClient` and `AnimalFactTracker` (network + per-story state)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/AnimalFactsAPIClient.swift`
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/AnimalFactTracker.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/AnimalFactsAPIClientTests.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/AnimalFactTrackerTests.swift`

**Interfaces:**
- Produces: `AnimalFactsAPIClient` (class, conforms to `AnimalFactFetching`), `AnimalFactsCache` (class: `load() -> [String: [String]]`, `save(_:)`), `AnimalFactTracker` (actor: `init(fetcher:cache:)`, `recordTurn(transcript:stage:) async -> String`, `sharedFacts() async -> [(animal: String, fact: String)]`, `reset() async`).
- Consumes: `AnimalFactFetching`, `AnimalFacts.extractFacts`/`findNewAnimal` (Task 6), `StoryStage` (Task 4).

`AnimalFactTracker` is an `actor` (not a plain class) because it does real `await`ed network fetches and must serialize concurrent access safely, matching `SessionCoordinator`'s own use of `actor` for the same reason. `config.ANIMAL_FACTS_API_KEY`'s existing behavior — silent no-op with no key — is preserved: `AnimalFactsAPIClient.fetchFacts` returns `nil` immediately if no key was configured.

- [ ] **Step 1: Write the failing `AnimalFactsAPIClient` tests**

```swift
import XCTest
@testable import TinyTalkCore

final class AnimalFactsAPIClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testReturnsNilImmediatelyWithNoKeyConfigured() async {
        let client = AnimalFactsAPIClient(apiKey: nil, session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertNil(facts)
    }

    func testReturnsNilForAnEmptyKey() async {
        let client = AnimalFactsAPIClient(apiKey: "", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertNil(facts)
    }

    func testFetchesAndExtractsFactsFromTheFirstRecord() async {
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("name=fox"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "ninja-key")
            let body = """
            [{"name":"Fox","characteristics":{"most_distinctive_feature":"its bushy tail","diet":"omnivore"}}]
            """
            return (200, body.data(using: .utf8)!)
        }
        let client = AnimalFactsAPIClient(apiKey: "ninja-key", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertEqual(facts, ["its most distinctive feature is its bushy tail", "its diet is omnivore"])
    }

    func testReturnsEmptyArrayWhenNoRecordsMatch() async {
        StubURLProtocol.handler = { _ in (200, "[]".data(using: .utf8)!) }
        let client = AnimalFactsAPIClient(apiKey: "ninja-key", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertEqual(facts, [])
    }

    func testReturnsNilOnANetworkError() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let client = AnimalFactsAPIClient(apiKey: "ninja-key", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertNil(facts)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter AnimalFactsAPIClientTests`
Expected: FAIL — `AnimalFactsAPIClient` does not exist.

- [ ] **Step 3: Implement `AnimalFactsAPIClient.swift`**

```swift
import Foundation

private struct AnimalRecord: Decodable {
    let characteristics: Characteristics?

    struct Characteristics: Decodable {
        let mostDistinctiveFeature: String?
        let topSpeed: String?
        let diet: String?
        let habitat: String?
        let slogan: String?
        let color: String?
        let groupBehavior: String?
        let lifespan: String?

        enum CodingKeys: String, CodingKey {
            case mostDistinctiveFeature = "most_distinctive_feature"
            case topSpeed = "top_speed"
            case diet, habitat, slogan, color
            case groupBehavior = "group_behavior"
            case lifespan
        }
    }
}

/// AnimalFactFetching backed by API Ninjas' Animals endpoint -- see
/// server/tinytalk/animal_facts.py's _fetch_facts_from_api for the
/// sibling server-side implementation this mirrors. Optional by design:
/// a nil/empty apiKey is a silent no-op, matching
/// config.ANIMAL_FACTS_API_KEY's existing "without it, lookups silently
/// no-op" behavior.
public final class AnimalFactsAPIClient: AnimalFactFetching, @unchecked Sendable {
    private static let host = "https://api.api-ninjas.com"
    private let apiKey: String?
    private let session: URLSession

    public init(apiKey: String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func fetchFacts(for canonicalName: String) async -> [String]? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "\(Self.host)/v1/animals")!
        components.queryItems = [URLQueryItem(name: "name", value: canonicalName)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let records = try JSONDecoder().decode([AnimalRecord].self, from: data)
            guard let first = records.first, let characteristics = first.characteristics else {
                return records.isEmpty ? [] : []
            }
            return AnimalFacts.extractFacts(from: AnimalRecordCharacteristics(
                mostDistinctiveFeature: characteristics.mostDistinctiveFeature,
                topSpeed: characteristics.topSpeed,
                diet: characteristics.diet,
                habitat: characteristics.habitat,
                slogan: characteristics.slogan,
                color: characteristics.color,
                groupBehavior: characteristics.groupBehavior,
                lifespan: characteristics.lifespan
            ))
        } catch {
            return nil
        }
    }
}

/// On-disk fact cache, mirroring animal_facts.py's _load_cache/_save_cache
/// -- a fetched fact is remembered so a repeated mention (in this or a
/// later demo session) never re-hits the API.
public final class AnimalFactsCache: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()

    public init(path: URL = AnimalFactsCache.defaultPath) {
        self.path = path
    }

    public static var defaultPath: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("animal_facts_cache.json")
    }

    public func load() -> [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: path) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    public func save(_ cache: [String: [String]]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: path)
    }
}
```

Note: unlike `_fetch_facts_from_api`, which distinguishes "API found the animal but it had no characteristics" (returns `[]`, cacheable) from "record has no `characteristics` key at all" only implicitly, this Swift version treats a missing `characteristics` object the same as an empty list — both are a legitimate, cacheable "no facts" answer, matching `_extract_facts`' own handling of a non-dict `characteristics`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter AnimalFactsAPIClientTests`
Expected: PASS.

- [ ] **Step 5: Write the failing `AnimalFactTracker` tests**

```swift
import XCTest
@testable import TinyTalkCore

final class FakeAnimalFactFetcher: AnimalFactFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedNames: [String] = []
    var factsToReturn: [String: [String]?] = [:]

    var requestedNames: [String] { lock.withLockUnchecked { _requestedNames } }

    func fetchFacts(for canonicalName: String) async -> [String]? {
        lock.withLockUnchecked { _requestedNames.append(canonicalName) }
        return factsToReturn[canonicalName] ?? nil
    }
}

private extension NSLock {
    func withLockUnchecked<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

final class AnimalFactTrackerTests: XCTestCase {
    func testRecordTurnReturnsWeaveInGuidanceOnAFreshMention() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = ["foxes are clever"]
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        let guidance = await tracker.recordTurn(transcript: "tell me about a fox", stage: .setup)

        XCTAssertTrue(guidance.contains("fox"))
        XCTAssertTrue(guidance.contains("foxes are clever"))
        let shared = await tracker.sharedFacts()
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared[0].animal, "fox")
    }

    func testSameAnimalIsNotFetchedTwice() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = ["foxes are clever"]
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)
        _ = await tracker.recordTurn(transcript: "the fox again", stage: .risingAction)

        XCTAssertEqual(fetcher.requestedNames, ["fox"])
    }

    func testAFailedFetchIsNotRetriedWithinTheSameStory() async {
        let fetcher = FakeAnimalFactFetcher() // factsToReturn defaults to nil == failure
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)
        _ = await tracker.recordTurn(transcript: "the fox again", stage: .risingAction)

        XCTAssertEqual(fetcher.requestedNames, ["fox"])
    }

    func testNudgesForAnAnimalDuringIntroSetupIfNoneMentionedYet() async {
        let fetcher = FakeAnimalFactFetcher()
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        let guidance = await tracker.recordTurn(transcript: "let's start a story", stage: .intro)

        XCTAssertTrue(guidance.contains("what animal should be in the story"))
    }

    func testNoNudgeOnceAnAnimalHasBeenMentioned() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = nil // fetch fails, but the animal WAS mentioned
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .intro)
        let guidance = await tracker.recordTurn(transcript: "what happens next", stage: .setup)

        XCTAssertEqual(guidance, "")
    }

    func testResetClearsSharedFactsAndAllowsRefetching() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = ["foxes are clever"]
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)
        await tracker.reset()
        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)

        XCTAssertEqual(fetcher.requestedNames, ["fox", "fox"])
        let shared = await tracker.sharedFacts()
        XCTAssertEqual(shared.count, 1) // only this story's fact, not both
    }

    private func tempCachePath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter AnimalFactTrackerTests`
Expected: FAIL — `AnimalFactTracker` does not exist.

- [ ] **Step 7: Implement `AnimalFactTracker.swift`**

```swift
import Foundation

private let weaveInTemplate =
    "The story just mentioned a %1$@. Weave this real fact about the " +
    "%1$@ naturally into what happens next, as part of the action -- " +
    "don't just state it as trivia: %2$@"

private let firstAnimalNudge =
    "No animal has been part of the story yet. Before continuing, warmly " +
    "ask the child what animal should be in the story."

/// Swift port of server/tinytalk/animal_facts.py's AnimalFactTracker --
/// per-story state, recreated fresh (via reset()) whenever a story
/// finishes. An actor because it does real awaited network fetches
/// (through `fetcher`) and must serialize concurrent access, same
/// reasoning as SessionCoordinator's own actor isolation.
public actor AnimalFactTracker {
    private let fetcher: any AnimalFactFetching
    private let cache: AnimalFactsCache
    private var facted: Set<String> = []
    private var attempted: Set<String> = []
    private var anyAnimalMentioned = false
    private var _sharedFacts: [(animal: String, fact: String)] = []

    public init(fetcher: any AnimalFactFetching, cache: AnimalFactsCache = AnimalFactsCache()) {
        self.fetcher = fetcher
        self.cache = cache
    }

    public func sharedFacts() -> [(animal: String, fact: String)] { _sharedFacts }

    public func reset() {
        facted = []
        attempted = []
        anyAnimalMentioned = false
        _sharedFacts = []
    }

    public func recordTurn(transcript: String, stage: StoryStage) async -> String {
        if let canonical = AnimalFacts.findNewAnimal(in: transcript, excluding: facted.union(attempted)) {
            anyAnimalMentioned = true
            attempted.insert(canonical)
            if let fact = await getFact(canonical) {
                facted.insert(canonical)
                _sharedFacts.append((canonical, fact))
                return String(format: weaveInTemplate, canonical, fact)
            }
            return ""
        }
        if (stage == .intro || stage == .setup) && !anyAnimalMentioned {
            return firstAnimalNudge
        }
        return ""
    }

    private func getFact(_ canonical: String) async -> String? {
        var current = cache.load()
        if let cached = current[canonical] {
            return cached.randomElement()
        }
        guard let facts = await fetcher.fetchFacts(for: canonical) else { return nil }
        current[canonical] = facts
        cache.save(current)
        return facts.randomElement()
    }
}
```

- [ ] **Step 8: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter AnimalFactTrackerTests`
Expected: PASS.

- [ ] **Step 9: Run the full iOS test suite so far**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, no regressions in any pre-existing test.

- [ ] **Step 10: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/AnimalFactsAPIClient.swift ios/TinyTalkCore/Sources/TinyTalkCore/AnimalFactTracker.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/AnimalFactsAPIClientTests.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/AnimalFactTrackerTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add AnimalFactsAPIClient and AnimalFactTracker

Completes the animal-facts port: API Ninjas client + on-disk cache
(mirroring animal_facts.py's _load_cache/_save_cache) plus the
per-story actor that ties detection, fetching, and the
already-facted/already-attempted bookkeeping together. Optional at
runtime -- no key configured is a silent no-op, matching the server's
existing behavior.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Swift — `AVSpeechTts` (SpeechSynthesizing via on-device AVSpeechSynthesizer)

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkPlatform/AVSpeechTts.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/AVSpeechTtsTests.swift` — **note:** `TinyTalkPlatform` has no existing test target of its own (only `TinyTalkCoreTests` exists, depending on `TinyTalkCore`). Before writing this task's test, check whether `Package.swift` needs a `TinyTalkPlatformTests` target added (`dependencies: ["TinyTalkPlatform"]`) — if `TinyTalkCoreTests` cannot import `TinyTalkPlatform` today, add that target rather than working around its absence.

**Interfaces:**
- Produces: `AVSpeechTts` (class, conforms to `SpeechSynthesizing`, defined in `TinyTalkCore`'s public interface but implemented against `AVFoundation` in `TinyTalkPlatform`, matching `RealAudioEngine`'s existing split).
- Consumes: `SpeechSynthesizing` (Task 7).

This is the spec's flagged open risk: `AVSpeechSynthesizer`'s native buffer format does not match the wire format (24kHz mono PCM16LE) and must be converted. A unit test can confirm the conversion produces correctly-shaped, non-empty PCM16 data and a plausible byte count for the sample rate — it **cannot** confirm the audio actually sounds correct (not garbled, not pitch-shifted). Real verification is on-device listening, called out explicitly in Task 16.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TinyTalkPlatform

final class AVSpeechTtsTests: XCTestCase {
    func testSynthesizeProducesNonEmptyPCM16Data() async {
        let tts = AVSpeechTts()
        var chunks: [Data] = []
        for await chunk in tts.synthesize("Hello there.") {
            chunks.append(chunk)
        }
        XCTAssertFalse(chunks.isEmpty)
        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(totalBytes, 0)
        // PCM16 is 2 bytes/sample -- every chunk must be an even byte count.
        for chunk in chunks {
            XCTAssertEqual(chunk.count % 2, 0)
        }
    }

    func testSynthesizingEmptyTextProducesNoAudio() async {
        let tts = AVSpeechTts()
        var chunks: [Data] = []
        for await chunk in tts.synthesize("") {
            chunks.append(chunk)
        }
        XCTAssertTrue(chunks.allSatisfy { $0.isEmpty == false } || chunks.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter AVSpeechTtsTests`
Expected: FAIL — `AVSpeechTts` does not exist (or the target itself doesn't build if `TinyTalkPlatform` isn't yet importable from the test target — resolve that via `Package.swift` first, per this task's Files note, before writing the implementation).

- [ ] **Step 3: Implement `AVSpeechTts.swift`**

```swift
import AVFoundation
import TinyTalkCore

/// SpeechSynthesizing backed by on-device AVSpeechSynthesizer -- see the
/// spec's rationale for choosing this over Groq's (paid, Preview-status)
/// TTS. Converts AVSpeechSynthesizer's native buffer format to the wire
/// protocol's 24kHz mono PCM16LE via AVAudioConverter, since the two
/// essentially never match natively.
public final class AVSpeechTts: NSObject, SpeechSynthesizing, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
    )!

    public init(voiceIdentifier: String? = nil) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
    }

    public func synthesize(_ text: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard !text.isEmpty else {
                continuation.finish()
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            }
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
                    continuation.finish()
                    return
                }
                if let converted = Self.convert(pcmBuffer, to: Self.targetFormat) {
                    continuation.yield(converted)
                }
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> Data? {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCapacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let int16Data = outBuffer.int16ChannelData else { return nil }
        let frameLength = Int(outBuffer.frameLength)
        return Data(bytes: int16Data[0], count: frameLength * MemoryLayout<Int16>.size)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter AVSpeechTtsTests`
Expected: PASS. If this fails specifically in a headless/CI-style environment with a speech-synthesis-unavailable error, that's expected there — this test needs a real simulator or device audio stack; re-run via Xcode's test navigator rather than bare `swift test` if that happens, and treat this task as pending real verification per Task 16 either way (the unit test only checks shape, not correctness).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Package.swift ios/TinyTalkCore/Sources/TinyTalkPlatform/AVSpeechTts.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/AVSpeechTtsTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add AVSpeechTts, on-device SpeechSynthesizing via AVSpeechSynthesizer

Converts the synthesizer's native output format to the wire protocol's
24kHz mono PCM16LE via AVAudioConverter. Unit-tested for shape only --
real audio-quality verification is on-device (Task 16).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Swift — `DemoConnection` and `PendingDemoStore`

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift`
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStore.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConnectionTests.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/PendingDemoStoreTests.swift`

**Interfaces:**
- Produces: `DemoConnection` (class, conforms to `ServerConnecting`), `PendingDemoStore` (class: `save(_:)`, `loadAll() -> [PendingDemoStoryPayload]`, `clear()`).
- Consumes: `ServerConnecting`/`ClientMessage`/`ServerEvent`/`ServerConnectionEvent` (`Interfaces.swift`/`Protocol.swift`, existing), `ChatCompleting`/`SpeechTranscribing`/`SpeechSynthesizing`/`DemoConnectionError` (Task 7), `DemoConversation` (Task 2), `Safety` (Task 3), `StoryArc` (Task 4), `ObjectTracker` (Task 5), `AnimalFactTracker` (Task 11), `PendingDemoStoryPayload` (Task 7).

This is the piece the whole feature hangs on — a second `ServerConnecting` conformer alongside `WebSocketServerConnection` (`ServerConnection.swift`), so `SessionCoordinator` needs zero changes. Structurally mirrors `WebSocketServerConnection`'s `AsyncStream`-plus-`Continuation` shape; behaviorally mirrors `session.py`'s `_run_turn`/`_finish_listening`/`_interrupt`, minus persistent-session-across-backgrounding (see Global Constraints' disclosed simplification).

**Known behavioral simplification, stated explicitly (not hidden):** unlike `_cancel_turn`'s heard-vs-sent timing math (`self._spoken`, `playback_offset`), an interrupted turn's reply is not partially recorded into conversation history here — it is simply not recorded at all. Porting the real server's precise "how much was actually heard" truncation is disproportionate complexity for a demo feature; the cost is a rare edge case (unheard text influencing a later turn), not a correctness bug in the common path.

- [ ] **Step 1: Write the failing `PendingDemoStore` tests**

```swift
import XCTest
@testable import TinyTalkCore

final class PendingDemoStoreTests: XCTestCase {
    private func makeStore() -> PendingDemoStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return PendingDemoStore(directory: dir)
    }

    private func makePayload(id: String) -> PendingDemoStoryPayload {
        PendingDemoStoryPayload(
            id: id,
            createdAt: "2026-09-09T12:00:00+00:00",
            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
            sharedFacts: [["fox", "foxes are clever"]]
        )
    }

    func testLoadAllReturnsEmptyWhenNothingSaved() {
        XCTAssertEqual(makeStore().loadAll(), [])
    }

    func testSaveThenLoadAllRoundTrips() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "abc")
        XCTAssertEqual(loaded[0].sharedFacts, [["fox", "foxes are clever"]])
    }

    func testMultipleSavesAreAllReturned() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        store.save(makePayload(id: "def"))
        XCTAssertEqual(Set(store.loadAll().map(\.id)), Set(["abc", "def"]))
    }

    func testClearRemovesEverything() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        store.clear()
        XCTAssertEqual(store.loadAll(), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter PendingDemoStoreTests`
Expected: FAIL — `PendingDemoStore` does not exist.

- [ ] **Step 3: Implement `PendingDemoStore.swift`**

```swift
import Foundation

/// Local, on-phone holding pen for stories completed away from home,
/// until AppModel (Task 15) hands them to the real server on next
/// reconnect. One JSON file per story, named by story id.
public final class PendingDemoStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = PendingDemoStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("PendingDemoStories", isDirectory: true)
    }

    public func save(_ payload: PendingDemoStoryPayload) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(payload.id).json"))
    }

    public func loadAll() -> [PendingDemoStoryPayload] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(PendingDemoStoryPayload.self, from: data)
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter PendingDemoStoreTests`
Expected: PASS.

- [ ] **Step 5: Write the failing `DemoConnection` tests**

```swift
import XCTest
@testable import TinyTalkCore

final class FakeChatClient: ChatCompleting, @unchecked Sendable {
    var replyText = "Once upon a time, a fox went for a walk. What happens next?"
    var error: Error?
    private(set) var receivedMessages: [[[String: String]]] = []

    func complete(messages: [[String: String]]) async throws -> String {
        receivedMessages.append(messages)
        if let error { throw error }
        return replyText
    }
}

final class FakeSttClient: SpeechTranscribing, @unchecked Sendable {
    var transcriptToReturn = "tell me a story"
    var error: Error?

    func transcribe(_ pcm: Data) async throws -> String {
        if let error { throw error }
        return transcriptToReturn
    }
}

final class FakeTtsClient: SpeechSynthesizing, @unchecked Sendable {
    func synthesize(_ text: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data([0x01, 0x02]))
            continuation.finish()
        }
    }
}

final class DemoConnectionTests: XCTestCase {
    private func makeConnection(
        chat: FakeChatClient = FakeChatClient(),
        stt: FakeSttClient = FakeSttClient(),
        tts: FakeTtsClient = FakeTtsClient(),
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) -> DemoConnection {
        DemoConnection(
            chatClient: chat,
            sttClient: stt,
            ttsClient: tts,
            animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher()),
            targetTurns: 7,
            onStoryCompleted: onStoryCompleted
        )
    }

    private func collectEvents(_ connection: DemoConnection, count: Int) async -> [ServerConnectionEvent] {
        var collected: [ServerConnectionEvent] = []
        for await event in connection.events() {
            collected.append(event)
            if collected.count == count { break }
        }
        return collected
    }

    func testFullTurnEmitsTranscriptReplyAudioThenTurnEnd() async throws {
        let connection = makeConnection()
        async let events = collectEvents(connection, count: 4) // transcriptFinal, responseText, audio, turnEnd

        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(audio: Data(repeating: 0, count: 100))
        try await connection.send(.speechEnd)

        let collected = await events
        guard case .message(.transcriptFinal(let text, let turnId1)) = collected[0] else {
            return XCTFail("expected transcriptFinal, got \(collected[0])")
        }
        XCTAssertEqual(text, "tell me a story")
        XCTAssertEqual(turnId1, 1)

        guard case .message(.responseText(_, let turnId2)) = collected[1] else {
            return XCTFail("expected responseText, got \(collected[1])")
        }
        XCTAssertEqual(turnId2, 1)

        guard case .audio = collected[2] else {
            return XCTFail("expected audio, got \(collected[2])")
        }

        guard case .message(.turnEnd(let turnId3)) = collected[3] else {
            return XCTFail("expected turnEnd, got \(collected[3])")
        }
        XCTAssertEqual(turnId3, 1)
    }

    func testAnEngineFailureEmitsAnErrorEventWithTheTurnId() async throws {
        let stt = FakeSttClient()
        stt.error = DemoConnectionError.groqError("boom")
        let connection = makeConnection(stt: stt)
        async let events = collectEvents(connection, count: 1)

        try await connection.send(.speechStart(turnId: 5))
        try await connection.send(.speechEnd)

        guard case .message(.error(_, let turnId)) = await events.first else {
            return XCTFail("expected an error event")
        }
        XCTAssertEqual(turnId, 5)
    }

    func testInterruptCancelsTheInFlightTurn() async throws {
        // A chat client that never resolves until cancelled, so we can
        // confirm interrupt() actually stops it rather than letting it
        // complete after the fact.
        final class HangingChatClient: ChatCompleting, @unchecked Sendable {
            func complete(messages: [[String: String]]) async throws -> String {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "should never get here"
            }
        }
        let connection = DemoConnection(
            chatClient: HangingChatClient(),
            sttClient: FakeSttClient(),
            ttsClient: FakeTtsClient(),
            animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher())
        )
        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(.speechEnd)
        try await Task.sleep(nanoseconds: 50_000_000) // let the turn actually start
        try await connection.send(.interrupt(turnId: 2))

        // No responseText for turn 1 should ever arrive -- give it a beat
        // and confirm nothing shows up.
        let task = Task<ServerConnectionEvent?, Never> {
            for await event in connection.events() { return event }
            return nil
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
    }

    func testConclusionCallsOnStoryCompletedWithTheFullTranscript() async throws {
        var completed: PendingDemoStoryPayload?
        let chat = FakeChatClient()
        chat.replyText = "And they all lived happily ever after. The end."
        let connection = makeConnection(chat: chat, onStoryCompleted: { completed = $0 })
        async let events = collectEvents(connection, count: 4)

        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(.speechEnd)
        _ = await events

        try await Task.sleep(nanoseconds: 50_000_000) // let completeStory()'s own await settle
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.turns.last?.speaker, "agent")
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter DemoConnectionTests`
Expected: FAIL — `DemoConnection` does not exist.

- [ ] **Step 7: Implement `DemoConnection.swift`**

```swift
import Foundation

public final class DemoConnection: ServerConnecting, @unchecked Sendable {
    /// Verbatim copy of config.py's SYSTEM_PROMPT, so demo mode's Elsie
    /// sounds the same as the real server's.
    public static let defaultSystemPrompt =
        "You are a warm, interesting storyteller telling a story out loud with a young, " +
        "intelligent child, aged about three to six. You and the child are making the " +
        "story up together. You like to subtly add educational facts to the story to make it " +
        "more interesting. Like any good arts major, you love to develop a good story arc.\n" +
        "\n" +
        "Rules you always follow:\n" +
        "- Reply with one to three short sentences. Never more. The child is " +
        "listening, not reading.\n" +
        "- Keep everything gentle and wholesome. No violence, no weapons, no death, " +
        "no frightening peril.\n" +
        "- End most replies by asking the child what should happen next.\n" +
        "- If the child interrupts you, follow their idea happily. Never scold them " +
        "for interrupting and never insist on finishing your previous sentence.\n" +
        "- Keep the story grounded in the real world: no magic, no talking " +
        "plants or objects, no impossible physics. Animal characters can " +
        "talk and think like people, but everything else about the world " +
        "should be realistic.\n" +
        "- Write plain spoken words only: no emoji, no asterisks, no stage " +
        "directions, no narration about yourself."

    private static let sttFailureGuidance =
        "You didn't hear anything new from the child just now -- it might " +
        "have been background noise. Don't mention this or ask them to " +
        "repeat themselves. Instead, gently continue the story yourself " +
        "using what's already happened, and end with an easy, inviting " +
        "question so they have a natural opening to jump back in."

    private let chatClient: any ChatCompleting
    private let sttClient: any SpeechTranscribing
    private let ttsClient: any SpeechSynthesizing
    private let animalFactTracker: AnimalFactTracker
    private let systemPrompt: String
    private let targetTurns: Int
    private let onStoryCompleted: ((PendingDemoStoryPayload) -> Void)?

    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>

    private let lock = NSLock()
    private var currentTurnId = 0
    private var audioBuffer = Data()
    private var conversation = DemoConversation()
    private var storyArc: StoryArc
    private var objectTracker = ObjectTracker()
    private var turnTask: Task<Void, Never>?

    public init(
        chatClient: any ChatCompleting,
        sttClient: any SpeechTranscribing,
        ttsClient: any SpeechSynthesizing,
        animalFactTracker: AnimalFactTracker,
        systemPrompt: String = DemoConnection.defaultSystemPrompt,
        targetTurns: Int = 7,
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) {
        self.chatClient = chatClient
        self.sttClient = sttClient
        self.ttsClient = ttsClient
        self.animalFactTracker = animalFactTracker
        self.systemPrompt = systemPrompt
        self.targetTurns = targetTurns
        self.onStoryCompleted = onStoryCompleted
        self.storyArc = StoryArc(targetTurns: targetTurns)
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
    }

    public func send(_ message: ClientMessage) async throws {
        switch message {
        case .speechStart(let turnId):
            lock.lock()
            turnTask?.cancel()
            turnTask = nil
            currentTurnId = turnId
            audioBuffer = Data()
            lock.unlock()
        case .speechEnd:
            let (turnId, pcm) = lock.withLockReturning { (currentTurnId, audioBuffer) }
            let task = Task { [weak self] in
                await self?.runTurn(turnId: turnId, pcm: pcm)
            }
            lock.lock(); turnTask = task; lock.unlock()
        case .interrupt(let turnId):
            lock.lock()
            turnTask?.cancel()
            turnTask = nil
            currentTurnId = turnId
            audioBuffer = Data()
            lock.unlock()
        case .objectSeen(let label):
            objectTracker.recordSeen(label: label)
        case .newStory:
            lock.lock()
            turnTask?.cancel()
            turnTask = nil
            conversation = DemoConversation()
            storyArc = StoryArc(targetTurns: targetTurns)
            objectTracker = ObjectTracker()
            lock.unlock()
            await animalFactTracker.reset()
        }
    }

    public func send(audio pcm: Data) async throws {
        lock.lock(); audioBuffer.append(pcm); lock.unlock()
    }

    public func events() -> AsyncStream<ServerConnectionEvent> { stream }

    public func close() {
        lock.lock(); turnTask?.cancel(); turnTask = nil; lock.unlock()
        continuation.finish()
    }

    private func runTurn(turnId: Int, pcm: Data) async {
        do {
            try Task.checkCancellation()
            let transcript = try await sttClient.transcribe(pcm)
            try Task.checkCancellation()
            continuation.yield(.message(.transcriptFinal(transcript, turnId: turnId)))

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                conversation.addChild(trimmed)
            }

            var guidance = storyArc.recordTurn(childText: transcript)
            let factGuidance = await animalFactTracker.recordTurn(transcript: transcript, stage: storyArc.stage)
            if !factGuidance.isEmpty { guidance += "\n\n" + factGuidance }
            let objectGuidance = objectTracker.consumeGuidance()
            if !objectGuidance.isEmpty { guidance += "\n\n" + objectGuidance }
            if trimmed.isEmpty { guidance += "\n\n" + Self.sttFailureGuidance }

            let messages = conversation.toMessages(systemPrompt: systemPrompt + "\n\n" + guidance)
            try Task.checkCancellation()
            let rawReply = try await chatClient.complete(messages: messages)
            try Task.checkCancellation()
            let reply = Safety.filterReply(rawReply.trimmingCharacters(in: .whitespacesAndNewlines))
            storyArc.recordReply(replyText: reply)

            continuation.yield(.message(.responseText(reply, turnId: turnId)))

            for await pcmChunk in ttsClient.synthesize(reply) {
                try Task.checkCancellation()
                continuation.yield(.audio(pcmChunk))
            }

            conversation.addAgent(reply)
            continuation.yield(.message(.turnEnd(turnId: turnId)))

            if storyArc.isDone {
                await completeStory()
            }
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(.message(.error(
                "Elsie's cloud brain is having trouble -- let's try again in a moment.",
                turnId: turnId
            )))
        }
    }

    private func completeStory() async {
        let turns = conversation.fullHistory
        let sharedFacts = await animalFactTracker.sharedFacts()
        let payload = PendingDemoStoryPayload(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            turns: turns.map {
                PendingDemoStoryTurn(speaker: $0.speaker.rawValue, text: $0.text, interrupted: $0.interrupted)
            },
            sharedFacts: sharedFacts.map { [$0.animal, $0.fact] }
        )
        onStoryCompleted?(payload)

        lock.lock()
        conversation = DemoConversation()
        storyArc = StoryArc(targetTurns: targetTurns)
        objectTracker = ObjectTracker()
        lock.unlock()
        await animalFactTracker.reset()
    }
}

private extension NSLock {
    func withLockReturning<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
```

- [ ] **Step 8: Run to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter DemoConnectionTests`
Expected: PASS.

- [ ] **Step 9: Run the full iOS test suite**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, no regressions anywhere, including `SessionCoordinatorTests` (unchanged, but confirms `DemoConnection` didn't have to touch anything it depends on).

- [ ] **Step 10: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStore.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConnectionTests.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/PendingDemoStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add DemoConnection, a ServerConnecting conformer backed by Groq

Ties together every ported module (Safety, StoryArc, ObjectTracker,
AnimalFactTracker, DemoConversation) plus the Groq/Whisper/on-device-TTS
clients into a full turn loop -- SessionCoordinator needs zero changes,
since this speaks the exact same ServerConnecting/ClientMessage/
ServerEvent vocabulary WebSocketServerConnection already does.
Completed stories are handed to PendingDemoStore for later sync.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: iOS — wire `DemoConnection` into `AppModel`

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`

**Interfaces:**
- Produces: `AppModel.awayFromHomeEnabled: Bool` (published), `AppModel.connectAwayFromHome() async`, `SessionCoordinator.syncDemoStories(_:) async`.
- Consumes: `DemoConnection`, `PendingDemoStore` (Task 13), `KeychainStore` (Task 8), `GroqChatClient`/`GroqWhisperClient` (Tasks 9-10), `AnimalFactsAPIClient`/`AnimalFactTracker` (Task 11), `AVSpeechTts` (Task 12).

Ordered before Task 15 (the Settings UI) deliberately: the UI binds to `awayFromHomeEnabled`, so that property must exist first.

- [ ] **Step 1: Add a thin passthrough on `SessionCoordinator`, mirroring `sendObjectSeen`/`newStory`'s existing pattern**

In `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`, add this method near `sendObjectSeen(label:)`:

```swift
    /// Hands completed away-from-home stories to whatever connection is
    /// current -- a no-op (best effort, like sendObjectSeen) if the send
    /// fails; AppModel only clears PendingDemoStore after this returns
    /// without throwing.
    public func syncDemoStories(_ stories: [PendingDemoStoryPayload]) async throws {
        try await connection.send(.syncDemoStories(stories: stories))
    }
```

Add the corresponding case to `ClientMessage` in `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`, in the enum:

```swift
    case syncDemoStories(stories: [PendingDemoStoryPayload])
```

and its `encode()` branch. This one payload has arbitrary user-generated transcript/reply text (unlike every other case here, which encodes a fixed identifier or no data at all), so `JSONSerialization` is used instead of this file's usual hand-built string interpolation — the existing `jsonEscaped` helper only escapes quotes/backslashes, not full JSON string escaping, and this message's content is exactly the case that would need it:

```swift
        case .syncDemoStories(let stories):
            let storiesJSON: [[String: Any]] = stories.map { story in
                [
                    "id": story.id,
                    "created_at": story.createdAt,
                    "turns": story.turns.map {
                        ["speaker": $0.speaker, "text": $0.text, "interrupted": $0.interrupted]
                    },
                    "shared_facts": story.sharedFacts,
                ]
            }
            let payload: [String: Any] = ["type": "sync_demo_stories", "stories": storiesJSON]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return #"{"type":"sync_demo_stories","stories":[]}"#
            }
            return json
```

Add a matching case to `ProtocolTests.swift` confirming `syncDemoStories` round-trips through valid JSON (decode the `encode()` output with `JSONSerialization` and check `type`/`stories` are present) — this message is send-only from the client (no `decodeServerEvent` counterpart needed, matching `.newStory`/`.objectSeen`).

- [ ] **Step 2: Run the existing protocol/coordinator tests to confirm nothing broke**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests`
Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests`
Expected: PASS. (`ClientMessage` gaining a new `case` cannot break an existing exhaustive `switch` over it inside this same package — `encode()` is the only exhaustive switch over `ClientMessage`, and this step already handled it.)

- [ ] **Step 3: Add `awayFromHomeEnabled` and `connectAwayFromHome()` to `AppModel`**

In `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`, add a published property alongside `serverAddress` (near line 40):

```swift
    @Published var awayFromHomeEnabled: Bool
```

and a private store property alongside the other private state (near `objectRecognizer`, line 77):

```swift
    private let pendingDemoStore = PendingDemoStore()
```

Update `init()` (currently lines 132-136) to load the persisted toggle state, matching `serverAddress`'s existing pattern:

```swift
    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
        awayFromHomeEnabled = UserDefaults.standard.bool(forKey: "awayFromHomeEnabled")
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        screen = hasOnboarded ? .landing : .onboarding
    }
```

Add a `didSet`-style persistence call. Since `@Published var awayFromHomeEnabled: Bool` can't carry a `didSet` alongside `@Published` cleanly with stored-property syntax in this file's existing style, instead persist it explicitly wherever it's toggled — add this small setter method, called from the Settings toggle binding (Task 15) instead of binding directly to the raw property:

```swift
    /// The Settings toggle calls this (not $awayFromHomeEnabled directly)
    /// so the choice survives an app relaunch, matching serverAddress's
    /// own persistence.
    func setAwayFromHomeEnabled(_ enabled: Bool) {
        awayFromHomeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "awayFromHomeEnabled")
    }
```

Add `connectAwayFromHome()`, mirroring `connect()`'s general shape (mic permission → connection → coordinator → mic capture wiring → VAD load → isConnected=true → startPollingState) but without server-address/resume-turn-id handling, which don't apply to a connection that isn't a persistent server session:

```swift
    /// Away-from-home counterpart to connect() -- builds a DemoConnection
    /// against Groq instead of a WebSocketServerConnection against the
    /// Mac. See the design spec's disclosed simplification: unlike the
    /// real server, there is no persistent session to resume if the app
    /// is backgrounded mid-reply -- that reply is simply lost, not
    /// replayed.
    func connectAwayFromHome() async {
        guard let groqKey = KeychainStore.get("groqApiKey"), !groqKey.isEmpty else {
            lastErrorMessage = "no Groq API key saved -- add one in Settings, under Away From Home."
            return
        }
        guard await RealAudioEngine.requestMicrophonePermission() else {
            lastErrorMessage = "microphone access denied. Check Settings > Privacy > Microphone > TinyTalkApp."
            return
        }

        let animalFactsKey = KeychainStore.get("animalFactsApiKey")
        let connection = DemoConnection(
            chatClient: GroqChatClient(apiKey: groqKey),
            sttClient: GroqWhisperClient(apiKey: groqKey),
            ttsClient: AVSpeechTts(),
            animalFactTracker: AnimalFactTracker(fetcher: AnimalFactsAPIClient(apiKey: animalFactsKey)),
            onStoryCompleted: { [weak self] payload in
                self?.pendingDemoStore.save(payload)
            }
        )

        guard let audio = try? RealAudioEngine() else {
            lastErrorMessage = "failed to configure audio session"
            return
        }
        audioEngine = audio
        audio.onDebugEvent = { [weak self] line in
            Task { @MainActor in self?.appendAudioDebugEvent(line) }
        }

        guard let vadModelPath = Bundle.main.path(forResource: "silero_vad", ofType: "onnx"),
              let vad = try? SileroVoiceActivityDetector(modelPath: vadModelPath) else {
            lastErrorMessage = "failed to load VAD model"
            return
        }

        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad, waitingDittyAudio: WaitingDitty.audio)
        self.coordinator = coordinator
        runLoop = Task { await coordinator.start() }

        let (micStream, micContinuation) = AsyncStream<Data>.makeStream()
        micStreamContinuation = micContinuation
        micConsumerTask = Task { [weak self] in
            for await pcm in micStream {
                await self?.coordinator?.captureAudio(pcm)
            }
        }

        do {
            try await audio.startCapturing { pcm in micContinuation.yield(pcm) }
        } catch {
            lastErrorMessage = "could not start audio capture: \(error.localizedDescription). Check Settings > Privacy > Microphone."
            disconnect()
            return
        }

        isConnected = true
        startPollingState()
    }
```

Update `connectResumingIfPending()` (currently lines 322-326) to branch:

```swift
    func connectResumingIfPending() async {
        let resumingTurnId = pendingResumeTurnId
        pendingResumeTurnId = nil
        if awayFromHomeEnabled {
            await connectAwayFromHome()
        } else {
            await connect(resumingTurnId: resumingTurnId)
        }
    }
```

Add the sync step to `connect()` (the real, LAN path), right after `isConnected = true` (currently line 261, followed by `startPollingState()` on line 262) — sync happens only on a real connection, never inside `connectAwayFromHome()` itself:

```swift
        isConnected = true
        let pending = pendingDemoStore.loadAll()
        if !pending.isEmpty {
            do {
                try await coordinator.syncDemoStories(pending)
                pendingDemoStore.clear()
            } catch {
                // Best effort, same reasoning as sendObjectSeen -- left
                // for the next successful reconnect to retry; nothing
                // is lost, since PendingDemoStore was not cleared.
                print("AppModel: failed to sync demo stories: \(error)")
            }
        }
        startPollingState()
```

- [ ] **Step 4: Build the iOS app target to confirm it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -scheme TinyTalkApp -destination 'generic/platform=iOS' build 2>&1 | tail -40`

(If `Local.xcconfig` doesn't exist in this worktree yet, copy it from `Local.xcconfig.example` first — see CLAUDE.md's "Fresh-worktree gotcha".)

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift ios/TinyTalkApp/TinyTalkApp/AppModel.swift
git commit -m "$(cat <<'EOF'
feat(ios): wire DemoConnection into AppModel behind an away-from-home toggle

connectAwayFromHome() builds a DemoConnection against Groq instead of
WebSocketServerConnection against the Mac; connectResumingIfPending()
branches on the new awayFromHomeEnabled flag. A real (LAN) connect now
syncs any pending demo-mode stories to the server right after
connecting. SessionCoordinator/ClientMessage gain a thin
syncDemoStories passthrough, mirroring sendObjectSeen's existing
best-effort pattern.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: iOS — the "AWAY FROM HOME" Settings card

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.awayFromHomeEnabled`/`setAwayFromHomeEnabled(_:)` (Task 14), `KeychainStore` (Task 8).

Reuses the exact same long-press gesture that already reveals "UNDER THE HOOD" — no new discovery surface, per the spec's gating design.

- [ ] **Step 1: Add state for the revealed card and the two key fields**

Near the existing `@State private var showDebugLogSheet = false` (line 17):

```swift
    /// Revealed by the same long-press as showDebugLogSheet -- see that
    /// property's doc comment. Not persisted: resets to hidden each time
    /// Settings is reopened, same as the debug sheet requires
    /// re-discovering the gesture.
    @State private var showAwayFromHomeCard = false
    @State private var groqApiKey: String = KeychainStore.get("groqApiKey") ?? ""
    @State private var animalFactsApiKey: String = KeychainStore.get("animalFactsApiKey") ?? ""
```

- [ ] **Step 2: Extend the long-press gesture to also reveal the new card**

Change the existing `.onLongPressGesture` on `underTheHoodCard`'s `Text("UNDER THE HOOD")` (around line 121):

```swift
                .onLongPressGesture(minimumDuration: 1.0) {
                    showDebugLogSheet = true
                    showAwayFromHomeCard = true
                }
```

- [ ] **Step 3: Add the card view and insert it into the scroll layout**

Add this view, placed after `underTheHoodCard`'s definition:

```swift
    @ViewBuilder
    private var awayFromHomeCard: some View {
        if showAwayFromHomeCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("AWAY FROM HOME")
                    .font(TTA.Typography.display(12))
                    .tracking(1.5)
                    .foregroundColor(TTA.Palette.inkSoft)

                Text("For demos only, away from the home WiFi: speech and story go through Groq's cloud AI instead of your Mac. Needs a free Groq API key.")
                    .font(TTA.Typography.body(12.5))
                    .foregroundColor(TTA.Palette.inkSoft)

                SecureField("Groq API key", text: $groqApiKey)
                    .font(.system(.body, design: .monospaced))
                    .padding(11)
                    .background(TTA.Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .onChange(of: groqApiKey) { _, newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete("groqApiKey")
                        } else {
                            KeychainStore.set(newValue, forKey: "groqApiKey")
                        }
                    }

                SecureField("API Ninjas key (optional -- animal facts)", text: $animalFactsApiKey)
                    .font(.system(.body, design: .monospaced))
                    .padding(11)
                    .background(TTA.Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .onChange(of: animalFactsApiKey) { _, newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete("animalFactsApiKey")
                        } else {
                            KeychainStore.set(newValue, forKey: "animalFactsApiKey")
                        }
                    }

                Toggle(
                    "Away-from-home mode",
                    isOn: Binding(
                        get: { model.awayFromHomeEnabled },
                        set: { model.setAwayFromHomeEnabled($0) }
                    )
                )
                .disabled(groqApiKey.isEmpty)
                .tint(TTA.Palette.wood)

                if model.awayFromHomeEnabled {
                    Text("On: Elsie's brain runs in Groq's cloud right now, not your Mac.")
                        .font(TTA.Typography.body(11.5))
                        .foregroundColor(TTA.Palette.alert)
                }
            }
            .padding(16)
            .background(TTA.Palette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
```

Insert `awayFromHomeCard` into the main `VStack(spacing: 18)` (around line 26-31), right after `underTheHoodCard`:

```swift
                ScrollView {
                    VStack(spacing: 18) {
                        serverCard
                        underTheHoodCard
                        awayFromHomeCard
                        storybookPreviewCard
                        replayButton
                    }
                    .padding(20)
                }
```

- [ ] **Step 4: Make the "nothing is sent to the internet" copy honest when away-from-home mode is active**

In `serverCard`, change the fixed explanatory `Text` (around line 92):

```swift
            Text(
                model.awayFromHomeEnabled
                    ? "Away from home: Elsie's brain is in Groq's cloud right now, not your Mac."
                    : "Your Mac on the home WiFi. Speech, story and voice all run there — nothing is sent to the internet."
            )
                .font(TTA.Typography.body(13.5))
                .foregroundColor(TTA.Palette.inkSoft)
```

- [ ] **Step 5: Build the iOS app target**

Run: `cd ios/TinyTalkApp && xcodebuild -scheme TinyTalkApp -destination 'generic/platform=iOS' build 2>&1 | tail -40`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat(ios): add the AWAY FROM HOME settings card

Reachable only via the same hidden long-press that already reveals
UNDER THE HOOD -- no new discovery surface. Groq/API-Ninjas keys go
straight to Keychain via onChange, never UserDefaults; the toggle is
disabled until a Groq key is present. The server card's "nothing is
sent to the internet" copy now reflects reality when this is on.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: On-device verification

Every prior task is unit-tested against fakes/stubs — none of it has touched a real Groq account, a real API Ninjas account, or real on-device speech synthesis. Per this repo's "Testing changes on-device" convention, this task is manual, not TDD, and is the actual acceptance test for the feature.

**Where the code lives:** `.claude/worktrees/away-from-home-demo-mode/` (this worktree), branch `worktree-away-from-home-demo-mode`.

**Does the server need restarting?** Yes — Task 1 changed `server/tinytalk/protocol.py`, `story_store.py`, and `session.py`. Kill and restart the running server before testing the sync step specifically:

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/away-from-home-demo-mode/server
source .venv/bin/activate
python -m tinytalk.app
```

**Does the iOS app need rebuilding?** Yes — every iOS task in this plan changes app code. Fresh Build & Run from Xcode is required; the currently-installed build predates this entire feature.

**Fresh-worktree gotcha:** `Local.xcconfig` is gitignored and won't exist in this worktree yet. Before building:

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/away-from-home-demo-mode/ios/TinyTalkApp
cp Local.xcconfig.example Local.xcconfig
xcodegen generate
open TinyTalkApp.xcodeproj
```

Set your Apple Developer Team under Signing & Capabilities (same Team ID as any other worktree — it's the household's own Apple ID, not a secret).

**Prerequisites specific to this feature:**
- A free Groq API key: https://console.groq.com/keys
- Optionally, a free API Ninjas key for animal facts: https://api-ninjas.com (100 requests/hour free tier)
- Verify `llama-3.1-8b-instant` and `whisper-large-v3-turbo` are still active models in the Groq console before testing — Groq's free-tier lineup changes over time (same caveat `config.py`'s own comment already carries for the LAN path).

**What to actually do and look for:**

1. **Reaching the toggle.** Open Settings, long-press "UNDER THE HOOD" for one second. Confirm both the debug log sheet opens (existing behavior, unchanged) AND a new "AWAY FROM HOME" card appears in the Settings scroll view once you dismiss the sheet. A short tap must do neither.
2. **Gating on the key.** With the Groq field empty, confirm the "Away-from-home mode" toggle is disabled (can't be turned on). Paste a real Groq key into the field, confirm the toggle becomes enabled.
3. **Turn off WiFi/cellular data to the Mac** (or just don't bother connecting to the home network at all) — the whole point is proving no home server is reachable. Turn the away-from-home toggle on. Confirm the server card's text changes to the "Elsie's brain is in Groq's cloud" copy.
4. **Happy path, full turn.** Tap "Create a Story" (or however Landing starts a story in this build). Talk to Elsie — a full sentence, not just a word. Confirm: `listening` → `waitingForReply` → `speaking` state transitions happen (same UI as the real server path), "Heard:" shows a real transcript, "Reply:" shows a real, in-character reply, and you actually hear the reply spoken (on-device TTS — this is the part no unit test could verify; listen for garbling, wrong pitch/speed, or silence, which would indicate the `AVAudioConverter` format-conversion step from Task 12 needs adjustment).
5. **Barge-in.** While Elsie is speaking, talk over her. Confirm playback stops instantly, same as the real server path — this exercises `DemoConnection`'s `interrupt` handling and confirms the "hanging in-flight Groq call" cancellation from Task 13 actually works on a real network call, not just a test double.
6. **Multi-turn story arc.** Keep going for several turns. Confirm the story has a beginning/middle/end shape (introduces a problem, develops it, resolves it) — this is `StoryArc`'s ported staging guidance actually reaching a real LLM. Let it run to a natural "The end."
7. **Animal facts (if an API Ninjas key was entered).** Mention a known animal (e.g., "a fox"). Confirm a real fact about it gets woven into the next reply, not just generic filler — check the server-independent `AnimalFactsCache` file exists afterward (`~/Library/.../Application Support/animal_facts_cache.json` inside the app's container, findable via Xcode's Devices window > Download Container).
8. **Object recognition.** Take a photo mid-story (same camera button as the real server path). Confirm the recognized object's identity shows up woven into the next reply.
9. **Safety filter.** This is harder to force honestly — if a reply ever contains something that reads as off (violence, scary content, profanity), confirm it was replaced with the gentle fallback text ("Hmm, let's take the story somewhere else!") rather than spoken as-is. Not expected to trigger in normal use; noted so you know what correct behavior looks like if it ever does.
10. **Sync on reconnect.** After the story concludes (or mid-story — either is fine), turn the away-from-home toggle back off and reconnect to the real home server (WiFi back on, Terminal 2 running). Confirm the story shows up as a new file under `server/data/stories/` (`ls -t server/data/stories/ | head -1`), with `"rewrite_status": "pending"` initially, moving to `"done"` a short while later once the background rewrite completes (same mechanism a live home story already uses — watch Terminal 2's log for `"story saved to..."`/rewrite completion lines).
11. **Backgrounding during demo mode (the disclosed limitation).** Start a turn, then background the app before the reply finishes. Confirm the app doesn't crash or hang — expected behavior is that turn is simply lost (no reply ever arrives when you return), not a resumed reply. If it instead crashes or gets stuck in a bad state, that's a real bug, not the accepted limitation.

If steps 4-6 work but sound quality in step 4 is genuinely bad (not just "a bit robotic," but actually broken/garbled), that's the signal to revisit Task 12's `AVAudioConverter` usage before considering this feature done — everything upstream of the audio itself was already verified against real Groq API calls in this same pass.

## Self-review

- **Spec coverage:** every section of `docs/superpowers/specs/2026-09-09-away-from-home-demo-mode-design.md` maps to a task above — Architecture → Tasks 2-13, Gating & credential storage → Tasks 8, 15, Persistence/sync → Tasks 1, 13, 14, Error handling → Task 13 (in-turn), Task 14 (sync best-effort), Testing approach → every task's own unit tests plus Task 16.
- **Scope corrections from the spec, disclosed inline rather than silently absorbed:** the spec was written against a stale local checkout and didn't account for the storybook rewrite pipeline, animal facts, or object recognition that `session.py`'s real `_run_turn` also does — Tasks 1, 6, 11 close that gap, per the user's explicit choice to include animal facts and object recognition.
- **Placeholder scan:** no `TBD`/`TODO` remains; the one intentionally-partial code block (Task 6's `_KNOWN_ANIMALS` transcription) is accompanied by an explicit, complete instruction for finishing it, not a hand-wave — data-table transcription from a known source, not a design decision left open.
- **Type consistency:** `ClientMessage`/`ServerEvent` case names and associated-value shapes used in Tasks 13-15 (`.speechStart(turnId:)`, `.transcriptFinal(_:turnId:)`, etc.) match `Protocol.swift`'s actual current definitions, verified by reading that file directly rather than assumed from the spec. `PendingDemoStoryPayload`/`PendingDemoStoryTurn` (Task 7) are used identically in Tasks 13, 14, and 15's wire encoding.

