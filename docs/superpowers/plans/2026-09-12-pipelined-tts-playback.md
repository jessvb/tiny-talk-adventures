# Pipelined TTS Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the audible per-buffer playback gap in TTS audio by letting `RealAudioEngine` accept multiple buffers ahead of when they're needed, instead of fully awaiting each buffer's real playback completion before the next can even be scheduled.

**Architecture:** Add a new `PlaybackQueueTracker` (pure, unit-testable concurrency primitive) plus `enqueue(_:)`/`waitForPlaybackToFinish()` methods to `RealAudioEngine` and the `AudioPlaying` protocol it conforms to. `SessionCoordinator`'s `.audio` case switches from `await audio.play(pcm)` to `await audio.enqueue(pcm)`; the one genuine completion wait moves to `turnEnd`, preserving `readyToShowTheEnd`'s existing "audio has truly finished" guarantee. The existing `play(_:)` method and its callers (the waiting ditty) are untouched.

**Tech Stack:** Swift 6 (TinyTalkCore/TinyTalkPlatform SwiftPM targets, XCTest), AVFoundation (AVAudioEngine/AVAudioPlayerNode).

**Spec:** `docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md` — read this first; this plan argues from that spec but does not restate its evidence/rationale.

## Global Constraints

- `readyToShowTheEnd` must still only become true once a turn's audio has genuinely finished being heard (`.dataPlayedBack` semantics), never merely scheduled or handed off to the render engine.
- The existing per-buffer `PlaybackCompletionGate` + 3-second scheduleBuffer-completion-timeout safety net is reused unmodified for each buffer — not removed, not restructured.
- `play(_:)` itself is not modified and the waiting ditty's use of it is not touched — zero behavior change to ditty playback.
- `stopPlaybackImmediately()` must reset any outstanding playback-queue tracking state, since a stopped buffer's own completion callback is not guaranteed to fire (already true and already documented for the existing single-buffer case in this file).
- `TinyTalkCoreTests` must not gain a dependency on `TinyTalkPlatform` (Task 12 of the away-from-home plan already ruled on this — see `Fakes.swift`'s existing `FakeAudio`, which is a self-contained simulation, not a wrapper around real platform types).

---

## Task 1: `PlaybackQueueTracker` — pure, unit-tested concurrency primitive

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkPlatform/PlaybackQueueTracker.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkPlatformTests/PlaybackQueueTrackerTests.swift`

**Interfaces:**
- Produces: `final class PlaybackQueueTracker: @unchecked Sendable` (internal access, no `public`/`private`) with `init()`, `func bufferEnqueued()`, `func bufferFinished()`, `func waitForIdle() async`, `func reset()`.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/TinyTalkCore/Tests/TinyTalkPlatformTests/PlaybackQueueTrackerTests.swift
import XCTest
@testable import TinyTalkPlatform

final class PlaybackQueueTrackerTests: XCTestCase {
    func testWaitForIdleResolvesImmediatelyWithNothingOutstanding() async {
        let tracker = PlaybackQueueTracker()
        // Should not hang -- if this test times out, waitForIdle() is
        // broken for the empty-reply-turn case (no .audio event ever
        // arrives, so bufferEnqueued() is never called).
        await tracker.waitForIdle()
    }

    func testWaitForIdleResolvesOnceTheOnlyOutstandingBufferFinishes() async {
        let tracker = PlaybackQueueTracker()
        tracker.bufferEnqueued()
        var resolved = false
        let waitTask = Task {
            await tracker.waitForIdle()
            resolved = true
        }
        // Give waitForIdle() a moment to actually register as a waiter
        // before we resolve the buffer -- otherwise this test could pass
        // even if bufferFinished() ran before waitForIdle() started
        // waiting, which wouldn't prove the suspend-then-resume path
        // works at all.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(resolved, "should still be waiting -- nothing has finished yet")
        tracker.bufferFinished()
        await waitTask.value
        XCTAssertTrue(resolved)
    }

    func testWaitForIdleWaitsForAllOutstandingBuffersNotJustOne() async {
        let tracker = PlaybackQueueTracker()
        tracker.bufferEnqueued()
        tracker.bufferEnqueued()
        var resolved = false
        let waitTask = Task {
            await tracker.waitForIdle()
            resolved = true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        tracker.bufferFinished()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(resolved, "should still be waiting -- only 1 of 2 outstanding buffers finished")
        tracker.bufferFinished()
        await waitTask.value
        XCTAssertTrue(resolved)
    }

    func testResetResumesAWaiterEvenThoughItsBufferNeverReportedFinished() async {
        let tracker = PlaybackQueueTracker()
        tracker.bufferEnqueued()
        var resolved = false
        let waitTask = Task {
            await tracker.waitForIdle()
            resolved = true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(resolved)
        tracker.reset() // simulates stopPlaybackImmediately() -- bufferFinished() is never called for this buffer
        await waitTask.value // must not hang
        XCTAssertTrue(resolved)
    }

    func testResetBeforeAnyoneIsWaitingLeavesTrackerIdleAfterward() async {
        let tracker = PlaybackQueueTracker()
        tracker.bufferEnqueued()
        tracker.reset()
        // Must resolve immediately -- reset() already cleared the
        // buffer this would otherwise have waited for.
        await tracker.waitForIdle()
    }

    func testBufferFinishedCalledMoreTimesThanEnqueuedNeverGoesNegative() {
        let tracker = PlaybackQueueTracker()
        tracker.bufferEnqueued()
        tracker.bufferFinished()
        // A second, unmatched bufferFinished() -- mirrors the real
        // per-buffer completion-vs-timeout race where both could
        // theoretically fire if a future bug in the gate ever regressed.
        // Must not crash or underflow; waitForIdle() must still resolve
        // immediately afterward.
        tracker.bufferFinished()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter PlaybackQueueTrackerTests 2>&1 | tail -30`
Expected: FAIL to build — `PlaybackQueueTracker` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// ios/TinyTalkCore/Sources/TinyTalkPlatform/PlaybackQueueTracker.swift
import Foundation

/// Tracks how many playback buffers are "outstanding" -- scheduled but
/// not yet confirmed finished -- so a caller can enqueue several buffers
/// back-to-back without waiting for each one individually, then await
/// genuine completion of all of them at once. See
/// docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md for
/// why this exists: RealAudioEngine.play() previously fully awaited each
/// buffer's real playback completion before the next could even be
/// scheduled, and on-device timing evidence traced a real, audible
/// per-buffer stutter to that serialization.
///
/// Lock-protected, `@unchecked Sendable` -- same idiom PlaybackCompletionGate
/// already establishes in AudioEngine.swift for state shared between a
/// completion closure (fires on an arbitrary AVFoundation thread) and
/// Swift concurrency.
final class PlaybackQueueTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var waiter: CheckedContinuation<Void, Never>?

    /// Call once per buffer, right before scheduling it.
    func bufferEnqueued() {
        lock.withLock { outstanding += 1 }
    }

    /// Call exactly once per enqueued buffer, whichever of (real
    /// completion, timeout fallback) resolves it first -- mirrors how
    /// PlaybackCompletionGate already guarantees "exactly once" per
    /// buffer today. Safe to call more times than bufferEnqueued() was
    /// called (never goes negative) -- defensive only, should not
    /// happen in practice.
    func bufferFinished() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            outstanding = max(0, outstanding - 1)
            if outstanding == 0, let waiter {
                self.waiter = nil
                return waiter
            }
            return nil
        }
        toResume?.resume()
    }

    /// Suspends until every buffer enqueued so far has been confirmed
    /// finished (via bufferFinished()) -- resolves immediately if
    /// nothing is outstanding.
    func waitForIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeNow: Bool = lock.withLock {
                if outstanding <= 0 {
                    return true
                }
                waiter = continuation
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    /// Forces outstanding back to zero and resumes any waiter
    /// immediately -- called when playback is forcibly stopped
    /// (barge-in), since a stopped buffer's own completion callback is
    /// not guaranteed to fire (AudioEngine.swift already documents that
    /// distrust for the pre-existing single-buffer case).
    func reset() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            outstanding = 0
            let w = waiter
            waiter = nil
            return w
        }
        toResume?.resume()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter PlaybackQueueTrackerTests 2>&1 | tail -30`
Expected: PASS, 6/6.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkPlatform/PlaybackQueueTracker.swift ios/TinyTalkCore/Tests/TinyTalkPlatformTests/PlaybackQueueTrackerTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): add PlaybackQueueTracker for pipelined audio playback

Pure, unit-tested concurrency primitive: tracks how many playback
buffers are outstanding so a caller can enqueue several ahead of time
and await genuine completion of all of them at once, instead of
fully waiting after each individual buffer. First step of the fix
described in docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `PlaybackQueueTracker` into `RealAudioEngine`

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Interfaces.swift` (the `AudioPlaying` protocol, currently lines 7-12)
- Modify: `ios/TinyTalkCore/Sources/TinyTalkPlatform/AudioEngine.swift` (add a stored property near the other private state around line 48-74; add two new methods right after `play(_:)`, which currently spans roughly lines 414-494; modify `stopPlaybackImmediately()`, currently lines 410-412)

