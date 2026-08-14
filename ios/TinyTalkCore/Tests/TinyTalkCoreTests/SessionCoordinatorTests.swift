import XCTest
@testable import TinyTalkCore

final class SessionCoordinatorTests: XCTestCase {
    func testHappyPathReachesIdleAfterTurnEnd() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(connection.sentMessages, [.speechStart, .speechEnd])
        XCTAssertEqual(audio.played, [Data([1, 2, 3])])

        runLoop.cancel()
    }

    func testMicAudioIsForwardedToServerWhileListening() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.captureAudio(Data([9, 9]))
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(connection.sentAudio, [Data([9, 9])])

        runLoop.cancel()
    }

    /// Mirrors the server's test_interrupt_during_speaking_stops_the_turn:
    /// the hardest case, an interrupt arriving mid-playback. Also asserts
    /// GENUINE cancellation of the in-flight play() call (not just that
    /// stopPlaybackImmediately() was called) -- see FakeAudio.playWasCancelled
    /// and the SessionCoordinator doc comment explaining why this matters.
    func testInterruptDuringSlowPlaybackGenuinelyCancelsInFlightPlay() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 50_000_000 // 50ms -- long enough to interrupt mid-flight
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.audio(Data([9, 9, 9])))
        try? await Task.sleep(nanoseconds: 10_000_000) // let play() start, well before its 50ms delay finishes

        vad.fire(.speechStart) // the barge-in

        try? await Task.sleep(nanoseconds: 80_000_000) // longer than playDelayNanos, to catch a late false-positive

        let state = await coordinator.state
        XCTAssertEqual(state, .listening)
        XCTAssertTrue(audio.stopped, "stopPlaybackImmediately must have been called")
        XCTAssertTrue(audio.played.isEmpty, "the in-flight chunk must NOT complete and record itself as played after interrupt")
        XCTAssertTrue(audio.playWasCancelled, "the in-flight play() call must have observed real task cancellation")

        runLoop.cancel()
    }

    /// A disconnect arriving while idle (no turn active, no turnTask) must
    /// be handled without crashing or corrupting state. Note this
    /// deliberately does NOT try to detect whether coordinator.start()
    /// itself returns -- it must NOT return just because the connection
    /// closed, since consumeVADEvents() is meant to keep running for the
    /// app's whole lifetime regardless (only an explicit external cancel,
    /// e.g. the user tapping Disconnect, should stop it). An earlier
    /// version of this test tried to race `await runLoop.value` against a
    /// timeout to prove "the loop exited" -- that hung indefinitely,
    /// because cancelling a wrapper task does not force-unblock a plain
    /// `await` on a separately-created, never-cancelled Task. Caught
    /// during planning by actually running this test, not by inspection.
    func testClosedEventWhileIdleDoesNotCrashOrCorruptState() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // Deliberately idle -- no speechStart/speechEnd, no turnTask exists.
        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        runLoop.cancel()
    }

    /// The more important case: a disconnect arriving MID-TURN must walk
    /// state back to .idle, not leave the coordinator stuck. This is the
    /// real bug caught during planning (see SessionState.swift's
    /// `.disconnected` event and its doc comment for the fix).
    func testClosedEventDuringActiveTurnWalksStateBackToIdle() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.audio(Data([1, 2, 3]))) // state is now .speaking

        try? await Task.sleep(nanoseconds: 10_000_000)
        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "a disconnect mid-turn must not leave the coordinator stuck")

        runLoop.cancel()
    }

    /// Regression coverage for the per-turn AsyncStream handoff: after an
    /// interrupt tears one down, a fresh turn must work normally, not be
    /// left in a broken state by the previous turn's cleanup.
    func testInterruptThenNewTurnCompletesNormally() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechStart) // interrupt before any reply
        try? await Task.sleep(nanoseconds: 5_000_000)

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.audio(Data([5])))
        connection.emit(.message(.turnEnd))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(audio.played, [Data([5])])

        runLoop.cancel()
    }

    func testInterruptWhileWaitingForReplyBeforeAnyAudioArrivesStillStopsCleanly() async {
        // A barge-in can happen before the reply's first audio chunk has
        // even arrived -- interrupting during .waitingForReply must work
        // too, not just during .speaking.
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        vad.fire(.speechStart) // barge-in before any audio chunk arrived
        try? await Task.sleep(nanoseconds: 10_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .listening)

        runLoop.cancel()
    }

    func testServerErrorEndsTheTurnImmediatelyWithoutWaitingForTurnEnd() async {
        // A lesson carried forward from a real server-side bug: treat
        // `error` as terminal, don't hang waiting for turn_end.
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.error("Ollama is not running")))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        runLoop.cancel()
    }

    func testInterruptRecordsLatency() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 50_000_000
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.audio(Data([1])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let history = await coordinator.latencyHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertGreaterThanOrEqual(history[0].vadFireToPlaybackStoppedMillis, 0)

        runLoop.cancel()
    }
}
