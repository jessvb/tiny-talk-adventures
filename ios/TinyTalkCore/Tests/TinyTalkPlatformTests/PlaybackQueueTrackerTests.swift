import XCTest
@testable import TinyTalkPlatform

@MainActor
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
        let generation = tracker.bufferEnqueued()
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
        tracker.bufferFinished(generation: generation)
        await waitTask.value
        XCTAssertTrue(resolved)
    }

    func testWaitForIdleWaitsForAllOutstandingBuffersNotJustOne() async {
        let tracker = PlaybackQueueTracker()
        let generation = tracker.bufferEnqueued()
        _ = tracker.bufferEnqueued()
        var resolved = false
        let waitTask = Task {
            await tracker.waitForIdle()
            resolved = true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        tracker.bufferFinished(generation: generation)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(resolved, "should still be waiting -- only 1 of 2 outstanding buffers finished")
        tracker.bufferFinished(generation: generation)
        await waitTask.value
        XCTAssertTrue(resolved)
    }

    func testResetResumesAWaiterEvenThoughItsBufferNeverReportedFinished() async {
        let tracker = PlaybackQueueTracker()
        _ = tracker.bufferEnqueued()
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
        _ = tracker.bufferEnqueued()
        tracker.reset()
        // Must resolve immediately -- reset() already cleared the
        // buffer this would otherwise have waited for.
        await tracker.waitForIdle()
    }

    func testBufferFinishedCalledMoreTimesThanEnqueuedNeverGoesNegative() {
        let tracker = PlaybackQueueTracker()
        let generation = tracker.bufferEnqueued()
        tracker.bufferFinished(generation: generation)
        // A second, unmatched bufferFinished() -- mirrors the real
        // per-buffer completion-vs-timeout race where both could
        // theoretically fire if a future bug in the gate ever regressed.
        // Must not crash or underflow; waitForIdle() must still resolve
        // immediately afterward.
        tracker.bufferFinished(generation: generation)
    }

    func testResetPreventsAStaleCompletionFromAffectingALaterGeneration() async {
        let tracker = PlaybackQueueTracker()
        let staleGeneration = tracker.bufferEnqueued() // turn N's buffer
        tracker.reset() // barge-in -- turn N discarded, generation advances

        // Turn N+1 starts immediately and enqueues its own buffer.
        _ = tracker.bufferEnqueued()

        var resolved = false
        let waitTask = Task {
            await tracker.waitForIdle()
            resolved = true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(resolved, "turn N+1's buffer hasn't finished yet")

        // Turn N's orphaned 3-second timeout finally fires -- must be a
        // no-op, not a decrement of turn N+1's count.
        tracker.bufferFinished(generation: staleGeneration)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(resolved, "a stale completion from the reset-away turn must not resolve turn N+1's wait")

        waitTask.cancel()
    }
}