**Interfaces:**
- Consumes: `PlaybackQueueTracker` from Task 1 (`bufferEnqueued()`, `bufferFinished()`, `waitForIdle() async`, `reset()`).
- Produces: `AudioPlaying.enqueue(_ pcm: Data) async`, `AudioPlaying.waitForPlaybackToFinish() async` — later tasks call these by these exact names.

- [ ] **Step 1: Add the two new methods to the `AudioPlaying` protocol**

In `ios/TinyTalkCore/Sources/TinyTalkCore/Interfaces.swift`, the protocol currently reads:

```swift
public protocol AudioPlaying: Sendable {
    /// Must return immediately with no async work and no network
    /// dependency -- this is on the critical path for barge-in latency.
    func stopPlaybackImmediately()
    func play(_ pcm: Data) async
}
```

Change it to:

```swift
public protocol AudioPlaying: Sendable {
    /// Must return immediately with no async work and no network
    /// dependency -- this is on the critical path for barge-in latency.
    func stopPlaybackImmediately()
    func play(_ pcm: Data) async
    /// Schedules a buffer for playback and returns as soon as scheduling
    /// succeeds -- NOT once the buffer has actually finished playing.
    /// Multiple enqueue(_:) calls queue back-to-back on the underlying
    /// player node; use waitForPlaybackToFinish() to know when
    /// everything enqueued so far has genuinely finished. See
    /// docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md.
    func enqueue(_ pcm: Data) async
    /// Suspends until every buffer enqueued via enqueue(_:) so far has
    /// genuinely finished playing (or resolves immediately if none are
    /// outstanding).
    func waitForPlaybackToFinish() async
}
```

- [ ] **Step 2: Add the tracker property and reset it in `stopPlaybackImmediately()`**

In `ios/TinyTalkCore/Sources/TinyTalkPlatform/AudioEngine.swift`, add a new private stored property alongside the class's other private state (near `private var playbackConnectionFormat: AVAudioFormat!` and `onAudioCaptured`):

```swift
private let playbackQueueTracker = PlaybackQueueTracker()
```

Change `stopPlaybackImmediately()` from:

```swift
    public func stopPlaybackImmediately() {
        playerNode.stop()
    }
```

to:

