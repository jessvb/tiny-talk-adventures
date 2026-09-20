# Demo Mode Parity — Phase 1: Local Storybook + Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Away from home, the whole story-to-storybook loop works through the screens that already exist — story-length settings apply, "Finish this story" works, The End appears by itself, Library lists the story, Reading shows its pages, 🔊 narrates a page — and a finished storybook syncs to the Mac intact instead of being redone.

**Architecture:** `DemoConnection` becomes a local "server" for story browsing: it answers the same wire messages and emits the same events the Mac does, backed by a new on-phone `DemoStoryLibrary` (a file-backed `LocalStoryStore` plus a Swift port of the server's storybook rewrite, running on the existing Groq `ChatCompleting` seam). `SessionCoordinator`, `AppModel`'s Library/Reading/The End plumbing and every SwiftUI screen stay unchanged. At sync time the phone uploads each finished storybook with its transcript; a new server module validates it as untrusted input and stores it, falling back to today's transcript rewrite on any rejection. A test with an exhaustive `switch` over `ClientMessage` makes the silent-no-op class of bug (#24) impossible to reintroduce unnoticed.

**Tech Stack:** Swift 6 / XCTest in the `ios/TinyTalkCore` SwiftPM package (no new dependencies), the SwiftUI app target (`AppModel` only), Python 3 + pytest + Pillow in `server/` (Pillow is already a dependency; nothing new to install).

**Spec:** `docs/superpowers/specs/2026-09-19-demo-mode-parity-design.md` (approved 2026-09-19; PR #44). Read it first — this plan implements its "Phase 1". The follow-on plan is `docs/superpowers/plans/2026-09-20-demo-mode-phase-2-away-illustrations.md`.

## Deviations from the approved spec (flag both in the PR)

1. **Phasing refinement.** The spec puts `get_page_image` and "uploading images with the sync payload" in Phase 2. They ship here instead, because `DemoConnection` is one file and the sync payload and server validator define the wire format once (the spec's own Phase 1 text already says the validator "handles images from the start"). They are unit-tested here with fake illustrators and synthetic images; Phase 2 is then only the image *source* and its wiring.
2. **Disk-write failures are swallowed, not logged.** The spec's error-handling section says a local disk write failure is "logged to the debug log". `LocalStoryStore` lives in the SwiftPM core, uses `try?` exactly like the existing `PendingDemoStore`, and has no debug-log channel. The failure mode is benign: a story that could not be saved locally is simply not browsable away from home, and it still syncs from the untouched `PendingDemoStore` queue. If the household wants the log line, it is a small follow-up (an `onDebugEvent` hook on the store, wired in `AppModel`).

## Global Constraints

Copied from the spec and the repo's `CLAUDE.md`; every task below is subject to them.

- **Nothing new is mandatory.** "Phase 1 needs only the Groq key demo mode already requires." No new SwiftPM or pip dependencies; no new accounts.
- **Server change is limited to the sync endpoint's validator.** "Any change to the server's live-conversation or live-rewrite path" is out of scope.
- **Server validator limits (verbatim):** "title 1–200 chars; 1–10 pages; each page text 1–2000 chars; each image ≤ 1.5 MB decoded"; images must decode with PIL as JPEG or PNG "and have a pixel area of at most 4.2 million (2048×2048), checked from the header before decoding"; the server "re-encodes to PNG under a server-generated filename (`{story_id}-page-{i}.png`)"; "raw client bytes are never written to disk"; `safety.find_blocked` runs over the title, every page and the derived epilogue and "any hit rejects the whole storybook"; the epilogue is "recomputed from `shared_facts`… the uploaded text is ignored"; on any rejection the story stays `pending` and today's `_run_synced_rewrite` runs.
- **Settings bounds (verbatim):** "turns 4–12, pages 3–10", applied to the **next** story only, "never retroactive".
- **The epilogue is never model-written:** `"And one true thing we learned about the {animal}: {fact}"` from the first shared fact, otherwise none.
- **One storybook build at a time**, process-wide ("Builds are still serialized so rewrites never overlap"). Groq's free tier is 30 requests/minute; a story costs roughly 1–3 rewrite calls, sequentially.
- **No gate on new stories while a rewrite runs** in demo mode (cloud backends have no shared memory budget).
- **`PendingDemoStore` is unchanged** and remains the sync queue of transcript payloads; the local storybook is an enrichment keyed by the same id.
- **Wire compatibility both ways:** an old server ignores the unknown `storybook` key; an old phone sends none.
- **Every `ClientMessage` case gets an explicit demo-mode decision**; `syncDemoStories` is an explicit no-op, "not folded into a shared catch-all".
- **Kid safety:** any text shown or spoken to the child passes `Safety` (the storybook rewrite retries when `Safety.findBlocked` flags its output).
- **Repo rules (`CLAUDE.md`):** Python only inside a venv (never global `pip`); small commits, one per task; never push to `main`; a PR for the household to review before merge; after implementing, give concrete on-device test instructions (Task 12).

## How to use this plan

**Provenance.** Every code block below was extracted programmatically from an implementation that was built and verified end to end on a scratch branch (`scratch-demo-mode-verified`, local only: `d43aa4a` = Phase 1, `62b55d3` = Phase 2): 333 Swift tests (362 after Phase 2) with 0 failures, 463 server tests passing, `xcodebuild` BUILD SUCCEEDED, and mutation checks proving the key regression tests can fail. Copy blocks exactly. If a block does not compile or a test does not pass, the cause is a transcription slip or a moved base, not the block — stop and investigate; do not "improve" it.

**Block conventions.**
- A `swift` / `python` block under "Create" is the **complete file**.
- A `diff` block is a unified diff against the file **as it is on your branch right now**: lines starting `+` are added, `-` removed, other lines are context that must match. Line numbers in `@@` headers may be off by a few lines; match on content.
- A block introduced with "Append" is added at the end of the named file, after a blank line.

**Test commands.** `swift test` prints roughly a million log lines from a ditty-loop test, so **always redirect to a file and grep the summary**. Two plain commands per run (use any scratch path unique to your session):

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter SomeTestClass > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | grep -v "ditty loop" | tail -5
```

The file's last lines are a Swift Testing footer ("0 tests"); the XCTest count is the last `Executed N tests` line. Log lines containing "send failed" come from tests that exercise failure paths and are not failures. One test, `testPageAudioDittyStopsOnStopPageAudio`, is a known flake (~2 in 40 runs on unmodified `main`): if it is the only failure in a full run, re-run it alone before concluding anything.

Server tests run with `main`'s venv interpreter **from this worktree's `server/` directory** (`python -m` puts the working directory first on the import path, so `tinytalk` resolves to this worktree's code):

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/server
```
```bash
~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests -q -p no:cacheprovider
```

Sanity check once: `~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -c "import tinytalk; print(tinytalk.__file__)"` must print a path under `.claude/worktrees/demo-mode-phase-1/`.

**Commits.** One commit per task, using `git -C <worktree>` with plain single commands (some harnesses refuse compound command lines). Add your harness's attribution trailers to each commit message.

## Preflight (do once, before Task 1)

- [ ] **Confirm you are on the right branch, clean.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 status --short --branch
```

Expected: `## worktree-demo-mode-phase-1` and no modified files (untracked/ignored files such as `ios/TinyTalkApp/Local.xcconfig` are fine).

- [ ] **Record the baselines** (both must be green before you start). On the base this plan was verified against (`5b9700a`, the spec commit) they are **256** Swift tests and **423** server tests. Use the two test-command recipes above with no `--filter` / with `tests`.

If `main` has moved since (PR #43 docs refresh, PR #44 spec, and draft PR #45's bugfix batch were all open when this was written), merge it first (`git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 merge origin/main`), re-run the baselines, and read every count in this plan as **baseline + N**: the per-task "+N" figures are exact, the absolute totals assume the 256 / 423 baselines. Overlap notes: PR #43 rewrites a comment inside `DemoConnection.swift`'s `send(_:)` (Task 6 replaces that whole file — keep the comment intent: `syncDemoStories` is never sent to a `DemoConnection`); PR #45 edits `AppModel.swift` and `SessionCoordinator.swift`, so if it has merged, Task 11's `AppModel.swift` hunks may need re-anchoring by content rather than by line number — the changes are self-contained and each hunk states its intent in its comments.

## File Structure

**Create (all under `ios/TinyTalkCore/Sources/TinyTalkCore/` unless noted)**

| File | Responsibility |
|---|---|
| `StorybookWriter.swift` | Swift port of `server/tinytalk/storybook.py`'s rewrite: same prompts, tolerant JSON extraction, shared 3-attempt retry budget, fact-derived epilogue. Returns `nil` for "failed". |
| `LocalStoryStore.swift` | `LocalStoryPage` / `LocalStory` records and the lock-guarded, file-backed store (`<id>.json` + `<id>/page-<i>.jpg`) in Application Support. |
| `DemoStoryLibrary.swift` | The on-phone library: save a finished story, list/detail/page text/page image in the shapes the UI already consumes, one-at-a-time storybook builds, sync payloads. Also the `StoryIllustrating` seam Phase 2 plugs into. |
| `SerialAsyncQueue.swift` | A tiny chained-`Task` queue that runs async work strictly one at a time (actors don't serialize across `await`s). |
| `server/tinytalk/synced_storybook.py` | Validates an uploaded storybook as untrusted input and stores it (or rejects it so the caller falls back to a transcript rewrite). |
| `Tests/TinyTalkCoreTests/DemoFakes.swift` | Shared test doubles, built up task by task. |
| `Tests/TinyTalkCoreTests/StorybookWriterTests.swift`, `LocalStoryStoreTests.swift`, `DemoStoryLibraryTests.swift`, `DemoProtocolParityTests.swift`, `server/tests/test_synced_storybook.py` | Tests for the above. |

**Modify**

| File | Change |
|---|---|
| `Safety.swift` | Add `findBlocked(_:)` (a port of `safety.find_blocked`); `isSafe` reuses it. |
| `SavedStory.swift` | `RewriteStatus` and `IllustrationsStatus` become `Codable` (the store persists them). |
| `PendingDemoStory.swift` | Sync types `DemoSyncPage` / `DemoSyncStorybook` and an optional `storybook` on `PendingDemoStoryPayload`. |
| `StoryArc.swift` | `hasStarted`, so a settings change can tell an unstarted arc from one in progress. |
| `DemoConnection.swift` | Becomes the local "server": settings, "Finish this story", list/get, page audio and images, `rewriting_*` events. |
| `Protocol.swift` | `sync_demo_stories` encodes the optional `storybook`. |
| `server/tinytalk/session.py` | `handle_sync_demo_stories` consults the validator before scheduling a rewrite. |
| `ios/TinyTalkApp/TinyTalkApp/AppModel.swift` | Wires the library into demo mode, resets library state on a backend switch, syncs storybooks. (No unit-test target exists for the app; it is verified by a build and on-device.) |

---

### Task 1: `Safety.findBlocked`

The storybook safety-retry needs to know *which* terms were flagged, not just that something was. `Safety.isSafe` only answers yes/no.

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Safety.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SafetyTests.swift`

**Interfaces:**
- Consumes: the existing blocked-terms list and safe-phrase masking already in `Safety.swift`.
- Produces: `Safety.findBlocked(_ text: String) -> [String]` — the blocked terms found in `text`: safe phrases masked first, lowercased, distinct, in first-appearance order. `Safety.isSafe(_:)` keeps its behaviour (it is now `findBlocked(text).isEmpty`).

- [ ] **Step 1: Add the failing tests.** Apply this diff to `SafetyTests.swift`:

````diff
--- a/ios/TinyTalkCore/Tests/TinyTalkCoreTests/SafetyTests.swift
+++ b/ios/TinyTalkCore/Tests/TinyTalkCoreTests/SafetyTests.swift
@@ -134,4 +134,43 @@ final class SafetyTests: XCTestCase {
         XCTAssertTrue(Safety.isSafe("The race had begun at last."))
         XCTAssertTrue(Safety.isSafe("She was a knifemaker's daughter."))
     }
+
+    // MARK: - findBlocked (mirrors test_safety.py's find_blocked tests)
+
+    func testFindBlockedReturnsEmptyForSafeText() {
+        XCTAssertEqual(Safety.findBlocked("The fox ran through the sunny meadow."), [])
+    }
+
+    func testFindBlockedNamesTheMatchedWord() {
+        // The storybook safety-retry needs to tell the model specifically
+        // what to avoid -- a bare true/false from isSafe() isn't enough.
+        XCTAssertEqual(Safety.findBlocked("He picked up the knife."), ["knife"])
+    }
+
+    func testFindBlockedNamesEveryDistinctMatchInOrder() {
+        XCTAssertEqual(Safety.findBlocked("There was blood on the knife."), ["blood", "knife"])
+    }
+
+    func testFindBlockedListsARepeatedWordOnlyOnce() {
+        XCTAssertEqual(Safety.findBlocked("A knife, another knife, and one more knife."), ["knife"])
+    }
+
+    func testFindBlockedLowercasesWhatItReports() {
+        XCTAssertEqual(Safety.findBlocked("The hunter had a GUN."), ["gun"])
+    }
+
+    func testFindBlockedRespectsTheSafePhraseMask() {
+        XCTAssertEqual(Safety.findBlocked("She wished upon a shooting star."), [])
+        XCTAssertEqual(
+            Safety.findBlocked("He wished on a shooting star while shooting arrows at the target."),
+            ["shooting"]
+        )
+    }
+
+    func testIsSafeIsConsistentWithFindBlocked() {
+        // isSafe() must stay a thin wrapper -- no separate matching logic
+        // that could drift from what findBlocked() reports.
+        XCTAssertEqual(Safety.isSafe("He picked up the knife."), Safety.findBlocked("He picked up the knife.").isEmpty)
+        XCTAssertEqual(Safety.isSafe("A gentle story."), Safety.findBlocked("A gentle story.").isEmpty)
+    }
 }
````

- [ ] **Step 2: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter SafetyTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines saying `findBlocked` is not a member of `Safety`.

- [ ] **Step 3: Implement.** Apply this diff to `Safety.swift`:

````diff
--- a/ios/TinyTalkCore/Sources/TinyTalkCore/Safety.swift
+++ b/ios/TinyTalkCore/Sources/TinyTalkCore/Safety.swift
@@ -56,11 +56,27 @@ public enum Safety {
         return try! NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
     }()
 
-    public static func isSafe(_ text: String) -> Bool {
+    /// Every distinct blocked word/phrase matched in `text`, lowercased, in
+    /// the order each first appears -- mirrors safety.py's find_blocked().
+    /// Lets a caller (StorybookWriter's safety-retry loop, DemoConnection's
+    /// forced-conclude retry) tell the model specifically what to avoid,
+    /// not just that something was wrong. The safe-phrase mask runs first,
+    /// exactly as in the Python original.
+    public static func findBlocked(_ text: String) -> [String] {
         let fullRange = NSRange(text.startIndex..., in: text)
         let masked = safePattern.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
         let maskedRange = NSRange(masked.startIndex..., in: masked)
-        return blockedPattern.firstMatch(in: masked, range: maskedRange) == nil
+        var found: [String] = []
+        for match in blockedPattern.matches(in: masked, range: maskedRange) {
+            guard let range = Range(match.range, in: masked) else { continue }
+            let term = String(masked[range]).lowercased()
+            if !found.contains(term) { found.append(term) }
+        }
+        return found
+    }
+
+    public static func isSafe(_ text: String) -> Bool {
+        findBlocked(text).isEmpty
     }
 
     public static func filterReply(_ text: String) -> String {
````

- [ ] **Step 4: Run the tests and watch them pass.** Same two commands as Step 2. Expected: `Executed 31 tests, with 0 failures` (24 existing + 7 new).

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/Safety.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/SafetyTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): Safety.findBlocked, a port of safety.find_blocked" -m "Returns the blocked terms in a text (safe phrases masked first) so the storybook safety retry can tell the model what to leave out. isSafe now reuses it."
```

---

### Task 2: `StorybookWriter` (the storybook rewrite, ported)

A faithful Swift port of `server/tinytalk/storybook.py`'s rewrite pass. Read that file alongside this task — the prompts, the tolerant `{…}` extraction and the shared attempt budget are deliberately identical, and the tests mirror `server/tests/test_storybook.py`.

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/StorybookWriter.swift`
- Create: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoFakes.swift` (first slice: `ScriptedChatClient`)
- Create: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/StorybookWriterTests.swift`

**Interfaces:**
- Consumes: `ChatCompleting.complete(messages: [[String: String]]) async throws -> String` (`DemoInterfaces.swift`); `Safety.findBlocked` (Task 1); `PendingDemoStoryTurn(speaker:text:interrupted:)`.
- Produces: `WrittenStorybook(title: String, pages: [String], epilogue: String?)`; `StorybookWriter(chat: any ChatCompleting, maxAttempts: Int = StorybookWriter.defaultMaxAttempts)` with `func write(turns: [PendingDemoStoryTurn], sharedFacts: [[String]], pageCount: Int) async -> WrittenStorybook?` (`nil` = failed: unparseable or unsafe after every attempt, or the chat call threw). Test double `ScriptedChatClient` (replies one per call, the last repeating; exposes `callCount`, `receivedMessages`, and an optional `error` to throw).

- [ ] **Step 1: Create the shared fakes file with its first double.**

````swift
import Foundation
@testable import TinyTalkCore

/// Replies with a scripted sequence, one reply per call. If more calls
/// happen than replies were given, the LAST reply repeats -- the same
/// convention as the server tests' FakeRewriteLlm, so a test that wants a
/// specific attempt count passes exactly that many replies and asserts on
/// `callCount`. Records every messages array it receives.
final class ScriptedChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String]
    private var _receivedMessages: [[[String: String]]] = []
    /// Set before use; when non-nil every call throws it.
    var error: Error?

    init(_ replies: String...) {
        self.replies = replies
    }

    var receivedMessages: [[[String: String]]] { lock.withLock { _receivedMessages } }
    var callCount: Int { lock.withLock { _receivedMessages.count } }

    func complete(messages: [[String: String]]) async throws -> String {
        if let error { throw error }
        return lock.withLock {
            _receivedMessages.append(messages)
            guard !replies.isEmpty else { return "" }
            return replies[min(_receivedMessages.count - 1, replies.count - 1)]
        }
    }
}
````

- [ ] **Step 2: Create the tests.**

````swift
import XCTest
@testable import TinyTalkCore

/// Mirrors server/tests/test_storybook.py's cases for storybook.py -- the
/// Swift port is verified against the same behavior, not assumed to match.
final class StorybookWriterTests: XCTestCase {
    private let turns = [
        PendingDemoStoryTurn(speaker: "child", text: "tell me about a fox", interrupted: false),
        PendingDemoStoryTurn(speaker: "agent", text: "Once there was a clever fox.", interrupted: false),
    ]

    private func json(title: String = "A Story", pages: [String] = ["Once upon a time."], epilogue: String? = nil) -> String {
        var object: [String: Any] = ["title": title, "pages": pages.map { ["text": $0] }]
        if let epilogue { object["epilogue"] = epilogue }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func write(
        _ chat: ScriptedChatClient,
        facts: [[String]] = [],
        pageCount: Int = 5,
        maxAttempts: Int = StorybookWriter.defaultMaxAttempts
    ) async -> WrittenStorybook? {
        await StorybookWriter(chat: chat, maxAttempts: maxAttempts)
            .write(turns: turns, sharedFacts: facts, pageCount: pageCount)
    }

    // MARK: - happy path

    func testParsesAValidRewriteAndGroundsTheEpilogueInTheRealFact() async {
        let chat = ScriptedChatClient(
            json(title: "Pip the Noisy Fox", pages: ["Once there was a fox.", "The end."],
                 epilogue: "Foxes have excellent hearing.")
        )
        let result = await write(chat, facts: [["fox", "foxes have excellent hearing"]])
        XCTAssertEqual(result?.title, "Pip the Noisy Fox")
        XCTAssertEqual(result?.pages, ["Once there was a fox.", "The end."])
        // Formatted from shared facts, NOT the model's own epilogue text.
        XCTAssertEqual(result?.epilogue, "And one true thing we learned about the fox: foxes have excellent hearing")
    }

    func testToleratesProseWrappedAroundTheJSON() async {
        let chat = ScriptedChatClient(
            "Sure, here you go:\n" + json(title: "Pip") + "\nHope that helps!"
        )
        let result = await write(chat)
        XCTAssertEqual(result?.title, "Pip")
    }

    func testOmitsTheEpilogueWhenNoFactsWereShared() async {
        let chat = ScriptedChatClient(json())
        let result = await write(chat)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.epilogue)
    }

    func testDiscardsAFabricatedEpilogueWhenNoFactsWereShared() async {
        let chat = ScriptedChatClient(json(epilogue: "Foxes can fly to the moon."))
        let result = await write(chat)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.epilogue, "a model-invented epilogue must never be used")
    }

    func testIgnoresTheModelsOwnEpilogueEvenWhenFactsWereShared() async {
        let chat = ScriptedChatClient(json(epilogue: "Foxes can fly to the moon."))
        let result = await write(chat, facts: [["owl", "owls can turn their heads far around"]])
        XCTAssertEqual(result?.epilogue, "And one true thing we learned about the owl: owls can turn their heads far around")
    }

    // MARK: - prompt shape

    func testPromptCarriesTheTranscriptPageCountAndKidSafetyFraming() async {
        let chat = ScriptedChatClient(json())
        _ = await write(chat, pageCount: 3)
        let messages = chat.receivedMessages[0]
        XCTAssertEqual(messages[0]["role"], "system")
        let system = messages[0]["content"] ?? ""
        XCTAssertTrue(system.contains("Keep everything gentle and wholesome"))
        // The live-dialogue rules must NOT leak into a one-shot rewrite:
        // they made the model end pages with "what should we do next".
        XCTAssertFalse(system.contains("asking the child what should happen next"))
        let user = messages[1]["content"] ?? ""
        XCTAssertTrue(user.contains("Child: tell me about a fox"))
        XCTAssertTrue(user.contains("Storyteller: Once there was a clever fox."))
        XCTAssertTrue(user.contains("exactly 3 pages"))
    }

    func testFactsAppearInThePromptAndAddTheEpilogueKeyOnlyWhenPresent() async {
        let withFacts = ScriptedChatClient(json())
        _ = await write(withFacts, facts: [["fox", "foxes have excellent hearing"]])
        let promptWithFacts = withFacts.receivedMessages[0][1]["content"] ?? ""
        XCTAssertTrue(promptWithFacts.contains("Real facts this story actually used: fox: foxes have excellent hearing."))
        XCTAssertTrue(promptWithFacts.contains(#""epilogue": "one true, real fact from the story, in one sentence""#))

        let withoutFacts = ScriptedChatClient(json())
        _ = await write(withoutFacts)
        let promptWithoutFacts = withoutFacts.receivedMessages[0][1]["content"] ?? ""
        XCTAssertFalse(promptWithoutFacts.contains("Real facts this story actually used"))
        XCTAssertFalse(promptWithoutFacts.contains(#""epilogue""#))
    }

    // MARK: - failure handling

    func testReturnsNilOnUnparseableOutputAfterEveryAttempt() async {
        let chat = ScriptedChatClient("this is not json at all")
        let result = await write(chat)
        XCTAssertNil(result)
        XCTAssertEqual(chat.callCount, StorybookWriter.defaultMaxAttempts)
    }

    func testReturnsNilWhenTheChatClientThrows() async {
        let chat = ScriptedChatClient(json())
        chat.error = DemoConnectionError.groqError("boom")
        let result = await write(chat)
        XCTAssertNil(result)
    }

    func testRetriesAndSucceedsOnceALaterAttemptParses() async {
        let chat = ScriptedChatClient("this is not json at all", json(title: "A Story"))
        let result = await write(chat)
        XCTAssertEqual(result?.title, "A Story")
        XCTAssertEqual(chat.callCount, 2)
    }

    func testParseRetryAsksForValidJSONAgain() async {
        let chat = ScriptedChatClient("this is not json at all", json())
        _ = await write(chat)
        let retry = chat.receivedMessages[1].last?["content"] ?? ""
        XCTAssertTrue(retry.lowercased().contains("valid json"))
    }

    // MARK: - kid-safety retry

    func testRetriesAndSavesOnceALaterAttemptIsSafe() async {
        let chat = ScriptedChatClient(json(title: "The Knife Fight"), json(title: "The Big Adventure"))
        let result = await write(chat)
        XCTAssertEqual(result?.title, "The Big Adventure")
        XCTAssertEqual(chat.callCount, 2)
    }

    func testSafetyRetryTellsTheModelWhatToAvoid() async {
        let chat = ScriptedChatClient(json(title: "The Knife Fight"), json(title: "A Story"))
        _ = await write(chat)
        let retry = chat.receivedMessages[1].last?["content"] ?? ""
        XCTAssertTrue(retry.lowercased().contains("knife"))
    }

    func testGivesUpAfterTheConfiguredNumberOfSafetyAttempts() async {
        let chat = ScriptedChatClient(json(title: "The Knife Fight"))
        let result = await write(chat)
        XCTAssertNil(result)
        XCTAssertEqual(chat.callCount, StorybookWriter.defaultMaxAttempts)
    }

    func testAnUnsafePageFailsTheStorybook() async {
        let chat = ScriptedChatClient(json(pages: ["The knight had to kill the dragon."]))
        let result = await write(chat)
        XCTAssertNil(result)
    }

    func testAnUnsafeGroundedEpilogueFailsTheStorybook() async {
        // The epilogue comes from the real shared fact, so an unsafe FACT
        // must be caught even though the model's own text is spotless.
        let chat = ScriptedChatClient(json())
        let result = await write(chat, facts: [["shark", "sharks can kill"]])
        XCTAssertNil(result)
    }

    func testMaxAttemptsIsHonoured() async {
        let chat = ScriptedChatClient("not json")
        _ = await write(chat, maxAttempts: 1)
        XCTAssertEqual(chat.callCount, 1)
    }
}
````

- [ ] **Step 3: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter StorybookWriterTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `cannot find 'StorybookWriter' in scope`.

- [ ] **Step 4: Implement.**

````swift
import Foundation

/// A finished storybook rewrite -- what StorybookWriter returns on success.
public struct WrittenStorybook: Equatable, Sendable {
    public let title: String
    public let pages: [String]
    /// Always derived from a story's real shared facts, never model-written
    /// -- see StorybookWriter.write(). nil when no facts were shared.
    public let epilogue: String?

    public init(title: String, pages: [String], epilogue: String?) {
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
    }
}

/// Swift port of server/tinytalk/storybook.py's rewrite pass: turns a
/// finished story's raw transcript into picture-book pages (a title, prose
/// pages, and an optional fact-grounded epilogue) using the phone's own
/// chat client (Groq, in demo mode). Same prompts, same tolerant JSON
/// extraction, and the same shared attempt budget for its two retryable
/// failure modes (unparseable reply, kid-safety flag) as the Python
/// original -- see that file for the rationale behind each of them.
public struct StorybookWriter: Sendable {
    /// Mirrors config.STORYBOOK_REWRITE_RETRY_ATTEMPTS.
    public static let defaultMaxAttempts = 3

    static let systemPrompt =
        "You are writing a children's picture-book story for a young child, " +
        "aged about three to six, to read or be read to again later.\n" +
        "\n" +
        "Rules you always follow:\n" +
        "- Keep everything gentle and wholesome. No violence, no weapons, no death, " +
        "no frightening peril.\n" +
        "- Keep the story grounded in the real world: no magic, no talking " +
        "plants or objects, no impossible physics. Animal characters can " +
        "talk and think like people, but everything else about the world " +
        "should be realistic.\n" +
        "- Write plain prose only: no emoji, no asterisks, no stage directions."

    static let parseRetryPrompt =
        "That wasn't valid JSON. Reply again with ONLY the JSON object, in the " +
        "exact same shape as before -- no other text before or after it."

    static func safetyRetryPrompt(terms: String) -> String {
        "That version isn't appropriate for a young child's storybook -- it " +
        "mentioned: \(terms). Rewrite the whole story again from scratch, same " +
        "characters and events, but leave out any mention of that. Reply with " +
        "ONLY the JSON object again, in the same shape as before."
    }

    private let chat: any ChatCompleting
    private let maxAttempts: Int

    public init(chat: any ChatCompleting, maxAttempts: Int = StorybookWriter.defaultMaxAttempts) {
        self.chat = chat
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Returns nil for "failed": the reply never parsed, or stayed unsafe,
    /// after every attempt -- or the chat call itself threw. The caller
    /// keeps the raw transcript either way (same as storybook.py's
    /// "failed" status leaving `turns` untouched).
    public func write(turns: [PendingDemoStoryTurn], sharedFacts: [[String]], pageCount: Int) async -> WrittenStorybook? {
        let facts: [(animal: String, fact: String)] = sharedFacts.compactMap { pair in
            pair.count == 2 ? (animal: pair[0], fact: pair[1]) : nil
        }
        // The spec requires the epilogue to always be a real fact the story
        // actually shared, never something the model invents -- so the
        // model's own "epilogue" text (whatever it is) is never used. When
        // real facts exist it is always formatted here, from the first one;
        // otherwise it is omitted, regardless of what the model volunteered.
        let epilogue: String? = facts.first.map {
            "And one true thing we learned about the \($0.animal): \($0.fact)"
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": Self.buildPrompt(turns: turns, facts: facts, pageCount: pageCount)],
        ]

        for attempt in 1...maxAttempts {
            let raw: String
            do {
                raw = try await chat.complete(messages: messages)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }

            guard let parsed = Self.parse(raw) else {
                if attempt < maxAttempts {
                    messages.append(["role": "assistant", "content": raw])
                    messages.append(["role": "user", "content": Self.parseRetryPrompt])
                    continue
                }
                return nil
            }

            let textsToCheck = [parsed.title] + parsed.pages + (epilogue.map { [$0] } ?? [])
            var blocked: [String] = []
            for text in textsToCheck {
                for term in Safety.findBlocked(text) where !blocked.contains(term) {
                    blocked.append(term)
                }
            }
            blocked.sort()

            if blocked.isEmpty {
                return WrittenStorybook(title: parsed.title, pages: parsed.pages, epilogue: epilogue)
            }
            if attempt < maxAttempts {
                messages.append(["role": "assistant", "content": raw])
                messages.append(["role": "user", "content": Self.safetyRetryPrompt(terms: blocked.joined(separator: ", "))])
            }
        }
        return nil
    }

    static func buildPrompt(
        turns: [PendingDemoStoryTurn], facts: [(animal: String, fact: String)], pageCount: Int
    ) -> String {
        let transcript = turns.map { turn -> String in
            let speaker = turn.speaker == "child" ? "Child" : "Storyteller"
            return "\(speaker): \(turn.text)"
        }.joined(separator: "\n")

        var factsSection = ""
        var epilogueKey = ""
        if !facts.isEmpty {
            let factsList = facts.map { "\($0.animal): \($0.fact)" }.joined(separator: "; ")
            factsSection =
                "Real facts this story actually used: \(factsList). If natural, " +
                "close with one of these as a one-sentence epilogue, phrased for " +
                "a young child.\n\n"
            epilogueKey = #", "epilogue": "one true, real fact from the story, in one sentence""#
        }

        return
            "You are turning a story a child and a storyteller made up together " +
            "into a picture-book version for the child to read again later.\n\n" +
            "Here is the full conversation, in order:\n\(transcript)\n\n" +
            factsSection +
            "Rewrite this as a children's storybook: continuous third-person " +
            "narration that captures the same characters, events, and facts -- " +
            "NOT a dialogue transcript, and don't write \"the child said\" or " +
            "\"the storyteller said\" anywhere. Split it into exactly \(pageCount) " +
            "pages. Reply with ONLY a JSON object, no other text, in this exact " +
            "shape:\n" +
            #"{"title": "...", "pages": [{"text": "..."}, ...]"# + epilogueKey + "}"
    }

    /// Extracts {title, pages} from the model's raw reply, tolerant of
    /// leading/trailing prose around the JSON object (a small model doesn't
    /// reliably follow "reply with ONLY json"). nil if nothing usable is
    /// found. Deliberately ignores any "epilogue" the model returned.
    static func parse(_ raw: String) -> (title: String, pages: [String])? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = object["title"] as? String,
              case let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let rawPages = object["pages"] as? [Any],
              !rawPages.isEmpty
        else { return nil }

        var pages: [String] = []
        for entry in rawPages {
            guard let page = entry as? [String: Any], let text = page["text"] as? String else { return nil }
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (title, pages)
    }
}
````

- [ ] **Step 5: Run the tests and watch them pass.** Same two commands as Step 3. Expected: `Executed 17 tests, with 0 failures`.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/StorybookWriter.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoFakes.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/StorybookWriterTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): StorybookWriter, a Swift port of the server's storybook rewrite" -m "Same prompts, tolerant JSON extraction, shared 3-attempt retry budget (unparseable or unsafe), and a fact-derived epilogue that is never model-written."
```

---

### Task 3: `LocalStoryStore` (the on-phone story files)

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift`
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/LocalStoryStore.swift`
- Create: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/LocalStoryStoreTests.swift`

**Interfaces:**
- Consumes: `PendingDemoStoryTurn` (existing); `RewriteStatus` / `IllustrationsStatus` (existing in `SavedStory.swift`, made `Codable` here).
- Produces: `LocalStoryPage(text:hasImage:)`; `LocalStory` (`id`, `createdAt` ISO 8601, `turns`, `sharedFacts`, `pageCount`, `title?`, `pages`, `epilogue?`, `rewriteStatus`, `illustrationsStatus?`; its initializer takes `id:createdAt:turns:sharedFacts:pageCount:` and defaults the rest to a `pending`, page-less story); `LocalStoryStore(directory:)` with `static var defaultDirectory: URL`, `save(_:)`, `load(id:) -> LocalStory?`, `loadAll() -> [LocalStory]` (newest first), `saveImage(_:id:pageIndex:)`, `imageData(id:pageIndex:) -> Data?`, `remove(ids:)`. Ids containing `/`, `\` or `..` are refused.

- [ ] **Step 1: Create the tests.**

````swift
import XCTest
@testable import TinyTalkCore

final class LocalStoryStoreTests: XCTestCase {
    private func makeStore() -> LocalStoryStore {
        LocalStoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func makeStory(id: String, createdAt: String = "2026-09-19T12:00:00Z") -> LocalStory {
        LocalStory(
            id: id,
            createdAt: createdAt,
            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
            sharedFacts: [["fox", "foxes are clever"]],
            pageCount: 5
        )
    }

    func testLoadAllIsEmptyWhenNothingIsSaved() {
        XCTAssertEqual(makeStore().loadAll(), [])
    }

    func testSaveThenLoadRoundTripsEveryField() {
        let store = makeStore()
        var story = makeStory(id: "abc12345")
        story.title = "Pip the Fox"
        story.pages = [LocalStoryPage(text: "Page one."), LocalStoryPage(text: "Page two.", hasImage: true)]
        story.epilogue = "And one true thing we learned about the fox: foxes are clever"
        story.rewriteStatus = .done
        story.illustrationsStatus = .partial
        store.save(story)
        XCTAssertEqual(store.load(id: "abc12345"), story)
    }

    func testLoadOfAnUnknownIdIsNil() {
        XCTAssertNil(makeStore().load(id: "nope"))
    }

    func testLoadAllReturnsNewestFirst() {
        let store = makeStore()
        store.save(makeStory(id: "old", createdAt: "2026-09-17T09:00:00Z"))
        store.save(makeStory(id: "new", createdAt: "2026-09-19T09:00:00Z"))
        store.save(makeStory(id: "mid", createdAt: "2026-09-18T09:00:00Z"))
        XCTAssertEqual(store.loadAll().map(\.id), ["new", "mid", "old"])
    }

    func testASavedStoryOverwritesItsPreviousVersion() {
        let store = makeStore()
        var story = makeStory(id: "abc")
        store.save(story)
        story.rewriteStatus = .failed
        store.save(story)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(store.load(id: "abc")?.rewriteStatus, .failed)
    }

    func testImagesRoundTripPerPage() {
        let store = makeStore()
        store.saveImage(Data([1, 2, 3]), id: "abc", pageIndex: 0)
        store.saveImage(Data([9, 9]), id: "abc", pageIndex: 2)
        XCTAssertEqual(store.imageData(id: "abc", pageIndex: 0), Data([1, 2, 3]))
        XCTAssertEqual(store.imageData(id: "abc", pageIndex: 2), Data([9, 9]))
        XCTAssertNil(store.imageData(id: "abc", pageIndex: 1))
    }

    func testRemoveDeletesTheStoryAndItsImages() {
        let store = makeStore()
        store.save(makeStory(id: "abc"))
        store.save(makeStory(id: "keep"))
        store.saveImage(Data([1]), id: "abc", pageIndex: 0)
        store.remove(ids: ["abc"])
        XCTAssertNil(store.load(id: "abc"))
        XCTAssertNil(store.imageData(id: "abc", pageIndex: 0))
        XCTAssertNotNil(store.load(id: "keep"))
    }

    func testAnIdThatCouldEscapeTheStoreDirectoryIsRejected() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStoryStore(directory: directory)
        store.save(makeStory(id: "../escape"))
        store.saveImage(Data([1]), id: "../escape", pageIndex: 0)
        XCTAssertNil(store.load(id: "../escape"))
        XCTAssertNil(store.imageData(id: "../escape", pageIndex: 0))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.json").path
        ))
    }

    func testACorruptFileIsSkippedNotFatal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStoryStore(directory: directory)
        store.save(makeStory(id: "good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        XCTAssertEqual(store.loadAll().map(\.id), ["good"])
    }
}
````

- [ ] **Step 2: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter LocalStoryStoreTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `cannot find 'LocalStoryStore' in scope`.

- [ ] **Step 3: Make the status enums `Codable`.** Apply this diff to `SavedStory.swift`:

````diff
--- a/ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift
+++ b/ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift
@@ -17,7 +17,7 @@ public struct StoryPage: Equatable, Sendable {
 
 /// Mirrors story_store.py's `rewrite_status` field exactly (`"pending"`,
 /// `"done"`, `"failed"`).
-public enum RewriteStatus: String, Equatable, Sendable {
+public enum RewriteStatus: String, Codable, Equatable, Sendable {
     case pending
     case done
     case failed
@@ -28,7 +28,7 @@ public enum RewriteStatus: String, Equatable, Sendable {
 /// (`nil`) means the text rewrite hasn't finished yet, or finished but
 /// no illustration pass has run at all -- distinct from any of the four
 /// named states.
-public enum IllustrationsStatus: String, Equatable, Sendable {
+public enum IllustrationsStatus: String, Codable, Equatable, Sendable {
     case pending
     case done
     case partial
````

- [ ] **Step 4: Create the store.**

````swift
import Foundation

/// One page of a locally-stored demo-mode storybook. The page's picture,
/// when there is one, lives in its own file (see LocalStoryStore.saveImage)
/// rather than inline in the JSON -- `hasImage` is what the UI is told.
public struct LocalStoryPage: Codable, Equatable, Sendable {
    public var text: String
    public var hasImage: Bool

    public init(text: String, hasImage: Bool = false) {
        self.text = text
        self.hasImage = hasImage
    }
}

/// A story made away from home, as stored on the phone. Field names and
/// statuses mirror server/tinytalk/story_store.py (and SavedStorySummary /
/// SavedStoryDetail), so mapping to what the UI already consumes is direct.
public struct LocalStory: Codable, Equatable, Sendable {
    public var id: String
    /// ISO 8601, exactly as PendingDemoStoryPayload.createdAt -- sorts
    /// chronologically as a plain string because it is always UTC.
    public var createdAt: String
    public var turns: [PendingDemoStoryTurn]
    public var sharedFacts: [[String]]
    /// The page count this story was created with (the parent's setting at
    /// the moment the story began) -- what its storybook rewrite asks for.
    public var pageCount: Int
    public var title: String?
    public var pages: [LocalStoryPage]
    public var epilogue: String?
    public var rewriteStatus: RewriteStatus
    public var illustrationsStatus: IllustrationsStatus?

    public init(
        id: String,
        createdAt: String,
        turns: [PendingDemoStoryTurn],
        sharedFacts: [[String]],
        pageCount: Int,
        title: String? = nil,
        pages: [LocalStoryPage] = [],
        epilogue: String? = nil,
        rewriteStatus: RewriteStatus = .pending,
        illustrationsStatus: IllustrationsStatus? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.turns = turns
        self.sharedFacts = sharedFacts
        self.pageCount = pageCount
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
        self.rewriteStatus = rewriteStatus
        self.illustrationsStatus = illustrationsStatus
    }
}

/// File-backed store for stories made in away-from-home demo mode, in the
/// app's Application Support directory: `<id>.json` for each story plus an
/// `<id>/page-<index>.jpg` per illustrated page. Same locking style as
/// PendingDemoStore (which stays, unchanged, as the sync queue of
/// transcripts) -- every method is synchronous and lock-guarded so it can be
/// called from the main actor (AppModel's sync path) and from background
/// tasks (a storybook build) alike.
public final class LocalStoryStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = LocalStoryStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("DemoStories", isDirectory: true)
    }

    /// Ids are generated locally (8 hex characters), but they also arrive
    /// via UI-supplied get_story/synthesize_page requests -- reject anything
    /// that could escape `directory` rather than trust them.
    private func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("\\") && !id.contains("..")
    }

    private func jsonURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    private func imageDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func imageURL(_ id: String, _ pageIndex: Int) -> URL {
        imageDirectory(id).appendingPathComponent("page-\(pageIndex).jpg")
    }

    public func save(_ story: LocalStory) {
        guard isSafeId(story.id) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(story) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: jsonURL(story.id), options: .atomic)
    }

    public func load(id: String) -> LocalStory? {
        guard isSafeId(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return loadLocked(id: id)
    }

    private func loadLocked(id: String) -> LocalStory? {
        guard let data = try? Data(contentsOf: jsonURL(id)) else { return nil }
        return try? JSONDecoder().decode(LocalStory.self, from: data)
    }

    /// Every stored story, newest first. A corrupt file is skipped, not
    /// raised -- one bad story must never break browsing the rest.
    public func loadAll() -> [LocalStory] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let stories: [LocalStory] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(LocalStory.self, from: data)
            }
        return stories.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveImage(_ data: Data, id: String, pageIndex: Int) {
        guard isSafeId(id), pageIndex >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: imageDirectory(id), withIntermediateDirectories: true)
        try? data.write(to: imageURL(id, pageIndex), options: .atomic)
    }

    public func imageData(id: String, pageIndex: Int) -> Data? {
        guard isSafeId(id), pageIndex >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: imageURL(id, pageIndex))
    }

    /// Deletes each story's JSON and its whole image directory. Unknown or
    /// unsafe ids are ignored.
    public func remove(ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids where isSafeId(id) {
            try? FileManager.default.removeItem(at: jsonURL(id))
            try? FileManager.default.removeItem(at: imageDirectory(id))
        }
    }
}
````

- [ ] **Step 5: Run the tests and watch them pass.** Same two commands as Step 2. Expected: `Executed 9 tests, with 0 failures`. Also run `--filter SavedStoryTests` (6 existing tests must still pass).

- [ ] **Step 6: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift ios/TinyTalkCore/Sources/TinyTalkCore/LocalStoryStore.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/LocalStoryStoreTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): LocalStoryStore for storybooks made away from home" -m "File-backed <id>.json plus <id>/page-<i>.jpg, lock-guarded like PendingDemoStore, newest first. RewriteStatus and IllustrationsStatus become Codable."
```

---

### Task 4: `DemoStoryLibrary`, the sync types and the serial build queue

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStory.swift`
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/SerialAsyncQueue.swift`
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoStoryLibrary.swift`
- Modify (append fakes): `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoFakes.swift`
- Modify: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/PendingDemoStoreTests.swift`
- Create: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoStoryLibraryTests.swift`

**Interfaces:**
- Consumes: `LocalStoryStore` (Task 3), `StorybookWriter` / `WrittenStorybook` (Task 2), existing `SavedStorySummary(id:title:createdAt:pageCount:rewriteStatus:)` and `SavedStoryDetail(id:title:pages:epilogue:rewriteStatus:illustrationsStatus:)` (what the Library/Reading screens already consume).
- Produces:
  - `IllustrationResult(images: [Data?], status: IllustrationsStatus)` and `protocol StoryIllustrating: Sendable { func illustrate(pages: [String]) async -> IllustrationResult }` (Phase 2 implements it).
  - `DemoSyncPage(text: String, imageJPEG: Data?)`, `DemoSyncStorybook(title: String, pages: [DemoSyncPage], illustrationsStatus: IllustrationsStatus?)`, and `PendingDemoStoryPayload.storybook: DemoSyncStorybook?` (defaults to `nil`; legacy payload files without the key still decode).
  - `DemoStoryLibrary(store:writer:illustrator:)` (`illustrator` defaults to `nil` = text-only) with `begin(_:pageCount:)`, `list() -> [SavedStorySummary]` (newest first), `detail(id:) -> SavedStoryDetail?`, `pageText(id:index:) -> String?`, `pageImage(id:index:) -> Data?`, `buildStorybook(id:) async` (serialized process-wide; a no-op for a story that is not `pending`), `resumeInterruptedBuilds() async`, and `static func syncPayloads(store: LocalStoryStore, pending: [PendingDemoStoryPayload]) -> [PendingDemoStoryPayload]`.
  - Internal `SerialAsyncQueue` with `func enqueue(_ work: @escaping @Sendable () async -> Void) async`.
  - Test doubles `FakeIllustrator`, `GatedChatClient` (holds each reply until `release()`), `ConcurrencyProbeChatClient` (records `maxInFlight`).

- [ ] **Step 1: Append the three new test doubles to `DemoFakes.swift`.**

````swift
/// Holds every complete() call open until the test releases it -- lets a
/// test keep a live turn genuinely in flight.
final class GatedChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private let reply: String

    init(reply: String) {
        self.reply = reply
    }

    func complete(messages: [[String: String]]) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return reply
    }

    func release() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let current = waiter
            waiter = nil
            return current
        }
        toResume?.resume()
    }
}

/// Reports what it was asked to illustrate and returns a scripted result.
final class FakeIllustrator: StoryIllustrating, @unchecked Sendable {
    private let lock = NSLock()
    private var _receivedPages: [[String]] = []
    let result: IllustrationResult

    init(result: IllustrationResult) {
        self.result = result
    }

    var receivedPages: [[String]] { lock.withLock { _receivedPages } }

    func illustrate(pages: [String]) async -> IllustrationResult {
        lock.withLock { _receivedPages.append(pages) }
        return result
    }
}

/// Answers every call with the same reply after a short real delay, and
/// records the highest number of calls ever in flight at once -- the probe
/// a "builds never overlap" test needs.
final class ConcurrencyProbeChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var _maxInFlight = 0
    private let reply: String

    init(reply: String) {
        self.reply = reply
    }

    var maxInFlight: Int { lock.withLock { _maxInFlight } }

    func complete(messages: [[String: String]]) async throws -> String {
        lock.withLock {
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        lock.withLock { inFlight -= 1 }
        return reply
    }
}
````

- [ ] **Step 2: Create the library tests.**

````swift
import XCTest
@testable import TinyTalkCore

final class DemoStoryLibraryTests: XCTestCase {
    private func makeStore() -> LocalStoryStore {
        LocalStoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func payload(id: String, createdAt: String = "2026-09-19T12:00:00Z", facts: [[String]] = []) -> PendingDemoStoryPayload {
        PendingDemoStoryPayload(
            id: id,
            createdAt: createdAt,
            turns: [
                PendingDemoStoryTurn(speaker: "child", text: "tell me about a fox", interrupted: false),
                PendingDemoStoryTurn(speaker: "agent", text: "Once there was a clever fox. The end.", interrupted: false),
            ],
            sharedFacts: facts
        )
    }

    private func storybookJSON(title: String = "Pip the Fox", pages: [String] = ["Page one.", "Page two.", "Page three."]) -> String {
        let object: [String: Any] = ["title": title, "pages": pages.map { ["text": $0] }]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func makeLibrary(
        store: LocalStoryStore,
        chat: any ChatCompleting,
        illustrator: (any StoryIllustrating)? = nil
    ) -> DemoStoryLibrary {
        DemoStoryLibrary(store: store, writer: StorybookWriter(chat: chat), illustrator: illustrator)
    }

    // MARK: - begin / list / detail

    func testABegunStoryIsListedAsPendingWithNoTitleOrPages() {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()))
        library.begin(payload(id: "abc"), pageCount: 3)
        let list = library.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "abc")
        XCTAssertNil(list[0].title)
        XCTAssertEqual(list[0].pageCount, 0)
        XCTAssertEqual(list[0].rewriteStatus, .pending)
    }

    func testListIsNewestFirstAndParsesTheCreationDate() {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()))
        library.begin(payload(id: "older", createdAt: "2026-09-17T09:00:00Z"), pageCount: 3)
        library.begin(payload(id: "newer", createdAt: "2026-09-19T09:00:00Z"), pageCount: 3)
        let list = library.list()
        XCTAssertEqual(list.map(\.id), ["newer", "older"])
        XCTAssertEqual(list[0].createdAt, ISO8601DateFormatter().date(from: "2026-09-19T09:00:00Z"))
    }

    func testDetailOfAnUnknownIdIsNil() {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()))
        XCTAssertNil(library.detail(id: "nope"))
    }

    // MARK: - buildStorybook

    func testBuildingProducesADoneStorybookAskingForTheStoryOwnPageCount() async {
        let chat = ScriptedChatClient(storybookJSON())
        let library = makeLibrary(store: makeStore(), chat: chat)
        library.begin(payload(id: "abc", facts: [["fox", "foxes have excellent hearing"]]), pageCount: 3)

        await library.buildStorybook(id: "abc")

        let detail = library.detail(id: "abc")
        XCTAssertEqual(detail?.title, "Pip the Fox")
        XCTAssertEqual(detail?.pages.map(\.text), ["Page one.", "Page two.", "Page three."])
        XCTAssertEqual(detail?.pages.map(\.hasImage), [false, false, false])
        XCTAssertEqual(detail?.epilogue, "And one true thing we learned about the fox: foxes have excellent hearing")
        XCTAssertEqual(detail?.rewriteStatus, .done)
        XCTAssertNil(detail?.illustrationsStatus, "no illustrator configured -> text-only")
        let prompt = chat.receivedMessages[0][1]["content"] ?? ""
        XCTAssertTrue(prompt.contains("exactly 3 pages"))
    }

    func testAFailedRewriteMarksTheStoryFailedAndKeepsItsTranscript() async {
        let store = makeStore()
        let library = makeLibrary(store: store, chat: ScriptedChatClient("this is not json at all"))
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")

        XCTAssertEqual(library.detail(id: "abc")?.rewriteStatus, .failed)
        XCTAssertNil(library.detail(id: "abc")?.title)
        XCTAssertEqual(store.load(id: "abc")?.turns.count, 2, "the transcript must survive a failed rewrite")
    }

    func testBuildingTwiceOnlyRewritesOnce() async {
        let chat = ScriptedChatClient(storybookJSON())
        let library = makeLibrary(store: makeStore(), chat: chat)
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")
        await library.buildStorybook(id: "abc")

        XCTAssertEqual(chat.callCount, 1)
    }

    func testAStoryRemovedWhileItsBuildIsInFlightIsNotResurrected() async {
        // E.g. the phone reconnected to the Mac and synced the story home
        // (deleting its local copy) while the storybook was still being
        // written. The finishing build must not re-save it.
        let gate = GatedChatClient(reply: storybookJSON())
        let store = makeStore()
        let library = makeLibrary(store: store, chat: gate)
        library.begin(payload(id: "abc"), pageCount: 3)

        let build = Task { await library.buildStorybook(id: "abc") }
        try? await Task.sleep(nanoseconds: 50_000_000) // the build is now parked inside the chat call
        store.remove(ids: ["abc"])
        gate.release()
        await build.value

        XCTAssertNil(store.load(id: "abc"))
        XCTAssertEqual(store.loadAll(), [])
    }

    func testBuildingAnUnknownStoryDoesNothing() async {
        let chat = ScriptedChatClient(storybookJSON())
        let library = makeLibrary(store: makeStore(), chat: chat)
        await library.buildStorybook(id: "ghost")
        XCTAssertEqual(chat.callCount, 0)
    }

    func testTwoBuildsNeverOverlapEvenWhenStartedTogether() async {
        let chat = ConcurrencyProbeChatClient(reply: storybookJSON())
        let store = makeStore()
        let library = makeLibrary(store: store, chat: chat)
        library.begin(payload(id: "one"), pageCount: 3)
        library.begin(payload(id: "two"), pageCount: 3)

        async let first: Void = library.buildStorybook(id: "one")
        async let second: Void = library.buildStorybook(id: "two")
        _ = await (first, second)

        XCTAssertEqual(chat.maxInFlight, 1, "builds must be serialized, not interleaved")
        XCTAssertEqual(library.detail(id: "one")?.rewriteStatus, .done)
        XCTAssertEqual(library.detail(id: "two")?.rewriteStatus, .done)
    }

    // MARK: - illustrations

    func testAnIllustratorsPicturesAreStoredAndReportedPerPage() async {
        let illustrator = FakeIllustrator(result: IllustrationResult(
            images: [Data([1]), nil, Data([3])], status: .partial
        ))
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()), illustrator: illustrator)
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")

        let detail = library.detail(id: "abc")
        XCTAssertEqual(detail?.pages.map(\.hasImage), [true, false, true])
        XCTAssertEqual(detail?.illustrationsStatus, .partial)
        XCTAssertEqual(library.pageImage(id: "abc", index: 0), Data([1]))
        XCTAssertNil(library.pageImage(id: "abc", index: 1))
        XCTAssertEqual(library.pageImage(id: "abc", index: 2), Data([3]))
        XCTAssertEqual(illustrator.receivedPages, [["Page one.", "Page two.", "Page three."]])
    }

    func testNoIllustrationsAreAttemptedWhenTheRewriteFailed() async {
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [], status: .failed))
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient("nope"), illustrator: illustrator)
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")

        XCTAssertEqual(illustrator.receivedPages, [])
    }

    // MARK: - page lookups

    func testPageTextAndImageLookupsAreBoundsChecked() async {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON(pages: ["Only page."])))
        library.begin(payload(id: "abc"), pageCount: 1)
        await library.buildStorybook(id: "abc")

        XCTAssertEqual(library.pageText(id: "abc", index: 0), "Only page.")
        XCTAssertNil(library.pageText(id: "abc", index: 1))
        XCTAssertNil(library.pageText(id: "abc", index: -1))
        XCTAssertNil(library.pageText(id: "ghost", index: 0))
        XCTAssertNil(library.pageImage(id: "abc", index: 0), "a page with no picture has no image")
    }

    // MARK: - interrupted builds

    func testResumeRebuildsOnlyStoriesLeftPending() async {
        let chat = ScriptedChatClient(storybookJSON())
        let store = makeStore()
        let library = makeLibrary(store: store, chat: chat)
        library.begin(payload(id: "finished"), pageCount: 3)
        await library.buildStorybook(id: "finished")
        XCTAssertEqual(chat.callCount, 1)
        library.begin(payload(id: "interrupted", createdAt: "2026-09-19T13:00:00Z"), pageCount: 3)

        await library.resumeInterruptedBuilds()

        XCTAssertEqual(chat.callCount, 2, "only the interrupted story should be rebuilt")
        XCTAssertEqual(library.detail(id: "interrupted")?.rewriteStatus, .done)
    }

    // MARK: - sync payloads

    func testSyncPayloadCarriesTheFinishedStorybookAndItsPictures() async {
        let store = makeStore()
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [Data([7, 7]), nil, nil], status: .partial))
        let library = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()), illustrator: illustrator)
        let original = payload(id: "abc", facts: [["fox", "foxes are clever"]])
        library.begin(original, pageCount: 3)
        await library.buildStorybook(id: "abc")

        let synced = DemoStoryLibrary.syncPayloads(store: store, pending: [original])

        XCTAssertEqual(synced.count, 1)
        XCTAssertEqual(synced[0].id, "abc")
        XCTAssertEqual(synced[0].turns, original.turns)
        XCTAssertEqual(synced[0].sharedFacts, [["fox", "foxes are clever"]])
        XCTAssertEqual(synced[0].storybook?.title, "Pip the Fox")
        XCTAssertEqual(synced[0].storybook?.pages.map(\.text), ["Page one.", "Page two.", "Page three."])
        XCTAssertEqual(synced[0].storybook?.pages.map(\.imageJPEG), [Data([7, 7]), nil, nil])
        XCTAssertEqual(synced[0].storybook?.illustrationsStatus, .partial)
    }

    func testSyncPayloadIsTranscriptOnlyForAStoryThatIsPendingFailedOrUnknown() async {
        let store = makeStore()
        let pendingLibrary = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()))
        let failedLibrary = makeLibrary(store: store, chat: ScriptedChatClient("nope"))
        let stillPending = payload(id: "pending")
        let failed = payload(id: "failed")
        let unknown = payload(id: "unknown")
        pendingLibrary.begin(stillPending, pageCount: 3)
        failedLibrary.begin(failed, pageCount: 3)
        await failedLibrary.buildStorybook(id: "failed")

        let synced = DemoStoryLibrary.syncPayloads(store: store, pending: [stillPending, failed, unknown])

        XCTAssertEqual(synced, [stillPending, failed, unknown], "no storybook may be attached to any of them")
        XCTAssertTrue(synced.allSatisfy { $0.storybook == nil })
    }
}
````

- [ ] **Step 3: Add the two `PendingDemoStore` backward-compatibility tests** (a payload file written before storybooks existed — no `storybook` key — must still load, as a transcript-only story). Apply this diff to `PendingDemoStoreTests.swift`:

````diff
--- a/ios/TinyTalkCore/Tests/TinyTalkCoreTests/PendingDemoStoreTests.swift
+++ b/ios/TinyTalkCore/Tests/TinyTalkCoreTests/PendingDemoStoreTests.swift
@@ -42,4 +42,25 @@ final class PendingDemoStoreTests: XCTestCase {
         store.clear()
         XCTAssertEqual(store.loadAll(), [])
     }
+
+    func testAPayloadFileWrittenBeforeStorybookExistedStillDecodes() throws {
+        // Payload files saved by earlier builds have no "storybook" key at
+        // all -- they must keep loading (as transcript-only stories).
+        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
+        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+        let legacy = #"{"id":"old","createdAt":"2026-09-09T12:00:00Z","turns":[{"speaker":"child","text":"hi","interrupted":false}],"sharedFacts":[["fox","foxes are clever"]]}"#
+        try Data(legacy.utf8).write(to: dir.appendingPathComponent("old.json"))
+
+        let loaded = PendingDemoStore(directory: dir).loadAll()
+
+        XCTAssertEqual(loaded.count, 1)
+        XCTAssertEqual(loaded[0].id, "old")
+        XCTAssertNil(loaded[0].storybook)
+    }
+
+    func testAPayloadWithoutAStorybookRoundTripsWithoutOne() {
+        let store = makeStore()
+        store.save(makePayload(id: "abc"))
+        XCTAssertNil(store.loadAll()[0].storybook)
+    }
 }
````

- [ ] **Step 4: Run the library tests and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter DemoStoryLibraryTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `cannot find 'DemoStoryLibrary' in scope` (and `storybook` extra-argument errors).

- [ ] **Step 5: Add the sync types.** Apply this diff to `PendingDemoStory.swift`:

````diff
--- a/ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStory.swift
+++ b/ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStory.swift
@@ -12,6 +12,34 @@ public struct PendingDemoStoryTurn: Codable, Sendable, Equatable {
     }
 }
 
+/// One page of a finished storybook being uploaded with a synced story.
+public struct DemoSyncPage: Codable, Sendable, Equatable {
+    public let text: String
+    /// The page's illustration as JPEG bytes, or nil when it has none.
+    public let imageJPEG: Data?
+
+    public init(text: String, imageJPEG: Data?) {
+        self.text = text
+        self.imageJPEG = imageJPEG
+    }
+}
+
+/// The finished storybook a demo-mode story carries to the home server at
+/// sync time, so nothing generated away from home is discarded or redone.
+/// The epilogue is deliberately NOT part of this: the server recomputes it
+/// from the story's shared facts (its own rule -- never model-written).
+public struct DemoSyncStorybook: Codable, Sendable, Equatable {
+    public let title: String
+    public let pages: [DemoSyncPage]
+    public let illustrationsStatus: IllustrationsStatus?
+
+    public init(title: String, pages: [DemoSyncPage], illustrationsStatus: IllustrationsStatus?) {
+        self.title = title
+        self.pages = pages
+        self.illustrationsStatus = illustrationsStatus
+    }
+}
+
 /// One story completed away from home, pending sync to the home server
 /// -- see DemoConnection (Task 13, writes these) and PendingDemoStore
 /// (Task 13, persists them) and AppModel (Task 15, sends them once
@@ -23,11 +51,22 @@ public struct PendingDemoStoryPayload: Codable, Sendable, Equatable {
     /// [[animal, fact], ...] -- matches AnimalFactTracker.sharedFacts()'s
     /// (animal, fact) pairs, in the shape the wire message sends them.
     public let sharedFacts: [[String]]
+    /// Only ever set at sync time (see DemoStoryLibrary.syncPayloads) --
+    /// never persisted by PendingDemoStore, so payload files written before
+    /// this field existed still decode (an absent key is simply nil).
+    public let storybook: DemoSyncStorybook?
 
-    public init(id: String, createdAt: String, turns: [PendingDemoStoryTurn], sharedFacts: [[String]]) {
+    public init(
+        id: String,
+        createdAt: String,
+        turns: [PendingDemoStoryTurn],
+        sharedFacts: [[String]],
+        storybook: DemoSyncStorybook? = nil
+    ) {
         self.id = id
         self.createdAt = createdAt
         self.turns = turns
         self.sharedFacts = sharedFacts
+        self.storybook = storybook
     }
 }
````

- [ ] **Step 6: Create the serial queue.**

````swift
import Foundation

/// Runs async work strictly one item at a time, in arrival order -- across
/// every caller sharing the same queue instance.
///
/// An `actor` would NOT do this: an actor only serializes the synchronous
/// stretches between suspension points, so two async operations on it can
/// still interleave whenever either one `await`s. A storybook build is
/// almost entirely awaits (LLM calls), hence this chained-Task queue.
final class SerialAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Returns once `work` has run to completion (after everything enqueued
    /// before it).
    func enqueue(_ work: @escaping @Sendable () async -> Void) async {
        let task = schedule(work)
        await task.value
    }

    // Synchronous on purpose: this toolchain marks NSLock.lock()/unlock()
    // unavailable from async contexts, so the locked section lives in a
    // plain function (same workaround DemoConnection uses).
    private func schedule(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        let next = Task {
            await previous?.value
            await work()
        }
        tail = next
        return next
    }
}
````

- [ ] **Step 7: Create the library.**

````swift
import Foundation

/// What a StoryIllustrating pass produced for one story: positional with
/// the story's pages (nil = no picture for that page), and the same
/// done/partial/failed status server/tinytalk/illustrations.py records.
public struct IllustrationResult: Equatable, Sendable {
    public let images: [Data?]
    public let status: IllustrationsStatus

    public init(images: [Data?], status: IllustrationsStatus) {
        self.images = images
        self.status = status
    }
}

/// The seam between DemoStoryLibrary and whatever draws a story's pictures.
/// Phase 1 ships without an implementation (a nil illustrator means
/// text-only storybooks); Phase 2's IllustrationPass conforms to it.
public protocol StoryIllustrating: Sendable {
    func illustrate(pages: [String]) async -> IllustrationResult
}

/// The on-phone library of stories made away from home: save a finished
/// story, list/detail it in exactly the shapes the Library/Reading screens
/// already consume, and turn its transcript into a storybook. Immutable
/// dependencies only -- storybook builds are serialized through one
/// process-wide queue, so several libraries (e.g. one per demo connection)
/// can never build at the same time.
public struct DemoStoryLibrary: Sendable {
    private static let buildQueue = SerialAsyncQueue()

    private let store: LocalStoryStore
    private let writer: StorybookWriter
    private let illustrator: (any StoryIllustrating)?

    public init(store: LocalStoryStore, writer: StorybookWriter, illustrator: (any StoryIllustrating)? = nil) {
        self.store = store
        self.writer = writer
        self.illustrator = illustrator
    }

    /// Saves a just-finished story's transcript as `pending`, awaiting its
    /// storybook. `pageCount` is the page count in force when the story began.
    public func begin(_ payload: PendingDemoStoryPayload, pageCount: Int) {
        store.save(LocalStory(
            id: payload.id,
            createdAt: payload.createdAt,
            turns: payload.turns,
            sharedFacts: payload.sharedFacts,
            pageCount: pageCount
        ))
    }

    /// Newest first -- what a `story_list` event carries.
    public func list() -> [SavedStorySummary] {
        let formatter = ISO8601DateFormatter()
        return store.loadAll().map { story in
            SavedStorySummary(
                id: story.id,
                title: story.title,
                createdAt: formatter.date(from: story.createdAt) ?? Date(),
                pageCount: story.pages.count,
                rewriteStatus: story.rewriteStatus
            )
        }
    }

    /// What a `story_detail` event carries; nil for an unknown id.
    public func detail(id: String) -> SavedStoryDetail? {
        guard let story = store.load(id: id) else { return nil }
        return SavedStoryDetail(
            id: story.id,
            title: story.title,
            pages: story.pages.map { StoryPage(text: $0.text, hasImage: $0.hasImage) },
            epilogue: story.epilogue,
            rewriteStatus: story.rewriteStatus,
            illustrationsStatus: story.illustrationsStatus
        )
    }

    public func pageText(id: String, index: Int) -> String? {
        guard let story = store.load(id: id), story.pages.indices.contains(index) else { return nil }
        return story.pages[index].text
    }

    /// nil when the story/page doesn't exist or the page has no picture.
    public func pageImage(id: String, index: Int) -> Data? {
        guard let story = store.load(id: id),
              story.pages.indices.contains(index),
              story.pages[index].hasImage
        else { return nil }
        return store.imageData(id: id, pageIndex: index)
    }

    /// Turns a `pending` story's transcript into its storybook, then (when
    /// an illustrator is configured) its pictures. Serialized process-wide,
    /// and a no-op for a story that is no longer `pending`, so it is safe to
    /// call twice for the same id.
    public func buildStorybook(id: String) async {
        let store = self.store
        let writer = self.writer
        let illustrator = self.illustrator
        await Self.buildQueue.enqueue {
            await Self.performBuild(id: id, store: store, writer: writer, illustrator: illustrator)
        }
    }

    /// A build interrupted by the app being backgrounded or killed leaves
    /// its story `pending` forever -- rebuild any such story. Idempotent.
    public func resumeInterruptedBuilds() async {
        for story in store.loadAll() where story.rewriteStatus == .pending {
            await buildStorybook(id: story.id)
        }
    }

    private static func performBuild(
        id: String, store: LocalStoryStore, writer: StorybookWriter, illustrator: (any StoryIllustrating)?
    ) async {
        guard var story = store.load(id: id), story.rewriteStatus == .pending else { return }

        let written = await writer.write(
            turns: story.turns, sharedFacts: story.sharedFacts, pageCount: story.pageCount
        )
        // The story may have been synced home (and its local copy deleted)
        // while the model was thinking -- never re-save it, or it would
        // reappear in the away Library as a duplicate of the synced one.
        guard store.load(id: id) != nil else { return }
        guard let written else {
            story.rewriteStatus = .failed
            store.save(story)
            return
        }
        story.title = written.title
        story.pages = written.pages.map { LocalStoryPage(text: $0) }
        story.epilogue = written.epilogue
        story.rewriteStatus = .done
        store.save(story)

        guard let illustrator else { return }
        story.illustrationsStatus = .pending
        store.save(story)
        let result = await illustrator.illustrate(pages: written.pages)
        guard store.load(id: id) != nil else { return } // same reason as above
        for (index, image) in result.images.enumerated() where story.pages.indices.contains(index) {
            guard let image else { continue }
            store.saveImage(image, id: id, pageIndex: index)
            story.pages[index].hasImage = true
        }
        story.illustrationsStatus = result.status
        store.save(story)
    }

    /// The payloads to send at sync time: each pending transcript, plus its
    /// finished storybook when the local rewrite reached `done`. Needs only
    /// the store, not a live library, because the sync runs from the
    /// real-server connect path, where no DemoStoryLibrary exists. A story
    /// that failed, is still pending, or has no local record syncs
    /// transcript-only, so the Mac rewrites it as it always has.
    public static func syncPayloads(
        store: LocalStoryStore, pending: [PendingDemoStoryPayload]
    ) -> [PendingDemoStoryPayload] {
        pending.map { payload in
            guard let story = store.load(id: payload.id),
                  story.rewriteStatus == .done,
                  let title = story.title,
                  !story.pages.isEmpty
            else { return payload }
            let pages = story.pages.enumerated().map { index, page in
                DemoSyncPage(
                    text: page.text,
                    imageJPEG: page.hasImage ? store.imageData(id: payload.id, pageIndex: index) : nil
                )
            }
            return PendingDemoStoryPayload(
                id: payload.id,
                createdAt: payload.createdAt,
                turns: payload.turns,
                sharedFacts: payload.sharedFacts,
                storybook: DemoSyncStorybook(title: title, pages: pages, illustrationsStatus: story.illustrationsStatus)
            )
        }
    }
}
````

- [ ] **Step 8: Run the library and store tests and watch them pass.** Run the two commands from Step 4 once with `--filter DemoStoryLibraryTests` (expected `Executed 15 tests, with 0 failures`) and once with `--filter PendingDemoStoreTests` (expected `Executed 6 tests, with 0 failures`).

- [ ] **Step 9: Run the whole Swift suite.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | grep -v "ditty loop" | tail -3
```

Expected: `Executed 306 tests, with 0 failures` (256 baseline + 7 + 17 + 9 + 15 + 2).

- [ ] **Step 10: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/PendingDemoStory.swift ios/TinyTalkCore/Sources/TinyTalkCore/SerialAsyncQueue.swift ios/TinyTalkCore/Sources/TinyTalkCore/DemoStoryLibrary.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoFakes.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/PendingDemoStoreTests.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoStoryLibraryTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): DemoStoryLibrary, the on-phone library behind Library/Reading" -m "Saves a finished story as pending, lists/details/pages it in the shapes the UI already consumes, builds its storybook one at a time process-wide, and produces sync payloads that carry the finished storybook. Adds the StoryIllustrating seam (nil = text-only) for Phase 2."
```

- [ ] **Step 11: Mutation check A — prove the serial queue is what keeps builds from overlapping.** Temporarily change `buildStorybook(id:)` in `DemoStoryLibrary.swift`: replace

```swift
        await Self.buildQueue.enqueue {
            await Self.performBuild(id: id, store: store, writer: writer, illustrator: illustrator)
        }
```

with

```swift
        await Self.performBuild(id: id, store: store, writer: writer, illustrator: illustrator)
```

Run `--filter DemoStoryLibraryTests/testTwoBuildsNeverOverlapEvenWhenStartedTogether` (same two commands as Step 4). Expected: **that test FAILS** (`maxInFlight` reaches 2). Then restore the committed file and confirm it is clean:

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 checkout -- ios/TinyTalkCore/Sources/TinyTalkCore/DemoStoryLibrary.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 status --short
```

Expected: no output.

- [ ] **Step 12: Mutation check B — prove a synced-away story is not resurrected.** Temporarily delete the first no-resurrection guard in `performBuild` (the line `guard store.load(id: id) != nil else { return }` that comes right after the `writer.write(...)` call — leave the second one, after `illustrate`, alone). Run `--filter DemoStoryLibraryTests/testAStoryRemovedWhileItsBuildIsInFlightIsNotResurrected`. Expected: **that test FAILS** (the removed story reappears). Restore with the same `git checkout --` command as Step 11 and confirm `git status --short` prints nothing.

---

### Task 5: `StoryArc.hasStarted`

A settings change must rebuild an arc that has not started but never touch one in progress (mirrors `story_arc.py`'s `has_started`, used by `SessionRunner.handle_update_settings`).

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/StoryArc.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/StoryArcTests.swift`

**Interfaces:**
- Consumes: `StoryArc`'s existing lock and `turnCount`.
- Produces: `StoryArc.hasStarted: Bool` — `true` once the first turn has been recorded (`turnCount > 0`). `forceConcludeGuidance()` does not start an arc.

- [ ] **Step 1: Add the failing tests.** Apply this diff to `StoryArcTests.swift`:

````diff
--- a/ios/TinyTalkCore/Tests/TinyTalkCoreTests/StoryArcTests.swift
+++ b/ios/TinyTalkCore/Tests/TinyTalkCoreTests/StoryArcTests.swift
@@ -2,6 +2,24 @@ import XCTest
 @testable import TinyTalkCore
 
 final class StoryArcTests: XCTestCase {
+    // MARK: - hasStarted (mirrors story_arc.py's has_started)
+
+    func testAFreshArcHasNotStartedAndRecordingATurnStartsIt() {
+        let arc = StoryArc(targetTurns: 7)
+        XCTAssertFalse(arc.hasStarted)
+        _ = arc.recordTurn(childText: "hello")
+        XCTAssertTrue(arc.hasStarted)
+    }
+
+    func testAnExplicitConclusionAloneDoesNotCountAsStartingTheArc() {
+        // forceConcludeGuidance()/markDone() deliberately leave turnCount
+        // alone (see story_arc.py), so they don't flip hasStarted either.
+        let arc = StoryArc(targetTurns: 7)
+        _ = arc.forceConcludeGuidance()
+        arc.markDone()
+        XCTAssertFalse(arc.hasStarted)
+    }
+
     // MARK: - Brief's required tests
 
     func testFirstTurnIsIntro() {
````

- [ ] **Step 2: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter StoryArcTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `value of type 'StoryArc' has no member 'hasStarted'`.

- [ ] **Step 3: Implement.** Apply this diff to `StoryArc.swift`:

````diff
--- a/ios/TinyTalkCore/Sources/TinyTalkCore/StoryArc.swift
+++ b/ios/TinyTalkCore/Sources/TinyTalkCore/StoryArc.swift
@@ -62,6 +62,15 @@ public final class StoryArc: @unchecked Sendable {
         return _isDone
     }
 
+    /// True once the first turn has been recorded -- mirrors story_arc.py's
+    /// has_started. Lets a settings change tell an arc that can still be
+    /// rebuilt with new settings from one already in progress (which must
+    /// never change retroactively).
+    public var hasStarted: Bool {
+        lock.lock(); defer { lock.unlock() }
+        return turnCount > 0
+    }
+
     private func stageForTurn(_ turn: Int) -> StoryStage {
         if turn <= 1 { return .intro }
         let setupEnd = Int((Double(targetTurns) / 4).rounded())
````

- [ ] **Step 4: Run the tests and watch them pass.** Same two commands as Step 2. Expected: `Executed 24 tests, with 0 failures` (22 existing + 2 new).

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/StoryArc.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/StoryArcTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): StoryArc.hasStarted" -m "Lets a settings change rebuild an unstarted arc without ever changing one in progress, mirroring story_arc.py's has_started."
```

---

### Task 6: `DemoConnection` becomes a local server

The largest task. `DemoConnection.send(_:)` currently lumps every story-browsing message into one silent no-op. After this task every `ClientMessage` case has an explicit behaviour (spec, "Message handling" table), stories are saved and built locally, and the events arrive in the order the real server sends them.

**Read these invariants before touching the file — they explain shapes that look odd:**

1. *Conclusion order matches the server:* concluding reply audio → `turnEnd` → save the transcript → `rewritingStarted` → (background build) → `rewritingDone`. `SessionCoordinator.readyToShowTheEnd` needs both `rewritingStarted` and the concluding turn's playback to finish.
2. *Every media request ends with exactly one terminating frame* (`pageAudioDone`, `pageImageDone` or `error`), even when cancelled: a pending page request diverts every later `.audio` frame into page playback, so a request that goes quiet would wedge live story audio.
3. *Media never interleaves with a live turn.* The server handles one message at a time; `startMediaTask` chains media work behind the previous media task **and** any in-flight turn, because `SessionCoordinator` routes `.audio` frames by "is a page request pending?" and `AVSpeechTts` shares one synthesizer.
4. *"Finish this story" is a turn with no transcript:* cancel in-flight work, run one turn with empty child text and `StoryArc.forceConcludeGuidance()`, mark the story done unconditionally, with the same safety-retry budget (`concludeSafetyRetryAttempts = 3`) as the server's `_conclude_story`.
5. *Settings never apply retroactively:* the page count is captured when a story begins (`storyPageCount`), and an arc is only rebuilt while `!hasStarted`.

**Files:**
- Modify (append fakes): `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoFakes.swift`
- Modify: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConnectionTests.swift`
- Replace: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift`

**Interfaces:**
- Consumes: `DemoStoryLibrary` and `PendingDemoStoryPayload` (Task 4), `StoryArc.hasStarted` (Task 5), `Safety.findBlocked` (Task 1), existing `ServerConnecting`, `ServerEvent`, `ServerConnectionEvent`, `ChatCompleting`, `SpeechTranscribing`, `SpeechSynthesizing`, `AnimalFactTracker`.
- Produces: `DemoConnection.init(chatClient:sttClient:ttsClient:animalFactTracker:systemPrompt:targetTurns:pageCount:library:onStoryCompleted:)` — `systemPrompt` defaults to `DemoConnection.defaultSystemPrompt`, `targetTurns` to 7, `pageCount` to 5, `library` and `onStoryCompleted` to `nil`; existing call sites compile unchanged. Behaviour: the table in the spec's "Message handling" section. Test doubles `EventRecorder` (records a connection's events; `messages`, `audioFrames`, `waitForCount(_:timeout:)`, `settle()`, `stop()`) and `ChunkedTtsClient` (a TTS double emitting several chunks; records `synthesizedTexts`).

- [ ] **Step 1: Confirm the file you are about to replace is still the base version.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 diff 5b9700a -- ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift
```

Expected: no output — or only a comment change from PR #43 in the `send(_:)` region (see Preflight). Anything else means `main` changed this file since the plan was verified: stop and reconcile before overwriting.

- [ ] **Step 2: Add the two new test doubles to `DemoFakes.swift`** — insert them **immediately after `ScriptedChatClient` and before `GatedChatClient`** (one blank line between classes), so the file ends up in the same order as the verified implementation:

````swift
/// Records every event a DemoConnection emits and lets a test wait until N
/// have arrived. One recorder per connection: an AsyncStream supports a
/// single consumer, and a consumer that breaks out of its loop can end the
/// stream for whoever reads next -- so tests must not call events() twice.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ServerConnectionEvent] = []
    private var task: Task<Void, Never>?

    init(_ connection: DemoConnection) {
        let stream = connection.events()
        task = Task { [weak self] in
            for await event in stream { self?.record(event) }
        }
    }

    private func record(_ event: ServerConnectionEvent) {
        lock.withLock { _events.append(event) }
    }

    var events: [ServerConnectionEvent] { lock.withLock { _events } }

    /// Only the `.message` events, unwrapped.
    var messages: [ServerEvent] {
        events.compactMap { if case .message(let message) = $0 { return message } else { return nil } }
    }

    /// Only the binary `.audio` frames (page audio, page images and live
    /// reply audio all arrive this way).
    var audioFrames: [Data] {
        events.compactMap { if case .audio(let data) = $0 { return data } else { return nil } }
    }

    func stop() { task?.cancel() }

    /// Polls until at least `count` events have arrived (or the timeout
    /// passes) and returns everything recorded so far.
    @discardableResult
    func waitForCount(_ count: Int, timeout: TimeInterval = 3) async -> [ServerConnectionEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while events.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return events
    }

    /// Waits a fixed quiet period and returns whatever arrived -- for
    /// asserting that NOTHING (more) was emitted.
    func settle(nanoseconds: UInt64 = 150_000_000) async -> [ServerConnectionEvent] {
        try? await Task.sleep(nanoseconds: nanoseconds)
        return events
    }
}

/// Synthesizes a fixed list of chunks, optionally with a real delay between
/// them (and honouring cancellation), and records every text it was asked
/// to speak.
final class ChunkedTtsClient: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _synthesizedTexts: [String] = []
    private let chunks: [Data]
    private let delayNanos: UInt64

    init(chunks: [Data], delayNanos: UInt64 = 0) {
        self.chunks = chunks
        self.delayNanos = delayNanos
    }

    var synthesizedTexts: [String] { lock.withLock { _synthesizedTexts } }

    func synthesize(_ text: String) -> AsyncStream<Data> {
        lock.withLock { _synthesizedTexts.append(text) }
        let chunks = self.chunks
        let delayNanos = self.delayNanos
        return AsyncStream { continuation in
            let task = Task {
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                    if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
````

- [ ] **Step 3: Add the new `DemoConnection` tests** (22 new tests, appended after the 4 existing ones). Apply this diff to `DemoConnectionTests.swift`:

````diff
--- a/ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConnectionTests.swift
+++ b/ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConnectionTests.swift
@@ -187,4 +187,481 @@ final class DemoConnectionTests: XCTestCase {
         XCTAssertNotNil(completed)
         XCTAssertEqual(completed?.turns.last?.speaker, "agent")
     }
+
+    // MARK: - shared helpers for the local-server behavior below
+
+    private func makeStore() -> LocalStoryStore {
+        LocalStoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
+    }
+
+    private func payload(id: String) -> PendingDemoStoryPayload {
+        PendingDemoStoryPayload(
+            id: id,
+            createdAt: "2026-09-19T12:00:00Z",
+            turns: [
+                PendingDemoStoryTurn(speaker: "child", text: "tell me about a fox", interrupted: false),
+                PendingDemoStoryTurn(speaker: "agent", text: "Once there was a clever fox. The end.", interrupted: false),
+            ],
+            sharedFacts: []
+        )
+    }
+
+    private func storybookJSON(pages: [String] = ["Page one.", "Page two."]) -> String {
+        let object: [String: Any] = ["title": "Pip the Fox", "pages": pages.map { ["text": $0] }]
+        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
+    }
+
+    private func makeLibraryConnection(
+        chat: any ChatCompleting,
+        library: DemoStoryLibrary?,
+        tts: any SpeechSynthesizing = FakeTtsClient(),
+        targetTurns: Int = 7,
+        pageCount: Int = 5,
+        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
+    ) -> DemoConnection {
+        DemoConnection(
+            chatClient: chat,
+            sttClient: FakeSttClient(),
+            ttsClient: tts,
+            animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher()),
+            targetTurns: targetTurns,
+            pageCount: pageCount,
+            library: library,
+            onStoryCompleted: onStoryCompleted
+        )
+    }
+
+    /// One complete ordinary turn (transcript, reply, audio, turn end),
+    /// waiting until the recorder has seen `total` events in all.
+    private func speak(_ connection: DemoConnection, recorder: EventRecorder, turnId: Int, total: Int) async throws {
+        try await connection.send(.speechStart(turnId: turnId))
+        try await connection.send(audio: Data(repeating: 0, count: 100))
+        try await connection.send(.speechEnd)
+        await recorder.waitForCount(total)
+    }
+
+    private func systemPrompt(of call: [[String: String]]) -> String { call[0]["content"] ?? "" }
+
+    // MARK: - update_settings
+
+    func testUpdateSettingsBeforeTheFirstTurnAppliesToThatStory() async throws {
+        let chat = FakeChatClient()
+        let connection = makeConnection(chat: chat)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.updateSettings(targetTurns: 4, pageCount: 3))
+        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
+        try await speak(connection, recorder: recorder, turnId: 2, total: 8)
+
+        // Turn 2 of a 4-turn story is "rising action"; under the default 7
+        // it would still be "setup" -- so this proves the new value was used.
+        XCTAssertTrue(systemPrompt(of: chat.receivedMessages[1]).contains("The story is building."))
+    }
+
+    func testUpdateSettingsMidStoryDoesNotChangeTheStoryInProgress() async throws {
+        let chat = FakeChatClient()
+        let connection = makeConnection(chat: chat)
+        let recorder = EventRecorder(connection)
+
+        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
+        try await connection.send(.updateSettings(targetTurns: 4, pageCount: 3))
+        try await speak(connection, recorder: recorder, turnId: 2, total: 8)
+
+        // Never retroactive: turn 2 is still "setup" under the story's
+        // original 7-turn arc, even though the setting changed in between.
+        let prompt = systemPrompt(of: chat.receivedMessages[1])
+        XCTAssertTrue(prompt.contains("Continue introducing the setting"))
+        XCTAssertFalse(prompt.contains("The story is building."))
+    }
+
+    func testUpdateSettingsClampsTurnsToTheServersLowerBound() async throws {
+        let chat = FakeChatClient()
+        let connection = makeConnection(chat: chat)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.updateSettings(targetTurns: 1, pageCount: 5))
+        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
+        try await speak(connection, recorder: recorder, turnId: 2, total: 8)
+
+        // Unclamped, a 1-turn story would jump straight to "resolution" on
+        // turn 2. Clamped to the server's minimum of 4 it is "rising action".
+        let prompt = systemPrompt(of: chat.receivedMessages[1])
+        XCTAssertTrue(prompt.contains("The story is building."))
+        XCTAssertFalse(prompt.contains("It's time to resolve"))
+    }
+
+    func testUpdateSettingsIsSilent() async throws {
+        let connection = makeConnection()
+        let recorder = EventRecorder(connection)
+        try await connection.send(.updateSettings(targetTurns: 6, pageCount: 4))
+        let events = await recorder.settle()
+        XCTAssertTrue(events.isEmpty)
+    }
+
+    // MARK: - list_stories / get_story
+
+    func testListStoriesAnswersWithTheLibrarysStories() async throws {
+        let chat = ScriptedChatClient(storybookJSON())
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        library.begin(payload(id: "abc"), pageCount: 2)
+        let connection = makeLibraryConnection(chat: chat, library: library)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.listStories)
+
+        let events = await recorder.waitForCount(1)
+        guard case .message(.storyList(let stories)) = events[0] else {
+            return XCTFail("expected storyList, got \(events[0])")
+        }
+        XCTAssertEqual(stories.map(\.id), ["abc"])
+        XCTAssertEqual(stories[0].rewriteStatus, .pending)
+    }
+
+    func testListStoriesWithoutALibraryAnswersWithAnEmptyListRatherThanSilence() async throws {
+        let connection = makeConnection()
+        let recorder = EventRecorder(connection)
+        try await connection.send(.listStories)
+        let events = await recorder.waitForCount(1)
+        guard case .message(.storyList(let stories)) = events[0] else {
+            return XCTFail("expected storyList, got \(events[0])")
+        }
+        XCTAssertEqual(stories, [])
+    }
+
+    func testGetStoryAnswersWithTheStoryDetail() async throws {
+        let chat = ScriptedChatClient(storybookJSON())
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        library.begin(payload(id: "abc"), pageCount: 2)
+        await library.buildStorybook(id: "abc")
+        let connection = makeLibraryConnection(chat: chat, library: library)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.getStory(storyId: "abc"))
+
+        let events = await recorder.waitForCount(1)
+        guard case .message(.storyDetail(let detail)) = events[0] else {
+            return XCTFail("expected storyDetail, got \(events[0])")
+        }
+        XCTAssertEqual(detail.id, "abc")
+        XCTAssertEqual(detail.title, "Pip the Fox")
+        XCTAssertEqual(detail.pages.map(\.text), ["Page one.", "Page two."])
+    }
+
+    // MARK: - story conclusion -> storybook
+
+    private static let closingReply = "And they all lived happily ever after. The end."
+
+    func testConclusionEmitsRewritingStartedThenRewritingDoneAfterTurnEnd() async throws {
+        let chat = ScriptedChatClient(Self.closingReply, storybookJSON())
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        var completed: PendingDemoStoryPayload?
+        let connection = makeLibraryConnection(chat: chat, library: library, onStoryCompleted: { completed = $0 })
+        let recorder = EventRecorder(connection)
+
+        try await speak(connection, recorder: recorder, turnId: 1, total: 6)
+
+        let events = recorder.events
+        XCTAssertEqual(events.count, 6, "transcriptFinal, responseText, audio, turnEnd, rewritingStarted, rewritingDone")
+        guard case .message(.transcriptFinal) = events[0],
+              case .message(.responseText) = events[1],
+              case .audio = events[2],
+              case .message(.turnEnd(let turnId)) = events[3],
+              case .message(.rewritingStarted) = events[4],
+              case .message(.rewritingDone) = events[5]
+        else { return XCTFail("unexpected event order: \(events)") }
+        XCTAssertEqual(turnId, 1)
+        XCTAssertNotNil(completed, "the transcript must be queued for sync before rewriting_started")
+
+        let saved = try XCTUnwrap(library.detail(id: try XCTUnwrap(completed?.id)))
+        XCTAssertEqual(saved.rewriteStatus, .done)
+        XCTAssertEqual(saved.title, "Pip the Fox")
+    }
+
+    func testAFailedRewriteStillReleasesRewritingDone() async throws {
+        let chat = ScriptedChatClient(Self.closingReply, "this is not json at all")
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        var completed: PendingDemoStoryPayload?
+        let connection = makeLibraryConnection(chat: chat, library: library, onStoryCompleted: { completed = $0 })
+        let recorder = EventRecorder(connection)
+
+        try await speak(connection, recorder: recorder, turnId: 1, total: 6)
+
+        guard case .message(.rewritingDone) = recorder.events.last else {
+            return XCTFail("rewriting_done must always follow rewriting_started, even when the rewrite fails")
+        }
+        XCTAssertEqual(library.detail(id: try XCTUnwrap(completed?.id))?.rewriteStatus, .failed)
+    }
+
+    func testWithoutALibraryAConclusionEmitsNoRewritingEvents() async throws {
+        let chat = FakeChatClient()
+        chat.replyText = Self.closingReply
+        let connection = makeConnection(chat: chat)
+        let recorder = EventRecorder(connection)
+
+        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
+        let events = await recorder.settle()
+
+        XCTAssertEqual(events.count, 4)
+        XCTAssertFalse(recorder.messages.contains(.rewritingStarted))
+    }
+
+    func testAStorybookAsksForThePageCountInForceWhenItsStoryBegan() async throws {
+        // A story only counts as underway once its first turn has been
+        // recorded (StoryArc.hasStarted, as on the server) -- so story 1
+        // completes one ordinary turn under 5 pages, THEN the parent lowers
+        // it to 3. Story 1 must still ask for 5 (never retroactive); story
+        // 2, which begins after the change, asks for 3.
+        let ordinaryReply = "Once upon a time, a fox went for a walk. What happens next?"
+        let chat = ScriptedChatClient(
+            ordinaryReply, Self.closingReply, storybookJSON(), // story 1: turn, concluding turn, rewrite
+            Self.closingReply, storybookJSON() // story 2: concluding turn, rewrite
+        )
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        let connection = makeLibraryConnection(chat: chat, library: library, pageCount: 5)
+        let recorder = EventRecorder(connection)
+
+        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
+        try await connection.send(.updateSettings(targetTurns: 7, pageCount: 3))
+        try await speak(connection, recorder: recorder, turnId: 2, total: 10)
+        try await speak(connection, recorder: recorder, turnId: 3, total: 16)
+
+        let firstRewritePrompt = chat.receivedMessages[2][1]["content"] ?? ""
+        let secondRewritePrompt = chat.receivedMessages[4][1]["content"] ?? ""
+        XCTAssertTrue(firstRewritePrompt.contains("exactly 5 pages"), "story 1 began under 5 pages")
+        XCTAssertTrue(secondRewritePrompt.contains("exactly 3 pages"), "story 2 began after the change")
+    }
+
+    // MARK: - "Finish this story" (conclude_story)
+
+    func testConcludeStoryRunsOneTurnWithNoTranscriptThenTheConclusionFlow() async throws {
+        let chat = ScriptedChatClient("The fox went home and slept. The end.", storybookJSON())
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        let connection = makeLibraryConnection(chat: chat, library: library)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.concludeStory(turnId: 3))
+        let events = await recorder.waitForCount(5)
+
+        XCTAssertEqual(events.count, 5, "responseText, audio, turnEnd, rewritingStarted, rewritingDone")
+        guard case .message(.responseText(_, let responseTurn)) = events[0],
+              case .audio = events[1],
+              case .message(.turnEnd(let endTurn)) = events[2],
+              case .message(.rewritingStarted) = events[3],
+              case .message(.rewritingDone) = events[4]
+        else { return XCTFail("unexpected event order: \(events)") }
+        XCTAssertEqual(responseTurn, 3)
+        XCTAssertEqual(endTurn, 3)
+        // Like the server, a forced conclusion skips STT entirely.
+        XCTAssertFalse(recorder.messages.contains { if case .transcriptFinal = $0 { return true } else { return false } })
+        XCTAssertTrue(systemPrompt(of: chat.receivedMessages[0]).contains("This must be the last reply"))
+    }
+
+    func testConcludeStoryEndsTheStoryEvenWhenTheReplyLacksAClosingPhrase() async throws {
+        let chat = ScriptedChatClient("The fox went home and slept.", storybookJSON())
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
+        let connection = makeLibraryConnection(chat: chat, library: library)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.concludeStory(turnId: 3))
+        await recorder.waitForCount(5)
+
+        XCTAssertTrue(recorder.messages.contains(.rewritingStarted),
+                      "an explicit request to finish must end the story regardless of the reply's wording")
+    }
+
+    func testConcludeStoryRetriesAFlaggedEndingWithTheFlaggedWordFedBack() async throws {
+        let chat = ScriptedChatClient("He picked up the knife. The end.", "The fox went home. The end.")
+        let connection = makeLibraryConnection(chat: chat, library: nil)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.concludeStory(turnId: 3))
+        await recorder.waitForCount(3)
+
+        XCTAssertEqual(chat.callCount, 2)
+        XCTAssertTrue((chat.receivedMessages[1].last?["content"] ?? "").contains("knife"))
+        guard case .message(.responseText(let reply, _)) = recorder.events[0] else {
+            return XCTFail("expected responseText first")
+        }
+        XCTAssertEqual(reply, "The fox went home. The end.")
+    }
+
+    func testConcludeStoryFallsBackOnlyAfterEveryRetryIsFlagged() async throws {
+        let chat = ScriptedChatClient("He picked up the knife. The end.")
+        let connection = makeLibraryConnection(chat: chat, library: nil)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.concludeStory(turnId: 3))
+        await recorder.waitForCount(3)
+
+        XCTAssertEqual(chat.callCount, DemoConnection.concludeSafetyRetryAttempts)
+        guard case .message(.responseText(let reply, _)) = recorder.events[0] else {
+            return XCTFail("expected responseText first")
+        }
+        XCTAssertEqual(reply, Safety.safeFallback, "the generic fallback is a last resort, not the first answer")
+    }
+
+    func testConcludeStoryNudgesAnEmptyReplyInsteadOfResubmittingItUnchanged() async throws {
+        let chat = ScriptedChatClient("", "All done now. The end.")
+        let connection = makeLibraryConnection(chat: chat, library: nil)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.concludeStory(turnId: 3))
+        await recorder.waitForCount(3)
+
+        XCTAssertEqual(chat.callCount, 2)
+        XCTAssertEqual(chat.receivedMessages[1].last?["content"], DemoConnection.concludeEmptyRetryNudge)
+    }
+
+    // MARK: - synthesize_page / get_page_image
+
+    /// A library holding one finished two-page story "abc": page 0 has a
+    /// picture, page 1 doesn't.
+    private func makeIllustratedLibrary() async -> DemoStoryLibrary {
+        let chat = ScriptedChatClient(storybookJSON(pages: ["First page.", "Second page."]))
+        let illustrator = FakeIllustrator(result: IllustrationResult(images: [Data([1, 2, 3]), nil], status: .partial))
+        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat), illustrator: illustrator)
+        library.begin(payload(id: "abc"), pageCount: 2)
+        await library.buildStorybook(id: "abc")
+        return library
+    }
+
+    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
+        let deadline = Date().addingTimeInterval(timeout)
+        while !condition() && Date() < deadline {
+            try? await Task.sleep(nanoseconds: 5_000_000)
+        }
+    }
+
+    private func kind(_ event: ServerConnectionEvent) -> String {
+        switch event {
+        case .audio: return "audio"
+        case .closed: return "closed"
+        case .message(let message):
+            switch message {
+            case .transcriptFinal: return "transcript"
+            case .responseText: return "response"
+            case .turnEnd: return "turnEnd"
+            case .pageAudioDone: return "pageAudioDone"
+            case .pageImageDone: return "pageImageDone"
+            case .error: return "error"
+            default: return "other"
+            }
+        }
+    }
+
+    func testSynthesizePageStreamsTheChunksThenTheDoneMarker() async throws {
+        let library = await makeIllustratedLibrary()
+        let tts = ChunkedTtsClient(chunks: [Data([1]), Data([2]), Data([3])])
+        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library, tts: tts)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 1))
+        await recorder.waitForCount(4)
+
+        XCTAssertEqual(recorder.audioFrames, [Data([1]), Data([2]), Data([3])])
+        XCTAssertEqual(recorder.messages, [.pageAudioDone(storyId: "abc", pageIndex: 1)])
+        XCTAssertEqual(tts.synthesizedTexts, ["Second page."])
+    }
+
+    func testSynthesizePageOfABadStoryOrPageAnswersWithAnErrorAndNoDoneMarker() async throws {
+        let library = await makeIllustratedLibrary()
+        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.synthesizePage(storyId: "ghost", pageIndex: 0))
+        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 5))
+        let events = await recorder.waitForCount(2)
+
+        XCTAssertEqual(events.count, 2)
+        guard case .message(.error(let first, _)) = events[0], case .message(.error(let second, _)) = events[1] else {
+            return XCTFail("expected two error frames, got \(events)")
+        }
+        XCTAssertEqual(first, "no page 0 for story 'ghost'")
+        XCTAssertEqual(second, "no page 5 for story 'abc'")
+        XCTAssertTrue(recorder.audioFrames.isEmpty)
+    }
+
+    func testACancelledPageAudioRequestStillEndsWithItsDoneMarker() async throws {
+        // A request that just went quiet would leave SessionCoordinator's
+        // page request pending forever, diverting all later live audio into
+        // page playback -- so a barge-in must still terminate it.
+        let library = await makeIllustratedLibrary()
+        let tts = ChunkedTtsClient(chunks: Array(repeating: Data([9]), count: 20), delayNanos: 30_000_000)
+        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library, tts: tts)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 0))
+        await recorder.waitForCount(1) // the first chunk is out
+        try await connection.send(.speechStart(turnId: 9)) // the child starts talking
+        await waitUntil { recorder.messages.contains(.pageAudioDone(storyId: "abc", pageIndex: 0)) }
+
+        XCTAssertTrue(recorder.messages.contains(.pageAudioDone(storyId: "abc", pageIndex: 0)))
+        XCTAssertLessThan(recorder.audioFrames.count, 20, "cancelling must stop the stream early")
+    }
+
+    func testPageAudioWaitsForAnInFlightLiveTurnInsteadOfInterleavingWithIt() async throws {
+        let library = await makeIllustratedLibrary()
+        let gate = GatedChatClient(reply: "Once upon a time. What happens next?")
+        let tts = ChunkedTtsClient(chunks: [Data([7])])
+        let connection = makeLibraryConnection(chat: gate, library: library, tts: tts)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.speechStart(turnId: 1))
+        try await connection.send(audio: Data(repeating: 0, count: 100))
+        try await connection.send(.speechEnd) // the turn now blocks inside the chat call
+        await recorder.waitForCount(1) // its transcript
+        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 0))
+
+        let whileTheTurnIsInFlight = await recorder.settle()
+        XCTAssertEqual(whileTheTurnIsInFlight.count, 1, "page audio must wait for the live turn, not interleave with it")
+
+        gate.release()
+        await waitUntil { recorder.messages.contains(.pageAudioDone(storyId: "abc", pageIndex: 0)) }
+
+        XCTAssertEqual(
+            recorder.events.map(kind),
+            ["transcript", "response", "audio", "turnEnd", "audio", "pageAudioDone"],
+            "the live turn's frames must all precede the page's"
+        )
+    }
+
+    func testGetPageImageSendsTheBytesThenTheDoneMarkerOrJustTheMarker() async throws {
+        let library = await makeIllustratedLibrary()
+        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library)
+        let recorder = EventRecorder(connection)
+
+        try await connection.send(.getPageImage(storyId: "abc", pageIndex: 0)) // has a picture
+        try await connection.send(.getPageImage(storyId: "abc", pageIndex: 1)) // has none
+        try await connection.send(.getPageImage(storyId: "abc", pageIndex: 9)) // no such page
+        await recorder.waitForCount(4)
+
+        let events = recorder.events
+        XCTAssertEqual(events.count, 4)
+        guard case .audio(let bytes) = events[0],
+              case .message(.pageImageDone(_, let firstIndex, let firstHasImage)) = events[1],
+              case .message(.pageImageDone(_, let secondIndex, let secondHasImage)) = events[2],
+              case .message(.error(let message, _)) = events[3]
+        else { return XCTFail("unexpected events: \(events)") }
+        XCTAssertEqual(bytes, Data([1, 2, 3]))
+        XCTAssertEqual(firstIndex, 0)
+        XCTAssertTrue(firstHasImage)
+        XCTAssertEqual(secondIndex, 1)
+        XCTAssertFalse(secondHasImage)
+        XCTAssertEqual(message, "no page 9 for story 'abc'")
+    }
+
+    func testGetStoryOfAnUnknownIdAnswersWithAnErrorFrameCarryingTheCurrentTurnId() async throws {
+        let connection = makeLibraryConnection(chat: FakeChatClient(), library: nil)
+        let recorder = EventRecorder(connection)
+        try await connection.send(.speechStart(turnId: 7)) // sets the current turn id, emits nothing
+
+        try await connection.send(.getStory(storyId: "ghost"))
+
+        let events = await recorder.waitForCount(1)
+        guard case .message(.error(let message, let turnId)) = events[0] else {
+            return XCTFail("expected an error frame, got \(events[0])")
+        }
+        XCTAssertEqual(message, "no saved story with id 'ghost'")
+        XCTAssertEqual(turnId, 7)
+    }
 }
````

- [ ] **Step 4: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter DemoConnectionTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `extra argument 'library' in call` (and `pageCount`).

- [ ] **Step 5: Replace `DemoConnection.swift` with the complete file.**

````swift
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

    /// Mirrors config.CONCLUDE_SAFETY_RETRY_ATTEMPTS.
    static let concludeSafetyRetryAttempts = 3

    /// Fed back when a forced conclusion trips the kid-safety check --
    /// mirrors session.py's _CONCLUDE_SAFETY_RETRY_TEMPLATE.
    static func concludeSafetyRetryPrompt(terms: String) -> String {
        "That reply isn't appropriate for a young child -- it mentioned: " +
        "\(terms). Give the same warm, complete ending again, same story, but " +
        "leave out any mention of that. Remember: this must be the last " +
        "reply, and it should end with the words \"The end.\""
    }

    /// Fed back when a forced-conclude attempt comes back empty --
    /// mirrors session.py's _CONCLUDE_EMPTY_RETRY_NUDGE.
    static let concludeEmptyRetryNudge =
        "You didn't write anything. Please write your ending now -- a few " +
        "warm sentences that finish the story, ending with the words " +
        "\"The end.\""

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
    private let library: DemoStoryLibrary?
    private let onStoryCompleted: ((PendingDemoStoryPayload) -> Void)?

    /// Optional hook for surfacing DemoConnection's diagnostic lines into
    /// the same on-screen debug log RealAudioEngine.onDebugEvent and
    /// SessionCoordinator.debugLog already feed -- see AudioEngine.swift's
    /// onDebugEvent doc comment for the shared pattern this mirrors, and
    /// DebugTimestamp's doc comment for why a shared, thread-safe formatter
    /// matters here specifically (runTurn runs on a background Task, not a
    /// fixed thread). Pre-timestamped here (not left to the caller) so it
    /// sorts correctly against those other sources' own timestamped lines
    /// after merging.
    public var onDebugEvent: (@Sendable (String) -> Void)?

    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>

    private let lock = NSLock()
    private var currentTurnId = 0
    private var audioBuffer = Data()
    private var conversation = DemoConversation()
    private var storyArc: StoryArc
    private var objectTracker = ObjectTracker()
    private var turnTask: Task<Void, Never>?
    /// The chain of page-browsing media requests (page audio, page images)
    /// -- see startMediaTask().
    private var mediaTask: Task<Void, Never>?
    /// The parent's story-length settings (see the .updateSettings case).
    /// Lock-protected like everything above since a settings change can
    /// arrive on any task. They apply to the NEXT story only.
    private var targetTurns: Int
    private var pageCount: Int
    /// The page count in force when the CURRENT story began -- what its
    /// storybook rewrite will ask for. Captured at story start (not read at
    /// conclusion) so a mid-story settings change never applies
    /// retroactively.
    private var storyPageCount: Int

    public init(
        chatClient: any ChatCompleting,
        sttClient: any SpeechTranscribing,
        ttsClient: any SpeechSynthesizing,
        animalFactTracker: AnimalFactTracker,
        systemPrompt: String = DemoConnection.defaultSystemPrompt,
        targetTurns: Int = 7,
        pageCount: Int = 5,
        library: DemoStoryLibrary? = nil,
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) {
        self.chatClient = chatClient
        self.sttClient = sttClient
        self.ttsClient = ttsClient
        self.animalFactTracker = animalFactTracker
        self.systemPrompt = systemPrompt
        self.targetTurns = targetTurns
        self.pageCount = pageCount
        self.storyPageCount = pageCount
        self.library = library
        self.onStoryCompleted = onStoryCompleted
        self.storyArc = StoryArc(targetTurns: targetTurns)
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
    }

    /// Starts a fresh story with the CURRENT settings: a new arc, and the
    /// page count its storybook will be asked for. Caller must hold `lock`.
    /// Mirrors SessionRunner._begin_story() server-side.
    private func beginStoryLocked() {
        storyArc = StoryArc(targetTurns: targetTurns)
        storyPageCount = pageCount
    }

    private func currentTurn() -> Int {
        lock.withLockReturning { currentTurnId }
    }

    public func send(_ message: ClientMessage) async throws {
        switch message {
        case .speechStart(let turnId):
            lock.withLock {
                mediaTask?.cancel()
                mediaTask = nil
                turnTask?.cancel()
                turnTask = nil
                currentTurnId = turnId
                audioBuffer = Data()
            }
        case .speechEnd:
            let (turnId, pcm) = lock.withLockReturning { (currentTurnId, audioBuffer) }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runTurn(turnId: turnId, pcm: pcm)
            }
            lock.withLock { turnTask = task }
        case .interrupt(let turnId):
            lock.withLock {
                mediaTask?.cancel()
                mediaTask = nil
                turnTask?.cancel()
                turnTask = nil
                currentTurnId = turnId
                audioBuffer = Data()
            }
        case .objectSeen(let label):
            let tracker = lock.withLockReturning { objectTracker }
            tracker.recordSeen(label: label)
        case .newStory:
            lock.withLock {
                mediaTask?.cancel()
                mediaTask = nil
                turnTask?.cancel()
                turnTask = nil
                conversation = DemoConversation()
                beginStoryLocked()
                objectTracker = ObjectTracker()
            }
            await animalFactTracker.reset()
        case .updateSettings(let turns, let pages):
            // Same bounds SessionRunner.handle_update_settings enforces
            // server-side (turns 4-12, pages 3-10). Applies to the NEXT
            // story only: an arc that hasn't started is rebuilt now (so the
            // very next story uses it); one already in progress is left
            // alone -- never retroactive.
            lock.withLock {
                targetTurns = max(4, min(12, turns))
                pageCount = max(3, min(10, pages))
                if !storyArc.hasStarted { beginStoryLocked() }
            }
        case .listStories:
            continuation.yield(.message(.storyList(library?.list() ?? [])))
        case .getStory(let storyId):
            if let detail = library?.detail(id: storyId) {
                continuation.yield(.message(.storyDetail(detail)))
            } else {
                continuation.yield(.message(.error("no saved story with id '\(storyId)'", turnId: currentTurn())))
            }
        case .concludeStory(let turnId):
            // Same as a barge-in first: whatever was in flight is abandoned.
            lock.withLock {
                mediaTask?.cancel()
                mediaTask = nil
                turnTask?.cancel()
                turnTask = nil
                currentTurnId = turnId
                audioBuffer = Data()
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runTurn(turnId: turnId, pcm: Data(), forceConclude: true)
            }
            lock.withLock { turnTask = task }
        case .getPageImage(let storyId, let pageIndex):
            startMediaTask { [weak self] in
                await self?.runPageImage(storyId: storyId, pageIndex: pageIndex)
            }
        case .synthesizePage(let storyId, let pageIndex):
            startMediaTask { [weak self] in
                await self?.runPageAudio(storyId: storyId, pageIndex: pageIndex)
            }
        case .syncDemoStories:
            // Genuinely never sent here: it is only issued by
            // AppModel.connect()'s real (LAN) path, once already reconnected
            // to the actual server (see SessionCoordinator.syncDemoStories).
            // An explicit no-op -- deliberately not folded into a shared
            // catch-all, so a NEW ClientMessage case can never silently
            // inherit "do nothing" (see DemoProtocolParityTests).
            break
        }
    }

    /// Runs page-browsing media work (page audio, page images) strictly in
    /// arrival order, and never while a live turn is still producing its own
    /// audio. Two reasons, both about the real server's behavior that
    /// DemoConnection must reproduce: SessionCoordinator routes an .audio
    /// frame to page playback whenever a page request is pending and to the
    /// live turn otherwise, which is only correct if frames from the two
    /// never interleave (the server guarantees that by handling one message
    /// at a time to completion); and AVSpeechTts shares one
    /// AVSpeechSynthesizer across every synthesize() call, so two
    /// overlapping ones would cut each other off.
    private func startMediaTask(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = mediaTask
            let inFlightTurn = turnTask
            mediaTask = Task {
                await previous?.value
                await inFlightTurn?.value
                await work()
            }
        }
    }

    /// Every synthesize_page request ends with EXACTLY ONE terminating
    /// frame -- page_audio_done, or an error for a bad story/page -- even
    /// when cancelled part-way (a barge-in, a new story, close()).
    /// SessionCoordinator keeps a request "pending" until one of those
    /// arrives, and a pending request diverts every later audio frame into
    /// page playback; a request that simply went quiet would wedge live
    /// story audio.
    private func runPageAudio(storyId: String, pageIndex: Int) async {
        guard let text = library?.pageText(id: storyId, index: pageIndex) else {
            continuation.yield(.message(.error(
                "no page \(pageIndex) for story '\(storyId)'", turnId: currentTurn()
            )))
            return
        }
        if !Task.isCancelled {
            for await chunk in ttsClient.synthesize(text) {
                if Task.isCancelled { break }
                continuation.yield(.audio(chunk))
            }
        }
        continuation.yield(.message(.pageAudioDone(storyId: storyId, pageIndex: pageIndex)))
    }

    /// One binary frame then page_image_done(hasImage: true) when the page
    /// has a picture; page_image_done(hasImage: false) alone when it
    /// doesn't; an error frame for a bad story/page -- matching the real
    /// server's handle_get_page_image.
    private func runPageImage(storyId: String, pageIndex: Int) async {
        guard library?.pageText(id: storyId, index: pageIndex) != nil else {
            continuation.yield(.message(.error(
                "no page \(pageIndex) for story '\(storyId)'", turnId: currentTurn()
            )))
            return
        }
        if let image = library?.pageImage(id: storyId, index: pageIndex) {
            continuation.yield(.audio(image))
            continuation.yield(.message(.pageImageDone(storyId: storyId, pageIndex: pageIndex, hasImage: true)))
        } else {
            continuation.yield(.message(.pageImageDone(storyId: storyId, pageIndex: pageIndex, hasImage: false)))
        }
    }

    public func send(audio pcm: Data) async throws {
        lock.withLock { audioBuffer.append(pcm) }
    }

    public func events() -> AsyncStream<ServerConnectionEvent> { stream }

    public func close() {
        lock.lock()
        mediaTask?.cancel(); mediaTask = nil
        turnTask?.cancel(); turnTask = nil
        lock.unlock()
        continuation.finish()
    }

    /// Captures conversation/storyArc/objectTracker once, under lock, at
    /// the top of the turn -- and operates only on those captured locals
    /// for the rest of the turn. This is deliberate: those three
    /// properties can be reassigned to fresh instances mid-turn by a
    /// concurrent .newStory (or by another turn's completeStory()), and
    /// reading `self.x` fresh at each use site -- as this used to do --
    /// let a still-running turn silently read/write whichever instance
    /// happened to be current at that exact statement, which is how a
    /// just-concluded story could be lost or a reply could leak into the
    /// wrong story's transcript. See task-13-report.md's fix-up entry.
    private func runTurn(turnId: Int, pcm: Data, forceConclude: Bool = false) async {
        let (localConversation, localStoryArc, localObjectTracker, localPageCount) = lock.withLockReturning {
            (conversation, storyArc, objectTracker, storyPageCount)
        }
        do {
            try Task.checkCancellation()
            // "Finish this story" has no child audio: like the server (whose
            // forced conclusion skips STT), no transcript is produced or emitted.
            let transcript: String
            if forceConclude {
                transcript = ""
            } else {
                transcript = try await sttClient.transcribe(pcm)
                try Task.checkCancellation()
                continuation.yield(.message(.transcriptFinal(transcript, turnId: turnId)))
            }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                localConversation.addChild(trimmed)
            }

            // forceConcludeGuidance() deliberately does NOT advance the arc's
            // turn count (an out-of-band final turn, not the next turn of the
            // normal budget), same as story_arc.py.
            var guidance = forceConclude
                ? localStoryArc.forceConcludeGuidance()
                : localStoryArc.recordTurn(childText: transcript)
            let factGuidance = await animalFactTracker.recordTurn(transcript: transcript, stage: localStoryArc.stage)
            if !factGuidance.isEmpty {
                guidance += "\n\n" + factGuidance
                // On-device testing had no way to confirm whether a fact
                // was actually found and woven in, or whether the
                // mechanism never fired -- same visibility gap the TTS
                // debug logging above already closed.
                onDebugEvent?("[\(DebugTimestamp.now())] animal fact guidance added for turn \(turnId)")
            }
            let objectGuidance = localObjectTracker.consumeGuidance()
            if !objectGuidance.isEmpty {
                guidance += "\n\n" + objectGuidance
                onDebugEvent?("[\(DebugTimestamp.now())] object recognition guidance added for turn \(turnId)")
            }
            if trimmed.isEmpty && !forceConclude { guidance += "\n\n" + Self.sttFailureGuidance }

            var messages = localConversation.toMessages(systemPrompt: systemPrompt + "\n\n" + guidance)
            try Task.checkCancellation()
            var raw = try await chatClient.complete(messages: messages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            var reply = Safety.filterReply(raw)
            if forceConclude {
                // An explicit "finish this story" request must not end on the
                // generic safety-fallback line ("...What should happen next?")
                // -- unlike an ordinary turn, where the conversation simply
                // continues, this reply becomes the story's permanent ending.
                // Retry with the flagged word(s) fed back (mirrors
                // session.py's forced-conclude retry) before finally
                // accepting the fallback as a last resort.
                var attempt = 1
                while reply == Safety.safeFallback && attempt < Self.concludeSafetyRetryAttempts {
                    attempt += 1
                    let blocked = Safety.findBlocked(raw)
                    if blocked.isEmpty {
                        // filterReply() also falls back on a genuinely empty
                        // completion -- nothing to name, so nudge the model
                        // to actually write something.
                        messages.append(["role": "user", "content": Self.concludeEmptyRetryNudge])
                    } else {
                        messages.append(["role": "assistant", "content": raw])
                        messages.append([
                            "role": "user",
                            "content": Self.concludeSafetyRetryPrompt(terms: blocked.joined(separator: ", ")),
                        ])
                    }
                    try Task.checkCancellation()
                    raw = try await chatClient.complete(messages: messages)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    reply = Safety.filterReply(raw)
                }
                // Unconditional: an explicit request to finish must not be
                // able to silently fail to end because the reply's wording
                // happens not to match a natural-conclusion phrase.
                localStoryArc.markDone()
            } else {
                localStoryArc.recordReply(replyText: reply)
            }

            continuation.yield(.message(.responseText(reply, turnId: turnId)))

            var ttsChunkCount = 0
            var ttsTotalBytes = 0
            var ttsMinChunkBytes = Int.max
            var ttsMaxChunkBytes = 0
            let synthesisStarted = DispatchTime.now()
            for await pcmChunk in ttsClient.synthesize(reply) {
                try Task.checkCancellation()
                ttsChunkCount += 1
                ttsTotalBytes += pcmChunk.count
                ttsMinChunkBytes = min(ttsMinChunkBytes, pcmChunk.count)
                ttsMaxChunkBytes = max(ttsMaxChunkBytes, pcmChunk.count)
                continuation.yield(.audio(pcmChunk))
            }
            let synthesisElapsedSeconds =
                Double(DispatchTime.now().uptimeNanoseconds - synthesisStarted.uptimeNanoseconds) / 1_000_000_000
            if ttsChunkCount == 0 {
                onDebugEvent?("[\(DebugTimestamp.now())] TTS produced 0 bytes for turn \(turnId)")
            } else {
                // Diagnostic for the on-device-reported garbled/stuttering
                // audio. Chunk count/size distribution and implied audio
                // duration (24kHz mono PCM16 = 48000 bytes/sec) already
                // confirmed the "tch tch tch" cause (AVSpeechSynthesizer.
                // write()'s ~11ms native buffers vs RealAudioEngine.play()'s
                // fully-sequential per-buffer playback wait -- fixed by
                // coalescing in AVSpeechTts). Comparing synthesisElapsedSeconds
                // (this loop's own wall-clock time) against the audio's
                // implied duration tests a different, still-open hypothesis
                // for the residual stutter: production (this loop, yielding
                // into continuation) and playback (SessionCoordinator's
                // separate consuming task, downstream of the same
                // AsyncStream) run concurrently, not sequentially -- if
                // on-device synthesis can't keep up with realtime under
                // concurrent VAD/mic-capture/TTS load, the playback consumer
                // would starve waiting for the next chunk with each
                // individual play() call still measuring perfectly normal,
                // which a play()-side timing check alone could never catch.
                let impliedSeconds = Double(ttsTotalBytes) / 48_000.0
                onDebugEvent?(
                    "[\(DebugTimestamp.now())] TTS for turn \(turnId): \(ttsChunkCount) chunks, " +
                    "\(ttsTotalBytes) bytes (~\(String(format: "%.2f", impliedSeconds))s audio), " +
                    "chunk size \(ttsMinChunkBytes)-\(ttsMaxChunkBytes) bytes, " +
                    "synthesis took \(String(format: "%.2f", synthesisElapsedSeconds))s wall-clock"
                )
            }
            try Task.checkCancellation() // closes the window between the last audio chunk and recording the reply

            localConversation.addAgent(reply)
            continuation.yield(.message(.turnEnd(turnId: turnId)))

            if localStoryArc.isDone {
                await completeStory(
                    conversation: localConversation,
                    storyArc: localStoryArc,
                    objectTracker: localObjectTracker,
                    pageCount: localPageCount
                )
            }
        } catch is CancellationError {
            return
        } catch {
            onDebugEvent?("[\(DebugTimestamp.now())] turn \(turnId) failed: \(error)")
            continuation.yield(.message(.error(
                "Elsie's cloud brain is having trouble -- let's try again in a moment.",
                turnId: turnId
            )))
        }
    }

    /// Takes the turn's own conversation/storyArc/objectTracker as
    /// parameters (the same instances runTurn captured at its start,
    /// never `self`'s live properties) and only resets `self`'s
    /// properties back to fresh instances if they still point at these
    /// same objects (===) -- so a concurrent .newStory that already
    /// replaced them isn't clobbered back to empty by a
    /// now-superseded turn's own cleanup.
    ///
    /// Disclosed, accepted residual risk: if .newStory lands in the
    /// narrow window while this function's own two awaits
    /// (sharedFacts()/reset()) are in flight, a stale
    /// animalFactTracker.reset() can still wipe a new story's
    /// already-accumulated animal-facts progress. Not fixed here --
    /// closing it needs a generation-counter mechanism disproportionate
    /// to this demo feature.
    private func completeStory(
        conversation: DemoConversation, storyArc: StoryArc, objectTracker: ObjectTracker, pageCount: Int
    ) async {
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

        lock.withLock {
            if self.conversation === conversation { self.conversation = DemoConversation() }
            if self.storyArc === storyArc { beginStoryLocked() }
            if self.objectTracker === objectTracker { self.objectTracker = ObjectTracker() }
        }
        await animalFactTracker.reset()

        // Mirrors SessionRunner._run_turn's concluding branch: turn_end has
        // already gone out (runTurn sent it) and the transcript is saved;
        // only now does rewriting_started follow. With the concluding turn's
        // playback finishing, that event is what makes SessionCoordinator's
        // readyToShowTheEnd true. The build then runs in the background --
        // deliberately NOT tied to this connection's lifetime: it is
        // app-level work, and cancelling it on close() (e.g. the app being
        // backgrounded) would wrongly mark the story failed.
        guard let library else { return }
        library.begin(payload, pageCount: pageCount)
        continuation.yield(.message(.rewritingStarted))
        let continuation = self.continuation
        let storyId = payload.id
        Task {
            await library.buildStorybook(id: storyId)
            continuation.yield(.message(.rewritingDone))
        }
    }
}

private extension NSLock {
    func withLockReturning<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }

    /// Void-returning counterpart to withLockReturning. Both exist because
    /// this toolchain's NSLock.lock()/unlock() are marked unavailable from
    /// asynchronous contexts (a Swift concurrency lint against blocking an
    /// async context directly) -- routing every lock/unlock pair through a
    /// synchronous, non-async wrapper like this one is the standard
    /// workaround, and keeps the actual locking semantics (same lock, same
    /// critical sections) identical to a bare lock()/unlock() pair.
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
````

- [ ] **Step 6: Run the tests and watch them pass.** Same two commands as Step 4. Expected: `Executed 26 tests, with 0 failures` (4 existing + 22 new).

- [ ] **Step 7: Run the whole Swift suite.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | grep -v "ditty loop" | tail -3
```

Expected: `Executed 330 tests, with 0 failures` (306 + 2 + 22).

- [ ] **Step 8: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoFakes.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoConnectionTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): DemoConnection answers story-browsing messages locally" -m "Settings, Finish this story, list/get, page audio and page images, and rewriting_started/done in the server's order. Every ClientMessage case now has an explicit demo-mode behaviour; syncDemoStories is an explicit documented no-op. Media requests always end with one terminating frame and never interleave with a live turn."
```

- [ ] **Step 9: Mutation check — prove page audio really waits for a live turn.** Temporarily delete the line `await inFlightTurn?.value` in `startMediaTask(_:)` (inside `DemoConnection.swift`). Run `--filter DemoConnectionTests/testPageAudioWaitsForAnInFlightLiveTurnInsteadOfInterleavingWithIt` (same two commands as Step 4). Expected: **that test FAILS**. Restore and confirm clean:

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 checkout -- ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 status --short
```

Expected: no output.

---

### Task 7: Protocol — `sync_demo_stories` carries the storybook

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: `DemoSyncStorybook` / `DemoSyncPage` (Task 4); `IllustrationsStatus.rawValue`.
- Produces: `ClientMessage.syncDemoStories(stories:)` encodes, per story, an optional `"storybook": {"title", "pages": [{"text", "image"?: base64}], "illustrations_status"?}`. The key is omitted when the story has no finished storybook; a page omits `image` when it has none; the epilogue is deliberately never sent.

- [ ] **Step 1: Add the failing tests.** Apply this diff to `ProtocolTests.swift`:

````diff
--- a/ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift
+++ b/ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift
@@ -72,6 +72,53 @@ final class ProtocolTests: XCTestCase {
         XCTAssertEqual(sharedFactsJSON, [["fox", "Foxes have whiskers on their legs too."]])
     }
 
+    func testSyncDemoStoriesCarriesTheFinishedStorybookWhenThereIsOne() throws {
+        let story = PendingDemoStoryPayload(
+            id: "story-1",
+            createdAt: "2026-09-19T12:00:00Z",
+            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
+            sharedFacts: [["fox", "Foxes are clever."]],
+            storybook: DemoSyncStorybook(
+                title: #"The "Brave" Fox"#,
+                pages: [
+                    DemoSyncPage(text: "Page one.", imageJPEG: Data([0xFF, 0xD8, 0xFF])),
+                    DemoSyncPage(text: "Page two.", imageJPEG: nil),
+                ],
+                illustrationsStatus: .partial
+            )
+        )
+
+        let encoded = ClientMessage.syncDemoStories(stories: [story]).encode()
+
+        let data = try XCTUnwrap(encoded.data(using: .utf8))
+        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
+        let storyJSON = try XCTUnwrap((json["stories"] as? [[String: Any]])?.first)
+        let storybook = try XCTUnwrap(storyJSON["storybook"] as? [String: Any])
+        XCTAssertEqual(storybook["title"] as? String, #"The "Brave" Fox"#)
+        XCTAssertEqual(storybook["illustrations_status"] as? String, "partial")
+        let pages = try XCTUnwrap(storybook["pages"] as? [[String: Any]])
+        XCTAssertEqual(pages.count, 2)
+        XCTAssertEqual(pages[0]["text"] as? String, "Page one.")
+        XCTAssertEqual(pages[0]["image"] as? String, Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
+        XCTAssertEqual(pages[1]["text"] as? String, "Page two.")
+        XCTAssertNil(pages[1]["image"], "a page with no picture must omit the key, not send null")
+        XCTAssertNil(storybook["epilogue"], "the server derives the epilogue from shared_facts")
+    }
+
+    func testSyncDemoStoriesOmitsTheStorybookKeyForATranscriptOnlyStory() throws {
+        let story = PendingDemoStoryPayload(
+            id: "story-1", createdAt: "2026-09-19T12:00:00Z",
+            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
+            sharedFacts: []
+        )
+        let encoded = ClientMessage.syncDemoStories(stories: [story]).encode()
+        let data = try XCTUnwrap(encoded.data(using: .utf8))
+        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
+        let storyJSON = try XCTUnwrap((json["stories"] as? [[String: Any]])?.first)
+        XCTAssertNil(storyJSON["storybook"], "an older server must see exactly today's payload shape")
+        XCTAssertEqual(Set(storyJSON.keys), Set(["id", "created_at", "turns", "shared_facts"]))
+    }
+
     func testSyncDemoStoriesEncodesEmptyStoriesArray() throws {
         let encoded = ClientMessage.syncDemoStories(stories: []).encode()
         let data = try XCTUnwrap(encoded.data(using: .utf8))
````

- [ ] **Step 2: Run them and watch one fail.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter ProtocolTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:|failed" /tmp/demo-mode-swift.txt | grep -v "ditty loop" | tail -8
```

Expected: the with-a-storybook test fails (the encoded JSON has no `storybook` key); the without-a-storybook test already passes — it is the backward-compatibility guard.

- [ ] **Step 3: Implement.** Apply this diff to `Protocol.swift`:

````diff
--- a/ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift
+++ b/ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift
@@ -78,7 +78,7 @@ public enum ClientMessage: Sendable, Equatable {
             return #"{"type":"new_story"}"#
         case .syncDemoStories(let stories):
             let storiesJSON: [[String: Any]] = stories.map { story in
-                [
+                var storyJSON: [String: Any] = [
                     "id": story.id,
                     "created_at": story.createdAt,
                     "turns": story.turns.map {
@@ -86,6 +86,28 @@ public enum ClientMessage: Sendable, Equatable {
                     },
                     "shared_facts": story.sharedFacts,
                 ]
+                // Optional and backward compatible in both directions: an
+                // older server ignores the unknown key and rewrites from the
+                // transcript; a story with no finished storybook simply
+                // omits it. The epilogue is deliberately never sent -- the
+                // server recomputes it from shared_facts.
+                if let storybook = story.storybook {
+                    var storybookJSON: [String: Any] = [
+                        "title": storybook.title,
+                        "pages": storybook.pages.map { page -> [String: Any] in
+                            var pageJSON: [String: Any] = ["text": page.text]
+                            if let image = page.imageJPEG {
+                                pageJSON["image"] = image.base64EncodedString()
+                            }
+                            return pageJSON
+                        },
+                    ]
+                    if let status = storybook.illustrationsStatus {
+                        storybookJSON["illustrations_status"] = status.rawValue
+                    }
+                    storyJSON["storybook"] = storybookJSON
+                }
+                return storyJSON
             }
             let payload: [String: Any] = ["type": "sync_demo_stories", "stories": storiesJSON]
             guard let data = try? JSONSerialization.data(withJSONObject: payload),
````

- [ ] **Step 4: Run the tests and watch them pass.** Same two commands as Step 2. Expected: `Executed 35 tests, with 0 failures` (33 existing + 2 new).

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): sync_demo_stories carries a finished storybook" -m "Optional and backward compatible in both directions. Pages carry base64 JPEG bytes when they have a picture; the epilogue is never sent (the server derives it)."
```

---

### Task 8: The protocol-parity guard

The mechanical answer to #24's "this keeps recurring": adding a `ClientMessage` case must fail to compile until someone decides what a `DemoConnection` does with it.

**Files:**
- Create: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoProtocolParityTests.swift`

**Interfaces:**
- Consumes: `DemoConnection` (Task 6), `EventRecorder` (Task 6), the pre-existing doubles `FakeChatClient`, `FakeSttClient`, `FakeTtsClient` (defined at the top of `DemoConnectionTests.swift`) and `FakeAnimalFactFetcher` (`AnimalFactTrackerTests.swift`), every `ClientMessage` case.
- Produces: a test whose exhaustive `switch` (no `default:`) classifies each case as "responds with an event" or "silent by design, with a stated reason".

- [ ] **Step 1: Create the guard.**

````swift
import XCTest
@testable import TinyTalkCore

/// The mechanical answer to issue #24's "this keeps recurring": a feature
/// built on a new ClientMessage that only the real server implements used
/// to silently no-op in demo mode, because DemoConnection lumped every such
/// case into one catch-all. Now every ClientMessage case must carry an
/// explicit demo-mode decision -- either "answers with an event" or "silent
/// by design, and here is why".
final class DemoProtocolParityTests: XCTestCase {
    private enum Expectation {
        case respondsWithAnEvent
        case silentByDesign(String)
    }

    /// EXHAUSTIVE ON PURPOSE (deliberately no `default:`): adding a case to
    /// ClientMessage fails to compile HERE until someone decides what a
    /// DemoConnection does with it. When that happens, also add a sample for
    /// it to `samples` below and bump the count assertion in
    /// testEverySampleIsCoveredOnceAndBehavesAsClassified.
    private static func expectation(for message: ClientMessage) -> Expectation {
        switch message {
        case .speechStart:
            return .silentByDesign("starts buffering mic audio; the reply follows speechEnd")
        case .speechEnd:
            return .respondsWithAnEvent
        case .interrupt:
            return .silentByDesign("cancels in-flight work; the server sends nothing back either")
        case .objectSeen:
            return .silentByDesign("feeds the next turn's guidance; the server sends nothing back either")
        case .newStory:
            return .silentByDesign("resets state locally; the server sends nothing back either")
        case .syncDemoStories:
            return .silentByDesign("never sent to a DemoConnection; only the real-server connect path issues it")
        case .listStories:
            return .respondsWithAnEvent
        case .getStory:
            return .respondsWithAnEvent
        case .concludeStory:
            return .respondsWithAnEvent
        case .updateSettings:
            return .silentByDesign("takes effect on the next story; the server sends no reply either")
        case .getPageImage:
            return .respondsWithAnEvent
        case .synthesizePage:
            return .respondsWithAnEvent
        }
    }

    /// One sample per ClientMessage case.
    private static let samples: [ClientMessage] = [
        .speechStart(turnId: 1),
        .speechEnd,
        .interrupt(turnId: 2),
        .objectSeen(label: "fox"),
        .newStory,
        .syncDemoStories(stories: []),
        .listStories,
        .getStory(storyId: "ghost"),
        .concludeStory(turnId: 3),
        .updateSettings(targetTurns: 5, pageCount: 4),
        .getPageImage(storyId: "ghost", pageIndex: 0),
        .synthesizePage(storyId: "ghost", pageIndex: 0),
    ]

    func testEverySampleIsCoveredOnceAndBehavesAsClassified() async throws {
        XCTAssertEqual(Self.samples.count, 12, "one sample per ClientMessage case -- update with the switch above")

        for message in Self.samples {
            let connection = DemoConnection(
                chatClient: FakeChatClient(),
                sttClient: FakeSttClient(),
                ttsClient: FakeTtsClient(),
                animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher())
            )
            let recorder = EventRecorder(connection)

            try await connection.send(message)
            let events = await recorder.settle()
            recorder.stop()

            switch Self.expectation(for: message) {
            case .respondsWithAnEvent:
                XCTAssertFalse(events.isEmpty, "\(message) must answer with at least one event, never silence")
            case .silentByDesign(let reason):
                XCTAssertTrue(events.isEmpty, "\(message) is meant to be silent (\(reason)) but emitted \(events)")
            }
        }
    }
}
````

- [ ] **Step 2: Run it.** It passes immediately — it is a guard over Task 6's work, not new behaviour.

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkCore --filter DemoProtocolParityTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -3
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkCore/Tests/TinyTalkCoreTests/DemoProtocolParityTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "test(ios): protocol-parity guard for DemoConnection" -m "An exhaustive switch over ClientMessage forces an explicit demo-mode decision for every case, so a new server-only message can never silently no-op away from home again (#24)."
```

- [ ] **Step 4: Mutation check A — a new `ClientMessage` case must break the build.** Temporarily add `case parityProbe` as the last case of `enum ClientMessage` in `Protocol.swift`. Run `--filter DemoProtocolParityTests` (Step 2's commands). Expected: **compile errors**, `switch must be exhaustive`, reported in `Protocol.swift` (its own `encode()`) and in `DemoConnection.swift` — `send(_:)` deliberately has no `default:`, which is the first line of defence and fails first because the library target builds before the tests. The parity test's own exhaustive switch is the second line: once the library compiles again, it fails to compile until someone adds a sample and a classification for the new case in the tests. Restore:

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 checkout -- ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift
```

- [ ] **Step 5: Mutation check B — a message quietly re-lumped into a no-op must fail the test.** In `DemoConnection.swift`, temporarily replace the `.listStories` case body (`continuation.yield(.message(.storyList(library?.list() ?? [])))`) with `break`. Run the same filter. Expected: **the test FAILS** with `listStories must answer with at least one event, never silence`. Restore with `git checkout --` on `DemoConnection.swift` and confirm `git status --short` prints nothing.

- [ ] **Step 6: Run the whole Swift suite.** Expected: `Executed 333 tests, with 0 failures` (330 + 2 + 1). If only `testPageAudioDittyStopsOnStopPageAudio` fails, re-run it alone (known flake).

---

### Task 9: Server — `synced_storybook.py`, the untrusted-upload validator

The phone is a client; everything it sends is untrusted (see `story_store.save_synced_story`, which already discards the phone's id and forces `rewrite_status: "pending"`). This module validates an uploaded storybook and stores it only if every check passes.

**Files:**
- Create: `server/tinytalk/synced_storybook.py`
- Create: `server/tests/test_synced_storybook.py`

**Interfaces:**
- Consumes: `story_store.update_story_rewrite(story_id, *, title, pages, epilogue, rewrite_status, stories_dir)` and `story_store.update_story_illustrations(story_id, *, image_filenames, illustrations_status, stories_dir)` (both exist), `safety.find_blocked(text) -> list[str]`, `story_store.STORIES_DIR`, Pillow.
- Produces: `store_uploaded_storybook(story_id: str, storybook: object, shared_facts: list[tuple[str, str]], *, stories_dir: Path = STORIES_DIR) -> bool` — `True` = accepted and stored (status `done`, images re-encoded to server-named PNGs); `False` = rejected or failed, caller falls back to a transcript rewrite. Never raises. Logs exactly one line per call: `synced storybook accepted for story %s: %d page(s), %d image(s)` or `synced storybook rejected for story %s: %s`. Also `derive_epilogue(shared_facts) -> str | None` and the limit constants `MAX_TITLE_CHARS`, `MAX_PAGES`, `MAX_PAGE_TEXT_CHARS`, `MAX_IMAGE_BYTES`, `MAX_IMAGE_PIXELS`.

- [ ] **Step 1: Create the tests.**

````python
import base64
import io
import logging

import pytest
from PIL import Image

from tinytalk import synced_storybook
from tinytalk.story_store import (
    load_story,
    read_page_image,
    save_synced_story,
    story_id_from_path,
)
from tinytalk.synced_storybook import (
    MAX_IMAGE_BYTES,
    MAX_PAGE_TEXT_CHARS,
    MAX_PAGES,
    MAX_TITLE_CHARS,
    derive_epilogue,
    store_uploaded_storybook,
)


def make_synced_story(tmp_path) -> str:
    path = save_synced_story(
        {"created_at": "2026-09-19T12:00:00+00:00", "turns": []}, stories_dir=tmp_path
    )
    return story_id_from_path(path)


def image_b64(fmt: str = "JPEG", size: tuple[int, int] = (8, 8)) -> str:
    buffer = io.BytesIO()
    Image.new("RGB", size, color=(200, 30, 30)).save(buffer, format=fmt)
    return base64.b64encode(buffer.getvalue()).decode()


def storybook(**overrides) -> dict:
    base = {
        "title": "Pip the Fox",
        "pages": [{"text": "Page one."}, {"text": "Page two."}],
    }
    base.update(overrides)
    return base


def assert_left_pending(story_id, tmp_path):
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "pending"
    assert story["title"] is None
    assert story["pages"] is None
    assert list(tmp_path.glob("*.png")) == [], "a rejected storybook must not leave image files behind"


# ---------- acceptance ----------


def test_a_valid_text_only_storybook_is_stored_as_done(tmp_path):
    story_id = make_synced_story(tmp_path)

    accepted = store_uploaded_storybook(story_id, storybook(), [], stories_dir=tmp_path)

    assert accepted is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["title"] == "Pip the Fox"
    assert story["pages"] == [{"text": "Page one."}, {"text": "Page two."}]
    assert story["epilogue"] is None
    assert story["rewrite_status"] == "done"
    assert story.get("illustrations_status") is None
    assert story["turns"] == [], "the transcript must be untouched"


def test_the_epilogue_is_recomputed_from_shared_facts_and_the_uploaded_one_is_ignored(tmp_path):
    story_id = make_synced_story(tmp_path)

    store_uploaded_storybook(
        story_id,
        storybook(epilogue="Foxes can fly to the moon."),
        [("fox", "foxes have excellent hearing")],
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["epilogue"] == "And one true thing we learned about the fox: foxes have excellent hearing"


def test_a_fabricated_epilogue_is_dropped_when_no_facts_were_shared(tmp_path):
    story_id = make_synced_story(tmp_path)
    store_uploaded_storybook(
        story_id, storybook(epilogue="Foxes can fly to the moon."), [], stories_dir=tmp_path
    )
    assert load_story(story_id, stories_dir=tmp_path)["epilogue"] is None


def test_derive_epilogue_matches_the_live_rewrite_formula():
    # test_storybook.py asserts this exact literal for build_and_attach();
    # pinning both to it means neither can drift without a test failing.
    assert (
        derive_epilogue([("fox", "foxes have excellent hearing")])
        == "And one true thing we learned about the fox: foxes have excellent hearing"
    )
    assert derive_epilogue([]) is None


def test_images_are_stored_as_server_named_pngs_and_marked_done(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[
        {"text": "Page one.", "image": image_b64("JPEG")},
        {"text": "Page two.", "image": image_b64("PNG")},
    ])

    accepted = store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    assert accepted is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "done"
    assert [page["image_path"] for page in story["pages"]] == [
        f"{story_id}-page-0.png",
        f"{story_id}-page-1.png",
    ]
    for index in range(2):
        data = read_page_image(story_id, index, stories_dir=tmp_path)
        assert Image.open(io.BytesIO(data)).format == "PNG"


def test_some_images_marks_the_illustrations_partial(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[{"text": "Page one.", "image": image_b64()}, {"text": "Page two."}])

    store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "partial"
    assert story["pages"][0]["image_path"] == f"{story_id}-page-0.png"
    assert story["pages"][1].get("image_path") is None


def test_raw_client_bytes_are_never_written_to_disk(tmp_path):
    # The stored file must be the SERVER's own PNG re-encode, not the
    # uploaded JPEG bytes.
    story_id = make_synced_story(tmp_path)
    uploaded = image_b64("JPEG")
    store_uploaded_storybook(
        story_id, storybook(pages=[{"text": "One.", "image": uploaded}]), [], stories_dir=tmp_path
    )
    stored = (tmp_path / f"{story_id}-page-0.png").read_bytes()
    assert stored != base64.b64decode(uploaded)
    assert stored.startswith(b"\x89PNG")


def test_client_supplied_filenames_and_paths_are_ignored(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[{
        "text": "Page one.",
        "image": image_b64(),
        "image_path": "../../evil.png",
        "filename": "../evil.png",
    }])

    store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["pages"][0]["image_path"] == f"{story_id}-page-0.png"
    assert not (tmp_path.parent / "evil.png").exists()
    assert sorted(p.name for p in tmp_path.glob("*.png")) == [f"{story_id}-page-0.png"]


def test_a_failed_image_write_keeps_the_text_storybook(tmp_path, monkeypatch):
    story_id = make_synced_story(tmp_path)
    # Built BEFORE patching: image_b64() itself uses Image.save().
    book = storybook(pages=[{"text": "One.", "image": image_b64()}])

    def boom(self, *args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(Image.Image, "save", boom)

    accepted = store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    assert accepted is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "done"
    assert story.get("illustrations_status") is None


# ---------- rejection ----------


def bad_storybooks():
    too_many_pages = [{"text": f"Page {i}."} for i in range(MAX_PAGES + 1)]
    return [
        pytest.param("not an object", id="not-a-dict"),
        pytest.param({"pages": [{"text": "One."}]}, id="missing-title"),
        pytest.param(storybook(title="   "), id="blank-title"),
        pytest.param(storybook(title=42), id="non-string-title"),
        pytest.param(storybook(title="T" * (MAX_TITLE_CHARS + 1)), id="title-too-long"),
        pytest.param({"title": "Pip"}, id="missing-pages"),
        pytest.param(storybook(pages=[]), id="zero-pages"),
        pytest.param(storybook(pages="nope"), id="pages-not-a-list"),
        pytest.param(storybook(pages=too_many_pages), id="too-many-pages"),
        pytest.param(storybook(pages=["not a dict"]), id="page-not-a-dict"),
        pytest.param(storybook(pages=[{"text": ""}]), id="empty-page-text"),
        pytest.param(storybook(pages=[{"nope": 1}]), id="missing-page-text"),
        pytest.param(storybook(pages=[{"text": "x" * (MAX_PAGE_TEXT_CHARS + 1)}]), id="page-text-too-long"),
        pytest.param(storybook(pages=[{"text": "One.", "image": 5}]), id="image-not-a-string"),
        pytest.param(storybook(pages=[{"text": "One.", "image": "!!!not base64!!!"}]), id="image-bad-base64"),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": base64.b64encode(b"garbage bytes").decode()}]),
            id="image-not-an-image",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": base64.b64encode(b"x" * (MAX_IMAGE_BYTES + 1)).decode()}]),
            id="image-too-many-bytes",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": image_b64("GIF")}]),
            id="image-wrong-format",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": image_b64("PNG", (2049, 2049))}]),
            id="image-over-the-pixel-limit",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": image_b64("PNG", (64, 64))[:-40]}]),
            id="image-truncated",
        ),
    ]


@pytest.mark.parametrize("bad", bad_storybooks())
def test_a_bad_storybook_is_rejected_and_the_story_left_pending(tmp_path, bad):
    story_id = make_synced_story(tmp_path)

    accepted = store_uploaded_storybook(story_id, bad, [], stories_dir=tmp_path)

    assert accepted is False
    assert_left_pending(story_id, tmp_path)


def test_an_unsafe_title_is_rejected(tmp_path):
    story_id = make_synced_story(tmp_path)
    assert store_uploaded_storybook(story_id, storybook(title="The Knife Fight"), [], stories_dir=tmp_path) is False
    assert_left_pending(story_id, tmp_path)


def test_an_unsafe_page_is_rejected(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[{"text": "The knight had to kill the dragon."}])
    assert store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path) is False
    assert_left_pending(story_id, tmp_path)


def test_an_unsafe_shared_fact_is_rejected_via_the_derived_epilogue(tmp_path):
    # The uploaded text is spotless, but the epilogue is built from the
    # real shared fact, so an unsafe fact must still be caught.
    story_id = make_synced_story(tmp_path)
    assert store_uploaded_storybook(
        story_id, storybook(), [("shark", "sharks can kill")], stories_dir=tmp_path
    ) is False
    assert_left_pending(story_id, tmp_path)


def test_an_unknown_story_id_is_rejected_not_raised(tmp_path):
    assert store_uploaded_storybook("ghost123", storybook(), [], stories_dir=tmp_path) is False


# ---------- logging ----------


def test_an_accepted_upload_logs_exactly_one_accepted_line(tmp_path, caplog):
    story_id = make_synced_story(tmp_path)
    with caplog.at_level(logging.INFO, logger="tinytalk.synced_storybook"):
        store_uploaded_storybook(
            story_id, storybook(pages=[{"text": "One.", "image": image_b64()}]), [], stories_dir=tmp_path
        )
    lines = [r.getMessage() for r in caplog.records if r.name == "tinytalk.synced_storybook"]
    assert lines == [f"synced storybook accepted for story {story_id}: 1 page(s), 1 image(s)"]


def test_a_rejected_upload_logs_exactly_one_rejected_line_with_the_reason(tmp_path, caplog):
    story_id = make_synced_story(tmp_path)
    with caplog.at_level(logging.INFO, logger="tinytalk.synced_storybook"):
        store_uploaded_storybook(story_id, storybook(title=""), [], stories_dir=tmp_path)
    lines = [r.getMessage() for r in caplog.records if r.name == "tinytalk.synced_storybook"]
    assert len(lines) == 1
    assert lines[0].startswith(f"synced storybook rejected for story {story_id}:")
    assert "title" in lines[0]
````

- [ ] **Step 2: Run them and watch them fail.**

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/server
```
```bash
~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_synced_storybook.py -q -p no:cacheprovider
```

Expected: a collection error — `ModuleNotFoundError: No module named 'tinytalk.synced_storybook'`.

- [ ] **Step 3: Implement.**

````python
"""Validates and stores a finished storybook that the phone uploads alongside
a story synced from away-from-home demo mode, so nothing generated away from
home (title, pages, illustrations) is discarded or redone at the Mac.

Everything in the upload is UNTRUSTED client data (see
story_store.save_synced_story(), which discards the phone's own id and forces
rewrite_status to "pending" for the same reason). The server therefore skips
its own rewrite ONLY when the whole storybook passes every check below;
otherwise store_uploaded_storybook() returns False and the caller falls back
to today's behavior -- leave the story pending and rewrite it from its
transcript. See docs/superpowers/specs/2026-09-19-demo-mode-parity-design.md.
"""

from __future__ import annotations

import base64
import binascii
import io
import logging
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from . import safety, story_store
from .story_store import STORIES_DIR

logger = logging.getLogger(__name__)

MAX_TITLE_CHARS = 200
MAX_PAGES = 10
MAX_PAGE_TEXT_CHARS = 2000
MAX_IMAGE_BYTES = 1_500_000
# 2048 x 2048. The phone's own images are at most 512 px on the long side,
# so this is generous -- it exists to refuse decompression bombs.
MAX_IMAGE_PIXELS = 2048 * 2048
_ALLOWED_IMAGE_FORMATS = frozenset({"JPEG", "PNG"})


class _Rejected(Exception):
    """A storybook failed validation; the message is the reason logged."""


def derive_epilogue(shared_facts: list[tuple[str, str]]) -> str | None:
    """The epilogue is always a real fact the story actually shared, never
    model-written -- so it is recomputed here from shared_facts and any
    epilogue text the phone sent is ignored. MUST match the formula in
    storybook.build_and_attach() (a test pins both to the same literal)."""
    if not shared_facts:
        return None
    animal, fact = shared_facts[0]
    return f"And one true thing we learned about the {animal}: {fact}"


def _validated_title(storybook: dict) -> str:
    title = storybook.get("title")
    if not isinstance(title, str) or not title.strip():
        raise _Rejected("missing or empty title")
    title = title.strip()
    if len(title) > MAX_TITLE_CHARS:
        raise _Rejected(f"title is longer than {MAX_TITLE_CHARS} characters")
    return title


def _decode_image(index: int, encoded: object) -> Image.Image | None:
    if encoded is None:
        return None
    if not isinstance(encoded, str):
        raise _Rejected(f"page {index} image is not a base64 string")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise _Rejected(f"page {index} image is not valid base64") from None
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        raise _Rejected(f"page {index} image is empty or larger than {MAX_IMAGE_BYTES} bytes")
    try:
        image = Image.open(io.BytesIO(raw))
        # Format and size come from the file header, so a decompression
        # bomb is refused BEFORE any pixel data is decoded.
        if image.format not in _ALLOWED_IMAGE_FORMATS:
            raise _Rejected(f"page {index} image is {image.format}, not JPEG or PNG")
        width, height = image.size
        if width * height > MAX_IMAGE_PIXELS:
            raise _Rejected(f"page {index} image is {width}x{height}, over the pixel limit")
        image.load()  # a full decode: catches truncated or corrupt data
    except _Rejected:
        raise
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError, Image.DecompressionBombError) as exc:
        raise _Rejected(f"page {index} image could not be decoded ({exc})") from None
    return image


def _validated_pages(storybook: dict) -> list[tuple[str, Image.Image | None]]:
    pages = storybook.get("pages")
    if not isinstance(pages, list) or not 1 <= len(pages) <= MAX_PAGES:
        raise _Rejected(f"pages must be a list of 1-{MAX_PAGES} entries")
    validated: list[tuple[str, Image.Image | None]] = []
    for index, page in enumerate(pages):
        if not isinstance(page, dict):
            raise _Rejected(f"page {index} is not an object")
        text = page.get("text")
        if not isinstance(text, str) or not text.strip():
            raise _Rejected(f"page {index} has no text")
        text = text.strip()
        if len(text) > MAX_PAGE_TEXT_CHARS:
            raise _Rejected(f"page {index} text is longer than {MAX_PAGE_TEXT_CHARS} characters")
        # Any filename/path the client might have attached is ignored: only
        # "text" and "image" are ever read from a page.
        validated.append((text, _decode_image(index, page.get("image"))))
    return validated


def _write_images(
    story_id: str, images: list[Image.Image | None], stories_dir: Path
) -> list[str | None]:
    """Re-encodes each decoded image to PNG under a SERVER-generated
    filename (`{story_id}-page-{i}.png`, the shape the home pipeline uses,
    so story_store.read_page_image() needs no change). Raw client bytes are
    never written to disk. A page whose image can't be written just has no
    picture; it never sinks the storybook's text."""
    filenames: list[str | None] = []
    for index, image in enumerate(images):
        if image is None:
            filenames.append(None)
            continue
        filename = f"{story_id}-page-{index}.png"
        try:
            image.convert("RGB").save(stories_dir / filename, format="PNG")
            filenames.append(filename)
        except (OSError, ValueError) as exc:
            logger.warning(
                "could not write the synced illustration for story %s page %d: %s",
                story_id, index, exc,
            )
            filenames.append(None)
    return filenames


def store_uploaded_storybook(
    story_id: str,
    storybook: object,
    shared_facts: list[tuple[str, str]],
    *,
    stories_dir: Path = STORIES_DIR,
) -> bool:
    """Validates the uploaded storybook and, if it passes every check,
    stores it on the already-saved synced story `story_id` (status "done").
    Returns True when accepted; False means "rejected or failed -- fall back
    to rewriting from the transcript". Never raises. Logs exactly one line
    per call ("accepted ..." or "rejected ...") so on-device verification can
    tell an accepted upload from a fallback rewrite."""
    try:
        if not isinstance(storybook, dict):
            raise _Rejected("storybook is not an object")
        title = _validated_title(storybook)
        pages = _validated_pages(storybook)
        epilogue = derive_epilogue(shared_facts)

        texts = [title, *(text for text, _ in pages), *([epilogue] if epilogue else [])]
        blocked = sorted({term for text in texts for term in safety.find_blocked(text)})
        if blocked:
            raise _Rejected(f"kid-safety check flagged: {', '.join(blocked)}")

        stored = story_store.update_story_rewrite(
            story_id,
            title=title,
            pages=[{"text": text} for text, _ in pages],
            epilogue=epilogue,
            rewrite_status="done",
            stories_dir=stories_dir,
        )
        if not stored:
            raise _Rejected("could not persist the rewrite")
    except _Rejected as exc:
        logger.warning("synced storybook rejected for story %s: %s", story_id, exc)
        return False
    except Exception:  # noqa: BLE001 - untrusted input must never crash the session
        logger.exception("synced storybook rejected for story %s: unexpected failure", story_id)
        return False

    filenames = _write_images(story_id, [image for _, image in pages], stories_dir)
    if any(filenames):
        story_store.update_story_illustrations(
            story_id,
            image_filenames=filenames,
            illustrations_status="done" if all(filenames) else "partial",
            stories_dir=stories_dir,
        )
    logger.info(
        "synced storybook accepted for story %s: %d page(s), %d image(s)",
        story_id, len(pages), sum(1 for name in filenames if name),
    )
    return True
````

- [ ] **Step 4: Run the tests and watch them pass.** Same command as Step 2. Expected: `35 passed`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add server/tinytalk/synced_storybook.py server/tests/test_synced_storybook.py
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(server): validate and store storybooks uploaded at sync time" -m "Untrusted input: bounded title/pages/image sizes, PIL header check and pixel cap before decoding, re-encode to a server-named PNG, kid-safety check over title/pages/epilogue, epilogue recomputed from shared_facts. Any rejection returns False so the caller falls back to today's transcript rewrite."
```

---

### Task 10: Server — `handle_sync_demo_stories` consults the validator

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`, `server/tests/test_protocol.py`

**Interfaces:**
- Consumes: `synced_storybook.store_uploaded_storybook` (Task 9), the existing `story_store.save_synced_story`, `SessionRunner._run_synced_rewrite`.
- Produces: `SessionRunner.handle_sync_demo_stories` skips scheduling `_run_synced_rewrite` for a story whose optional `storybook` is accepted; a story with no `storybook` never consults the validator; a rejected one falls back to the rewrite exactly as before. The synced path still does not touch the REWRITING gate or send `rewriting_*` events.

- [ ] **Step 1: Add the session tests.** Apply this diff to `server/tests/test_session.py`:

````diff
--- a/server/tests/test_session.py
+++ b/server/tests/test_session.py
@@ -1927,6 +1927,98 @@ async def test_handle_sync_demo_stories_skips_a_story_that_fails_to_save(monkeyp
     assert build_calls == []
 
 
+def _sync_with_storybook_fixtures(tmp_path, monkeypatch, *, accept: bool):
+    """Shared setup for the uploaded-storybook tests: save_synced_story is
+    faked (as in the tests above), storybook.build_and_attach and
+    synced_storybook.store_uploaded_storybook are recorded stand-ins."""
+    from tinytalk import story_store
+
+    monkeypatch.setattr(
+        story_store, "save_synced_story",
+        lambda payload, **kw: tmp_path / f"20260909T120000-{payload['id']}.json",
+    )
+    (tmp_path).mkdir(exist_ok=True)
+    build_calls = []
+    store_calls = []
+
+    async def fake_build_and_attach(story_id, turns, shared_facts, **kwargs):
+        build_calls.append(story_id)
+
+    def fake_store_uploaded_storybook(story_id, storybook, shared_facts, **kwargs):
+        store_calls.append((story_id, storybook, shared_facts))
+        return accept
+
+    monkeypatch.setattr("tinytalk.session.storybook.build_and_attach", fake_build_and_attach)
+    monkeypatch.setattr(
+        "tinytalk.session.synced_storybook.store_uploaded_storybook", fake_store_uploaded_storybook
+    )
+    return build_calls, store_calls
+
+
+_STORYBOOK = {"title": "Pip", "pages": [{"text": "Once."}]}
+
+
+def _sync_message(*stories) -> str:
+    return json.dumps({"type": "sync_demo_stories", "stories": list(stories)})
+
+
+def _synced_story(story_id: str, **extra) -> dict:
+    return {
+        "id": story_id,
+        "created_at": "2026-09-09T12:00:00+00:00",
+        "turns": [{"speaker": "child", "text": "hi", "interrupted": False}],
+        "shared_facts": [["fox", "foxes are clever"]],
+        **extra,
+    }
+
+
+async def test_a_synced_story_with_an_accepted_storybook_skips_the_rewrite(tmp_path, monkeypatch):
+    build_calls, store_calls = _sync_with_storybook_fixtures(tmp_path, monkeypatch, accept=True)
+    session = make_session(FakeTransport())
+
+    await session.handle_text(_sync_message(_synced_story("abc12345", storybook=_STORYBOOK)))
+    await asyncio.sleep(0.01)
+
+    assert store_calls == [("abc12345", _STORYBOOK, [("fox", "foxes are clever")])]
+    assert build_calls == [], "an accepted storybook must not be rewritten again"
+
+
+async def test_a_synced_story_whose_storybook_is_rejected_falls_back_to_the_rewrite(tmp_path, monkeypatch):
+    build_calls, store_calls = _sync_with_storybook_fixtures(tmp_path, monkeypatch, accept=False)
+    session = make_session(FakeTransport())
+
+    await session.handle_text(_sync_message(_synced_story("abc12345", storybook=_STORYBOOK)))
+    await asyncio.sleep(0.01)
+
+    assert len(store_calls) == 1
+    assert build_calls == ["abc12345"], "a rejected storybook must fall back to today's rewrite"
+
+
+async def test_a_synced_story_with_no_storybook_never_consults_the_validator(tmp_path, monkeypatch):
+    build_calls, store_calls = _sync_with_storybook_fixtures(tmp_path, monkeypatch, accept=True)
+    session = make_session(FakeTransport())
+
+    await session.handle_text(_sync_message(_synced_story("abc12345")))
+    await asyncio.sleep(0.01)
+
+    assert store_calls == []
+    assert build_calls == ["abc12345"]
+
+
+async def test_each_story_in_a_batch_is_judged_on_its_own(tmp_path, monkeypatch):
+    build_calls, store_calls = _sync_with_storybook_fixtures(tmp_path, monkeypatch, accept=True)
+    session = make_session(FakeTransport())
+
+    await session.handle_text(_sync_message(
+        _synced_story("with1111", storybook=_STORYBOOK),
+        _synced_story("without2"),
+    ))
+    await asyncio.sleep(0.01)
+
+    assert [call[0] for call in store_calls] == ["with1111"]
+    assert build_calls == ["without2"]
+
+
 async def test_handle_sync_demo_stories_does_not_touch_the_rewriting_gate(tmp_path, monkeypatch):
     """Regression test: synced stories must NOT send rewriting_done or
     touch self._machine, so they can't interfere with a concurrent live
````

- [ ] **Step 2: Add the protocol passthrough test** (a characterization test: `decode_client_message` already passes any story dict through, so it passes immediately and locks that in). Apply this diff to `server/tests/test_protocol.py`:

````diff
--- a/server/tests/test_protocol.py
+++ b/server/tests/test_protocol.py
@@ -219,6 +219,20 @@ def test_decode_sync_demo_stories():
     )
 
 
+def test_decode_sync_demo_stories_passes_an_optional_storybook_through_untouched():
+    # The server accepts any story dict, so the optional `storybook` key
+    # needs no protocol change -- it must simply survive decoding intact for
+    # synced_storybook to validate (decoding itself validates nothing here).
+    storybook = {"title": "Pip", "pages": [{"text": "Once.", "image": "AAAA"}], "illustrations_status": "done"}
+    raw = json.dumps({
+        "type": "sync_demo_stories",
+        "stories": [{"id": "abc", "created_at": "2026-09-19T12:00:00Z", "turns": [], "storybook": storybook}],
+    })
+    message = decode_client_message(raw)
+    assert isinstance(message, SyncDemoStories)
+    assert message.stories[0]["storybook"] == storybook
+
+
 def test_decode_sync_demo_stories_rejects_non_list_stories():
     raw = json.dumps({"type": "sync_demo_stories", "stories": "not-a-list"})
     with pytest.raises(ProtocolError):
````

- [ ] **Step 3: Run the session tests and watch the four new ones fail.**

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/server
```
```bash
~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_session.py -q -p no:cacheprovider
```

Expected: exactly **4 failed** — `test_a_synced_story_with_an_accepted_storybook_skips_the_rewrite`, `…whose_storybook_is_rejected_falls_back_to_the_rewrite`, `…with_no_storybook_never_consults_the_validator` and `test_each_story_in_a_batch_is_judged_on_its_own`. They fail while setting up their fixture, which patches `tinytalk.session.synced_storybook` — an attribute `session.py` does not have until Step 4. Every other test in the file (including the existing `test_handle_sync_demo_stories_does_not_touch_the_rewriting_gate`) passes.

- [ ] **Step 4: Implement.** Apply this diff to `server/tinytalk/session.py`:

````diff
--- a/server/tinytalk/session.py
+++ b/server/tinytalk/session.py
@@ -20,7 +20,7 @@ import logging
 import time
 from typing import Protocol
 
-from . import config, safety, storybook, story_store
+from . import config, safety, storybook, story_store, synced_storybook
 from .animal_facts import AnimalFactTracker
 from .audio import TTS_SAMPLE_RATE, split_sentences
 from .conversation import Conversation, Turn
@@ -411,7 +411,14 @@ class SessionRunner:
         triggers -- see story_store.save_synced_story() and
         _run_rewrite(). Runs independent of self._machine's state
         (unlike the live-turn actions above): a synced batch has no
-        relationship to whatever live story is or isn't in flight."""
+        relationship to whatever live story is or isn't in flight.
+
+        A story may also carry a finished `storybook` the phone already
+        wrote away from home (title, pages, illustrations). When it passes
+        synced_storybook's validation the rewrite is skipped entirely --
+        the phone's work is kept, not redone; otherwise (absent, or
+        rejected as untrusted input) the story is rewritten from its
+        transcript exactly as before."""
         for payload in stories:
             saved_path = story_store.save_synced_story(payload)
             if saved_path is None:
@@ -436,6 +443,11 @@ class SessionRunner:
                 for pair in payload.get("shared_facts", [])
                 if isinstance(pair, list) and len(pair) == 2
             ]
+            uploaded_storybook = payload.get("storybook")
+            if uploaded_storybook is not None and synced_storybook.store_uploaded_storybook(
+                story_id, uploaded_storybook, shared_facts
+            ):
+                continue
             asyncio.create_task(self._run_synced_rewrite(story_id, turns, shared_facts))
 
     async def handle_audio(self, pcm: bytes) -> None:
````

- [ ] **Step 5: Run the whole server suite and watch it pass.**

```bash
~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests -q -p no:cacheprovider
```

Expected: `463 passed` (423 baseline + 35 + 4 + 1).

- [ ] **Step 6: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add server/tinytalk/session.py server/tests/test_session.py server/tests/test_protocol.py
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(server): keep an accepted uploaded storybook instead of rewriting it" -m "handle_sync_demo_stories runs the validator when a synced story carries a storybook and skips the transcript rewrite only when it passes; absent or rejected storybooks behave exactly as before."
```

---

### Task 11: `AppModel` wiring and a build

The app target has no unit-test target and its behaviour is only really confirmed on the phone, so this task is verified by a successful build and then by Task 12's on-device script. Everything logic-bearing already lives (and is tested) in `TinyTalkCore`.

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`
- Create (gitignored, not committed): `ios/TinyTalkApp/Local.xcconfig`

**Interfaces:**
- Consumes: `DemoStoryLibrary`, `StorybookWriter`, `LocalStoryStore`, `GroqChatClient`, `DemoConnection.init(…library:…)`, `DemoStoryLibrary.syncPayloads(store:pending:)`, `SessionCoordinator.updateSettings(targetTurns:pageCount:)`.
- Produces: away from home, `connectAwayFromHome()` builds one shared `GroqChatClient`, a `DemoStoryLibrary`, and passes it to `DemoConnection`; it sends the parent's story-length settings after connecting and resumes any interrupted builds. `setAwayFromHomeEnabled(_:)` resets library state (and the End-screen baseline) on a real backend switch. `connect()` builds sync payloads with `syncPayloads` and clears `localStoryStore` for the synced ids.

- [ ] **Step 1: Make sure the fresh-worktree signing config exists** (gitignored; the team id comes from the example file):

```bash
cp -n ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkApp/Local.xcconfig.example ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkApp/Local.xcconfig
```

- [ ] **Step 2: Wire it up.** Apply this diff to `AppModel.swift`:

````diff
--- a/ios/TinyTalkApp/TinyTalkApp/AppModel.swift
+++ b/ios/TinyTalkApp/TinyTalkApp/AppModel.swift
@@ -134,6 +134,10 @@ final class AppModel: ObservableObject {
     private var audioEngine: RealAudioEngine?
     private let objectRecognizer = VisionObjectRecognizer()
     private let pendingDemoStore = PendingDemoStore()
+    /// The on-phone storybooks for stories made away from home -- shared by
+    /// the demo connection (which builds them) and the real-server connect
+    /// path (which uploads them at sync time). See DemoStoryLibrary.
+    private let localStoryStore = LocalStoryStore()
     private var runLoop: Task<Void, Never>?
     private var pollTask: Task<Void, Never>?
     /// Which turn_id's transcript/reply has already been appended to
@@ -269,12 +273,39 @@ final class AppModel: ObservableObject {
     /// disconnectUserInitiated(), which the "Home" menu item already
     /// calls from the same screens this can fire from).
     func setAwayFromHomeEnabled(_ enabled: Bool) {
-        let changingWhileConnected = enabled != awayFromHomeEnabled && isConnected
+        let isSwitching = enabled != awayFromHomeEnabled
+        let changingWhileConnected = isSwitching && isConnected
         awayFromHomeEnabled = enabled
         UserDefaults.standard.set(enabled, forKey: "awayFromHomeEnabled")
         if changingWhileConnected {
             disconnect()
         }
+        if isSwitching {
+            resetLibraryStateForBackendSwitch()
+        }
+    }
+
+    /// The story library lives on a different backend after a switch (the
+    /// home Mac's, or this phone's own), so everything cached from the OLD
+    /// one must go -- otherwise Library would show the other backend's
+    /// stale cards, and tapping one would open a Reading screen whose
+    /// story this backend has never heard of.
+    ///
+    /// Includes the End-screen baseline (hasEstablishedLibraryBaseline,
+    /// lastAcknowledgedConcludedStoryId), which disconnect() deliberately
+    /// does NOT reset within one backend (see hasEstablishedLibraryBaseline's
+    /// doc comment). Across a backend switch it must be: the first story
+    /// list from the NEW backend would otherwise present a "newest story"
+    /// different from the OLD backend's acknowledged id, and hijack
+    /// navigation to The End for an old, unrelated story (the issue #36
+    /// pattern).
+    private func resetLibraryStateForBackendSwitch() {
+        libraryStories = []
+        selectedStory = nil
+        pageImages = [:]
+        pendingStoryDetailFetchId = nil
+        hasEstablishedLibraryBaseline = false
+        lastAcknowledgedConcludedStoryId = nil
     }
 
     /// Settings' voice picker calls this. Unlike setAwayFromHomeEnabled(),
@@ -423,11 +454,17 @@ final class AppModel: ObservableObject {
         }
 
         isConnected = true
-        let pending = pendingDemoStore.loadAll()
+        // Each pending transcript, plus its finished storybook (title, pages,
+        // pictures) when one was built away from home -- so the Mac keeps
+        // what the child already saw instead of redoing (or losing) it. A
+        // story with no finished storybook syncs transcript-only, exactly as
+        // before.
+        let pending = DemoStoryLibrary.syncPayloads(store: localStoryStore, pending: pendingDemoStore.loadAll())
         if !pending.isEmpty {
             do {
                 try await coordinator.syncDemoStories(pending)
                 pendingDemoStore.clear()
+                localStoryStore.remove(ids: pending.map(\.id))
             } catch {
                 // Best effort, same reasoning as sendObjectSeen -- left
                 // for the next successful reconnect to retry; nothing
@@ -472,11 +509,16 @@ final class AppModel: ObservableObject {
         ttsClient.onDebugEvent = { [weak self] line in
             Task { @MainActor in self?.appendAudioDebugEvent(line) }
         }
+        // One Groq client shared by the live conversation and the storybook
+        // rewrite, so both use the same key (and the same free-tier budget).
+        let chatClient = GroqChatClient(apiKey: groqKey)
+        let library = DemoStoryLibrary(store: localStoryStore, writer: StorybookWriter(chat: chatClient))
         let connection = DemoConnection(
-            chatClient: GroqChatClient(apiKey: groqKey),
+            chatClient: chatClient,
             sttClient: GroqWhisperClient(apiKey: groqKey),
             ttsClient: ttsClient,
             animalFactTracker: AnimalFactTracker(fetcher: AnimalFactsAPIClient(apiKey: animalFactsKey)),
+            library: library,
             onStoryCompleted: { [weak self] payload in
                 self?.pendingDemoStore.save(payload)
             }
@@ -527,6 +569,15 @@ final class AppModel: ObservableObject {
         }
 
         isConnected = true
+        // Same as connect(): send the parent's story-length settings now, so
+        // even the very first story of this connection uses them (until
+        // now only the real-server path did this, so the Settings steppers
+        // silently did nothing away from home).
+        Task { await coordinator.updateSettings(targetTurns: storyTurnCount, pageCount: storybookPageCount) }
+        // A storybook build interrupted by the app being backgrounded or
+        // killed leaves its story "pending" forever -- pick any such story
+        // back up now.
+        Task { await library.resumeInterruptedBuilds() }
         startPollingState()
     }
 
````

- [ ] **Step 3: Build the app.**

```bash
xcodebuild -project ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkApp/TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build > /tmp/demo-mode-xcode.txt 2>&1
```
```bash
grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/demo-mode-xcode.txt | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm nothing unintended is staged** — `Local.xcconfig` must not appear:

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 status --short
```

Expected: only ` M ios/TinyTalkApp/TinyTalkApp/AppModel.swift`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 add ios/TinyTalkApp/TinyTalkApp/AppModel.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 commit -m "feat(ios): wire the local storybook library into demo mode and sync" -m "connectAwayFromHome builds a DemoStoryLibrary on a shared Groq client, sends the story-length settings, and resumes interrupted builds. A real backend switch resets library state including the End-screen baseline (the #36 pattern). Sync uploads each finished storybook and clears the local copy."
```

---

### Task 12: Final verification, on-device script, push, draft PR

**Files:** none (verification and hand-off).

- [ ] **Step 1: Full Swift suite.** Expected `Executed 333 tests, with 0 failures` as originally written — **335** as executed (the final-review fix wave added two Safety tests; see "Post-execution corrections" at the end) (use the whole-suite commands from Task 6 Step 7; re-run a lone `testPageAudioDittyStopsOnStopPageAudio` failure — known flake).

- [ ] **Step 2: Full server suite.** Expected `463 passed` (Task 10 Step 5's command).

- [ ] **Step 3: App build.** Expected `** BUILD SUCCEEDED **` (Task 11 Step 3's commands).

- [ ] **Step 4: Exactness check against the verified implementation** (only if the local scratch branch still exists in this repository; skip otherwise):

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 diff --ignore-all-space --ignore-blank-lines --stat d43aa4a HEAD -- ios server
```

Expected on a clean transcription of this plan **as originally written**: no output. As actually executed, the output is exactly the reviewed execution-time changes listed under "Post-execution corrections" at the end of this plan (a 9-line block in `AppModel.swift`, plus the final-review fix wave) and nothing else — any other file in the output is a transcription difference to explain before opening the PR. (Verify `git rev-parse --verify d43aa4a` succeeds first; if that commit is gone, skip this step.)

- [ ] **Step 5: Push the branch and open a DRAFT PR** (never push to `main`; never merge). Mark ready only after the on-device pass below.

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1 push -u origin worktree-demo-mode-phase-1
```

Then `gh pr create --draft --base main` with a body that summarizes the spec's Phase 1, lists the test counts above, and **pastes the on-device script below verbatim**.

- [ ] **Step 6: Hand the household this on-device script** (this repo's convention: exact worktree, server restart, rebuild, and a concrete script).

**Where the code lives:** `~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/` (branch `worktree-demo-mode-phase-1`).

**Server restart: YES** — `session.py` and the new `synced_storybook.py` changed and the server has no auto-reload. Stop any running `python -m tinytalk.app` (Ctrl-C in its terminal), make sure Ollama is up (`ollama serve`, or `curl http://127.0.0.1:11434/` replying `Ollama is running`), then start the server **from this worktree** with `main`'s venv (worktrees have no `.venv` of their own; `python -m` imports this worktree's code):

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/server
```
```bash
~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m tinytalk.app
```

(Optional: `export ANIMAL_FACTS_API_KEY=…` first, so stories mention real animal facts and the epilogue gets exercised.) Note this server starts with an **empty story library** — `server/data/` is gitignored and lives only in the main checkout — so the only story you will see at home is the one you sync in step 6.

**iOS rebuild: YES** — everything under `ios/` changed. Open this worktree's project (not the main checkout's) and Build & Run onto the phone:

```bash
open ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-1/ios/TinyTalkApp/TinyTalkApp.xcodeproj
```

`ios/TinyTalkApp/Local.xcconfig` already exists in this worktree (Task 11 created it).

**The script** (Groq key already saved; steps 1–4 with the Mac server stopped or its WiFi off — or simply turn WiFi off on the phone):

1. Settings → the hidden away-from-home card → turn **away from home** on. Set **turns to 4** and **pages to 3**. Create a story; it should conclude after about 4 turns. Start another and use the menu's **Finish this story** mid-story; it should end with a real closing line, not silence.
2. **The End appears by itself** after Elsie's last line finishes (no tap needed); once the rewrite finishes it shows the story's **real title** rather than a placeholder, and **"Read it now"** un-greys within seconds.
3. Read it: **3 pages** of prose. Tap 🔊 — first the waiting ditty, then narration in the chosen storyteller voice. Swipe to another page: the audio stops.
4. Back out to Library: the story is listed with its title and 3 pages. Go Home → **Read Stories** works.
5. Turn away-from-home **off** (Mac reachable). Library must **not** show the demo story yet, and opening Library must **not** jump to The End.
6. Connect to the home server. While switching (steps 5 → 6), also watch that the app does **not** jump to The End showing an old story right after the switch (commit `d1ae26a` guards a race there). **In the Mac server terminal you should see** `synced storybook accepted for story … : 3 page(s), 0 image(s)` — and **no** rewrite starting for that story. The home Library shows the story `done` with the same title and pages. (`0 image(s)` is correct in Phase 1; pictures arrive in Phase 2.)
7. Finish another away story, then switch on **airplane mode the moment Elsie's closing line ends**. The rewrite cannot reach Groq, so once The End settles, Library shows **"Couldn't finish this storybook"**. Turn airplane mode off, turn away-from-home off, and connect to the Mac so it syncs: this time the Mac log must **not** show `accepted` for that story; it arrives transcript-only, the Mac's own rewrite runs, and the story ends up `done` at home.

**What a pass looks like:** steps 1–4 work offline with no Mac involved; step 5 shows no stale cards and no hijack; step 6's log line is exactly the `accepted` line; step 7's log has no `accepted` line for that story. If step 6 shows `synced storybook rejected for story …: <reason>` instead, copy the reason into the PR — it names the failed check.

- [ ] **Step 7: After the household's pass,** mark the PR ready for review, and update the repo's `CLAUDE.md` "Current focus" (demo-mode parity Phase 1 done) in a small follow-up commit on the same branch. Phase 2 starts from `docs/superpowers/plans/2026-09-20-demo-mode-phase-2-away-illustrations.md` once this merges (or branch from this branch's head if you cannot wait, and retarget that PR after this one merges).

---

## Post-execution corrections (added 2026-09-20, after this plan was executed)

This plan was executed by a fresh subagent per task, each task independently reviewed (spec + quality), followed by a whole-branch review and one fix wave. The resulting tree differs from the scratch implementation this plan's code blocks came from in exactly the reviewed ways below — where they differ, trust the tree, not the blocks above.

1. **Task 11 was missing a line (`f1c059d`).** `connectAwayFromHome()` must also call `Task { await coordinator.listStories() }` after connecting, as `connect()` does. Without it the End-screen baseline is never seeded away from home: the poll loop treats the *first* `storyList` of a session as a baseline and deliberately does not navigate, so The End would never appear for the first story of every away-from-home session (after each backend switch and on a cold launch), and Landing's "Read Stories" would stay disabled. No unit test can see this (the app target has none), which is how the scratch implementation carried it. Found by Task 11's review, verified against `AppModel.swift`, and fixed with a 9-line block placed right after the `updateSettings` Task.
2. **Final-review fix wave (`0a24766`, `641dc7d`, `9811cda`, `d1ae26a`, `aa6bc4c`):** (a) `Safety.findBlocked` no longer has a `guard … continue` that could silently drop a match (it had turned `isSafe` fail-open, which also gates the home path); (b) the barge-in reset in `DemoConnection` is two helpers (`cancelInFlightLocked()`, `beginTurnLocked(turnId:)`) instead of five copies — behaviour-identical; (c) `LocalStoryStore.isSafeId` rejects `"."` (`remove(ids: ["."])` would have deleted the whole store); (d) `AppModel.startPollingState()` ignores a poll iteration whose coordinator is no longer current, so a stale iteration cannot re-seed the End-screen baseline from the backend just left after a switch; (e) two tests hardened (the sync fixture now uses a server-side id different from the phone's, so a regression to trusting the client's id fails; the parity guard waits per classification instead of a fixed sleep). Swift suite after the wave: **335** tests (333 + 2 new Safety tests); server suite unchanged at 463.
3. **Small inaccuracies in the text above:** Task 9's red step raises `ImportError: cannot import name 'synced_storybook' from 'tinytalk'` (not `ModuleNotFoundError`); Task 8's mutation A names `Protocol.swift` first (the compiler stops at the first failing file — `DemoConnection.swift`, then the parity test itself, fail in turn as each is patched); commands in this plan used `git -C ~/…`, which the worktree guard refuses (commit `0235373` switched them to absolute paths).
4. **Deviation #2's consequence is understated.** If `library.begin()`'s local write fails, `rewritingStarted` still goes out, but the story list's newest entry is the previously acknowledged story, so The End never appears at all — not merely "not browsable". (The server behaves the same way on a failed save, except that it logs it.)
5. **Known gaps deliberately not fixed here** (candidates for follow-up issues, not filed): no diagnostics on `StorybookWriter` failure exits or `LocalStoryStore` write failures (a Groq 429 or a full disk leaves no trace; an `onDebugEvent` hook plus a truthful `hasImage` would fix both); a check-then-act window between the no-resurrection guards and `store.save` (a `LocalStoryStore.saveIfPresent` would close it; the survivor is a permanently orphaned Library card); server hardening — the base64 payload is size-checked only after decoding, aggregate decoded pixels across pages are unbounded, and `websockets.serve(max_size=None)`; an interrupted illustration pass is never resumed and image bytes are read on the main actor (both inert until Phase 2 ships pictures).
