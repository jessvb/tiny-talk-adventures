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
        XCTAssertEqual(audio.enqueued, [Data([1, 2, 3])])

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
    /// faster than enqueue() drains them, so a naive cancelled runTurn kept
    /// delivering those stale buffered events: audio reached the audio
    /// engine after the interrupt, and a stale turnEnd from the OLD turn
    /// got applied to the live state machine after a NEW turn had already
    /// started, corrupting it and orphaning the new turn's continuation.
    /// Reproduced empirically during review (5/5 runs let stale audio reach
    /// the audio engine; 2/3 runs corrupted the next turn) before the
    /// `if Task.isCancelled { return }` guard was added to the top of
    /// runTurn's loop.
    func testInterruptDiscardsAlreadyBufferedTurnEventsAndDoesNotCorruptNextTurn() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.enqueueDelayNanos = 50_000_000 // chunk 1's enqueue() registration will be genuinely in-flight when the interrupt fires
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Emit several chunks and a turnEnd back-to-back, with nothing
        // draining them yet (runTurn is about to block inside chunk 1's
        // 50ms enqueue() registration) -- these all land in the per-turn
        // stream's buffer before runTurn ever looks at them.
        // consumeServerEvents() still forwards all of these (turn 1 hasn't
        // been superseded yet at the moment it reads them, well before the
        // barge-in below).
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.audio(Data([2])))
        connection.emit(.audio(Data([3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000) // let enqueue() start on chunk 1, well before its 50ms delay elapses

        // From here on, drop the delay to 0. This isolates the bug this
        // test targets: without it, chunks 2 and 3 would ALSO go through
        // Task.sleep and get "saved" by its own unrelated
        // cancellation-awareness (same mechanism the slow-enqueue test
        // below already covers), masking whether runTurn itself still
        // hands buffered-but-not-yet-started events to enqueue() at all.
        // With delay 0, any buffered chunk that reaches enqueue() records
        // itself instantly -- exactly the real-world case too, since TTS
        // chunks normally play back-to-back with no gap.
        audio.enqueueDelayNanos = 0

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

        XCTAssertTrue(audio.enqueued.isEmpty, "no buffered chunk from the OLD turn may reach enqueue() after the interrupt discarded it")
        XCTAssertTrue(audio.enqueueWasCancelled, "chunk 1's in-flight enqueue() must have observed genuine cancellation")

        // Drive the new turn (turn 2) to completion and confirm it was not
        // corrupted: pre-fix, the stale turn's buffered turnEnd could get
        // applied to the live machine and unconditionally nil out the NEW
        // turn's turnContinuation, silently orphaning it from all further
        // server events (so the assertions below would see it stuck,
        // never reaching .idle, and never enqueueing chunk 9).
        connection.emit(.message(.responseText("hi again", turnId: 2)))
        connection.emit(.audio(Data([9])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 30_000_000)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle, "a fresh turn after the interrupt must complete normally, not be corrupted by the stale turn's buffered events")
        XCTAssertEqual(audio.enqueued, [Data([9])], "the new turn's chunk must actually be enqueued -- proves its turnContinuation was not silently orphaned by stale cleanup")

        runLoop.cancel()
    }

    /// Mirrors the server's test_interrupt_during_speaking_stops_the_turn:
    /// the hardest case, an interrupt arriving mid-playback. Also asserts
    /// GENUINE cancellation of the in-flight enqueue() call (not just that
    /// stopPlaybackImmediately() was called) -- see FakeAudio.enqueueWasCancelled
    /// and the SessionCoordinator doc comment explaining why this matters.
    func testInterruptDuringSlowEnqueueGenuinelyCancelsInFlightEnqueue() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.enqueueDelayNanos = 50_000_000 // 50ms -- long enough to interrupt mid-flight
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([9, 9, 9])))
        try? await Task.sleep(nanoseconds: 10_000_000) // let enqueue() start, well before its 50ms delay finishes

        vad.fire(.speechStart) // the barge-in

        try? await Task.sleep(nanoseconds: 80_000_000) // longer than enqueueDelayNanos, to catch a late false-positive

        let state = await coordinator.state
        XCTAssertEqual(state, .listening)
        XCTAssertTrue(audio.stopped, "stopPlaybackImmediately must have been called")
        XCTAssertTrue(audio.enqueued.isEmpty, "the in-flight chunk must NOT complete and record itself as enqueued after interrupt")
        XCTAssertTrue(audio.enqueueWasCancelled, "the in-flight enqueue() call must have observed real task cancellation")

        runLoop.cancel()
    }

    /// The core correctness guarantee behind The End screen's
    /// auto-navigation: readyToShowTheEnd must NOT fire just because
    /// rewritingStarted arrived -- see that property's doc comment for
    /// the exact real-world race this proves doesn't cause a premature
    /// signal. Uses autoFinishEnqueuedBuffers/finishOldestEnqueuedBuffer()
    /// to force a genuine suspension inside waitForPlaybackToFinish(), the
    /// same kind of suspension a real device's audio playback would also
    /// have -- an instantly-finishing enqueue() would never expose this
    /// race.
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
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
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

    /// The opposite ordering from the test above: playback finishes
    /// (turnEnd reaches runTurn()) before rewritingStarted has even
    /// arrived. Proves the join works regardless of which signal lands
    /// first -- readyToShowTheEnd must still end up true, not stuck
    /// waiting on an event that already happened before the flag existed
    /// to combine with it.
    /// Issue #77: rewriting_started's fact line is kept per story id, so
    /// The End can show it right away -- and only for that story.
    func testRewritingStartedRecordsItsEpilogueUnderItsStoryId() async {
        let connection = FakeConnection()
        let coordinator = SessionCoordinator(connection: connection, audio: FakeAudio(), vad: FakeVAD())
        let runLoop = Task { await coordinator.start() }
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.rewritingStarted(storyId: "abc", epilogue: "And one true thing we learned about the fox: foxes hear well")))
        connection.emit(.message(.rewritingStarted(storyId: "def", epilogue: nil)))
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: "orphan fact")))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let early = await coordinator.earlyEpilogues
        XCTAssertEqual(early, ["abc": "And one true thing we learned about the fox: foxes hear well"])

        runLoop.cancel()
    }

    func testReadyToShowTheEndFiresWhenRewritingStartedArrivesAfterPlaybackFinishes() async {
        let connection = FakeConnection()
        let audio = FakeAudio() // instant playback -- turnEnd reaches runTurn almost immediately
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        var ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "must not be ready before rewritingStarted has arrived at all")

        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "must become ready once rewritingStarted arrives, even though playback already finished")

        runLoop.cancel()
    }

    func testConcludeStorySendsConcludeStoryAndEntersWaitingForReply() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.concludeStory()
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(connection.sentMessages, [.concludeStory(turnId: 1)])
        let state = await coordinator.state
        XCTAssertEqual(state, .waitingForReply)

        // The server's forced final reply arrives exactly like a normal
        // turn's -- proves concludeStory() actually set up a turnTask to
        // receive it, not just sent the control frame.
        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(audio.enqueued, [Data([1])])

        runLoop.cancel()
    }

    func testListStoriesAndGetStoryUpdatePolledState() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.listStories()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(connection.sentMessages, [.listStories])

        connection.emit(.message(.storyList([
            SavedStorySummary(id: "pip", title: "Pip", createdAt: Date(), pageCount: 5, rewriteStatus: .done),
        ])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let list = await coordinator.latestStoryList
        XCTAssertEqual(list?.map(\.id), ["pip"])

        await coordinator.getStory(storyId: "pip")
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(connection.sentMessages, [.listStories, .getStory(storyId: "pip")])

        connection.emit(.message(.storyDetail(
            SavedStoryDetail(id: "pip", title: "Pip", pages: [StoryPage(text: "Once upon a time.")], epilogue: nil, rewriteStatus: .done)
        )))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let detail = await coordinator.latestStoryDetail
        XCTAssertEqual(detail?.id, "pip")
        XCTAssertEqual(detail?.pages, [StoryPage(text: "Once upon a time.")])

        runLoop.cancel()
    }

    func testGetPageImageSendsRequestAndStoresResultOnMatchingDoneMarker() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(connection.sentMessages, [.getPageImage(storyId: "pip", pageIndex: 1)])

        connection.emit(.audio(Data([0x01, 0x02, 0x03])))
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 1, hasImage: true)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let images = await coordinator.pageImages
        XCTAssertEqual(images["pip#1"], Data([0x01, 0x02, 0x03]))

        runLoop.cancel()
    }

    func testPageImageDoneWithoutImageLeavesNoEntryInPageImages() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 1, hasImage: false)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let images = await coordinator.pageImages
        XCTAssertNil(images["pip#1"])

        runLoop.cancel()
    }

    /// The core regression test for the FIFO-queue fix: two different
    /// pages requested before EITHER response arrives (completely
    /// ordinary during real usage -- SwiftUI's TabView(.page) style fires
    /// .onAppear for multiple pages during a swipe transition) must both
    /// resolve correctly once their .audio/page_image_done pairs arrive,
    /// in order. This FAILS against the old single-slot design
    /// (pendingPageImageRequest/latestPageImage): the second getPageImage()
    /// call would silently overwrite the first request's pending state
    /// before its response was ever processed, permanently losing page 1's
    /// image.
    func testTwoConcurrentPageImageRequestsBothResolveCorrectly() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        await coordinator.getPageImage(storyId: "pip", pageIndex: 2)
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(
            connection.sentMessages,
            [.getPageImage(storyId: "pip", pageIndex: 1), .getPageImage(storyId: "pip", pageIndex: 2)]
        )

        // Both responses arrive in the order the requests were sent -- see
        // pendingPageImageRequests' doc comment for why this FIFO ordering
        // is guaranteed by the server, not merely assumed here.
        connection.emit(.audio(Data([1, 1, 1])))
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 1, hasImage: true)))
        connection.emit(.audio(Data([2, 2, 2])))
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 2, hasImage: true)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let images = await coordinator.pageImages
        XCTAssertEqual(images["pip#1"], Data([1, 1, 1]))
        XCTAssertEqual(images["pip#2"], Data([2, 2, 2]))

        runLoop.cancel()
    }

    /// Regression guard for the existing turn-scoped audio path
    /// (testHappyPathReachesIdleAfterTurnEnd's own live-turn .audio
    /// handling, line 5-28 of this file): with no page-image request
    /// pending, live TTS audio arriving mid-turn must still reach
    /// FakeAudio exactly as before this task's change to the .audio
    /// branch in consumeServerEvents().
    func testLiveTurnAudioStillPlaysWithNoPageImageRequestPending() async {
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
        connection.emit(.audio(Data([4, 5, 6])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([4, 5, 6])])

        runLoop.cancel()
    }

    /// Code-review finding: a mismatched page_image_done (wrong storyId or
    /// pageIndex) must not resolve -- or clear -- an unrelated pending
    /// request. A later, genuinely matching marker must still resolve it.
    func testPageImageDoneWithMismatchedIdsLeavesPendingRequestIntact() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.audio(Data([9, 9, 9])))
        connection.emit(.message(.pageImageDone(storyId: "someone-else", pageIndex: 1, hasImage: true)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let afterMismatch = await coordinator.pageImages
        XCTAssertNil(afterMismatch["pip#1"], "a mismatched marker must not resolve an unrelated pending request")
        XCTAssertNil(afterMismatch["someone-else#1"], "a mismatched marker must not fabricate an entry for itself either")

        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 1, hasImage: true)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let result = await coordinator.pageImages
        XCTAssertEqual(result["pip#1"], Data([1, 2, 3]), "the genuinely matching marker must still resolve the still-pending request")

        runLoop.cancel()
    }

    /// Code-review finding: getPageImage()'s `try?` used to swallow a send
    /// failure silently, leaving pendingPageImageRequest set forever with
    /// no request having actually reached the server -- which would
    /// permanently divert every later live .audio frame away from playback
    /// instead of a live turn. Confirms the send failure itself clears the
    /// pending state so a subsequent live turn plays normally.
    func testGetPageImageClearsPendingStateIfSendFails() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        connection.sendMessageError = FakeSendError()
        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        connection.sendMessageError = nil

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "a failed getPageImage() send must not permanently divert later live audio")

        runLoop.cancel()
    }

    /// Code-review finding: if a get_page_image request's page_image_done
    /// marker never arrives (e.g. the server's error path for a missing
    /// story/out-of-range page, which sends a generic error frame and no
    /// marker at all -- see session.py's handle_get_page_image),
    /// pendingPageImageRequest must not stay stuck forever, since the
    /// .audio branch checks it BEFORE the turn-scoped isCurrentTurnAudio
    /// gate: a stuck request would silently divert every later live-turn
    /// .audio frame away from playback. An unrelated error clears it, even
    /// though its turn_id (0) does not match any real turn -- the fix must
    /// not depend on turn_id matching, since the server's error path for
    /// this failure uses whatever turn_id happens to be current, not
    /// anything tied to the page-image request.
    func testUnrelatedErrorClearsStuckPendingPageImageRequestSoLiveAudioStillPlays() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        // No page_image_done ever arrives for this request -- simulate the
        // server's failure path instead: a generic error frame.
        connection.emit(.message(.error("story not found", turnId: 0)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "an unrelated error must clear a stuck pending page-image request, not just leave it discarded")

        runLoop.cancel()
    }

    /// Code-review finding: handleConnectionLost() is reached from the SEND
    /// side too (a control-frame send failing in
    /// handleSpeechStart()/handleSpeechEnd()/interrupt()), which does NOT
    /// return from consumeServerEvents() the way the .closed path does --
    /// that loop keeps running afterwards. If a page-image request was left
    /// pending when that happens, it must not stay stuck and silently
    /// divert a later, genuinely new turn's live audio.
    func testConnectionLostViaSendFailureClearsStuckPendingPageImageRequestSoLiveAudioStillPlays() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        // No page_image_done ever arrives for this request.

        // Force handleConnectionLost() via the send-failure path (not
        // .closed, which would end consumeServerEvents() for good and make
        // this test unable to observe anything afterwards).
        connection.sendMessageError = FakeSendError()
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.sendMessageError = nil

        // A brand new turn's live audio must still play.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 2)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "handleConnectionLost() must clear a stuck pending page-image request, not just leave it discarded")

        runLoop.cancel()
    }

    /// Unlike getPageImage (one binary frame, buffered until its marker
    /// arrives), synthesize_page streams MULTIPLE chunks -- each one must
    /// reach playback as it arrives, not be buffered into one blob.
    func testSynthesizePageStreamsEachChunkToPlaybackAsItArrives() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(connection.sentMessages, [.synthesizePage(storyId: "pip", pageIndex: 1)])

        connection.emit(.audio(Data([1, 1, 1])))
        connection.emit(.audio(Data([2, 2, 2])))
        connection.emit(.audio(Data([3, 3, 3])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        // All three chunks reached playback before the done marker even
        // arrived -- confirms streaming, not buffer-then-play-on-done.
        XCTAssertEqual(audio.enqueued, [Data([1, 1, 1]), Data([2, 2, 2]), Data([3, 3, 3])])

        connection.emit(.message(.pageAudioDone(storyId: "pip", pageIndex: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        runLoop.cancel()
    }

    /// Regression guard mirroring testLiveTurnAudioStillPlaysWithNoPageImageRequestPending:
    /// with no page-audio request pending, live TTS audio arriving mid-turn
    /// must still reach FakeAudio exactly as before this task's change.
    func testLiveTurnAudioStillPlaysWithNoPageAudioRequestPending() async {
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
        connection.emit(.audio(Data([4, 5, 6])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([4, 5, 6])])

        runLoop.cancel()
    }

    /// stopPageAudio() must both stop local playback AND clear the pending
    /// request -- otherwise a late-arriving chunk for the just-abandoned
    /// request would still reach playback (the .audio routing below checks
    /// pendingPageAudioRequest, not whether the UI still wants to hear it).
    func testStopPageAudioStopsPlaybackAndDropsLateArrivingChunks() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.audio(Data([1, 1, 1])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        await coordinator.stopPageAudio()
        XCTAssertTrue(audio.stopped)

        // A late chunk for the abandoned request must not reach playback --
        // it's no longer "pending", so it falls through to the turn-scoped
        // gate and is dropped (no live turn is active here either).
        connection.emit(.audio(Data([2, 2, 2])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(audio.enqueued, [Data([1, 1, 1])], "no chunk after stopPageAudio() should reach playback")

        runLoop.cancel()
    }

    /// Reproduces the real bug pendingPageAudioDoneMarkersToDiscard exists
    /// for: a rapid re-tap (stop an in-flight request, immediately request
    /// a new one) must not let the abandoned request's still-arriving tail
    /// get played as if it were the new request's audio. The stop alone is
    /// not enough -- by the time the leftovers arrive,
    /// pendingPageAudioRequest is already non-nil again for the NEW
    /// request, so the routing check the previous test relies on would
    /// wave them straight through to playback.
    func testAbandonedPageAudioTailDoesNotBleedIntoNextRequest() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // Page A starts streaming.
        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.audio(Data([1, 1, 1])))
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Child re-taps before A finishes -- abandon A, request B.
        await coordinator.stopPageAudio()
        await coordinator.synthesizePage(storyId: "pip", pageIndex: 2)
        try? await Task.sleep(nanoseconds: 5_000_000)

        // A's already-in-flight tail keeps arriving (the server had no
        // way to know A was abandoned) -- this chunk must be discarded,
        // not played as if it belonged to B.
        connection.emit(.audio(Data([9, 9, 9])))
        connection.emit(.message(.pageAudioDone(storyId: "pip", pageIndex: 1)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        // B's real audio now arrives and must play normally.
        connection.emit(.audio(Data([2, 2, 2])))
        connection.emit(.message(.pageAudioDone(storyId: "pip", pageIndex: 2)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(audio.enqueued, [Data([1, 1, 1]), Data([2, 2, 2])], "A's post-abandonment tail (9,9,9) must never reach playback")

        runLoop.cancel()
    }

    /// The failure mode the discard counter could otherwise introduce: an
    /// abandoned synthesize_page whose page_index turns out to be invalid
    /// is answered server-side with an error frame and NO page_audio_done
    /// (see session.py's _page_or_error), so the marker the counter waits
    /// for never comes. Without the error frame also clearing that count,
    /// the .audio routing would swallow every later frame forever and the
    /// app would go silent for the rest of the connection -- including
    /// live-turn story audio, which has nothing to do with page reading.
    func testErrorClearsOwedDiscardMarkersSoLiveAudioStillPlays() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        // Abandoned while in flight -- a page_audio_done marker is now
        // owed, but this request is one the server will reject outright.
        await coordinator.stopPageAudio()
        connection.emit(.message(.error("no page 1 for story 'pip'", turnId: 0)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "an error frame must clear owed discard markers, or live audio is lost forever")

        runLoop.cancel()
    }

    /// Mirrors testUnrelatedErrorClearsStuckPendingPageImageRequestSoLiveAudioStillPlays
    /// for the audio case: an unrelated error must not leave
    /// pendingPageAudioRequest stuck forever silently diverting live-turn
    /// audio into playback-as-page-audio.
    func testUnrelatedErrorClearsStuckPendingPageAudioRequestSoLiveAudioStillPlays() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        // No page_audio_done ever arrives -- simulate a server failure.
        connection.emit(.message(.error("story not found", turnId: 0)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "an unrelated error must clear a stuck pending page-audio request")

        runLoop.cancel()
    }

    /// Mirrors testGetPageImageClearsPendingStateIfSendFails for the audio case.
    func testSynthesizePageClearsPendingStateIfSendFails() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        connection.sendMessageError = FakeSendError()
        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        connection.sendMessageError = nil

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "a failed synthesizePage() send must not permanently divert later live audio")

        runLoop.cancel()
    }

    /// Mirrors testConnectionLostViaSendFailureClearsStuckPendingPageImageRequestSoLiveAudioStillPlays
    /// for the audio case: handleConnectionLost() (reached from the SEND
    /// side, e.g. a control-frame send failing in handleSpeechStart(), not
    /// from synthesizePage()'s own send-failure catch in Step 8) must also
    /// clear pendingPageAudioRequest, not just leave it stuck.
    func testConnectionLostViaSendFailureClearsStuckPendingPageAudioRequestSoLiveAudioStillPlays() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        // No page_audio_done marker ever arrives for this request.

        // Force handleConnectionLost() via the send-failure path (not
        // .closed, which would end consumeServerEvents() for good and make
        // this test unable to observe anything afterwards).
        connection.sendMessageError = FakeSendError()
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.sendMessageError = nil

        // A brand new turn's live audio must still play.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("hi", turnId: 2)))
        connection.emit(.audio(Data([7, 8, 9])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.enqueued, [Data([7, 8, 9])], "handleConnectionLost() must clear a stuck pending page-audio request, not just leave it discarded")

        runLoop.cancel()
    }

    /// The page-audio counterpart to
    /// testWaitingDittyLoopsWhileWaitingForReplyAndStopsWhenRealAudioArrives
    /// -- confirms the fix for the on-device report "I didn't get any
    /// voices initially" (tapping 🔊 gave no audio feedback while the
    /// server synthesized that page's TTS).
    func testPageAudioDittyLoopsWhileWaitingAndStopsWhenRealAudioArrives() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000 // paces the loop so it iterates a few times, not thousands
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: dittyAudio
        )
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        // No chunks arrive yet -- let the ditty loop run for a while.
        try? await Task.sleep(nanoseconds: 30_000_000)

        let playedWhileWaiting = audio.played
        XCTAssertFalse(playedWhileWaiting.isEmpty, "the ditty should have looped at least once while waiting for page audio")
        XCTAssertTrue(
            playedWhileWaiting.allSatisfy { $0 == dittyAudio },
            "only ditty audio should have played so far -- no real page audio has arrived yet"
        )

        connection.emit(.audio(Data([1, 2, 3])))
        try? await Task.sleep(nanoseconds: 20_000_000)

        // The loop must have genuinely stopped, not just paused.
        let countRightAfterRealAudio = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterRealAudio,
            "the page-audio ditty loop must have stopped -- no further chunks should appear once real audio starts"
        )
        XCTAssertEqual(audio.enqueued, [Data([1, 2, 3])])

        runLoop.cancel()
    }

    func testPageAudioDittyStopsOnStopPageAudio() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: dittyAudio
        )
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 20_000_000) // ditty looping, no chunk yet

        await coordinator.stopPageAudio()
        await waitForDittyStopToLand(audio)

        let countRightAfterStop = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterStop,
            "stopPageAudio() must stop the page-audio ditty, even though no real audio ever arrived to stop it the other way"
        )

        runLoop.cancel()
    }

    /// Confirms a real gap this fix closes: without it, an abandoned
    /// synthesize_page whose story/page is invalid (error frame, no
    /// page_audio_done -- see session.py's _page_or_error) would leave the
    /// page-audio ditty looping for the full dittyTimeoutSeconds instead of
    /// stopping the instant the error arrives.
    func testPageAudioDittyStopsOnUnrelatedError() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.playDelayNanos = 5_000_000
        let vad = FakeVAD()
        let dittyAudio = Data([0xAA, 0xBB])
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: dittyAudio
        )
        let runLoop = Task { await coordinator.start() }

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 20_000_000) // ditty looping

        XCTAssertFalse(audio.stopped, "precondition: nothing has stopped playback yet, so audio.stopped below really means the error was handled")
        connection.emit(.message(.error("no page 1 for story 'pip'", turnId: 0)))
        // emit() only yields to the stream -- the coordinator handles the
        // error asynchronously, so snapshotting right away raced it.
        await waitForDittyStopToLand(audio)

        let countRightAfterError = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterError,
            "an error answering synthesize_page must stop the page-audio ditty immediately, not just eventually via its timeout"
        )

        runLoop.cancel()
    }

    /// Waits until a ditty stop has genuinely landed -- stopWaitingDitty()
    /// always calls audio.stopPlaybackImmediately(), so audio.stopped
    /// flips then -- AND the one iteration already mid-play() at that
    /// moment has returned (see FakeAudio.playsInFlight for why it may
    /// still record itself after the stop). Only after both is a
    /// played.count snapshot a fair "nothing more may play" baseline.
    /// Snapshotting before either was issue #71's off-by-one flake. Keeps
    /// the assertion's teeth: a loop that didn't actually stop would add
    /// ~4 more plays during the caller's following 20ms wait.
    private func waitForDittyStopToLand(_ audio: FakeAudio) async {
        await eventually { audio.stopped && audio.playsInFlight == 0 }
    }

    /// Confirms handlePageAudioDittyTimeout() is properly scoped: it must
    /// resolve entirely on its own, without needing or affecting any
    /// turn/session state -- a page-audio wait has no turn of its own to
    /// abandon, unlike handleDittyTimeout()'s live-turn version.
    func testPageAudioDittyTimesOutWithoutTouchingSessionState() async {
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

        await coordinator.synthesizePage(storyId: "pip", pageIndex: 1)
        // No page audio (or error) ever arrives -- let the timeout fire.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let stateAfterTimeout = await coordinator.state
        XCTAssertEqual(stateAfterTimeout, .idle, "a page-audio ditty timeout must never touch the turn state machine")
        let mutedAfterTimeout = await coordinator.isMuted
        XCTAssertFalse(mutedAfterTimeout, "a page-audio ditty timeout must never touch mute state")

        // The loop must have genuinely stopped, not just paused.
        let countRightAfterTimeout = audio.played.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            audio.played.count, countRightAfterTimeout,
            "the page-audio ditty loop must stop once it times out, not keep looping forever"
        )

        runLoop.cancel()
    }

    func testIsRewritingTracksRewritingStartedAndDone() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        var rewriting = await coordinator.isRewriting
        XCTAssertFalse(rewriting)

        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        try? await Task.sleep(nanoseconds: 10_000_000)
        rewriting = await coordinator.isRewriting
        XCTAssertTrue(rewriting)

        connection.emit(.message(.rewritingDone))
        try? await Task.sleep(nanoseconds: 10_000_000)
        rewriting = await coordinator.isRewriting
        XCTAssertFalse(rewriting, "isRewriting must go back to false once the rewrite finishes")

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

    /// Issue #69: Home mid-story -> Create a Story opened a fresh connection,
    /// but the server's one long-lived session still held the abandoned
    /// story's conversation and arc. The fresh connection's reset is ONLY
    /// the wire message: it runs before mic capture has started, so none of
    /// newStory()'s client-side teardown (stopping playback, unmuting) may
    /// touch the audio engine yet -- and a fresh coordinator has nothing to
    /// tear down anyway.
    func testStartFreshServerStorySendsOnlyNewStoryAndLeavesAudioAlone() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)

        await coordinator.startFreshServerStory()

        XCTAssertEqual(connection.sentMessages, [.newStory])
        XCTAssertFalse(audio.stopped, "must not touch playback before capture has configured the engine")
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        let muted = await coordinator.isMuted
        XCTAssertFalse(muted)
    }

    /// The reset must reach the server before the child's first utterance
    /// can: the server processes one connection's frames in order, so
    /// new_story ahead of speech_start means the first turn already sees
    /// the INTRO stage.
    func testStartFreshServerStoryIsSentAheadOfTheFirstSpeechStart() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        await coordinator.startFreshServerStory()
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(connection.sentMessages.first, .newStory)
        XCTAssertTrue(connection.sentMessages.contains(.speechStart(turnId: 1)))

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
        XCTAssertEqual(audio.enqueued, [Data([5])])

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
        // a network round-trip. Nothing about enqueue()'s own timing is
        // on this path at all (it only affects the vadFireToPlaybackStopped
        // metric if the stamp itself moved, not through any playback
        // delay). A generous bound (well under real network RTT,
        // comfortably above pure scheduling noise) still exists to catch
        // a future regression that puts real async work back before the
        // stamp.
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

        XCTAssertTrue(audio.enqueued.isEmpty, "turn 1's stale audio must not be enqueued once turn 2 is active")
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

        XCTAssertEqual(audio.enqueued, [Data([2, 2, 2])], "turn 2's real reply must enqueue normally, unaffected by the discarded stale one")
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
        XCTAssertEqual(audio.enqueued.last, Data([1, 2, 3]))

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
            audio.enqueued.contains(Data([1, 2, 3])),
            "a late reply for an already-abandoned turn must never be enqueued"
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

    /// Issue #49 diagnostics: only actual mute changes are logged (AppModel's
    /// poll loop can re-assert the same value every tick), and the first
    /// captured chunk is logged once and counted even while muted.
    func testMuteChangesAndFirstCapturedChunkAreLoggedOnce() async {
        let coordinator = SessionCoordinator(connection: FakeConnection(), audio: FakeAudio(), vad: FakeVAD())

        await coordinator.setMuted(true)
        await coordinator.setMuted(true)
        await coordinator.setMuted(false)
        await coordinator.captureAudio(Data([1]))
        await coordinator.setMuted(true)
        await coordinator.captureAudio(Data([2]))

        let log = await coordinator.debugLog
        XCTAssertEqual(log.filter { $0.contains("setMuted: isMuted false -> true") }.count, 2)
        XCTAssertEqual(log.filter { $0.contains("setMuted: isMuted true -> false") }.count, 1)
        XCTAssertEqual(log.filter { $0.contains("captureAudio: first mic chunk received (isMuted=false") }.count, 1)
        XCTAssertEqual(log.filter { $0.contains("first mic chunk") }.count, 1)
        let chunks = await coordinator.capturedChunkCount
        XCTAssertEqual(chunks, 2, "muted chunks still count -- they reached the coordinator")
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
        XCTAssertEqual(audio.enqueued, [Data([1, 2, 3])])

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
        XCTAssertEqual(audio.enqueued, [Data([5, 6, 7])])
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
        XCTAssertEqual(audio.enqueued, [Data([1])])

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
        XCTAssertTrue(audio.enqueued.isEmpty)
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

    func testUpdateSettingsSendsTheLlmBackend() async {
        let connection = FakeConnection()
        let coordinator = SessionCoordinator(connection: connection, audio: FakeAudio(), vad: FakeVAD())
        let runLoop = Task { await coordinator.start() }

        await coordinator.updateSettings(targetTurns: 9, pageCount: 4, llmBackend: "groq")
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(
            connection.sentMessages,
            [.updateSettings(targetTurns: 9, pageCount: 4, llmBackend: "groq")]
        )
        runLoop.cancel()
    }

    func testUpdateSettingsSendsTheTtsVoice() async {
        let connection = FakeConnection()
        let coordinator = SessionCoordinator(connection: connection, audio: FakeAudio(), vad: FakeVAD())
        let runLoop = Task { await coordinator.start() }

        await coordinator.updateSettings(targetTurns: 9, pageCount: 4, llmBackend: "groq", ttsVoice: "bm_george")
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(
            connection.sentMessages,
            [.updateSettings(targetTurns: 9, pageCount: 4, llmBackend: "groq", ttsVoice: "bm_george")]
        )
        runLoop.cancel()
    }

    func testLlmBackendEventIsStoredAsLatestStatus() async {
        let connection = FakeConnection()
        let coordinator = SessionCoordinator(connection: connection, audio: FakeAudio(), vad: FakeVAD())
        let runLoop = Task { await coordinator.start() }

        connection.emit(.message(.llmBackend(
            LlmBackendStatus(requested: "groq", active: "groq", groqAvailable: true)
        )))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let status = await coordinator.latestLlmBackendStatus
        XCTAssertEqual(status, LlmBackendStatus(requested: "groq", active: "groq", groqAvailable: true))
        runLoop.cancel()
    }

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
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
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

        // Turn 2's own buffer genuinely finishes -- exactly ONE
        // finishOldestEnqueuedBuffer() call, which only resolves turn 2's
        // waitForPlaybackToFinish() if turn 1's discarded buffer is no
        // longer counted as outstanding. The machine now stays .speaking
        // through that wait (issue #28), so .idle below is what actually
        // proves it resolved; before, it went .idle at turnEnd regardless
        // and this assertion could never have caught a stuck wait.
        audio.finishOldestEnqueuedBuffer()
        await eventually { await coordinator.state == .idle }

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "turn 2 must complete normally -- turn 1's un-finished buffer must not leave stale outstanding state behind")

        runLoop.cancel()
    }

    // MARK: - Issue #28: barge-in during the pipelined playback tail

    /// Polls until `condition` holds (2s cap), instead of the fixed
    /// Task.sleep settling the rest of this file uses -- a fixed sleep is a
    /// race on a loaded machine, and for a barge-in test specifically it
    /// can also make the test pass for the wrong reason (barge-in landing
    /// before turnEnd was even handled takes the .speaking path, not the
    /// bug's). Callers still assert the final value, so a timeout fails
    /// with the real assertion's message.
    private func eventually(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Runs one turn up to the moment this bug lives in: the whole reply AND
    /// its turn_end have reached the coordinator while the buffer is still
    /// (simulated-)playing. audio.hasPlaybackWaiter is the signal that
    /// runTurn() has really processed turnEnd and is parked waiting for
    /// playback to finish -- the state the real device is in for the last
    /// several seconds of every reply.
    private func driveTurnToTheAudiblePlaybackTail(
        coordinator: SessionCoordinator, connection: FakeConnection, audio: FakeAudio, vad: FakeVAD, chunk: Data
    ) async {
        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        // handleSpeechEnd() flips the machine before it has created this
        // turn's event stream; nothing observable marks that later step, so
        // this one short settle sleep stays (same as every test above).
        try? await Task.sleep(nanoseconds: 10_000_000)

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(chunk))
        connection.emit(.message(.turnEnd(turnId: 1)))
        await eventually { audio.hasPlaybackWaiter }
    }

    /// Issue #28. The real server synthesizes far faster than real time (an
    /// entire multi-sentence reply, and its turn_end, can arrive within
    /// ~1-2s of the first chunk while the audio takes 5-8+s to actually
    /// play -- see session.py's _cancel_turn()), and since playback was
    /// pipelined (enqueue() per chunk, one waitForPlaybackToFinish() at
    /// turnEnd) the coordinator processes that turnEnd long before the
    /// audio has finished. handleSpeechStart() only takes the
    /// stop-playback path (interrupt()) from .waitingForReply/.speaking,
    /// so a child talking over the still-playing tail of the reply hit the
    /// ordinary "new utterance" path instead, which never stops playback:
    /// Elsie kept talking. autoFinishEnqueuedBuffers = false is what makes
    /// the fake reply "genuinely still playing" at this point, exactly
    /// like the real device's playerNode queue.
    func testBargeInAfterTurnEndWhileTheReplyIsStillPlayingStopsPlayback() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false // the reply is still audibly playing until the test says otherwise
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await driveTurnToTheAudiblePlaybackTail(
            coordinator: coordinator, connection: connection, audio: audio, vad: vad, chunk: Data([1, 2, 3])
        )
        XCTAssertTrue(audio.hasPlaybackWaiter, "precondition: turn_end has been handled and the reply is still playing")
        XCTAssertFalse(audio.stopped, "precondition: nothing has stopped playback yet")

        vad.fire(.speechStart) // the child talks over the tail of Elsie's reply
        await eventually { audio.stopped }

        XCTAssertTrue(audio.stopped, "a barge-in during the tail of a reply that is still playing must stop playback")
        await eventually { await coordinator.state == .listening }
        let state = await coordinator.state
        XCTAssertEqual(state, .listening)
        let history = await coordinator.latencyHistory
        XCTAssertEqual(history.count, 1, "the barge-in must show up in the on-screen VAD->stopped latency list")

        runLoop.cancel()
    }

    /// The same root cause, seen from the UI: StoryView's status line
    /// reads "Elsie is talking" for .speaking and "Ready when you are" for
    /// .idle, and it went to .idle as soon as the server's turn_end
    /// arrived -- a second or two into a reply that was still audibly
    /// playing for several more.
    func testStateStaysSpeakingUntilTheReplyHasFinishedPlayingThenReturnsToIdle() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await driveTurnToTheAudiblePlaybackTail(
            coordinator: coordinator, connection: connection, audio: audio, vad: vad, chunk: Data([1, 2, 3])
        )
        XCTAssertTrue(audio.hasPlaybackWaiter, "precondition: turn_end has been handled and the reply is still playing")

        var state = await coordinator.state
        XCTAssertEqual(state, .speaking, "turn_end has arrived but the audio is still playing -- Elsie is still talking")

        audio.finishOldestEnqueuedBuffer() // playback genuinely finishes
        await eventually { await coordinator.state == .idle }

        state = await coordinator.state
        XCTAssertEqual(state, .idle, "back to idle once the last buffer has actually finished")

        runLoop.cancel()
    }

    /// Barge-in during the tail must leave the coordinator able to run the
    /// next turn normally. The interrupted turn's runTurn() is suspended in
    /// waitForPlaybackToFinish() when the interrupt resets the audio; it
    /// resumes (cancelled) and unwinds, and none of that may disturb the
    /// turn that follows. (runTurn()'s `!Task.isCancelled` guard before
    /// applying turnEnd is defensive: FakeAudio, like the real tracker,
    /// resumes the waiter synchronously on stop, so a cancelled turn
    /// resuming AFTER a newer turn started is not reachable from here.)
    func testBargeInDuringThePlaybackTailThenNewTurnCompletesNormally() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await driveTurnToTheAudiblePlaybackTail(
            coordinator: coordinator, connection: connection, audio: audio, vad: vad, chunk: Data([1])
        )

        vad.fire(.speechStart) // barge-in during the tail -- turn 2
        await eventually { audio.stopped }
        XCTAssertTrue(audio.stopped)
        // The interrupted turn's runTurn() has resumed and unwound: it logs
        // this line the moment its wait returns, and everything after that
        // line runs without another suspension.
        await eventually { await coordinator.debugLog.contains { $0.contains("waitForPlaybackToFinish() took") } }

        audio.autoFinishEnqueuedBuffers = true
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        try? await Task.sleep(nanoseconds: 10_000_000) // handleSpeechEnd() creates turn 2's stream just after the state flip
        var state = await coordinator.state
        XCTAssertEqual(state, .waitingForReply, "turn 1's unwinding must not walk turn 2 back to idle")

        connection.emit(.message(.responseText("hi again", turnId: 2)))
        connection.emit(.audio(Data([2])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        await eventually { await coordinator.state == .idle }

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(audio.enqueued, [Data([1]), Data([2])], "turn 2's audio must reach playback normally")

        runLoop.cancel()
    }

    // MARK: - Issue #47: talking over the concluding reply

    /// Shared setup for the #47 tests: the ditty is configured (with a paced
    /// play() so a wrongly-started loop iterates a few times instead of
    /// spinning) because "a ditty started over The End" is half of the bug.
    private func makeConcludedStoryFixture() -> (
        coordinator: SessionCoordinator, connection: FakeConnection, audio: FakeAudio, vad: FakeVAD
    ) {
        let connection = FakeConnection()
        let audio = FakeAudio()
        audio.autoFinishEnqueuedBuffers = false // the concluding reply is audibly playing until the test says otherwise
        audio.playDelayNanos = 5_000_000
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad, waitingDittyAudio: Data([0xAA, 0xBB])
        )
        return (coordinator, connection, audio, vad)
    }

    /// One whole concluding turn in the real wire order, up to The End being
    /// ready. Needs instant playback (autoFinishEnqueuedBuffers = true).
    private func driveConcludingTurnToTheEnd(
        coordinator: SessionCoordinator, connection: FakeConnection, vad: FakeVAD
    ) async {
        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        try? await Task.sleep(nanoseconds: 10_000_000) // handleSpeechEnd() creates the turn's stream just after the state flip
        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        await eventually { await coordinator.readyToShowTheEnd }
    }

    /// Order A. The real wire order is audio..., turn_end, rewriting_started,
    /// and the server synthesizes far faster than real time, so a child
    /// talking over the concluding reply almost always does so after BOTH
    /// have been consumed. Base behavior: the cancelled runTurn still called
    /// noteTurnPlaybackFinished() as it unwound, so The End did appear --
    /// but the barge-in went out as an `interrupt` the server ignores
    /// (REWRITING), the child's utterance became a turn nobody answers, and
    /// its waiting ditty looped over The End.
    func testBargeInOverTheConcludingReplyAfterRewritingStartedShowsTheEndAndStartsNoUtterance() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        let runLoop = Task { await coordinator.start() }

        await driveTurnToTheAudiblePlaybackTail(
            coordinator: coordinator, connection: connection, audio: audio, vad: vad, chunk: Data([1, 2, 3])
        )
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        await eventually { await coordinator.isRewriting }
        var ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "precondition: the concluding reply is still playing")

        vad.fire(.speechStart) // the child talks over the ending
        await eventually { await coordinator.readyToShowTheEnd }
        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "talking over the concluding reply must stop it and let The End appear")
        // (FakeAudio.stopped can't say this: stopping the turn-1 ditty already set it.)
        XCTAssertFalse(audio.hasPlaybackWaiter, "the concluding reply must stop the moment the child talks over it")

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 30_000_000) // room for a wrongly-started ditty to play
        let playedAtTheEnd = audio.played.count
        try? await Task.sleep(nanoseconds: 30_000_000)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "no utterance may start once the story has concluded -- nothing would ever answer it")
        XCTAssertEqual(
            connection.sentMessages, [.speechStart(turnId: 1), .speechEnd],
            "the server ignores everything sent during REWRITING -- an interrupt/speech_end here is a message into the void"
        )
        XCTAssertEqual(audio.played.count, playedAtTheEnd, "no waiting ditty may loop over The End")

        runLoop.cancel()
    }

    /// Order B. The barge-in lands before the concluding turn's turn_end has
    /// reached the client: it is sent as an ordinary interrupt (the client
    /// cannot know yet), turn_end is then discarded as stale, and
    /// rewriting_started arrives afterwards. Base behavior: nothing ever set
    /// currentTurnPlaybackFinished, so readyToShowTheEnd stayed false for
    /// good (The End never appeared) and the child's utterance became a
    /// turn nobody answers, its ditty looping until the timeout.
    func testBargeInBeforeTheConcludingTurnEndArrivesStillShowsTheEndOnceRewritingStarts() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        try? await Task.sleep(nanoseconds: 10_000_000) // handleSpeechEnd() creates the turn's stream just after the state flip
        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        await eventually { await coordinator.state == .speaking }

        vad.fire(.speechStart) // barge-in, before turn_end has arrived
        await eventually { connection.sentMessages.contains(.interrupt(turnId: 2)) }
        // What the server does next: it has already entered REWRITING (so it
        // ignored that interrupt) and its concluding turn_end and
        // rewriting_started are already on the wire.
        connection.emit(.message(.turnEnd(turnId: 1)))
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))

        await eventually { await coordinator.readyToShowTheEnd }
        var ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "the concluding turn was cut off by the barge-in; its stale turn_end must not leave The End unreachable")
        var state = await coordinator.state
        XCTAssertEqual(state, .idle, "the barge-in utterance can never be answered once the story has concluded")

        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let playedAtTheEnd = audio.played.count
        try? await Task.sleep(nanoseconds: 30_000_000)
        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            connection.sentMessages, [.speechStart(turnId: 1), .speechEnd, .interrupt(turnId: 2)],
            "the abandoned utterance must not be finished toward a server that ignores it"
        )
        XCTAssertEqual(audio.played.count, playedAtTheEnd, "no waiting ditty may loop over The End")
        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready)

        runLoop.cancel()
    }

    /// The other interleaving of the same race: turn_end was already
    /// consumed, the barge-in went out as an ordinary interrupt, and the
    /// child's whole utterance was already finished (speech_end sent, ditty
    /// looping, currentTurnPlaybackFinished reset by that new turn) when
    /// rewriting_started finally arrived.
    func testRewritingStartedAfterABargeInUtteranceWasAlreadySentAbandonsItAndShowsTheEnd() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        let runLoop = Task { await coordinator.start() }

        await driveTurnToTheAudiblePlaybackTail(
            coordinator: coordinator, connection: connection, audio: audio, vad: vad, chunk: Data([1, 2, 3])
        )
        vad.fire(.speechStart) // barge-in, before rewriting_started has arrived
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        try? await Task.sleep(nanoseconds: 20_000_000) // the new turn's ditty is looping
        var ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "precondition: rewriting_started has not arrived yet")

        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        await eventually { await coordinator.readyToShowTheEnd }

        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "the turn the server is going to ignore must be abandoned, not left waiting for a reply")
        let playedAtTheEnd = audio.played.count
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(audio.played.count, playedAtTheEnd, "the ditty for that abandoned turn must stop")

        runLoop.cancel()
    }

    /// The client half of issue #32 for speech: once rewriting_started has
    /// arrived the server drops every speech_start/audio/speech_end, so the
    /// client must not send them (and must not then sit in .waitingForReply
    /// with a ditty). This is the plain case -- the concluding reply already
    /// finished playing, The End has not been navigated to yet.
    func testSpeechAfterTheStoryConcludedIsNotSentToTheServer() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        audio.autoFinishEnqueuedBuffers = true // the concluding reply plays out instantly
        let runLoop = Task { await coordinator.start() }

        await driveConcludingTurnToTheEnd(coordinator: coordinator, connection: connection, vad: vad)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "precondition: the concluding reply has finished playing")

        vad.fire(.speechStart)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let playedAfterSpeech = audio.played.count
        try? await Task.sleep(nanoseconds: 30_000_000)

        let stateAfterSpeech = await coordinator.state
        XCTAssertEqual(stateAfterSpeech, .idle)
        XCTAssertEqual(connection.sentMessages, [.speechStart(turnId: 1), .speechEnd], "nothing the child says after the conclusion may reach the server")
        XCTAssertEqual(audio.played.count, playedAfterSpeech, "no ditty for an utterance that was never started")

        runLoop.cancel()
    }

    /// Guards the other direction: the suppression above must end with the
    /// rewrite, or a child who is still on the story screen after
    /// rewriting_done (the server is IDLE again) would be ignored for good.
    func testSpeechIsSentAgainOnceTheRewriteIsDone() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        audio.autoFinishEnqueuedBuffers = true
        let runLoop = Task { await coordinator.start() }

        await driveConcludingTurnToTheEnd(coordinator: coordinator, connection: connection, vad: vad)
        connection.emit(.message(.rewritingDone))
        await eventually { await coordinator.isRewriting == false }

        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }

        let state = await coordinator.state
        XCTAssertEqual(state, .listening, "speech must work again once the rewrite is done")
        XCTAssertEqual(connection.sentMessages.last, .speechStart(turnId: 2))

        runLoop.cancel()
    }

    /// Guards against the new "abandon it" rule over-firing: in the real
    /// wire order (turn_end, then rewriting_started) the two can be
    /// consumed back to back while runTurn() has barely started on the
    /// reply. That concluding turn is still the CURRENT turn and must play
    /// out untouched.
    func testConcludingReplyIsNotAbandonedWhenTurnEndAndRewritingStartedArriveBackToBack() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        try? await Task.sleep(nanoseconds: 10_000_000)
        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        await eventually { audio.hasPlaybackWaiter }

        var ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "the reply is still playing")
        let state = await coordinator.state
        XCTAssertEqual(state, .speaking, "the concluding turn must not be abandoned")

        audio.finishOldestEnqueuedBuffer()
        await eventually { await coordinator.readyToShowTheEnd }
        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready)

        runLoop.cancel()
    }

    /// The "New Story" half of issue #32 (the speech half is covered by
    /// testSpeechAfterTheStoryConcludedIsNotSentToTheServer above): tapping
    /// New Story while a rewrite is genuinely still in progress must not
    /// pretend it succeeded. Before this fix, newStory() unconditionally
    /// reset isRewriting/readyToShowTheEnd to false and sent .newStory
    /// regardless of server reality -- the server's own REWRITING gate
    /// (session.py's handle_new_story()) silently ignores that message, so
    /// the client was left believing a fresh story had started while the
    /// server was still finishing the old one. The next utterance then hit
    /// the server's silent speech_start no-op with nothing to catch it
    /// locally (handleSpeechStart()'s isRewriting guard sees isRewriting ==
    /// false), reproducing the original silent hang.
    func testNewStoryDuringRewriteDoesNotResetStateOrSendNewStory() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        audio.autoFinishEnqueuedBuffers = true
        let runLoop = Task { await coordinator.start() }

        await driveConcludingTurnToTheEnd(coordinator: coordinator, connection: connection, vad: vad)
        let sentBeforeTap = connection.sentMessages

        await coordinator.newStory()

        let rewriting = await coordinator.isRewriting
        XCTAssertTrue(rewriting, "a New Story tap must not pretend a still-running rewrite has finished")
        let ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "The End's readiness must survive a New Story tap the server is going to ignore")
        XCTAssertEqual(connection.sentMessages, sentBeforeTap, "no .newStory may be sent while the server would just ignore it")

        runLoop.cancel()
    }

    /// Guards the other direction, mirroring testSpeechIsSentAgainOnceTheRewriteIsDone:
    /// the suppression above must end with the rewrite, or New Story would
    /// stay broken for good even after the server is genuinely IDLE again.
    func testNewStoryWorksAgainOnceTheRewriteIsDone() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        audio.autoFinishEnqueuedBuffers = true
        let runLoop = Task { await coordinator.start() }

        await driveConcludingTurnToTheEnd(coordinator: coordinator, connection: connection, vad: vad)
        connection.emit(.message(.rewritingDone))
        await eventually { await coordinator.isRewriting == false }

        await coordinator.newStory()

        XCTAssertEqual(connection.sentMessages.last, .newStory, "New Story must work again once the rewrite is done")
        let ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "a genuinely fresh story must reset The End's readiness")

        runLoop.cancel()
    }

    /// Issue #64: AppModel reads readyToShowTheEnd as "the live story is
    /// over" (StoryEntry's liveStoryConcluded) when Library's "+" tile is
    /// tapped -- which, on the Read-it-now path, is long after the rewrite
    /// finished. It must still say so then, or "+" would resume the
    /// finished story instead of starting a new one.
    func testReadyToShowTheEndStaysLatchedAfterTheRewriteFinishes() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        audio.autoFinishEnqueuedBuffers = true
        let runLoop = Task { await coordinator.start() }

        await driveConcludingTurnToTheEnd(coordinator: coordinator, connection: connection, vad: vad)
        connection.emit(.message(.rewritingDone))
        await eventually { await coordinator.isRewriting == false }

        let ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "only newStory() may un-latch it, not the rewrite finishing")

        runLoop.cancel()
    }

    /// PR #67 on-device step 4: a coordinator that connects while the
    /// server is still REWRITING the PREVIOUS story gets that story's
    /// rewriting_started from resend_current_status(). Once the rewrite
    /// finishes and the child tells a new story, its first ordinary
    /// turn_end must not combine with that stale rewriting_started --
    /// base behavior latched readyToShowTheEnd mid-story, so Library's "+"
    /// treated the live story as finished and started a new one over it.
    func testRewritingStartedFromBeforeThisStoryNeverCombinesWithALaterOrdinaryTurn() async {
        let (coordinator, connection, audio, vad) = makeConcludedStoryFixture()
        audio.autoFinishEnqueuedBuffers = true
        let runLoop = Task { await coordinator.start() }

        connection.emit(.message(.rewritingStarted(storyId: nil, epilogue: nil)))
        await eventually { await coordinator.isRewriting }
        connection.emit(.message(.rewritingDone))
        await eventually { await coordinator.isRewriting == false }

        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.state == .waitingForReply }
        try? await Task.sleep(nanoseconds: 10_000_000) // handleSpeechEnd() creates the turn's stream just after the state flip
        connection.emit(.message(.responseText("Once upon a time.", turnId: 1)))
        connection.emit(.audio(Data([1])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        await eventually { await coordinator.state == .idle }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "an ordinary turn of a new story is not The End")

        runLoop.cancel()
    }

    // MARK: - Issue #48: the last error goes stale when the next turn starts

    /// Drives a turn to the ditty timeout, which sets the sticky "took too
    /// long thinking" error and lands back in .idle.
    private func driveATurnToTheDittyTimeout(
        coordinator: SessionCoordinator, vad: FakeVAD
    ) async {
        vad.fire(.speechStart)
        await eventually { await coordinator.state == .listening }
        vad.fire(.speechEnd)
        await eventually { await coordinator.lastErrorMessage != nil }
        await eventually { await coordinator.state == .idle }
    }

    /// AppModel's poll loop can only show a repeat of the SAME error text
    /// (timing out twice in a row) if the coordinator's value goes back to
    /// nil in between -- and the error the child was just told about ("say
    /// something to wake them up") is stale the moment they do.
    func testLastErrorMessageClearsWhenTheChildStartsTheNextTurn() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad,
            waitingDittyAudio: Data([0xAA, 0xBB]), dittyTimeoutSeconds: 0.03
        )
        let runLoop = Task { await coordinator.start() }

        await driveATurnToTheDittyTimeout(coordinator: coordinator, vad: vad)
        var error = await coordinator.lastErrorMessage
        XCTAssertNotNil(error, "precondition: the ditty timeout set an error")

        vad.fire(.speechStart) // the child says something, as the message asked
        await eventually { await coordinator.lastErrorMessage == nil }
        error = await coordinator.lastErrorMessage
        XCTAssertNil(error, "an error from the previous turn is stale once a new turn begins")

        vad.fire(.speechEnd) // ...and this turn times out too, with the very same text
        await eventually { await coordinator.lastErrorMessage != nil }
        error = await coordinator.lastErrorMessage
        XCTAssertNotNil(error, "a repeat of the same error must be visible again, not swallowed as 'unchanged'")

        runLoop.cancel()
    }

    func testConcludeStoryClearsTheLastError() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(
            connection: connection, audio: audio, vad: vad,
            waitingDittyAudio: Data([0xAA, 0xBB]), dittyTimeoutSeconds: 0.03
        )
        let runLoop = Task { await coordinator.start() }

        await driveATurnToTheDittyTimeout(coordinator: coordinator, vad: vad)
        var error = await coordinator.lastErrorMessage
        XCTAssertNotNil(error, "precondition: the ditty timeout set an error")

        await coordinator.concludeStory() // "Finish this story" starts a turn of its own
        error = await coordinator.lastErrorMessage
        XCTAssertNil(error)

        runLoop.cancel()
    }
}