```swift
    public func stopPlaybackImmediately() {
        playerNode.stop()
        // A stopped/cancelled buffer's own scheduleBuffer completion
        // callback is not guaranteed to fire -- see play()'s own doc
        // comments on why this file already distrusts that assumption
        // elsewhere. Without this, a future turn's
        // waitForPlaybackToFinish() could hang forever waiting for a
        // buffer this stop just discarded.
        playbackQueueTracker.reset()
    }
```

- [ ] **Step 3: Add `enqueue(_:)` and `waitForPlaybackToFinish()`, mirroring `play(_:)`'s existing structure**

Add these two methods immediately after the existing `play(_:)` method's closing brace:

```swift
    /// Schedules a buffer without waiting for it to actually finish
    /// playing -- see AudioPlaying.enqueue(_:)'s doc comment and
    /// PlaybackQueueTracker's doc comment for why. Mirrors play(_:)'s
    /// structure almost exactly (same ensureEngineRunning() guard, same
    /// per-buffer PlaybackCompletionGate + 3-second-timeout race, same
    /// .dataPlayedBack completion type) -- the only difference is that
    /// this does not wrap scheduling in a continuation that waits for
    /// that race to resolve; it fires the schedule and the buffer's own
    /// timeout fallback, then returns.
    public func enqueue(_ pcm: Data) async {
        guard let buffer = pcmDataToBuffer(pcm) else { return }
        guard await ensureEngineRunning() else {
            print("RealAudioEngine: engine never started -- dropping this enqueue() call rather than hanging forever")
            return
        }
        playbackQueueTracker.bufferEnqueued()
        let gate = PlaybackCompletionGate()
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            if gate.tryResume() {
                self?.playbackQueueTracker.bufferFinished()
            }
        }
        // Deliberately unconditional -- see play()'s own doc comment on
        // why guarding this with `if !playerNode.isPlaying` was actively
        // harmful on real hardware.
        playerNode.play()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if gate.tryResume() {
                let message = "RealAudioEngine: enqueue() scheduleBuffer completion did not fire within 3s (likely the engine was stopped mid-render by a concurrent reconfiguration) -- giving up on this buffer rather than hanging forever"
                print(message)
                self?.onDebugEvent?("[\(DebugTimestamp.now())] \(message)")
                self?.playbackQueueTracker.bufferFinished()
            }
        }
    }

    /// Suspends until every buffer enqueued via enqueue(_:) so far has
    /// genuinely finished playing.
    public func waitForPlaybackToFinish() async {
        await playbackQueueTracker.waitForIdle()
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd ios/TinyTalkCore && swift build 2>&1 | tail -40`
Expected: `Build complete!` with no errors (existing Sendable-closure-capture warnings elsewhere in this file, if any, are pre-existing and unrelated).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/Interfaces.swift ios/TinyTalkCore/Sources/TinyTalkPlatform/AudioEngine.swift
git commit -m "$(cat <<'EOF'
feat(ios): add RealAudioEngine.enqueue()/waitForPlaybackToFinish()

Mirrors play(_:)'s existing structure (same ensureEngineRunning()
guard, same per-buffer PlaybackCompletionGate + 3-second-timeout race,
same .dataPlayedBack completion type) but decouples scheduling from
waiting, via the new PlaybackQueueTracker. stopPlaybackImmediately()
now also resets the tracker, since a stopped buffer's completion
callback is not guaranteed to fire. play(_:) itself and its only
caller (the waiting ditty) are unchanged.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Extend `FakeAudio`, update every existing test it affects, add new coverage

