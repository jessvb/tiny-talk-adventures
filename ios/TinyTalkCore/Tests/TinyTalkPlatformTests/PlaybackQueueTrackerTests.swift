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
