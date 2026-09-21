import XCTest
@testable import TinyTalkPlatform

/// A hand-cranked clock for PlaybackQueueTracker(clock:): the hang-guard
/// arithmetic is all about WHEN buffers were scheduled relative to each
/// other, so these tests set the time explicitly instead of sleeping.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0

    func now() -> TimeInterval { lock.withLock { current } }
    func set(_ time: TimeInterval) { lock.withLock { current = time } }
}

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
        let generation = tracker.bufferEnqueued(durationSeconds: 1).generation
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
        let generation = tracker.bufferEnqueued(durationSeconds: 1).generation
        _ = tracker.bufferEnqueued(durationSeconds: 1)
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
        _ = tracker.bufferEnqueued(durationSeconds: 1)
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
        _ = tracker.bufferEnqueued(durationSeconds: 1)
        tracker.reset()
        // Must resolve immediately -- reset() already cleared the
        // buffer this would otherwise have waited for.
        await tracker.waitForIdle()
    }

    func testBufferFinishedCalledMoreTimesThanEnqueuedNeverGoesNegative() {
        let tracker = PlaybackQueueTracker()
        let generation = tracker.bufferEnqueued(durationSeconds: 1).generation
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
        let staleGeneration = tracker.bufferEnqueued(durationSeconds: 1).generation // turn N's buffer
        tracker.reset() // barge-in -- turn N discarded, generation advances

        // Turn N+1 starts immediately and enqueues its own buffer.
        _ = tracker.bufferEnqueued(durationSeconds: 1)

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

    // MARK: - Hang-guard deadlines (issue #29)
    //
    // The hang-guard exists for the engine-stopped-mid-render case: a
    // buffer whose completion callback never fires is given up on so the
    // wait can't hang forever. Before the fix each buffer's guard ran
    // max(3s, its OWN duration + 2s) from the moment it was SCHEDULED --
    // but a buffer queued behind others doesn't start playing until they
    // finish, so with a whole reply scheduled within ~2s every buffer
    // behind the first was given up on while still waiting its turn, and
    // waitForPlaybackToFinish() returned early (The End appearing, and
    // the header dropping "Elsie is talking", mid-reply).

    /// Runs a queue to the end the way RealAudioEngine.enqueue() resolves
    /// it: each buffer is finished by whichever comes first of its real
    /// completion (`completesAt`, nil = the callback never arrives) and its
    /// own hang-guard, in chronological order. Returns the clock time at
    /// which waitForIdle() resolved.
    private func timeWaitResolves(
        tracker: PlaybackQueueTracker,
        clock: FakeClock,
        tickets: [(generation: Int, hangGuardSeconds: TimeInterval)],
        completesAt: [TimeInterval?]
    ) async -> TimeInterval? {
        var resolvedAt: TimeInterval?
        let waitTask = Task {
            await tracker.waitForIdle()
            resolvedAt = clock.now()
        }
        try? await Task.sleep(nanoseconds: 20_000_000) // let it register as the waiter
        let resolutions = tickets.indices
            .map { (index: $0, at: min(completesAt[$0] ?? .infinity, tickets[$0].hangGuardSeconds)) }
            .sorted { $0.at < $1.at }
        for resolution in resolutions {
            clock.set(resolution.at)
            tracker.bufferFinished(generation: tickets[resolution.index].generation)
            try? await Task.sleep(nanoseconds: 20_000_000) // let a resumed waiter run
        }
        waitTask.cancel()
        return resolvedAt
    }

    func testHangGuardOfAQueuedBufferIsMeasuredFromWhenItsTurnEndsNotFromWhenItWasScheduled() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        // Three 4s sentences arrive together at t=0 (the server synthesizes
        // faster than real time): they play at 0-4, 4-8 and 8-12s.
        let first = tracker.bufferEnqueued(durationSeconds: 4)
        let second = tracker.bufferEnqueued(durationSeconds: 4)
        let third = tracker.bufferEnqueued(durationSeconds: 4)
        // Expected end of each buffer, plus the 2s grace.
        XCTAssertEqual(first.hangGuardSeconds, 6)
        XCTAssertEqual(second.hangGuardSeconds, 10)
        XCTAssertEqual(third.hangGuardSeconds, 14)
    }

    func testWaitStaysSuspendedUntilTheQueuesRealEndWhenCompletionsArriveOnTime() async {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        let tickets = [
            tracker.bufferEnqueued(durationSeconds: 4),
            tracker.bufferEnqueued(durationSeconds: 4),
            tracker.bufferEnqueued(durationSeconds: 4),
        ]
        // Real completions land at 4, 8 and 12s. No hang-guard may win the
        // race for any of them, or the wait would resolve before 12s.
        let resolvedAt = await timeWaitResolves(
            tracker: tracker, clock: clock, tickets: tickets, completesAt: [4, 8, 12]
        )
        XCTAssertEqual(resolvedAt, 12, "the wait must last until the last queued buffer really finished")
    }

    func testHangGuardStillResolvesTheWaitWhenNoCompletionEverArrives() async {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        let tickets = [
            tracker.bufferEnqueued(durationSeconds: 4),
            tracker.bufferEnqueued(durationSeconds: 4),
            tracker.bufferEnqueued(durationSeconds: 4),
        ]
        // The engine was stopped mid-render: no completion ever fires. The
        // wait must still end (never hang), at the last buffer's expected
        // end (12s) plus the 2s grace.
        let resolvedAt = await timeWaitResolves(
            tracker: tracker, clock: clock, tickets: tickets, completesAt: [nil, nil, nil]
        )
        XCTAssertEqual(resolvedAt, 14)
    }

    func testABufferScheduledWhileEarlierOnesStillPlayStartsWhenTheyEnd() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        _ = tracker.bufferEnqueued(durationSeconds: 4) // plays 0-4s
        clock.set(3) // the server is a little slower: the next sentence lands mid-playback
        let second = tracker.bufferEnqueued(durationSeconds: 4) // plays 4-8s, i.e. 5s from now
        XCTAssertEqual(second.hangGuardSeconds, 7)
    }

    func testABufferScheduledPastTheExpectedEndOfAnUnreportedOneStartsNow() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        _ = tracker.bufferEnqueued(durationSeconds: 4) // expected to end at 4s; its completion is slow to be reported
        clock.set(10)
        let second = tracker.bufferEnqueued(durationSeconds: 2)
        XCTAssertEqual(second.hangGuardSeconds, 4, "the first buffer's expected end is long past, so this one starts now")
    }

    func testABufferScheduledAfterTheQueueDrainedIsNotDelayedByTheOldQueue() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        let first = tracker.bufferEnqueued(durationSeconds: 4)
        clock.set(4)
        tracker.bufferFinished(generation: first.generation) // queue idle
        clock.set(100) // a long silence before the next sentence
        let second = tracker.bufferEnqueued(durationSeconds: 2)
        XCTAssertEqual(second.hangGuardSeconds, 4, "starts at once: 2s of playback + 2s grace")
    }

    func testTheQueueClockRestartsWhenTheQueueGoesIdleEvenIfItFinishedEarly() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        let first = tracker.bufferEnqueued(durationSeconds: 4) // expected to end at 4s...
        clock.set(1)
        tracker.bufferFinished(generation: first.generation) // ...but really finished at 1s: idle
        let second = tracker.bufferEnqueued(durationSeconds: 2)
        // Nothing is playing, so this starts now (1s) -- not at the stale
        // 4s the first buffer had been expected to run to.
        XCTAssertEqual(second.hangGuardSeconds, 4)
    }

    func testResetStartsAFreshQueueClockForTheNextReply() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        _ = tracker.bufferEnqueued(durationSeconds: 10) // a long reply, cut off by a barge-in
        clock.set(1)
        tracker.reset()
        let next = tracker.bufferEnqueued(durationSeconds: 2)
        XCTAssertEqual(next.hangGuardSeconds, 4, "the discarded reply's 10s must not delay the next one")
    }

    func testAStaleCompletionFromBeforeAResetDoesNotDisturbTheNextRepliesQueueClock() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        let stale = tracker.bufferEnqueued(durationSeconds: 10)
        clock.set(1)
        tracker.reset() // barge-in
        _ = tracker.bufferEnqueued(durationSeconds: 5) // the next reply: plays 1-6s
        // The discarded reply's orphaned hang-guard fires late. It must
        // be a no-op -- in particular it must not "drain" the new reply's
        // queue and restart its clock.
        tracker.bufferFinished(generation: stale.generation)
        let third = tracker.bufferEnqueued(durationSeconds: 3) // plays 6-9s, i.e. 8s from now
        XCTAssertEqual(third.hangGuardSeconds, 10)
    }

    func testALoneBufferKeepsTheOriginalThreeSecondFloorAndTwoSecondGrace() {
        let clock = FakeClock()
        let tracker = PlaybackQueueTracker(clock: clock.now)
        XCTAssertEqual(tracker.bufferEnqueued(durationSeconds: 0.5).hangGuardSeconds, 3)
        tracker.reset()
        XCTAssertEqual(tracker.bufferEnqueued(durationSeconds: 10).hangGuardSeconds, 12)
    }
}