**Scope note:** switching `.audio` from `play()` to `enqueue()` affects far more of this test file than just "add tests for the new methods." A grep for `audio.played`/`audio.playDelayNanos`/`audio.playWasCancelled` across `SessionCoordinatorTests.swift` turns up ~14 existing test functions. Each one is classified precisely below — most need a mechanical field rename, two need real (but well-understood) rework of how they force a race, several need no change at all (they're purely about the waiting ditty, which still calls the unchanged `play()`). This task leaves the suite red until Task 4 lands — expected, since these assertions check `enqueued`/`enqueueWasCancelled`, which stay empty/false until `SessionCoordinator` actually calls `enqueue()`.

**Files:**
- Modify: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/Fakes.swift` (the `FakeAudio` class, currently lines 5-45)
- Modify: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AudioPlaying.enqueue(_:)`/`.waitForPlaybackToFinish()` from Task 2 (protocol conformance only — `FakeAudio` does NOT depend on `TinyTalkPlatform` or the real `PlaybackQueueTracker`; per Global Constraints, `TinyTalkCoreTests` must stay independent of `TinyTalkPlatform`, so this is a self-contained re-implementation of the same *contract*, not a reuse of the same *type*).
- Produces: `FakeAudio.enqueued: [Data]`, `FakeAudio.enqueueWasCancelled: Bool`, `FakeAudio.enqueueDelayNanos: UInt64` (mirrors `playDelayNanos`, but delays *registering* the buffer — models the real `enqueue()`'s own `ensureEngineRunning()` await point, which a real interrupt could race against), `FakeAudio.autoFinishEnqueuedBuffers: Bool` (default `true`), `FakeAudio.finishOldestEnqueuedBuffer()` (test control for completion timing, a separate axis from registration timing).

- [ ] **Step 1: Extend `FakeAudio`**

In `ios/TinyTalkCore/Tests/TinyTalkCoreTests/Fakes.swift`, `FakeAudio` currently reads:

```swift
final class FakeAudio: AudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false
    private var _played: [Data] = []
    private var _playWasCancelled = false
    private var _playDelayNanos: UInt64 = 0
    var playDelayNanos: UInt64 {
        get { lock.withLock { _playDelayNanos } }
        set { lock.withLock { _playDelayNanos = newValue } }
    }

    var stopped: Bool { lock.withLock { _stopped } }
    var played: [Data] { lock.withLock { _played } }
    var playWasCancelled: Bool { lock.withLock { _playWasCancelled } }

    func stopPlaybackImmediately() {
        lock.withLock { _stopped = true }
    }

    func play(_ pcm: Data) async {
        let playDelayNanos = playDelayNanos
        if playDelayNanos > 0 {
            do {
                try await Task.sleep(nanoseconds: playDelayNanos)
            } catch {
                lock.withLock { _playWasCancelled = true }
                return
            }
        }
        lock.withLock { _played.append(pcm) }
    }
}
```

Change it to:

```swift
final class FakeAudio: AudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false
    private var _played: [Data] = []
    private var _playWasCancelled = false
    private var _playDelayNanos: UInt64 = 0
    private var _enqueued: [Data] = []
    private var _enqueueWasCancelled = false
    private var _enqueueDelayNanos: UInt64 = 0
    private var _outstandingEnqueued = 0
    private var _autoFinishEnqueuedBuffers = true
    private var waiter: CheckedContinuation<Void, Never>?
    var playDelayNanos: UInt64 {
        get { lock.withLock { _playDelayNanos } }
        set { lock.withLock { _playDelayNanos = newValue } }
    }
    /// Delays enqueue(_:) *registering* its buffer -- models the real
    /// RealAudioEngine.enqueue()'s own ensureEngineRunning() await
    /// point, which a real interrupt could race against before the
    /// buffer is ever scheduled. Distinct from playback-completion
    /// timing (see autoFinishEnqueuedBuffers/finishOldestEnqueuedBuffer()
    /// below) -- the real enqueue()/waitForPlaybackToFinish() split
    /// decouples these two axes, so this fake must too.
    var enqueueDelayNanos: UInt64 {
        get { lock.withLock { _enqueueDelayNanos } }
        set { lock.withLock { _enqueueDelayNanos = newValue } }
    }
    /// When true (the default), enqueue(_:) marks its own buffer
    /// finished immediately after registering it, so tests that don't
    /// care about precise completion timing (the vast majority) don't
    /// need to change. Tests that DO care set this false and call
    /// finishOldestEnqueuedBuffer() themselves.
    var autoFinishEnqueuedBuffers: Bool {
        get { lock.withLock { _autoFinishEnqueuedBuffers } }
        set { lock.withLock { _autoFinishEnqueuedBuffers = newValue } }
    }

    var stopped: Bool { lock.withLock { _stopped } }
    var played: [Data] { lock.withLock { _played } }
    var playWasCancelled: Bool { lock.withLock { _playWasCancelled } }
    /// Buffers passed to enqueue(_:) so far, in order.
    var enqueued: [Data] { lock.withLock { _enqueued } }
    /// True if an enqueue(_:) call observed real Task cancellation (via
    /// enqueueDelayNanos's Task.sleep throwing) before it ever managed
    /// to register its buffer -- mirrors playWasCancelled's purpose for
    /// the enqueue path.
    var enqueueWasCancelled: Bool { lock.withLock { _enqueueWasCancelled } }

    func stopPlaybackImmediately() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            _stopped = true
            _outstandingEnqueued = 0
            let w = waiter
            waiter = nil
            return w
        }
        toResume?.resume()
    }

    func play(_ pcm: Data) async {
        let playDelayNanos = playDelayNanos
        if playDelayNanos > 0 {
            do {
                try await Task.sleep(nanoseconds: playDelayNanos)
            } catch {
                lock.withLock { _playWasCancelled = true }
                return
            }
        }
        lock.withLock { _played.append(pcm) }
    }

    func enqueue(_ pcm: Data) async {
        let enqueueDelayNanos = enqueueDelayNanos
        if enqueueDelayNanos > 0 {
            do {
                try await Task.sleep(nanoseconds: enqueueDelayNanos)
            } catch {
                lock.withLock { _enqueueWasCancelled = true }
                return // never registered -- matches a real enqueue() whose ensureEngineRunning() await got cancelled before scheduleBuffer ever ran
            }
        }
        let shouldAutoFinish: Bool = lock.withLock {
            _enqueued.append(pcm)
            _outstandingEnqueued += 1
            return _autoFinishEnqueuedBuffers
        }
        if shouldAutoFinish {
            finishOldestEnqueuedBuffer()
        }
    }

    /// Test control: marks the oldest outstanding enqueue(_:) call as
    /// finished, resuming waitForPlaybackToFinish() if this was the last
    /// one outstanding. A self-contained simulation of
    /// PlaybackQueueTracker's contract (not a reuse of that type --
    /// TinyTalkCoreTests must not depend on TinyTalkPlatform, see this
    /// plan's Global Constraints).
    func finishOldestEnqueuedBuffer() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            guard _outstandingEnqueued > 0 else { return nil }
            _outstandingEnqueued -= 1
            if _outstandingEnqueued == 0, let waiter {
                self.waiter = nil
                return waiter
            }
            return nil
        }
        toResume?.resume()
    }

    func waitForPlaybackToFinish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeNow: Bool = lock.withLock {
                if _outstandingEnqueued <= 0 {
                    return true
                }
                waiter = continuation
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }
}
```

- [ ] **Step 2: Update the 10 existing tests that need only a mechanical field rename**

Each of these currently checks `audio.played`/`audio.played.isEmpty` for *real-turn reply audio* (not ditty audio). Change exactly the referenced line(s) in each; nothing else about the test changes:

| Test function | Line(s) | Change |
|---|---|---|
| `testHappyPathReachesIdleAfterTurnEnd` | 25 | `XCTAssertEqual(audio.played, [Data([1, 2, 3])])` → `XCTAssertEqual(audio.enqueued, [Data([1, 2, 3])])` |
| `testStaleReplyForAnAbandonedTurnIsDiscardedNotMisattributed` | 1077 | `XCTAssertTrue(audio.played.isEmpty, "turn 1's stale audio must not be played once turn 2 is active")` → `XCTAssertTrue(audio.enqueued.isEmpty, "turn 1's stale audio must not be enqueued once turn 2 is active")` |
| `testStaleReplyForAnAbandonedTurnIsDiscardedNotMisattributed` | 1090 | `XCTAssertEqual(audio.played, [Data([2, 2, 2])], "turn 2's real reply must play normally, unaffected by the discarded stale one")` → `XCTAssertEqual(audio.enqueued, [Data([2, 2, 2])], "turn 2's real reply must enqueue normally, unaffected by the discarded stale one")` |
| `testConcludeStorySendsConcludeStoryAndEntersWaitingForReply` | 309 | `XCTAssertEqual(audio.played, [Data([1])])` → `XCTAssertEqual(audio.enqueued, [Data([1])])` |
| `testInterruptThenNewTurnCompletesNormally` | 684 | `XCTAssertEqual(audio.played, [Data([5])])` → `XCTAssertEqual(audio.enqueued, [Data([5])])` |
| `testMutingWhileListeningStopsListeningAndFinalizesTheTurn` | 1433 | `XCTAssertEqual(audio.played, [Data([1, 2, 3])])` → `XCTAssertEqual(audio.enqueued, [Data([1, 2, 3])])` |
| `testResumeEntersWaitingForReplyMutedAndPlaysTheReplayedReply` | 1684 | `XCTAssertEqual(audio.played, [Data([5, 6, 7])])` → `XCTAssertEqual(audio.enqueued, [Data([5, 6, 7])])` |
| `testResumeDoesNotLoseEventsEmittedBeforeStartIsCalled` | 1718 | `XCTAssertEqual(audio.played, [Data([1])])` → `XCTAssertEqual(audio.enqueued, [Data([1])])` |
| `testResumeWithMismatchedTurnIdDiscardsTheReplayedEvents` | 1743 | `XCTAssertTrue(audio.played.isEmpty)` → `XCTAssertTrue(audio.enqueued.isEmpty)` |
| `testWaitingDittyLoopsWhileWaitingForReplyAndStopsWhenRealAudioArrives` | 1197 | `XCTAssertEqual(audio.played.last, Data([1, 2, 3]))` → `XCTAssertEqual(audio.enqueued.last, Data([1, 2, 3]))` — leave every other line in this test (the ditty-count assertions at 1178-1196) exactly as-is; they check `audio.played`'s *count staying flat*, which is still correct since `enqueue()` never touches `_played` |
| `testLateReplyAfterDittyTimeoutIsDiscarded` | 1338 | `XCTAssertFalse(audio.played.contains(Data([1, 2, 3])), "a late reply for an already-abandoned turn must never be played")` → `XCTAssertFalse(audio.enqueued.contains(Data([1, 2, 3])), "a late reply for an already-abandoned turn must never be enqueued")` |

That's 11 call sites across 10 functions (one function, `testStaleReplyForAnAbandonedTurnIsDiscardedNotMisattributed`, has two).

- [ ] **Step 3: Update `testInterruptRecordsLatency` (stale comment/setting only — no assertion changes)**

This test (line 736) sets `audio.playDelayNanos = 50_000_000`, but its own existing comment already states that delay "is irrelevant to this bound" — it never asserts on `played`/`enqueued` at all. Once `.audio` routes through `enqueue()`, that line does nothing (it only affects `play()`, which nothing in this test's path calls anymore). Remove the now-meaningless line and tighten the comment:

Change:
```swift
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 50_000_000
        let vad = FakeVAD()
```
to:
```swift
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
```

And change the comment block above `XCTAssertLessThan` from:
```swift
        // Regression coverage for a code-review finding: the metric must be
        // stamped right after audio.stopPlaybackImmediately(), before the
        // network send, so it reflects only the (synchronous) stop -- not
        // a network round-trip. audio.play()'s 50ms delay is irrelevant to
        // this bound: that delay only affects the in-flight play() call
        // being cancelled, not anything on the vadFireToPlaybackStopped
        // path, which is a handful of synchronous calls. A generous bound
        // (well under real network RTT, comfortably above pure scheduling
        // noise) still exists to catch a future regression that puts real
        // async work back before the stamp.
```
to:
```swift
        // Regression coverage for a code-review finding: the metric must be
        // stamped right after audio.stopPlaybackImmediately(), before the
        // network send, so it reflects only the (synchronous) stop -- not
        // a network round-trip. Nothing about enqueue()'s own timing is
        // on this path at all (it only affects the vadFireToPlaybackStopped
        // metric if the stamp itself moved, not through any playback
        // delay). A generous bound (well under real network RTT,
        // comfortably above pure scheduling noise) still exists to catch
        // a future regression that puts real async work back before the
        // stamp.
```

- [ ] **Step 4: Rework `testInterruptDiscardsAlreadyBufferedTurnEventsAndDoesNotCorruptNextTurn` (lines 94-164)**

This test's core guarantee — chunks buffered-but-unprocessed at interrupt time never reach the audio engine at all — is untouched by this plan (the `if Task.isCancelled { return }` guard it relies on isn't being modified). Only its *assertions about the one chunk that had already started processing* need to change, since `enqueue()` doesn't have the same "genuinely in-flight, blocking" shape `play()` did — mirror that shape instead via the new `enqueueDelayNanos`/`enqueueWasCancelled`.

Change:
```swift
        audio.playDelayNanos = 50_000_000 // chunk 1 will be genuinely in-flight when the interrupt fires
```
to:
```swift
        audio.enqueueDelayNanos = 50_000_000 // chunk 1's enqueue() registration will be genuinely in-flight when the interrupt fires
```

Change:
```swift
        audio.playDelayNanos = 0
```
to:
```swift
        audio.enqueueDelayNanos = 0
```

Change:
```swift
        XCTAssertTrue(audio.played.isEmpty, "no buffered chunk from the OLD turn may reach play() after the interrupt discarded it")
        XCTAssertTrue(audio.playWasCancelled, "chunk 1's in-flight play() must have observed genuine cancellation")
```
to:
```swift
        XCTAssertTrue(audio.enqueued.isEmpty, "no buffered chunk from the OLD turn may reach enqueue() after the interrupt discarded it")
        XCTAssertTrue(audio.enqueueWasCancelled, "chunk 1's in-flight enqueue() must have observed genuine cancellation")
```

Change:
```swift
        XCTAssertEqual(audio.played, [Data([9])], "the new turn's chunk must actually be played -- proves its turnContinuation was not silently orphaned by stale cleanup")
```
to:
```swift
        XCTAssertEqual(audio.enqueued, [Data([9])], "the new turn's chunk must actually be enqueued -- proves its turnContinuation was not silently orphaned by stale cleanup")
```

Also update the two comment blocks that explain the mechanism (lines ~85-93 and ~120-128) to say `enqueue()` instead of `play()` — read them in place and adjust the wording to match (they describe *why* the test is structured this way; the reasoning is unchanged, only the method name in the prose).

- [ ] **Step 5: Rework `testInterruptDuringSlowPlaybackGenuinelyCancelsInFlightPlay` (lines 171-198)**

Same pattern as Step 4, applied to this test. Change:
```swift
        audio.playDelayNanos = 50_000_000 // 50ms -- long enough to interrupt mid-flight
```
to:
```swift
        audio.enqueueDelayNanos = 50_000_000 // 50ms -- long enough to interrupt mid-flight
```

Change:
```swift
        XCTAssertTrue(audio.played.isEmpty, "the in-flight chunk must NOT complete and record itself as played after interrupt")
        XCTAssertTrue(audio.playWasCancelled, "the in-flight play() call must have observed real task cancellation")
```
to:
```swift
        XCTAssertTrue(audio.enqueued.isEmpty, "the in-flight chunk must NOT complete and record itself as enqueued after interrupt")
        XCTAssertTrue(audio.enqueueWasCancelled, "the in-flight enqueue() call must have observed real task cancellation")
```

Consider renaming this test to `testInterruptDuringSlowEnqueueGenuinelyCancelsInFlightEnqueue` for clarity (its doc comment at lines 166-170 references "play()" by name too — update that comment the same way as Step 4's).

- [ ] **Step 6: Rework `testReadyToShowTheEndWaitsForPlaybackEvenWhenRewritingStartedArrivesFirst` (lines 209-248)**

This one is about *completion* timing, not registration timing — use `autoFinishEnqueuedBuffers`/`finishOldestEnqueuedBuffer()`, not `enqueueDelayNanos`. Replace the whole test body with:

```swift
    func testReadyToShowTheEndWaitsForPlaybackEvenWhenRewritingStartedArrivesFirst() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false // genuinely still playing until we say so
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3]))) // enqueue()'d, not yet marked finished
        try? await Task.sleep(nanoseconds: 10_000_000) // let enqueue() register the buffer

        // The server always sends rewriting_started strictly after this
        // turn's turn_end (see session.py's _run_turn) -- but nothing
        // makes consumeServerEvents() wait for runTurn()'s own in-flight
        // enqueue() call before processing it, so it can arrive here, at
        // the client, while that buffer is still (simulated-)outstanding.
        connection.emit(.message(.rewritingStarted))
        try? await Task.sleep(nanoseconds: 5_000_000)

        var ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "must not be ready while the concluding turn's audio is still playing")
        var rewriting = await coordinator.isRewriting
        XCTAssertTrue(rewriting, "isRewriting itself should already reflect the server's push")

        // turnEnd is now suspended inside waitForPlaybackToFinish() --
        // the buffer hasn't been marked finished yet.
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "must still not be ready -- the buffer has not been marked finished yet")

        // The buffer genuinely finishes playing now.
        audio.finishOldestEnqueuedBuffer()
        try? await Task.sleep(nanoseconds: 20_000_000)

        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "must become ready once playback has genuinely finished")

        runLoop.cancel()
    }
```

Also update this test's doc comment (lines 200-208) — it currently says "Uses playDelayNanos the same way testInterruptDuringSlowPlaybackGenuinelyCancelsInFlightPlay does" and "an instantly-resolving play() would never expose this race"; change to reference `autoFinishEnqueuedBuffers`/`finishOldestEnqueuedBuffer()` and `enqueue()` instead.

- [ ] **Step 7: Confirm the remaining `playDelayNanos`-using tests need no change**

Read each of these in place and confirm they're purely about the waiting ditty (which still calls the unchanged `play()`) — no edits needed, just verify while you're in the file:
- `testWaitingDittyStopsOnInterruptBeforeAnyReplyArrives` (line 1202)
- `testWaitingDittyStopsOnEmptyReplyWithNoAudio` (line 1231)
- `testWaitingDittyTimesOutAndReturnsToIdleWithAnErrorIfNoReplyArrives` (line 1266)
- `testResumeDoesNotStartTheDittyOnItsOwn`, `testStartResumedWaitingDittyStartsItAfterResume`, `testStartResumedWaitingDittyIsANoOpIfTheTurnAlreadyFinished` (lines 1756, 1769, 1788)

- [ ] **Step 8: Write the new tests for `enqueue`/`waitForPlaybackToFinish` themselves**

Add to `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`, following the exact setup pattern every other test in this file uses (`FakeConnection()`/`FakeAudio()`/`FakeVAD()`/`SessionCoordinator(connection:audio:vad:)`/`let runLoop = Task { await coordinator.start() }`, drive with `vad.fire(...)` and `connection.emit(...)`, `try? await Task.sleep(nanoseconds:)` between steps, `runLoop.cancel()` at the end):

```swift
    func testMultipleAudioEventsInOneTurnAllEnqueueNotPlay() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.audio(Data([2])))
        connection.emit(.audio(Data([3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([1]), Data([2]), Data([3])])
        XCTAssertTrue(audio.played.isEmpty, "real-reply audio must never call play() -- only the ditty does")

        runLoop.cancel()
    }

    func testTurnEndWaitsForAllEnqueuedBuffersBeforeNotingPlaybackFinished() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.audio(Data([2])))
        connection.emit(.message(.rewritingStarted))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        var ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "turnEnd must still be suspended in waitForPlaybackToFinish() -- neither buffer has finished")

        audio.finishOldestEnqueuedBuffer() // 1 of 2
        try? await Task.sleep(nanoseconds: 10_000_000)
        ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "still waiting on the second buffer")

        audio.finishOldestEnqueuedBuffer() // 2 of 2
        try? await Task.sleep(nanoseconds: 20_000_000)
        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "both buffers finished -- turnEnd's wait must have resolved")

        runLoop.cancel()
    }

    func testEmptyReplyTurnEndDoesNotHangOnWaitForPlaybackToFinish() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // No .audio event at all -- an empty reply.
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "turnEnd handling must complete, not hang, when nothing was ever enqueued")

        runLoop.cancel()
    }

    func testInterruptResetsFakeAudioSoALaterTurnsWaitForPlaybackToFinishIsUnaffected() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart) // turn 1
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1]))) // enqueued, never finished
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart) // the barge-in -- turn 2
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(audio.stopped, "stopPlaybackImmediately must have been called")

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi again", turnId: 2)))
        connection.emit(.audio(Data([2])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "turn 2 must complete normally -- turn 1's un-finished buffer must not leave stale outstanding state behind")

        runLoop.cancel()
    }
```

- [ ] **Step 9: Run the full `SessionCoordinatorTests` suite to confirm the expected (temporary) failures**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests 2>&1 | tail -80`
Expected: it builds successfully (Task 2 already added `enqueue`/`waitForPlaybackToFinish` to the protocol, and this task's `FakeAudio` implements them), but every test this step updated fails, because `SessionCoordinator.swift` still calls `audio.play(pcm)` for real-turn audio — nothing ever reaches `audio.enqueued`. This is expected and resolves in Task 4. Skim the failure list and confirm it matches exactly the tests this task touched (Steps 2, 4, 5, 6, 8) — any *other* failing test means something in this task's edits went wrong.

- [ ] **Step 10: Commit**

```bash
git add ios/TinyTalkCore/Tests/TinyTalkCoreTests/Fakes.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
test(ios): update SessionCoordinatorTests for enqueue()/waitForPlaybackToFinish()

Extends FakeAudio with enqueue(_:)/waitForPlaybackToFinish() (a
self-contained simulation of PlaybackQueueTracker's contract --
TinyTalkCoreTests must not depend on TinyTalkPlatform) and its own
completion/registration timing controls (autoFinishEnqueuedBuffers,
enqueueDelayNanos), decoupled the same way the real implementation
decouples them.

Updates every existing test that asserted on real-turn audio.played
(11 call sites across 10 functions) to assert on .enqueued instead;
reworks the two tests that specifically forced an interrupt race via
playDelayNanos to use the new enqueueDelayNanos/enqueueWasCancelled
pair instead, preserving their exact original intent. Ditty-only tests
are untouched -- the ditty still calls the unchanged play(). Adds 4 new
tests for enqueue/waitForPlaybackToFinish's own contract.

Expected to leave these tests red until Task 4 switches
SessionCoordinator itself over.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Switch `SessionCoordinator` to `enqueue`/`waitForPlaybackToFinish`

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift` (the `.audio` case, currently lines 897-937, and the `.message(.turnEnd(_))` case, currently lines 938-955)

**Interfaces:**
- Consumes: `AudioPlaying.enqueue(_:)`/`.waitForPlaybackToFinish()` from Task 2, exercised via `FakeAudio` from Task 3.

- [ ] **Step 1: Replace the `.audio` case's per-chunk timing diagnostic and `play()` call with `enqueue(_:)`**

The `.audio` case currently ends with (after the existing `.waitingForReply` handling block):

```swift
                // Diagnostic for the on-device-reported stutter that
                // survived the TTS chunk-coalescing fix: measures whether
                // a play() call is taking noticeably longer than the audio
                // it's actually playing (24kHz mono PCM16 = 48000
                // bytes/sec), which would mean something is stalling
                // mid-render. Monotonic clock, matching LatencyLogger's own
                // reasoning for why wall-clock Date() is the wrong tool for
                // measuring a duration. On-device evidence (2026-09-11,
                // 200ms chunks) showed only modest (~100-130ms) per-call
                // overshoot -- logging every call's overshoot now that
                // AVSpeechTts yields ~1s chunks (≈12-13 calls/reply, well
                // under the debug log's 50-entry cap) gives the full
                // picture instead of just the ones that happened to cross
                // an arbitrary threshold, in case the larger chunk size
                // alone isn't enough to make the total overshoot
                // imperceptible.
                let playStarted = DispatchTime.now()
                await audio.play(pcm)
                let playElapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - playStarted.uptimeNanoseconds) / 1_000_000_000
                let expectedSeconds = Double(pcm.count) / 48_000.0
                let overshootSeconds = playElapsedSeconds - expectedSeconds
                logDebug(
                    "play() took \(String(format: "%.2f", playElapsedSeconds))s for a " +
                    "\(String(format: "%.2f", expectedSeconds))s buffer (\(pcm.count) bytes) " +
                    "-- overshoot \(String(format: "%.3f", overshootSeconds))s"
                )
```

Replace that entire block with:

```swift
                // Enqueues without waiting for real playback completion --
                // multiple .audio events now queue back-to-back on the
                // player node instead of each one fully blocking the next.
                // The old per-play()-call timing diagnostic (measuring
                // overshoot against a single buffer's own duration) no
                // longer means the same thing once calls don't block each
                // other -- see the turnEnd case below for its replacement,
                // which measures the one point that still genuinely waits.
                // See PlaybackQueueTracker's doc comment (AudioEngine.swift)
                // and docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md.
                await audio.enqueue(pcm)
```

- [ ] **Step 2: Add the one genuine wait to the `turnEnd` case**

The `.message(.turnEnd(_))` case currently reads:

```swift
            case .message(.turnEnd(_)):
                // Covers the empty-reply case: no .audio event ever
                // arrives, so this is the only place left to stop a
                // still-looping ditty for this turn -- and, for the same
                // reason, the only place left to auto-unmute if .speaking
                // was never reached (the "waiting" is over either way).
                stopWaitingDitty()
                await setMuted(false)
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                // Every audio chunk this turn received has, by this
                // point, genuinely finished playing (each was awaited in
                // the .audio case above before this loop could reach
                // turnEnd) -- see readyToShowTheEnd's doc comment for why
                // this specific point, not rewritingStarted's arrival, is
                // the real "finished being spoken" signal.
                noteTurnPlaybackFinished()
                return
```

Change it to:

```swift
            case .message(.turnEnd(_)):
                // Covers the empty-reply case: no .audio event ever
                // arrives, so this is the only place left to stop a
                // still-looping ditty for this turn -- and, for the same
                // reason, the only place left to auto-unmute if .speaking
                // was never reached (the "waiting" is over either way).
                stopWaitingDitty()
                await setMuted(false)
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                // .audio events this turn only enqueue()'d their buffers
                // (see the .audio case above) -- this is now the one
                // place that actually waits for genuine playback
                // completion, preserving readyToShowTheEnd's existing
                // "audio has truly finished, not just been scheduled"
                // guarantee (see that property's own doc comment for the
                // past real bug -- The End appearing mid-sentence -- this
                // prevents). Resolves immediately for an empty-reply turn,
                // since no .audio event means nothing was ever enqueued.
                let waitStarted = DispatchTime.now()
                await audio.waitForPlaybackToFinish()
                let waitElapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - waitStarted.uptimeNanoseconds) / 1_000_000_000
                logDebug("waitForPlaybackToFinish() took \(String(format: "%.2f", waitElapsedSeconds))s at turnEnd")
                noteTurnPlaybackFinished()
                return
```

- [ ] **Step 3: Run the full Swift test suite**

Run: `cd ios/TinyTalkCore && swift test 2>&1 | grep -E "^Test Suite.*(passed|failed)|Executed|error:|BUILD FAILED" | tail -20`
Expected: all suites pass now, including the tests Task 3 deliberately left red (the 11 renamed `.enqueued` assertions, the 2 reworked interrupt-timing tests, the 1 completion-timing test, and the 4 new `enqueue`/`waitForPlaybackToFinish`-specific tests) and every ditty-only/untouched test that was passing the whole time. A regression in any interrupt/barge-in/resume test here means this change broke something Task 13 of the away-from-home plan already fixed once — treat any such failure as a stop-and-investigate, not something to paper over.

- [ ] **Step 4: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift
git commit -m "$(cat <<'EOF'
fix(ios): pipeline TTS playback -- enqueue per chunk, wait once per turn

SessionCoordinator's .audio case now calls audio.enqueue(pcm) instead
of await audio.play(pcm) -- buffers queue back-to-back on the player
node instead of each one fully blocking the next. The one genuine
"wait for real playback completion" moves to turnEnd, preserving
readyToShowTheEnd's existing guarantee. Fixes the audible per-buffer
stutter that survived two rounds of TTS chunk-size tuning -- see
docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md for
the on-device evidence and design rationale.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Final verification (full suite + Xcode app build)

**Files:** none (verification only).

- [ ] **Step 1: Full Swift test suite**

Run: `cd ios/TinyTalkCore && swift test 2>&1 | grep -E "^Test Suite.*(passed|failed)|Executed|error:|BUILD FAILED" | tail -20`
Expected: all suites pass (server-side pytest suite is untouched by this plan and does not need re-running).

- [ ] **Step 2: iOS app compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`. Nothing in `ios/TinyTalkApp/TinyTalkApp/*.swift` needs editing for this plan (no App-target code references `enqueue`/`waitForPlaybackToFinish` directly), but this confirms the whole app still links against the changed `AudioPlaying` protocol and `RealAudioEngine`.

- [ ] **Step 3: Report on-device verification instructions**

This plan's changes cannot be fully verified without a real device (same as every other playback-timing claim in this codebase). Tell the user exactly this, following CLAUDE.md's "Testing changes on-device" convention:
- Worktree: `~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/away-from-home-demo-mode`
- iOS rebuild required (files under `ios/` changed) — fresh Build & Run from Xcode onto the device.
- What to do: repeat the away-from-home Task 16 checklist's step 4 (a full-turn TTS reply) and listen for the "tch tch tch" stutter. Check the debug log (Settings → long-press "UNDER THE HOOD") for the new `waitForPlaybackToFinish() took Xs at turnEnd` line — a small number (well under a full buffer's duration) each turn is the expected, healthy signal; a number close to or exceeding ~1s (a full buffer's worth) would suggest something is still serializing.
- Also re-check barge-in (step 5) and, once demo mode's own story flow reaches a natural end, that nothing hangs — both depend on invariants this change touches (`stopPlaybackImmediately()`'s new tracker reset; `readyToShowTheEnd`'s timing).
- Per the spec's own open question: a real-server (LAN/Kokoro) on-device smoke test is worth doing at some point too, since this change is designed to help that path as well, but isn't required before PR #22 (an away-from-home-mode PR) merges.
