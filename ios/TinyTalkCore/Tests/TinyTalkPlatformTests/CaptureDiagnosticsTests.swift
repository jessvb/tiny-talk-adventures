import XCTest
@testable import TinyTalkPlatform

/// Issue #39 diagnostics: these cover the pieces of RealAudioEngine's
/// capture-state logging that can run on the Mac (RealAudioEngine itself is
/// iOS-only). What they pin is the DISTINCTION the log has to make --
/// "no buffers ever reached the tap" vs. "buffers arrived but were dropped
/// in conversion" vs. "buffers arrived and were all digital silence" --
/// because that distinction is the whole point of the instrumentation.
final class CaptureDiagnosticsTests: XCTestCase {
    private func pcm16(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testCountsStartAtZero() {
        XCTAssertEqual(CaptureDiagnostics().counts, .init(buffersReceived: 0, chunksDelivered: 0, peakAmplitude: 0))
    }

    func testBuffersArrivedAndChunksDeliveredAreCountedSeparately() {
        // A tap buffer that fails conversion still counts as ARRIVED but
        // never as DELIVERED -- that gap is the "conversion is silently
        // dropping everything" signature.
        let diagnostics = CaptureDiagnostics()
        diagnostics.bufferArrived()
        diagnostics.bufferArrived()
        diagnostics.bufferArrived()
        diagnostics.chunkDelivered(peak: 10)
        XCTAssertEqual(diagnostics.counts.buffersReceived, 3)
        XCTAssertEqual(diagnostics.counts.chunksDelivered, 1)
    }

    func testPeakIsTheLargestSeenNotTheLatest() {
        let diagnostics = CaptureDiagnostics()
        diagnostics.chunkDelivered(peak: 500)
        diagnostics.chunkDelivered(peak: 20)
        XCTAssertEqual(diagnostics.counts.peakAmplitude, 500)
    }

    func testCountersAreSafeUnderConcurrentUpdates() {
        // The tap callback and the watchdog/stop paths touch this from
        // different threads.
        let diagnostics = CaptureDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1000 {
                diagnostics.bufferArrived()
                diagnostics.chunkDelivered(peak: 1)
            }
        }
        XCTAssertEqual(diagnostics.counts.buffersReceived, 8000)
        XCTAssertEqual(diagnostics.counts.chunksDelivered, 8000)
    }

    func testPeakAmplitudeOfDigitalSilenceIsZero() {
        XCTAssertEqual(CaptureDiagnostics.peakAmplitude(ofPCM16: pcm16([0, 0, 0, 0])), 0)
    }

    func testPeakAmplitudeUsesMagnitudeOfNegativeSamples() {
        XCTAssertEqual(CaptureDiagnostics.peakAmplitude(ofPCM16: pcm16([100, -300, 250])), 300)
    }

    func testPeakAmplitudeOfInt16MinDoesNotOverflow() {
        // abs(Int16.min) traps; the magnitude is 32768.
        XCTAssertEqual(CaptureDiagnostics.peakAmplitude(ofPCM16: pcm16([Int16.min, 1])), 32768)
    }

    func testPeakAmplitudeOfEmptyOrTrailingOddByteData() {
        XCTAssertEqual(CaptureDiagnostics.peakAmplitude(ofPCM16: Data()), 0)
        var data = pcm16([7])
        data.append(0xFF) // a stray half-sample must be ignored, not read past the end
        XCTAssertEqual(CaptureDiagnostics.peakAmplitude(ofPCM16: data), 7)
    }

    func testTapAndStopFlagsRoundTrip() {
        let diagnostics = CaptureDiagnostics()
        XCTAssertFalse(diagnostics.isTapInstalled)
        XCTAssertFalse(diagnostics.wasStopped)
        diagnostics.setTapInstalled(true)
        XCTAssertTrue(diagnostics.isTapInstalled)
        diagnostics.setTapInstalled(false)
        XCTAssertFalse(diagnostics.isTapInstalled)
        diagnostics.markStopped()
        XCTAssertTrue(diagnostics.wasStopped)
    }

    func testMarkStoppedCancelsTheWatchdogTask() async {
        let diagnostics = CaptureDiagnostics()
        let task = Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
        diagnostics.replaceWatchdog(with: task)
        diagnostics.markStopped()
        XCTAssertTrue(task.isCancelled)
    }

    func testReplacingTheWatchdogCancelsThePreviousOne() async {
        let diagnostics = CaptureDiagnostics()
        let first = Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
        let second = Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
        diagnostics.replaceWatchdog(with: first)
        diagnostics.replaceWatchdog(with: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        second.cancel()
    }
}

/// Records which watchdog callback fired, with the counts it was handed.
private final class WatchdogCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var zero: [CaptureDiagnostics.Counts] = []
    private var flowing: [CaptureDiagnostics.Counts] = []
    func recordZero(_ counts: CaptureDiagnostics.Counts) { lock.withLock { zero.append(counts) } }
    func recordFlowing(_ counts: CaptureDiagnostics.Counts) { lock.withLock { flowing.append(counts) } }
    var zeroCalls: [CaptureDiagnostics.Counts] { lock.withLock { zero } }
    var flowingCalls: [CaptureDiagnostics.Counts] { lock.withLock { flowing } }
}

