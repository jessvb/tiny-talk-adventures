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
        // buffer before runTurn ever looks at them.
        connection.emit(.audio(Data([1])))
        connection.emit(.audio(Data([2])))
        connection.emit(.audio(Data([3])))
        connection.emit(.message(.turnEnd))
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

        // Drive the new turn to completion and confirm it was not
        // corrupted: pre-fix, the stale turn's buffered turnEnd could get
        // applied to the live machine and unconditionally nil out the NEW
        // turn's turnContinuation, silently orphaning it from all further
        // server events (so the assertions below would see it stuck,
        // never reaching .idle, and never playing chunk 9).
        connection.emit(.audio(Data([9])))
        connection.emit(.message(.turnEnd))
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

        XCTAssertEqual(connection.sentMessages, [.speechStart])
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
        connection.emit(.audio(Data([9, 9, 9]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Captured while .speaking, i.e. the audio that triggers the
        // barge-in -- must not be dropped.
        await coordinator.captureAudio(Data([7]))
        await coordinator.captureAudio(Data([8]))

        vad.fire(.speechStart) // the barge-in
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(connection.sentMessages.last, .interrupt)
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

        // Cap is 24_000 * 2 bytes/sec * 0.2s = 9600 bytes. Four 4000-byte
        // chunks (16000 bytes total) exceed that, so the oldest ones must
        // be evicted, leaving only the most recent chunks whose combined
        // size fits under the cap.
        let chunk1 = Data(repeating: 1, count: 4000)
        let chunk2 = Data(repeating: 2, count: 4000)
        let chunk3 = Data(repeating: 3, count: 4000)
        let chunk4 = Data(repeating: 4, count: 4000)
        await coordinator.captureAudio(chunk1)
        await coordinator.captureAudio(chunk2)
        await coordinator.captureAudio(chunk3)
        await coordinator.captureAudio(chunk4)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(connection.sentAudio, [chunk3, chunk4], "the oldest chunks (1 and 2) must have been evicted once the ~200ms byte cap was exceeded")

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
            [.message(.speechStart), .audio(Data([1])), .audio(Data([2])), .audio(Data([3]))],
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
        connection.emit(.audio(Data([9, 9, 9]))) // drives state to .speaking
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Pre-roll captured while .speaking, just before the barge-in.
        await coordinator.captureAudio(Data([7]))
        await coordinator.captureAudio(Data([8]))

        connection.sendMessageDelayNanos = 40_000_000
        connection.sendAudioDelayNanos = 15_000_000

        vad.fire(.speechStart) // the barge-in -> interrupt()
        try? await Task.sleep(nanoseconds: 10_000_000) // interrupt()'s control-frame send is now in flight

        // The race: a concurrent captureAudio() call while `interrupt`'s
        // control frame is still being sent.
        await coordinator.captureAudio(Data([10]))

        try? await Task.sleep(nanoseconds: 150_000_000)

        let log = connection.sentLog
        guard let interruptIndex = log.firstIndex(of: .message(.interrupt)) else {
            XCTFail("interrupt control frame was never sent")
            runLoop.cancel()
            return
        }
        XCTAssertEqual(
            Array(log[interruptIndex...]),
            [.message(.interrupt), .audio(Data([7])), .audio(Data([8])), .audio(Data([10]))],
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
        // turnContinuation is nil.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)

        let stateBeforeError = await coordinator.state
        XCTAssertEqual(stateBeforeError, .listening)

        connection.emit(.message(.error("stt feed failed")))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let errorMessage = await coordinator.lastErrorMessage
        XCTAssertEqual(errorMessage, "stt feed failed", "an error frame arriving outside an active turn must still be surfaced, not silently dropped")

        runLoop.cancel()
    }
}
