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

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(connection.sentMessages, [.speechStart(turnId: 1), .speechEnd])
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

    /// Regression test for a code-review finding: the VAD must keep
    /// monitoring the mic even while the agent is .speaking, since that is
    /// the only way a barge-in can ever be detected in the first place --
    /// the design spec is explicit that "VAD keeps monitoring the mic
    /// throughout" playback. Every other test in this file calls
    /// `vad.fire()` directly, which bypasses `captureAudio()` entirely and
    /// would never have caught a regression here -- this test drives
    /// `captureAudio()` itself, gated only on network-send behavior, not
    /// VAD feeding.
    func testCaptureAudioFeedsVADEvenWhileSpeaking() async {
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
        connection.emit(.audio(Data([1, 2, 3]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateWhileSpeaking = await coordinator.state
        XCTAssertEqual(stateWhileSpeaking, .speaking)

        await coordinator.captureAudio(Data([7, 7]))
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(vad.fed, [Data([7, 7])], "VAD must keep receiving mic audio while .speaking, or a barge-in can never be detected")
        XCTAssertTrue(connection.sentAudio.isEmpty, "mic audio must NOT be uploaded to the server while not .listening")

        runLoop.cancel()
    }

    /// Regression test for a code-review finding: AsyncStream.finish() only
    /// stops NEW items from being enqueued -- it does not discard items
    /// already buffered. TTS can stream several chunks (and even turnEnd)
    /// faster than play() drains them, so a naive cancelled runTurn kept
    /// delivering those stale buffered events: audio played after the
    /// interrupt, and a stale turnEnd from the OLD turn got applied to the
    /// live state machine after a NEW turn had already started, corrupting
    /// it and orphaning the new turn's continuation. Reproduced empirically
    /// during review (5/5 runs played stale audio; 2/3 runs corrupted the
    /// next turn) before the `if Task.isCancelled { return }` guard was
    /// added to the top of runTurn's loop.
    func testInterruptDiscardsAlreadyBufferedTurnEventsAndDoesNotCorruptNextTurn() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 50_000_000 // chunk 1 will be genuinely in-flight when the interrupt fires
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Emit several chunks and a turnEnd back-to-back, with nothing
        // draining them yet (runTurn is about to block inside chunk 1's
        // 50ms play() call) -- these all land in the per-turn stream's
        // buffer before runTurn ever looks at them. consumeServerEvents()
        // still forwards all of these (turn 1 hasn't been superseded yet
        // at the moment it reads them, well before the barge-in below).
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.audio(Data([2])))
        connection.emit(.audio(Data([3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000) // let play() start on chunk 1, well before its 50ms delay elapses

        // From here on, drop the delay to 0. This isolates the bug this
        // test targets: without it, chunks 2 and 3 would ALSO go through
        // Task.sleep and get "saved" by its own unrelated
        // cancellation-awareness (same mechanism the slow-playback test
        // above already covers), masking whether runTurn itself still
        // hands buffered-but-not-yet-started events to play() at all. With
        // delay 0, any buffered chunk that reaches play() records itself
        // instantly -- exactly the real-world case too, since TTS chunks
        // normally play back-to-back with no gap.
        audio.playDelayNanos = 0

        vad.fire(.speechStart) // the barge-in, while chunks 2, 3, and turnEnd are still buffered, unprocessed
        // Immediately (no settling delay) start a brand-new turn, so its
        // setup races the stale, cancelled runTurn's continued draining of
        // chunks 2/3/turnEnd -- this is the exact race the reviewer
        // reproduced probabilistically (2/3 runs corrupted). Not waiting
        // here, instead of waiting first and starting the new turn only
        // once the stale task has surely finished, is what actually opens
        // the corrupting window: the new turn's turnContinuation must be
        // assigned WHILE the stale task could still process its buffered
        // turnEnd, or the bug never has a chance to manifest.
        vad.fire(.speechEnd)

        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(audio.played.isEmpty, "no buffered chunk from the OLD turn may reach play() after the interrupt discarded it")
        XCTAssertTrue(audio.playWasCancelled, "chunk 1's in-flight play() must have observed genuine cancellation")

        // Drive the new turn (turn 2) to completion and confirm it was not
        // corrupted: pre-fix, the stale turn's buffered turnEnd could get
        // applied to the live machine and unconditionally nil out the NEW
        // turn's turnContinuation, silently orphaning it from all further
        // server events (so the assertions below would see it stuck,
        // never reaching .idle, and never playing chunk 9).
        connection.emit(.message(.responseText("hi again", turnId: 2)))
        connection.emit(.audio(Data([9])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 30_000_000)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle, "a fresh turn after the interrupt must complete normally, not be corrupted by the stale turn's buffered events")
        XCTAssertEqual(audio.played, [Data([9])], "the new turn's chunk must actually be played -- proves its turnContinuation was not silently orphaned by stale cleanup")

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
        connection.emit(.message(.responseText("hi", turnId: 1)))
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
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3]))) // state is now .speaking

        try? await Task.sleep(nanoseconds: 10_000_000)
        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "a disconnect mid-turn must not leave the coordinator stuck")

        runLoop.cancel()
    }

    /// Root-cause regression test for the "press Connect, no ditty or
    /// reply, straight to idle" bug: handleAppBackgrounded() has always
    /// proactively captured activeTurnId before an intentional disconnect,
    /// but a disconnect this coordinator discovers on its own (a network
    /// drop, a server hiccup -- exactly what a plain "press Connect after
    /// it dropped" scenario looks like) had no equivalent capture. By the
    /// time a caller notices via polling that isClosed flipped true,
    /// machine.state has already been walked back to .idle by this same
    /// .closed handling -- so the resumable turn_id has to be captured
    /// HERE, at the moment of disconnect, or the information is lost for
    /// good and AppModel has nothing correct to pass to connect(
    /// resumingTurnId:) on the next attempt.
    func testClosedEventDuringActiveTurnCapturesTheResumableTurnId() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1))) // state is now .speaking

        try? await Task.sleep(nanoseconds: 10_000_000)
        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let resumableTurnId = await coordinator.resumableTurnIdAtDisconnect
        XCTAssertEqual(resumableTurnId, 1, "disconnecting while .speaking must capture the in-flight turn_id to resume")

        runLoop.cancel()
    }

    /// The counterpart case: a disconnect while genuinely idle (nothing in
    /// flight, nothing to resume) must NOT report a resumable turn_id --
    /// otherwise the next connect() would incorrectly try to resume a turn
    /// that was never actually left hanging.
    func testClosedEventWhileIdleDoesNotCaptureAResumableTurnId() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let resumableTurnId = await coordinator.resumableTurnIdAtDisconnect
        XCTAssertNil(resumableTurnId, "nothing was in flight -- there is nothing to resume")

        runLoop.cancel()
    }

    /// A disconnect while .listening (mid-utterance, before speech_end)
    /// is also not resumable -- matches handleAppBackgrounded()'s existing
    /// criteria (only .waitingForReply/.speaking count) and state.py's own
    /// ABANDON semantics: there is no reply in flight to pick back up,
    /// just a partial utterance the server already discards on its side.
    func testClosedEventWhileListeningDoesNotCaptureAResumableTurnId() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let resumableTurnId = await coordinator.resumableTurnIdAtDisconnect
        XCTAssertNil(resumableTurnId, "mid-utterance, not mid-reply -- nothing to resume")

        runLoop.cancel()
    }

    /// Root-cause regression test for a real on-device bug: the app got
    /// permanently stuck showing "waitingForReply" after taking photos
    /// mid-turn, confirmed via a real server log that the server's own
    /// session state was still LISTENING at the moment of disconnect --
    /// i.e. it never received speech_end at all. handleSpeechEnd() flips
    /// machine.state to .waitingForReply SYNCHRONOUSLY, before sending
    /// speech_end; the old code wrapped that send in `try?`, silently
    /// discarding a failure and leaving the coordinator waiting forever for
    /// a reply the server never knew to generate. Nothing would notice
    /// until the WebSocket's separate receive loop eventually failed on its
    /// own -- confirmed on real hardware to take tens of seconds.
    func testSpeechEndSendFailureWalksStateBackToIdleInsteadOfStickingInWaitingForReply() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.sendMessageError = FakeSendError()
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "a failed speech_end send must not leave the coordinator stuck in .waitingForReply")
        let isClosed = await coordinator.isClosed
        XCTAssertTrue(isClosed, "a failed send is as trustworthy a disconnect signal as the receive side observing .closed")

        runLoop.cancel()
    }

    /// Same failure mode, one step earlier: a failed speech_start send must
    /// not leave the coordinator stuck in .listening waiting for a turn
    /// that was never actually announced to the server.
    func testSpeechStartSendFailureWalksStateBackToIdle() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        connection.sendMessageError = FakeSendError()
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "a failed speech_start send must not leave the coordinator stuck in .listening")
        let isClosed = await coordinator.isClosed
        XCTAssertTrue(isClosed)

        runLoop.cancel()
    }

    /// Same failure mode again, on the barge-in path: a failed interrupt
    /// send must not leave the coordinator stuck believing a barge-in is
    /// still in progress.
    func testInterruptSendFailureWalksStateBackToIdle() async {
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
        connection.emit(.audio(Data([1, 2, 3]))) // state is now .speaking
        try? await Task.sleep(nanoseconds: 10_000_000)

        connection.sendMessageError = FakeSendError()
        vad.fire(.speechStart) // barge-in: .speaking -> interrupt()
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "a failed interrupt send must not leave the coordinator stuck mid-barge-in")
        let isClosed = await coordinator.isClosed
        XCTAssertTrue(isClosed)

        runLoop.cancel()
    }

    /// Regression coverage for the per-turn AsyncStream handoff: after an
    /// interrupt tears one down, a fresh turn must work normally, not be
    /// left in a broken state by the previous turn's cleanup.
    /// newStory() is the debug/testing "reset" affordance: abandon
    /// whatever's happening (mirrors interrupt()'s in-flight-turn
    /// teardown) and land in .idle rather than .listening, since nothing
    /// new is starting.
    func testNewStoryDuringActiveTurnCancelsItAndReturnsToIdle() async {
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
        connection.emit(.audio(Data([1, 2, 3]))) // state is now .speaking

        await coordinator.newStory()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(connection.sentMessages.last, .newStory)
        let reply = await coordinator.lastReply
        XCTAssertEqual(reply, "", "abandoning the story should clear the last-shown reply")

        runLoop.cancel()
    }

    /// A subsequent turn after newStory() must work completely normally --
    /// same regression concern as testInterruptThenNewTurnCompletesNormally,
    /// applied to the new reset path instead of interrupt.
    func testNewStoryThenNewTurnCompletesNormally() async {
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
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        await coordinator.newStory()

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("a new tale", turnId: 2)))
        connection.emit(.audio(Data([9])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        let reply = await coordinator.lastReply
        XCTAssertEqual(reply, "a new tale")

        runLoop.cancel()
    }

    func testInterruptThenNewTurnCompletesNormally() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart) // turn 1
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechStart) // interrupt before any reply -- turn 2
        try? await Task.sleep(nanoseconds: 5_000_000)

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 2)))
        connection.emit(.audio(Data([5])))
        connection.emit(.message(.turnEnd(turnId: 2)))
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

        connection.emit(.message(.error("Ollama is not running", turnId: 1)))
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
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let history = await coordinator.latencyHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertGreaterThanOrEqual(history[0].vadFireToPlaybackStoppedMillis, 0)
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
        XCTAssertLessThan(history[0].vadFireToPlaybackStoppedMillis, 20.0, "playback-stopped latency should reflect only the (synchronous) stop, not any subsequent network round-trip")

        runLoop.cancel()
    }

    /// Regression test for a whole-branch review finding: captureAudio()
    /// only sends audio to the server once .listening, which only becomes
    /// true AFTER the VAD has already decided speech started -- so the
    /// very audio that caused the VAD to fire never reached the server,
    /// clipping the start of every utterance. The pre-roll buffer must
    /// flush everything captured before speechStart, in order, right after
    /// the speech_start control frame.
    func testPreRollAudioIsFlushedOnSpeechStart() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // Captured while idle -- this is the audio the VAD used to decide
        // to fire speechStart, arriving to captureAudio() BEFORE the state
        // machine transitions to .listening.
        await coordinator.captureAudio(Data([1]))
        await coordinator.captureAudio(Data([2]))
        await coordinator.captureAudio(Data([3]))
        XCTAssertTrue(connection.sentAudio.isEmpty, "pre-roll audio must not be sent until speech_start is announced")

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(connection.sentMessages, [.speechStart(turnId: 1)])
        XCTAssertEqual(connection.sentAudio, [Data([1]), Data([2]), Data([3])], "buffered pre-roll audio must be flushed, in capture order, right after speech_start")

        runLoop.cancel()
    }

    /// Same pre-roll requirement, but for the barge-in path: audio captured
    /// while .speaking (buffered because it isn't .listening yet) must be
    /// flushed right after the `interrupt` control frame.
    func testPreRollAudioIsFlushedOnBargeIn() async {
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
        connection.emit(.audio(Data([9, 9, 9]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Captured while .speaking, i.e. the audio that triggers the
        // barge-in -- must not be dropped.
        await coordinator.captureAudio(Data([7]))
        await coordinator.captureAudio(Data([8]))

        vad.fire(.speechStart) // the barge-in
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(connection.sentMessages.last, .interrupt(turnId: 2))
        XCTAssertEqual(Array(connection.sentAudio.suffix(2)), [Data([7]), Data([8])], "pre-roll captured just before the barge-in must be flushed right after the interrupt control frame")

        runLoop.cancel()
    }

    /// Regression test: the pre-roll ring buffer must stay capped (~200ms
    /// of 24kHz mono Int16 audio) rather than growing unbounded, evicting
    /// the OLDEST chunks first once the cap is exceeded.
    func testPreRollBufferEvictsOldestChunksOnceCapExceeded() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // Cap is 24_000 * 2 bytes/sec * 0.5s = 24000 bytes. Six 5000-byte
        // chunks (30000 bytes total) exceed that, so the oldest ones must
        // be evicted, leaving only the most recent chunks whose combined
        // size fits under the cap (chunks 3-6: 20000 bytes).
        let chunk1 = Data(repeating: 1, count: 5000)
        let chunk2 = Data(repeating: 2, count: 5000)
        let chunk3 = Data(repeating: 3, count: 5000)
        let chunk4 = Data(repeating: 4, count: 5000)
        let chunk5 = Data(repeating: 5, count: 5000)
        let chunk6 = Data(repeating: 6, count: 5000)
        await coordinator.captureAudio(chunk1)
        await coordinator.captureAudio(chunk2)
        await coordinator.captureAudio(chunk3)
        await coordinator.captureAudio(chunk4)
        await coordinator.captureAudio(chunk5)
        await coordinator.captureAudio(chunk6)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(connection.sentAudio, [chunk3, chunk4, chunk5, chunk6], "the oldest chunks (1 and 2) must have been evicted once the ~500ms byte cap was exceeded")

        runLoop.cancel()
    }

    /// Regression test for a whole-branch review finding: a dropped/failed
    /// connection was invisible to a UI polling this coordinator's state --
    /// `.closed` walked state back to .idle, which looks identical to a
    /// normal idle state. `isClosed` is the dedicated signal a poll loop
    /// needs to notice the connection actually died.
    func testClosedEventSetsIsClosedFlag() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        let isClosedBefore = await coordinator.isClosed
        XCTAssertFalse(isClosedBefore)

        connection.emit(.closed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let isClosedAfter = await coordinator.isClosed
        XCTAssertTrue(isClosedAfter, "isClosed must flip to true once the connection closes, so a polling UI can notice and tear itself down")

        runLoop.cancel()
    }

    /// Regression test for a re-review finding on the pre-roll fix itself:
    /// actor reentrancy meant the ordering guarantee didn't actually hold.
    /// `machine.handle(.speechStart)` flips state to `.listening`
    /// SYNCHRONOUSLY, before `try? await connection.send(.speechStart)` even
    /// starts its network round trip -- so a captureAudio() call delivered
    /// by a separate task (the mic pipeline) while that send is still in
    /// flight used to see `.listening` already, take the direct-send
    /// branch, and race its own independently-awaited send against both the
    /// control frame and the pre-roll flush that follows it.
    ///
    /// The previous 5 pre-roll tests never caught this because
    /// FakeConnection.send() resolved instantly, so there was never a real
    /// suspension window for a concurrent captureAudio() call to land in.
    /// This test uses FakeConnection's new sendMessageDelayNanos to force
    /// the control frame's send to genuinely suspend, then drives
    /// captureAudio() from the test itself (a separate, concurrently
    /// scheduled call into the actor, exactly like the real mic pipeline)
    /// while that send is provably still in flight, and asserts the
    /// resulting wire order via sentLog -- which, unlike sentMessages/
    /// sentAudio separately, is the only place the RELATIVE order of
    /// control frames and audio is observable at all.
    func testSpeechStartOrderingSurvivesReentrantCaptureAudioDuringFlush() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // Ordinary pre-roll, captured while idle, before the VAD ever fires.
        await coordinator.captureAudio(Data([1]))
        await coordinator.captureAudio(Data([2]))

        // Make the control frame's send genuinely suspend for 40ms, and
        // each audio send take 15ms -- both real `await` suspension points
        // a concurrent task can be scheduled into, not the previous fakes'
        // instantly-resolving ones.
        connection.sendMessageDelayNanos = 40_000_000
        connection.sendAudioDelayNanos = 15_000_000

        vad.fire(.speechStart)
        // handleSpeechStart() has by now definitely run its synchronous
        // prefix (machine.handle -> .listening, isFlushing = true) and is
        // parked inside the 40ms-delayed connection.send(.speechStart) --
        // well before that delay elapses.
        try? await Task.sleep(nanoseconds: 10_000_000)

        // The race: captureAudio() called from a separate task (this test's
        // own), concurrently with the still-in-flight control-frame send.
        // Pre-fix, machine.state already reads .listening here, so this
        // would take the direct-send branch and reach the wire out of
        // order. Post-fix, isFlushing still reads true, so this must
        // buffer instead.
        await coordinator.captureAudio(Data([3]))

        // Long enough for: the remaining ~30ms of the control-frame send,
        // plus three 15ms-delayed audio sends (chunks 1, 2, 3) draining
        // through flushPreRoll().
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            connection.sentLog,
            [.message(.speechStart(turnId: 1)), .audio(Data([1])), .audio(Data([2])), .audio(Data([3]))],
            "control frame must go out first, then pre-roll in capture order, then the chunk captured during the flush window -- nothing reordered ahead of the control frame or the earlier pre-roll"
        )

        runLoop.cancel()
    }

    /// Same race, but for the barge-in path (interrupt() has its own
    /// control-frame-send-then-flush sequence, with the identical
    /// reentrancy window).
    func testInterruptOrderingSurvivesReentrantCaptureAudioDuringFlush() async {
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
        connection.emit(.audio(Data([9, 9, 9]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Pre-roll captured while .speaking, just before the barge-in.
        await coordinator.captureAudio(Data([7]))
        await coordinator.captureAudio(Data([8]))

        connection.sendMessageDelayNanos = 40_000_000
        connection.sendAudioDelayNanos = 15_000_000

        vad.fire(.speechStart) // the barge-in -> interrupt(), turn 2
        try? await Task.sleep(nanoseconds: 10_000_000) // interrupt()'s control-frame send is now in flight

        // The race: a concurrent captureAudio() call while `interrupt`'s
        // control frame is still being sent.
        await coordinator.captureAudio(Data([10]))

        try? await Task.sleep(nanoseconds: 150_000_000)

        let log = connection.sentLog
        guard let interruptIndex = log.firstIndex(of: .message(.interrupt(turnId: 2))) else {
            XCTFail("interrupt control frame was never sent")
            runLoop.cancel()
            return
        }
        XCTAssertEqual(
            Array(log[interruptIndex...]),
            [.message(.interrupt(turnId: 2)), .audio(Data([7])), .audio(Data([8])), .audio(Data([10]))],
            "interrupt control frame must go out first, then pre-roll in capture order, then the chunk captured during the flush window"
        )

        runLoop.cancel()
    }

    /// Regression test for a whole-branch review finding: `error` frames
    /// were only surfaced by runTurn()'s loop, which only exists between
    /// speech_end and turn end. An error arriving OUTSIDE that window
    /// (e.g. while .listening, before speech_end -- reachable if the
    /// server's STT feed fails) used to hit `turnContinuation?.yield(event)`
    /// with a nil continuation and vanish silently.
    func testOutOfTurnErrorStillSetsLastErrorMessage() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // .listening, but before speech_end -- no turn is active yet, so
        // turnContinuation is nil. currentTurnId is already 1, though (set
        // synchronously by handleSpeechStart before its control-frame
        // send), which is what lets this error's turn_id match.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateBeforeError = await coordinator.state
        XCTAssertEqual(stateBeforeError, .listening)

        connection.emit(.message(.error("stt feed failed", turnId: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let errorMessage = await coordinator.lastErrorMessage
        XCTAssertEqual(errorMessage, "stt feed failed", "an error frame arriving outside an active turn must still be surfaced, not silently dropped")

        runLoop.cancel()
    }

    /// The actual point of turn_id: a reply that arrives for a turn the
    /// client has already abandoned must be discarded, not misattributed to
    /// whatever turn happens to be active when it arrives. Confirmed on
    /// real hardware to otherwise either misattribute the reply to the
    /// wrong turn or drop it entirely -- see Protocol.swift's doc comment.
    func testStaleReplyForAnAbandonedTurnIsDiscardedNotMisattributed() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart) // turn 1
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Before turn 1's server reply ever arrives, the child barges in
        // and starts a whole new utterance -- turn 2.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Turn 1's reply finally shows up late, tagged with the OLD turn_id.
        // Simulates the server having fallen behind (a multi-second STT
        // call) and only now finishing what it started for turn 1.
        connection.emit(.message(.transcriptFinal("turn one's words", turnId: 1)))
        connection.emit(.message(.responseText("turn one's reply", turnId: 1)))
        connection.emit(.audio(Data([1, 1, 1])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(audio.played.isEmpty, "turn 1's stale audio must not be played once turn 2 is active")
        let lastReplyAfterStaleReply = await coordinator.lastReply
        XCTAssertEqual(lastReplyAfterStaleReply, "", "turn 1's stale reply text must not be surfaced as if it were current")
        let stateAfterStaleReply = await coordinator.state
        XCTAssertEqual(stateAfterStaleReply, .waitingForReply, "turn 2 must still be genuinely waiting -- the stale turnEnd must not have silently ended it")

        // Turn 2's real reply, correctly tagged, must still work normally.
        connection.emit(.message(.transcriptFinal("turn two's words", turnId: 2)))
        connection.emit(.message(.responseText("turn two's reply", turnId: 2)))
        connection.emit(.audio(Data([2, 2, 2])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.played, [Data([2, 2, 2])], "turn 2's real reply must play normally, unaffected by the discarded stale one")
        let lastReplyAfterRealReply = await coordinator.lastReply
        XCTAssertEqual(lastReplyAfterRealReply, "turn two's reply")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        runLoop.cancel()
    }

    /// A UI building a running turn history (e.g. AppModel.turns) needs to
    /// know which turn lastTranscript/lastReply actually belong to -- NOT
    /// just activeTurnId (the CURRENT turn), which can already have
    /// advanced before that new turn's own text arrives. Confirmed on real
    /// hardware to duplicate the previous turn's bubble and then silently
    /// skip the real new one when a UI keyed its dedup check off
    /// activeTurnId instead -- see AppModel.swift's turns-history doc
    /// comment.
    func testLastTranscriptAndReplyTurnIdReflectWhichTurnTheTextBelongsTo() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart) // turn 1
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.transcriptFinal("hello there", turnId: 1)))
        connection.emit(.message(.responseText("what animal should we meet", turnId: 1)))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let transcriptTurnIdAfterTurn1 = await coordinator.lastTranscriptTurnId
        let replyTurnIdAfterTurn1 = await coordinator.lastReplyTurnId
        XCTAssertEqual(transcriptTurnIdAfterTurn1, 1)
        XCTAssertEqual(replyTurnIdAfterTurn1, 1)

        // The child starts talking again -- activeTurnId advances to 2
        // immediately (handleSpeechStart() bumps it synchronously), well
        // before turn 2's own transcript/reply have arrived.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)

        let activeTurnIdMidTurn2 = await coordinator.activeTurnId
        XCTAssertEqual(activeTurnIdMidTurn2, 2, "activeTurnId must already reflect the new turn")
        let transcriptTurnIdMidTurn2 = await coordinator.lastTranscriptTurnId
        let replyTurnIdMidTurn2 = await coordinator.lastReplyTurnId
        let transcriptMidTurn2 = await coordinator.lastTranscript
        XCTAssertEqual(transcriptTurnIdMidTurn2, 1, "lastTranscriptTurnId must still point at turn 1 -- turn 2's transcript hasn't arrived yet")
        XCTAssertEqual(replyTurnIdMidTurn2, 1, "lastReplyTurnId must still point at turn 1 for the same reason")
        XCTAssertEqual(transcriptMidTurn2, "hello there", "the text itself must still be turn 1's, unchanged, until turn 2's own transcriptFinal arrives")

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.transcriptFinal("what about a fox", turnId: 2)))
        connection.emit(.message(.responseText("a fox it is", turnId: 2)))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let transcriptTurnIdAfterTurn2 = await coordinator.lastTranscriptTurnId
        let replyTurnIdAfterTurn2 = await coordinator.lastReplyTurnId
        XCTAssertEqual(transcriptTurnIdAfterTurn2, 2)
        XCTAssertEqual(replyTurnIdAfterTurn2, 2)

        runLoop.cancel()
    }

    /// waitingDittyAudio defaults to nil specifically so every OTHER test
    /// in this file (which doesn't pass it) stays completely unaffected --
    /// these are the only tests that opt in to exercise the feature itself.
    func testWaitingDittyLoopsWhileWaitingForReplyAndStopsWhenRealAudioArrives() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000 // paces the loop so it iterates a few times, not thousands
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: dittyAudio
        )
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        // No reply arrives yet -- let the ditty loop run for a while.
        try? await Task.sleep(nanoseconds: 30_000_000)

        let playedWhileWaiting = audio.played
        XCTAssertFalse(playedWhileWaiting.isEmpty, "the ditty should have looped at least once while waiting for a reply")
        XCTAssertTrue(
            playedWhileWaiting.allSatisfy { $0 == dittyAudio },
            "only ditty audio should have played so far -- no real reply audio has arrived yet"
        )

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        try? await Task.sleep(nanoseconds: 20_000_000)

        // The loop must have genuinely stopped, not just paused -- confirm
        // no MORE ditty chunks appear even after waiting again.
        let countRightAfterRealAudio = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterRealAudio,
            "the ditty loop must have stopped -- no further chunks should appear once real audio starts"
        )
        XCTAssertEqual(audio.played.last, Data([1, 2, 3]))

        runLoop.cancel()
    }

    func testWaitingDittyStopsOnInterruptBeforeAnyReplyArrives() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: dittyAudio
        )
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 20_000_000) // ditty looping, no reply yet

        vad.fire(.speechStart) // the barge-in, before any reply arrived
        try? await Task.sleep(nanoseconds: 10_000_000)

        let countRightAfterInterrupt = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterInterrupt,
            "the ditty loop must stop on interrupt, even though no reply ever arrived to stop it the other way"
        )

        runLoop.cancel()
    }

    func testWaitingDittyStopsOnEmptyReplyWithNoAudio() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: dittyAudio
        )
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 20_000_000) // ditty looping

        // Empty transcript path: turn_end with no response_text/audio at all.
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let countRightAfterTurnEnd = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterTurnEnd,
            "the ditty loop must stop once the turn ends, even when no reply audio ever arrived"
        )

        runLoop.cancel()
    }

    /// The timeout that bounds the ditty loop when the server goes quiet
    /// for longer than expected -- see SessionCoordinator's
    /// dittyTimeoutSeconds. Confirms the abandoned-turn path lands the
    /// same place a normal reply/error/turn_end would: back in .idle,
    /// unmuted, with an on-screen message instead of looping forever.
    func testWaitingDittyTimesOutAndReturnsToIdleWithAnErrorIfNoReplyArrives() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000 // a couple of iterations before the timeout fires
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad,
            waitingDittyAudio: dittyAudio, dittyTimeoutSeconds: 0.03
        )
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        // No reply ever arrives -- let the timeout fire.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let stateAfterTimeout = await coordinator.state
        XCTAssertEqual(
            stateAfterTimeout, .idle,
            "a timed-out turn must return to idle, same as a normal turn_end, so the child can just try again"
        )
        let errorAfterTimeout = await coordinator.lastErrorMessage
        XCTAssertEqual(
            errorAfterTimeout,
            "The agent took too long thinking. Can you say something to wake them up?"
        )
        let mutedAfterTimeout = await coordinator.isMuted
        XCTAssertFalse(mutedAfterTimeout, "must unmute once the wait is abandoned, same as every other end-of-wait path")

        // The loop must have genuinely stopped, not just paused.
        let countRightAfterTimeout = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterTimeout,
            "the ditty loop must stop once it times out, not keep looping forever"
        )

        runLoop.cancel()
    }

    /// A reply that finally arrives AFTER the timeout already gave up on
    /// this turn must not resurrect it -- confirms the abandon path relies
    /// on the same turnContinuation-is-nil discard the rest of the
    /// coordinator already uses for stale/abandoned turns, rather than
    /// needing its own separate guard.
    func testLateReplyAfterDittyTimeoutIsDiscarded() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad,
            waitingDittyAudio: dittyAudio, dittyTimeoutSeconds: 0.03
        )
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 100_000_000) // let the timeout fire

        // The server finally replies, long after the client gave up.
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let stateAfterLateReply = await coordinator.state
        XCTAssertEqual(stateAfterLateReply, .idle, "a late reply for an abandoned turn must not resurrect it")
        XCTAssertFalse(
            audio.played.contains(Data([1, 2, 3])),
            "a late reply for an already-abandoned turn must never be played"
        )

        runLoop.cancel()
    }

    /// The mute button's whole point: while muted, captured mic audio must
    /// never reach the VAD at all, not just be withheld from the server --
    /// see SessionCoordinator.isMuted's doc comment for why that's a
    /// deliberate design choice (a real barge-in can only ever start from a
    /// VAD-observed speechStart, so starving the VAD of audio is what
    /// actually prevents it, in the real app where a real VAD reacts to
    /// feed() calls). This test drives captureAudio() directly (like
    /// testCaptureAudioFeedsVADEvenWhileSpeaking does), not vad.fire(),
    /// since fire() bypasses captureAudio() entirely and would prove
    /// nothing about muting.
    func testMutedAudioNeverReachesVADOrServerAndUnmutingRestoresBoth() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.setMuted(true)

        // Muted while idle: must not even reach the VAD (so it can never
        // decide to fire speechStart from this audio).
        await coordinator.captureAudio(Data([1]))
        XCTAssertTrue(vad.fed.isEmpty, "muted audio must not reach the VAD while idle")

        // Muted while .listening (a real utterance already in flight): must
        // also not be uploaded to the server.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.captureAudio(Data([2]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(vad.fed.isEmpty, "muted audio must not reach the VAD while listening")
        XCTAssertTrue(connection.sentAudio.isEmpty, "muted audio must not be uploaded to the server")

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Unmuting must restore normal behavior for audio captured from
        // this point on.
        await coordinator.setMuted(false)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([9]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        await coordinator.captureAudio(Data([3]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(vad.fed, [Data([3])], "unmuted audio must reach the VAD again")

        runLoop.cancel()
    }

    /// Follow-up feature request: muting mid-utterance must actually stop
    /// listening, not leave the state machine stuck in .listening forever
    /// (which is what would happen without this -- captureAudio() stops
    /// feeding the VAD the instant isMuted flips true, so the VAD could
    /// never observe the silence hangover needed to fire speechEnd on its
    /// own). setMuted(true) reuses handleSpeechEnd() directly, so this
    /// finalizes the in-progress utterance exactly like a natural
    /// VAD-observed silence would: the server gets a real speech_end and
    /// the turn proceeds normally.
    func testMutingWhileListeningStopsListeningAndFinalizesTheTurn() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateWhileListening = await coordinator.state
        XCTAssertEqual(stateWhileListening, .listening)

        await coordinator.setMuted(true)
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(connection.sentMessages, [.speechStart(turnId: 1), .speechEnd], "muting mid-utterance must send a real speech_end, finalizing whatever was captured so far")
        let stateAfterMute = await coordinator.state
        XCTAssertEqual(stateAfterMute, .waitingForReply, "muting must actually stop listening, not leave the state machine stuck in .listening")

        // The turn started by the mute-triggered speechEnd must still
        // complete normally.
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(audio.played, [Data([1, 2, 3])])

        runLoop.cancel()
    }

    /// Muting while NOT .listening (e.g. idle, or already waitingForReply/
    /// speaking) must be a pure no-op as far as the state machine and wire
    /// protocol are concerned -- handleSpeechEnd()'s own state guard
    /// handles this, but worth a direct regression test since setMuted(_:)
    /// now unconditionally calls it.
    func testMutingWhileNotListeningDoesNotSendSpeechEndOrChangeState() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.setMuted(true)
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertTrue(connection.sentMessages.isEmpty, "muting while idle must not send anything to the server")
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        runLoop.cancel()
    }

    /// The mic now auto-mutes for the whole .waitingForReply window (no
    /// button press needed) and auto-unmutes the instant real reply audio
    /// starts, so barge-in works normally once there's something to barge
    /// in on.
    func testMicAutoMutesDuringWaitingForReplyAndAutoUnmutesOnceSpeakingBegins() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateWhileWaiting = await coordinator.state
        XCTAssertEqual(stateWhileWaiting, .waitingForReply)

        await coordinator.captureAudio(Data([1]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(vad.fed.isEmpty, "mic audio must not reach the VAD while auto-muted during .waitingForReply")

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([9]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateWhileSpeaking = await coordinator.state
        XCTAssertEqual(stateWhileSpeaking, .speaking)

        await coordinator.captureAudio(Data([2]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            vad.fed, [Data([2])],
            "mic audio must reach the VAD again once real reply audio starts playing"
        )

        runLoop.cancel()
    }

    /// An empty reply (turn_end with no .audio event at all) never reaches
    /// .speaking, so it's the only place besides .audio left to clear the
    /// auto-mute -- without this, a story turn with no spoken reply would
    /// leave the NEXT turn permanently auto-muted.
    func testAutoMuteClearsOnEmptyReplyTurnEndSoTheNextTurnIsNotStuckMuted() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.turnEnd(turnId: 1))) // empty reply, no audio ever arrives
        try? await Task.sleep(nanoseconds: 10_000_000)

        let stateAfterEmptyReply = await coordinator.state
        XCTAssertEqual(stateAfterEmptyReply, .idle)

        vad.fire(.speechStart) // a fresh, unrelated utterance
        try? await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.captureAudio(Data([3]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            vad.fed, [Data([3])],
            "auto-mute from a previous turn must not leak into a fresh one after an empty-reply turnEnd"
        )

        runLoop.cancel()
    }

    /// Same requirement as the empty-reply case, but for a server error
    /// ending the turn before .speaking is ever reached.
    func testAutoMuteClearsOnServerErrorSoTheNextTurnIsNotStuckMuted() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.error("Ollama is not running", turnId: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.captureAudio(Data([4]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            vad.fed, [Data([4])],
            "auto-mute from a previous turn must not leak into a fresh one after a server error"
        )

        runLoop.cancel()
    }

    func testSendObjectSeenSendsTheLabelToTheServer() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)

        await coordinator.sendObjectSeen(label: "teddy bear")

        XCTAssertEqual(connection.sentMessages, [.objectSeen(label: "teddy bear")])
    }

    /// Auto-mute and manual mute are independent flags, OR'd together --
    /// a standing manual mute (e.g. a parent stepping away) must still
    /// apply even once auto-mute itself would have cleared on reaching
    /// .speaking.
    /// The actual point of sharing one flag instead of OR-ing a separate
    /// auto-mute on top: a child/parent must be able to press the SAME
    /// mute button during an automatically-muted .waitingForReply window
    /// and have it genuinely work, e.g. to speak up and redirect the story
    /// while it's still thinking.
    func testPressingMuteButtonDuringAutoMutedWaitingForReplyGenuinelyUnmutes() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateWhileWaiting = await coordinator.state
        XCTAssertEqual(stateWhileWaiting, .waitingForReply)
        let mutedBeforeUnmute = await coordinator.isMuted
        XCTAssertTrue(mutedBeforeUnmute, "auto-mute should have engaged on entering .waitingForReply")

        await coordinator.setMuted(false) // the child/parent presses the button to unmute
        let mutedAfterUnmute = await coordinator.isMuted
        XCTAssertFalse(mutedAfterUnmute)

        await coordinator.captureAudio(Data([1]))
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            vad.fed, [Data([1])],
            "pressing the mute button during .waitingForReply must genuinely unmute -- one shared flag, not a separate auto-mute the button can't override"
        )

        runLoop.cancel()
    }

    /// The accepted flip side of sharing one flag: reaching .speaking
    /// always auto-unmutes, even overriding a mute the child/parent set
    /// during the wait -- documented as intentional in isMuted's doc
    /// comment (nothing is being captured yet at the moment this
    /// override happens; they can re-mute if they still want it muted
    /// once the reply starts).
    func testAutoUnmuteOnSpeakingOverridesAManualMuteSetDuringTheWait() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        await coordinator.setMuted(true) // redundant with auto-mute, but exercises the manual path too

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([9]))) // drives state to .speaking, which auto-unmutes
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateWhileSpeaking = await coordinator.state
        XCTAssertEqual(stateWhileSpeaking, .speaking)
        let mutedWhileSpeaking = await coordinator.isMuted
        XCTAssertFalse(
            mutedWhileSpeaking,
            "auto-unmute on reaching .speaking overrides a mute set during the wait -- one shared flag, last write wins, by design"
        )

        runLoop.cancel()
    }

    /// resume() is what a fresh coordinator calls after reconnecting from a
    /// backgrounding-triggered disconnect (see ContentView.swift's
    /// AppModel.connect(resumingTurnId:)) -- the server replays the whole
    /// reply for that turn_id from its start (see the server's
    /// replay_last_turn()), and this coordinator must land exactly where a
    /// normal turn would: .waitingForReply, muted, ready to play whatever
    /// arrives and reach .idle on turn_end.
    func testResumeEntersWaitingForReplyMutedAndPlaysTheReplayedReply() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)

        await coordinator.resume(turnId: 7)

        let stateAfterResume = await coordinator.state
        XCTAssertEqual(stateAfterResume, .waitingForReply)
        let mutedAfterResume = await coordinator.isMuted
        XCTAssertTrue(mutedAfterResume, "resuming should mute the mic for the wait, same as a normal speechEnd")

        // start() is only launched AFTER resume() returns -- mirrors
        // AppModel.connect(resumingTurnId:)'s required ordering, and proves
        // resume() itself doesn't depend on consumeServerEvents() already
        // running.
        let runLoop = Task { await coordinator.start() }

        connection.emit(.message(.responseText("the fox found a key", turnId: 7)))
        connection.emit(.audio(Data([5, 6, 7])))
        connection.emit(.message(.turnEnd(turnId: 7)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        let reply = await coordinator.lastReply
        XCTAssertEqual(reply, "the fox found a key")
        XCTAssertEqual(audio.played, [Data([5, 6, 7])])
        let mutedAfterTurnEnd = await coordinator.isMuted
        XCTAssertFalse(mutedAfterTurnEnd)

        runLoop.cancel()
    }

    /// Regression guard for the ordering requirement in resume()'s doc
    /// comment: events emitted on the connection BEFORE start() is ever
    /// called (simulating the server replaying instantly on connect,
    /// possibly before consumeServerEvents() has been scheduled to run)
    /// must not be lost or misattributed -- AsyncStream buffers them, and
    /// resume() having already set currentTurnId before start() runs is
    /// what keeps them from being discarded as stale once they are read.
    func testResumeDoesNotLoseEventsEmittedBeforeStartIsCalled() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)

        await coordinator.resume(turnId: 3)
        // Emitted before start() -- exercises AsyncStream's own buffering,
        // not the coordinator's.
        connection.emit(.message(.responseText("already generated", turnId: 3)))
        connection.emit(.audio(Data([1])))
        connection.emit(.message(.turnEnd(turnId: 3)))

        let runLoop = Task { await coordinator.start() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        let reply = await coordinator.lastReply
        XCTAssertEqual(reply, "already generated")
        XCTAssertEqual(audio.played, [Data([1])])

        runLoop.cancel()
    }

    /// A stale replay for a turn_id the client no longer cares about (e.g.
    /// this coordinator was actually created to resume a LATER turn) must
    /// be discarded like any other turn_id mismatch -- resume() participates
    /// in the same currentTurnId gating as a normal turn, not a bypass of it.
    func testResumeWithMismatchedTurnIdDiscardsTheReplayedEvents() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)

        await coordinator.resume(turnId: 5)
        let runLoop = Task { await coordinator.start() }

        connection.emit(.message(.responseText("wrong turn", turnId: 4)))
        connection.emit(.audio(Data([9])))
        connection.emit(.message(.turnEnd(turnId: 4)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let reply = await coordinator.lastReply
        XCTAssertEqual(reply, "", "a reply for a different turn_id must be discarded, not applied")
        XCTAssertTrue(audio.played.isEmpty)
        let state = await coordinator.state
        XCTAssertEqual(state, .waitingForReply, "still waiting -- nothing matching turn_id 5 ever arrived")

        runLoop.cancel()
    }

    /// resume() deliberately does NOT start the waiting ditty itself --
    /// confirmed on real hardware that calling play() (and so
    /// engine.start()) before mic capture has ever configured
    /// RealAudioEngine's input side reliably fails with an input/output
    /// sample-rate mismatch. startResumedWaitingDitty() is the separate
    /// call AppModel makes only after mic capture has started.
    func testResumeDoesNotStartTheDittyOnItsOwn() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let ditty = Data([1, 1, 1])
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad, waitingDittyAudio: ditty)

        await coordinator.resume(turnId: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(audio.played.isEmpty, "resume() alone must not play anything yet")
    }

    func testStartResumedWaitingDittyStartsItAfterResume() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let ditty = Data([1, 1, 1])
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad, waitingDittyAudio: ditty)

        await coordinator.resume(turnId: 1)
        await coordinator.startResumedWaitingDitty()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(audio.played.contains(ditty), "the ditty should be looping once explicitly started")
    }

    /// If the resumed reply has already fully arrived by the time the
    /// caller gets around to starting the ditty (mic capture's own retry
    /// logic can take a couple of seconds on real hardware), there is
    /// nothing left to wait for -- starting the ditty at that point would
    /// just be a spurious chime after (or during) the real reply.
    func testStartResumedWaitingDittyIsANoOpIfTheTurnAlreadyFinished() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let ditty = Data([1, 1, 1])
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad, waitingDittyAudio: ditty)

        await coordinator.resume(turnId: 1)
        let runLoop = Task { await coordinator.start() }
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([9])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        await coordinator.startResumedWaitingDitty()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(audio.played.contains(ditty), "no ditty once the resumed turn has already ended")

        runLoop.cancel()
    }

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
}