final class CaptureWatchdogTests: XCTestCase {
    func testWarnsExactlyOnceWhenNoBufferEverArrives() async {
        let diagnostics = CaptureDiagnostics()
        let calls = WatchdogCalls()
        await CaptureWatchdog.run(
            after: 20_000_000, diagnostics: diagnostics,
            onZeroBuffers: calls.recordZero, onBuffersFlowing: calls.recordFlowing
        )
        XCTAssertEqual(calls.zeroCalls, [.init(buffersReceived: 0, chunksDelivered: 0, peakAmplitude: 0)])
        XCTAssertTrue(calls.flowingCalls.isEmpty)
    }

    func testReportsHealthyWithTheCountsWhenBuffersArrivedInTime() async {
        let diagnostics = CaptureDiagnostics()
        diagnostics.bufferArrived()
        diagnostics.chunkDelivered(peak: 42)
        let calls = WatchdogCalls()
        await CaptureWatchdog.run(
            after: 20_000_000, diagnostics: diagnostics,
            onZeroBuffers: calls.recordZero, onBuffersFlowing: calls.recordFlowing
        )
        XCTAssertTrue(calls.zeroCalls.isEmpty, "must not cry wolf when the tap is delivering")
        XCTAssertEqual(calls.flowingCalls, [.init(buffersReceived: 1, chunksDelivered: 1, peakAmplitude: 42)])
    }

    func testBuffersArrivingDuringTheWaitCountAsHealthy() async {
        // The check happens at the END of the delay, not the start.
        let diagnostics = CaptureDiagnostics()
        let calls = WatchdogCalls()
        let task = Task {
            await CaptureWatchdog.run(
                after: 200_000_000, diagnostics: diagnostics,
                onZeroBuffers: calls.recordZero, onBuffersFlowing: calls.recordFlowing
            )
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        diagnostics.bufferArrived()
        await task.value
        XCTAssertTrue(calls.zeroCalls.isEmpty)
        XCTAssertEqual(calls.flowingCalls.count, 1)
    }

    func testDoesNotReportAnythingBeforeTheDelayElapses() async {
        let diagnostics = CaptureDiagnostics()
        let calls = WatchdogCalls()
        let task = Task {
            await CaptureWatchdog.run(
                after: 5_000_000_000, diagnostics: diagnostics,
                onZeroBuffers: calls.recordZero, onBuffersFlowing: calls.recordFlowing
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(calls.zeroCalls.isEmpty)
        XCTAssertTrue(calls.flowingCalls.isEmpty)
        task.cancel()
        await task.value
    }

    func testCancellationSuppressesBothReports() async {
        // stopCapturing() cancels the watchdog -- a normal teardown inside
        // the window must not produce a false "no buffers" warning.
        let diagnostics = CaptureDiagnostics()
        let calls = WatchdogCalls()
        let task = Task {
            await CaptureWatchdog.run(
                after: 5_000_000_000, diagnostics: diagnostics,
                onZeroBuffers: calls.recordZero, onBuffersFlowing: calls.recordFlowing
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await task.value
        XCTAssertTrue(calls.zeroCalls.isEmpty)
        XCTAssertTrue(calls.flowingCalls.isEmpty)
    }
}

final class WeakInstanceRegistryTests: XCTestCase {
    private final class Dummy {}

    func testIdsAreSequentialAndStablePerInstance() {
        let registry = WeakInstanceRegistry<Dummy>()
        let a = Dummy()
        let b = Dummy()
        XCTAssertEqual(registry.id(for: a), 1)
        XCTAssertEqual(registry.id(for: b), 2)
        XCTAssertEqual(registry.id(for: a), 1, "asking again must not register a second entry")
        XCTAssertEqual(registry.liveCount, 2)
        withExtendedLifetime((a, b)) {}
    }

    func testALiveCountDropsWhenAnInstanceDeallocates() {
        // The point of tracking weakly: the count must reflect engines that
        // are genuinely still ALIVE (leaked/retained), not ones ever created.
        let registry = WeakInstanceRegistry<Dummy>()
        var old: Dummy? = Dummy()
        let current = Dummy()
        _ = registry.id(for: old!)
        _ = registry.id(for: current)
        XCTAssertEqual(registry.liveCount, 2)
        old = nil
        XCTAssertEqual(registry.liveCount, 1)
        XCTAssertEqual(registry.liveInstances().map(\.id), [2])
        withExtendedLifetime(current) {}
    }

    func testIdsAreNeverReusedAfterADeallocation() {
        let registry = WeakInstanceRegistry<Dummy>()
        var first: Dummy? = Dummy()
        XCTAssertEqual(registry.id(for: first!), 1)
        first = nil
        let second = Dummy()
        XCTAssertEqual(registry.id(for: second), 2, "log lines from a dead engine must stay attributable")
        withExtendedLifetime(second) {}
    }

    func testLiveInstancesAreListedOldestFirst() {
        let registry = WeakInstanceRegistry<Dummy>()
        let a = Dummy()
        let b = Dummy()
        _ = registry.id(for: b)
        _ = registry.id(for: a)
        let live = registry.liveInstances()
        XCTAssertEqual(live.map(\.id), [1, 2])
        XCTAssertTrue(live[0].instance === b)
        XCTAssertTrue(live[1].instance === a)
    }
}
