import XCTest
@testable import TinyTalkPlatform

/// Issues #39/#49: RealAudioEngine's capture self-healing. The engine glue is
/// iOS-only; what's pinned here is the decision logic -- when a dead tap
/// triggers a recovery attempt, that attempts are bounded, that giving up
/// is reported exactly once, and that buffers flowing again resets it all.
final class CaptureRecoveryBudgetTests: XCTestCase {
    func testBuffersFlowingIsHealthy() {
        var budget = CaptureRecoveryBudget(maxAttempts: 3)
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 18), .healthy)
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 20), .healthy)
    }

    func testZeroBuffersAttemptsRecoveryUpToTheLimitThenGivesUpOnce() {
        var budget = CaptureRecoveryBudget(maxAttempts: 3)
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 1))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 2))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 3))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .giveUp(attempts: 3))
        // Bounded: no further attempts, and no repeated escalation.
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .stillDead)
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .stillDead)
    }

    func testBuffersReturningAfterAnAttemptReportsRecoveredAndResets() {
        var budget = CaptureRecoveryBudget(maxAttempts: 3)
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 1))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 2))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 5), .recovered(afterAttempts: 2))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 5), .healthy)
        // A later, unrelated death gets a full budget again.
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 1))
    }

    func testBuffersReturningAfterGivingUpAlsoReportsRecovered() {
        var budget = CaptureRecoveryBudget(maxAttempts: 1)
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .attemptRecovery(attempt: 1))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 0), .giveUp(attempts: 1))
        XCTAssertEqual(budget.evaluate(buffersSinceLastCheck: 3), .recovered(afterAttempts: 1))
    }
}

final class CaptureHealthMonitorTests: XCTestCase {
    /// Lock-protected so the monitor Task and the test can share it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _decisions: [CaptureRecoveryBudget.Decision] = []
        private var _buffers = 0
        var decisions: [CaptureRecoveryBudget.Decision] { lock.withLock { _decisions } }
        var buffers: Int { lock.withLock { _buffers } }
        func record(_ decision: CaptureRecoveryBudget.Decision) { lock.withLock { _decisions.append(decision) } }
        func addBuffers(_ count: Int) { lock.withLock { _buffers += count } }
    }

    private let tick: UInt64 = 20_000_000  // 20ms

    private func waitUntil(_ condition: @escaping () -> Bool, timeoutSeconds: Double = 2) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testADeadTapGetsBoundedRecoveryAttemptsThenOneGiveUp() async {
        let recorder = Recorder()
        let tick = tick
        let task = Task {
            await CaptureHealthMonitor.run(
                intervalNanos: tick,
                maxAttempts: 2,
                currentBuffers: { recorder.buffers },
                onDecision: { recorder.record($0) }
            )
        }
        await waitUntil { recorder.decisions.count >= 5 }
        task.cancel()
        XCTAssertEqual(
            Array(recorder.decisions.prefix(5)),
            [.attemptRecovery(attempt: 1), .attemptRecovery(attempt: 2), .giveUp(attempts: 2), .stillDead, .stillDead]
        )
    }

    func testRecoveryThatBringsBuffersBackIsReportedAsRecovered() async {
        let recorder = Recorder()
        let tick = tick
        let task = Task {
            await CaptureHealthMonitor.run(
                intervalNanos: tick,
                maxAttempts: 3,
                currentBuffers: { recorder.buffers },
                onDecision: { decision in
                    recorder.record(decision)
                    // The "recovery" works: the tap delivers again.
                    if case .attemptRecovery = decision { recorder.addBuffers(10) }
                }
            )
        }
        await waitUntil { recorder.decisions.count >= 2 }
        task.cancel()
        XCTAssertEqual(Array(recorder.decisions.prefix(2)), [.attemptRecovery(attempt: 1), .recovered(afterAttempts: 1)])
    }

    func testBuffersPresentBeforeTheMonitorStartedDoNotCountAsFlowing() async {
        // Counts are cumulative per engine: a tap that delivered earlier and
        // then died must still read as dead.
        let recorder = Recorder()
        recorder.addBuffers(400)
        let tick = tick
        let task = Task {
            await CaptureHealthMonitor.run(
                intervalNanos: tick,
                maxAttempts: 3,
                currentBuffers: { recorder.buffers },
                onDecision: { recorder.record($0) }
            )
        }
        await waitUntil { recorder.decisions.count >= 1 }
        task.cancel()
        XCTAssertEqual(recorder.decisions.first, .attemptRecovery(attempt: 1))
    }

    func testCancellationStopsTheMonitorPromptly() async {
        let recorder = Recorder()
        let task = Task {
            await CaptureHealthMonitor.run(
                intervalNanos: 10_000_000_000,
                maxAttempts: 3,
                currentBuffers: { recorder.buffers },
                onDecision: { recorder.record($0) }
            )
        }
        task.cancel()
        await task.value
        XCTAssertTrue(recorder.decisions.isEmpty)
    }
}
