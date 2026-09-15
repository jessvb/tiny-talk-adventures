# Library & Reading Screens Real-Data Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `LibraryView`, Landing's "Read Stories" button, and `ReadingView`'s page-audio button to the real `list_stories`/`get_story`/`synthesize_page` server APIs, replacing `MockStories.swift` for these paths.

**Architecture:** Server-side needs zero changes — all three APIs already exist and are tested. All work is iOS-side: (1) a small new wire-protocol surface (`synthesizePage`/`pageAudioDone`, mirroring the already-shipped `getPageImage`/`pageImageDone`), (2) a `SessionCoordinator` mechanism for page audio that streams each chunk straight into playback rather than buffering (unlike the single-frame image case), and (3) `AppModel`/View-layer wiring that reuses the exact fetch-placeholder-then-resolve pattern PR #17 already established for The End screen.

**Tech Stack:** Swift, SwiftUI, Swift Concurrency (actors), XCTest, Swift Package Manager (`ios/TinyTalkCore`).

**Spec:** `docs/superpowers/specs/2026-09-15-library-reading-screens-design.md`

## Global Constraints

- No server-side changes anywhere in this plan — `list_stories`, `get_story`, `synthesize_page` are already implemented and tested server-side.
- No "seam" or placeholder work for illustrations — `ReadingView`'s image rendering (PR #27) already works generically off real `SavedStoryDetail` data; nothing in this plan touches image code.
- Reading's audio interaction model does not change: manual tap-per-page 🔊, stops on page change, no auto-advance.
- `pendingPageAudioRequest` is a single optional value, not a queue — audio's manual tap-per-page model never has more than one request in flight (unlike images, which prefetch every page at once).
- Each arriving audio chunk is enqueued to playback immediately as it arrives (streaming), not buffered into one blob and played after the fact.

---

### Task 1: Protocol — `synthesizePage` / `pageAudioDone` wire types

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: nothing new — mirrors the existing `.getPageImage`/`.pageImageDone` pattern already in this file.
- Produces: `ClientMessage.synthesizePage(storyId: String, pageIndex: Int)` (with `.encode()` support), `ServerEvent.pageAudioDone(storyId: String, pageIndex: Int)` (with `decodeServerEvent(_:)` support). Task 2 consumes both.

- [ ] **Step 1: Write the failing encode test**

Add to `ProtocolTests.swift`, right after `testGetPageImageEncodesStoryIdAndPageIndex()`:

```swift
    func testSynthesizePageEncodesStoryIdAndPageIndex() {
        XCTAssertEqual(
            ClientMessage.synthesizePage(storyId: "abcd1234", pageIndex: 2).encode(),
            #"{"type":"synthesize_page","story_id":"abcd1234","page_index":2}"#
        )
    }
```

- [ ] **Step 2: Write the failing decode tests**

Add to `ProtocolTests.swift`, right after `testDecodesPageImageDoneWithoutImage()`:

```swift
    func testDecodesPageAudioDone() throws {
        let event = try decodeServerEvent(
            #"{"type": "page_audio_done", "story_id": "abcd1234", "page_index": 1}"#
        )
        XCTAssertEqual(event, .pageAudioDone(storyId: "abcd1234", pageIndex: 1))
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests/testSynthesizePageEncodesStoryIdAndPageIndex`
Expected: FAIL to build — `ClientMessage` has no member `synthesizePage`.

- [ ] **Step 4: Add the `ClientMessage.synthesizePage` case**

In `Protocol.swift`, add the case right after `getPageImage` in the `ClientMessage` enum (after line 58):

```swift
    /// Request on-demand TTS audio for one saved-story page -- see
    /// protocol.py's SynthesizePage. Streams multiple binary audio chunks
    /// (unlike getPageImage's single frame), terminated by a
    /// page_audio_done marker -- see ServerEvent.pageAudioDone.
    case synthesizePage(storyId: String, pageIndex: Int)
```

Add the matching encoder case right after the `getPageImage` case in `encode()` (after line 100):

```swift
        case .synthesizePage(let storyId, let pageIndex):
            return #"{"type":"synthesize_page","story_id":"\#(Self.jsonEscaped(storyId))","page_index":\#(pageIndex)}"#
```

- [ ] **Step 5: Add the `ServerEvent.pageAudioDone` case**

Add the case right after `pageImageDone` in the `ServerEvent` enum (after line 146):

```swift
    /// All of this page's audio chunks have been sent as binary frames --
    /// see protocol.py's encode_page_audio_done(). Unlike pageImageDone,
    /// carries no hasImage-equivalent flag: synthesize_page always
    /// produces audio for non-empty page text (no safety-check discard
    /// path exists for TTS the way there is for illustrations).
    case pageAudioDone(storyId: String, pageIndex: Int)
```

Add the matching decode case in `decodeServerEvent(_:)`'s `switch type`, right after `"page_image_done"` (after line 190):

```swift
        case "page_audio_done":
            return .pageAudioDone(
                storyId: json["story_id"] as? String ?? "",
                pageIndex: json["page_index"] as? Int ?? 0
            )
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests`
Expected: PASS, all tests including the three new ones.

- [ ] **Step 7: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift
git commit -m "feat(ios): add synthesizePage/pageAudioDone wire types"
```

---

### Task 2: SessionCoordinator — page-audio request + streaming playback

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1's `ClientMessage.synthesizePage`/`ServerEvent.pageAudioDone`. `AudioPlaying`'s existing `enqueue(_ pcm: Data) async` and `stopPlaybackImmediately()` (both already used elsewhere in this file).
- Produces: `SessionCoordinator.synthesizePage(storyId: String, pageIndex: Int) async`, `SessionCoordinator.stopPageAudio() async`. Task 7 consumes both.

- [ ] **Step 1: Write the failing "sends request, streams chunks to playback" test**

Add to `SessionCoordinatorTests.swift`, right after `testConnectionLostViaSendFailureClearsStuckPendingPageImageRequestSoLiveAudioStillPlays()`:

```swift
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
```

- [ ] **Step 2: Write the failing "doesn't divert live-turn audio" regression test**

```swift
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
```

- [ ] **Step 3: Write the failing "stopPageAudio clears pending state and stops playback" test**

```swift
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
```

- [ ] **Step 4: Write the failing "unrelated error clears stuck pending page-audio request" test**

```swift
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
```

- [ ] **Step 5: Write the failing "send failure clears pending state" test**

```swift
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
```

- [ ] **Step 6: Write the failing "connection lost via send failure" test**

Distinct from Step 5: that one exercises `synthesizePage()`'s own send-failure catch block. This one mirrors `testConnectionLostViaSendFailureClearsStuckPendingPageImageRequestSoLiveAudioStillPlays` exactly — a send failure on a DIFFERENT, later call (`speechStart`) routes through `handleConnectionLost()`, which must independently clear `pendingPageAudioRequest` too (Step 13 below), since `consumeServerEvents()` keeps running afterward (this is not the `.closed` path).

```swift
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
```

- [ ] **Step 7: Run tests to verify they all fail**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests/testSynthesizePageStreamsEachChunkToPlaybackAsItArrives`
Expected: FAIL to build — `SessionCoordinator` has no member `synthesizePage`/`stopPageAudio`.

- [ ] **Step 8: Add `pendingPageAudioRequest` state**

In `SessionCoordinator.swift`, add right after `pendingPageImageBytes`'s declaration (after line 183):

```swift
    /// The single in-flight synthesizePage() request, if any -- see
    /// getPageImage()'s pendingPageImageRequests for why THAT one is a
    /// queue. This one is a single optional, not a queue: ReadingView's
    /// manual tap-per-page 🔊 model (no prefetch-all-pages, unlike images)
    /// means at most one page-audio request is ever genuinely in flight at
    /// once. Checked before the turn-scoped isCurrentTurnAudio gate in
    /// consumeServerEvents(), same placement as pendingPageImageRequests,
    /// so incoming page audio isn't silently dropped or misrouted as
    /// live-turn audio. Cleared by stopPageAudio(), by an unrelated error
    /// (mirrors the image case), by handleConnectionLost(), and by
    /// matching page_audio_done marker.
    private var pendingPageAudioRequest: (storyId: String, pageIndex: Int)?
```

- [ ] **Step 9: Add the `synthesizePage()` and `stopPageAudio()` methods**

Add right after `getPageImage()` (after line 1009):

```swift
    /// See protocol.py's SynthesizePage. Fire-and-forget; each chunk is
    /// enqueued to playback as it arrives (see consumeServerEvents()'s
    /// .audio handling) -- unlike getPageImage, there is no result to poll,
    /// since this plays audio rather than producing data a UI reads back.
    public func synthesizePage(storyId: String, pageIndex: Int) async {
        pendingPageAudioRequest = (storyId: storyId, pageIndex: pageIndex)
        do {
            try await connection.send(.synthesizePage(storyId: storyId, pageIndex: pageIndex))
        } catch {
            // Mirrors getPageImage()'s send-failure cleanup: this request
            // never reached the server, so nothing will ever arrive to
            // resolve it -- clear it now rather than leaving it stuck,
            // which would permanently divert later live-turn audio into
            // playback-as-page-audio (see the .audio branch below).
            if pendingPageAudioRequest?.storyId == storyId, pendingPageAudioRequest?.pageIndex == pageIndex {
                pendingPageAudioRequest = nil
            }
        }
    }

    /// What ReadingView calls when the child swipes to a new page or
    /// leaves Reading while a page's audio is still playing/pending --
    /// mirrors AVSpeechSynthesizer.stopSpeaking(at: .immediate)'s old
    /// role. Must clear pendingPageAudioRequest, not just stop playback:
    /// otherwise a chunk still in flight from the just-abandoned request
    /// would reach consumeServerEvents()'s .audio branch, see the (now
    /// stale) pending request, and start playing again moments after the
    /// child already left the page.
    public func stopPageAudio() async {
        pendingPageAudioRequest = nil
        audio.stopPlaybackImmediately()
    }
```

- [ ] **Step 10: Route `.audio` frames to playback while a page-audio request is pending**

In `consumeServerEvents()`, modify the `.audio` handling (lines 668-683) to add the new branch between the existing image check and the turn-scoped gate:

```swift
            if case .audio(let data) = event {
                if !pendingPageImageRequests.isEmpty {
                    // Assumes the server sends a requested page image as
                    // exactly one binary frame -- if that ever changes to
                    // multiple chunks, this would need to accumulate them
                    // instead of overwriting. Safe to stash in this single
                    // slot even with multiple requests in flight: see
                    // pendingPageImageBytes' own doc comment for the FIFO
                    // guarantee that makes this correct.
                    pendingPageImageBytes = data
                    continue
                }
                if pendingPageAudioRequest != nil {
                    // Unlike images, streamed straight to playback rather
                    // than stashed -- see pendingPageAudioRequest's doc
                    // comment. Safe to check after the image-queue branch
                    // above: the server processes one message at a time to
                    // completion (see pendingPageImageRequests' doc
                    // comment), so any earlier-sent getPageImage requests
                    // fully resolve before a later-sent synthesizePage's
                    // bytes ever start arriving -- these two branches never
                    // actually race for the same frame.
                    await audio.enqueue(data)
                    continue
                }
                guard isCurrentTurnAudio else { continue }
                turnContinuation?.yield(event)
                continue
            }
```

- [ ] **Step 11: Clear pending page-audio state on an unrelated error**

Modify the error-cleanup block (lines 685-710) to also cover `pendingPageAudioRequest`:

```swift
            if case .message(.error) = event, !pendingPageImageRequests.isEmpty || pendingPageAudioRequest != nil {
                // A get_page_image or synthesize_page failure is reported
                // as a generic error frame with no way to correlate it back
                // to a specific pending request -- see
                // pendingPageImageRequests' doc comment. ANY error while
                // either kind of request is pending is treated as a
                // safe-to-clear signal for both: worst case a page's image
                // or audio just never shows up/plays, which is far better
                // than leaving either stuck forever, permanently diverting
                // every later .audio frame away from live-turn playback.
                // Deliberately does NOT `continue`: the error frame itself
                // still needs to fall through to normal turn-scoped error
                // handling below, unchanged.
                pendingPageImageRequests.removeAll()
                pendingPageImageBytes = nil
                pendingPageAudioRequest = nil
            }
```

- [ ] **Step 12: Add the `pageAudioDone` resolution case**

In `consumeServerEvents()`'s story-lifecycle switch, add right after the `.message(.pageImageDone(...))` case (after line 761, before `default: break`):

```swift
            case .message(.pageAudioDone(let storyId, let pageIndex)):
                // No turn_id, same as the other story-lifecycle events
                // above. Unlike pageImageDone, there is no bytes buffer to
                // consume here -- every chunk already reached playback
                // directly in the .audio branch above. This just clears
                // the pending marker once the matching request's audio is
                // fully sent, so a later unrelated error (see above) no
                // longer needs to guard against clearing a request that's
                // already finished.
                if pendingPageAudioRequest?.storyId == storyId, pendingPageAudioRequest?.pageIndex == pageIndex {
                    pendingPageAudioRequest = nil
                }
                continue
```

- [ ] **Step 13: Add `.message(.pageAudioDone)` to the turn_id-extraction switch's unreachable case**

Modify the second `switch event` in `consumeServerEvents()` (lines 766-779) to include the new case, since it's already handled above:

```swift
            let eventTurnId: Int
            switch event {
            case .message(.transcriptPartial(_, let turnId)),
                 .message(.transcriptFinal(_, let turnId)),
                 .message(.responseText(_, let turnId)),
                 .message(.turnEnd(let turnId)),
                 .message(.error(_, let turnId)):
                eventTurnId = turnId
            case .audio, .closed,
                 .message(.rewritingStarted), .message(.rewritingDone),
                 .message(.storyList), .message(.storyDetail),
                 .message(.pageImageDone), .message(.pageAudioDone):
                fatalError("unreachable: handled above")
            }
```

- [ ] **Step 14: Clear pending page-audio state on disconnect**

Modify `handleConnectionLost(reason:)` (lines 575-613) to also clear `pendingPageAudioRequest`, right after the existing `pendingPageImageBytes = nil` (line 596):

```swift
        pendingPageImageRequests.removeAll()
        pendingPageImageBytes = nil
        // A lost connection means no page_audio_done marker (or further
        // chunks) for any pending synthesizePage() request will ever
        // arrive either -- same reasoning as the image case just above.
        pendingPageAudioRequest = nil
```

- [ ] **Step 15: Run tests to verify they all pass**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests`
Expected: PASS, all tests including the five new ones, and no regressions in the existing page-image/live-turn tests.

- [ ] **Step 16: Run the full package test suite**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, full suite green (no regressions elsewhere from the two switch statements changing).

- [ ] **Step 17: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift
git commit -m "feat(ios): stream synthesize_page audio to playback in SessionCoordinator"
```

---

### Task 3: AppModel — generalize story-detail fetch, populate `libraryStories`

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`

**Interfaces:**
- Consumes: nothing new — `SessionCoordinator.listStories()`/`getStory(storyId:)` already exist and are already used by this file.
- Produces: `AppModel.openStory(_ summary: SavedStorySummary)`, `AppModel.refreshLibrary()`. Task 4 consumes both. The renamed `pendingStoryDetailFetchId` is private to this file.

This app target (`TinyTalkApp`, not the `TinyTalkCore` package) has no unit test suite — confirmed no `AppModelTests.swift` exists anywhere in the repo. Verification for this task is a build check plus the on-device test script at the end of this plan, matching how every other `AppModel`/View change in this codebase is verified.

- [ ] **Step 1: Rename `pendingTheEndDetailStoryId` to `pendingStoryDetailFetchId`**

In `AppModel.swift`, this flag is about to be shared by both The End's automatic fetch and Library's manual fetch (Task 4) -- rename it everywhere it appears so the name doesn't lie about scope. Replace the declaration (lines 165-169):

```swift
    /// Set the instant a story-detail fetch is kicked off -- either
    /// automatically (a story just concluded, see the readyToShowTheEnd
    /// handling below) or manually (a Library card tap, see openStory()
    /// below) -- and cleared once the matching storyDetail arrives. Guards
    /// against starting a second fetch while one is already in flight (see
    /// both call sites). Reset on disconnect() for the same reason as
    /// pendingTheEndLookup: a torn-down coordinator can never deliver on it.
    private var pendingStoryDetailFetchId: String?
```

Replace the reset in `disconnect()` (line 504):

```swift
        pendingStoryDetailFetchId = nil
```

Replace all three occurrences in `startPollingState()`'s poll loop (lines 855-856, 878-879, 904-905) -- same logic, only the name changes:

```swift
                    if let newest = storyList?.first,
                       newest.id != self.lastAcknowledgedConcludedStoryId,
                       self.pendingStoryDetailFetchId == nil {
                        self.pendingStoryDetailFetchId = newest.id
                        self.lastAcknowledgedConcludedStoryId = newest.id
```

```swift
                    if let storyDetail, storyDetail.id == self.pendingStoryDetailFetchId {
                        self.pendingStoryDetailFetchId = nil
                        self.selectedStory = storyDetail
                    } else if let storyDetail, self.screen == .theEnd, storyDetail.id == self.selectedStory?.id {
                        self.selectedStory = storyDetail
                    }
```

```swift
                    if self.previousIsRewriting, !rewriting, self.screen == .theEnd,
                       let storyId = self.selectedStory?.id, self.pendingStoryDetailFetchId == nil {
                        self.pendingStoryDetailFetchId = storyId
                        Task { await coordinator.getStory(storyId: storyId) }
                    }
```

- [ ] **Step 2: Populate `libraryStories` from the existing poll loop**

In `startPollingState()`'s `MainActor.run` block, add right after `self.isRewriting = rewriting` (after line 833):

```swift
                    self.isRewriting = rewriting

                    // Library's real data source: every listStories()
                    // response (fired today by the readyToShowTheEnd
                    // trigger below, handleAppForegrounded(), connect()'s
                    // initial fetch, and refreshLibrary() below) lands
                    // here -- nothing about this assignment cares which
                    // trigger caused it.
                    if let storyList {
                        self.libraryStories = storyList
                    }
```

- [ ] **Step 3: Clear a stuck pending fetch on a real server error**

In the same block, modify the existing error handling (lines 910-916) so a `getStory()` failure (e.g. a stale poll race hitting an unknown story id) doesn't leave `pendingStoryDetailFetchId` stuck forever, which would silently block all future story-detail fetches (both The End's and Library's):

```swift
                    // Only overwrite with a real server error -- a nil here
                    // just means "no server error yet," and must not erase
                    // a client-side error (e.g. audio capture failing to
                    // start) that connect() already surfaced.
                    if let errorMessage {
                        self.lastErrorMessage = errorMessage
                        // A pending story-detail fetch can never be
                        // resolved by an error frame (no story_detail will
                        // follow it) -- clear it so a stale, permanently-
                        // unresolvable fetch doesn't block every future
                        // Library tap or The End auto-navigation.
                        self.pendingStoryDetailFetchId = nil
                    }
```

This is a deliberate scope decision, not a placeholder: the spec calls for "a couldn't-open-this-story state rather than hanging forever." A dedicated Reading-screen error message would need to distinguish "still loading" from "genuinely failed" (`ReadingView`'s existing blank fallback covers both today, since a fresh placeholder also has empty `pages`), which in turn needs new published state — real scope for a path that requires a story to vanish server-side between being listed and being tapped, which nothing in this codebase can even cause yet. This fix already delivers the important half (no permanent hang: `lastErrorMessage`'s existing app-wide banner surfaces the failure, and future taps/auto-navigation work normally again) without inventing loading-vs-error UI for a case that can't currently occur. Revisit if a real delete-story feature ever makes this reachable.

- [ ] **Step 4: Add `openStory(_:)` and `refreshLibrary()`**

Add these two new methods right after `requestPageImage(storyId:pageIndex:)` (after line 582):

```swift
    /// What LibraryView calls when the child taps a `.done` story card --
    /// mirrors the automatic fetch startPollingState() already does when a
    /// story concludes (see pendingStoryDetailFetchId's doc comment): show
    /// a pending placeholder immediately, navigate, then let the poll loop
    /// overwrite selectedStory once the real detail arrives. Guards against
    /// stomping an already-in-flight fetch, same as the automatic trigger.
    func openStory(_ summary: SavedStorySummary) {
        guard pendingStoryDetailFetchId == nil else { return }
        selectedStory = SavedStoryDetail(
            id: summary.id, title: summary.title, pages: [], epilogue: nil, rewriteStatus: summary.rewriteStatus
        )
        screen = .reading
        pendingStoryDetailFetchId = summary.id
        Task { [weak self] in
            await self?.coordinator?.getStory(storyId: summary.id)
        }
    }

    /// What LibraryView calls on appear, so opening Library is always
    /// fresh rather than depending on having recently backgrounded or
    /// concluded a story (the two triggers that otherwise populate
    /// libraryStories, see startPollingState()).
    func refreshLibrary() {
        Task { [weak self] in
            await self?.coordinator?.listStories()
        }
    }
```

- [ ] **Step 5: Build the app target to verify it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30`
Expected: `BUILD SUCCEEDED` (or the last lines show no errors — code signing is expected to be skipped in this dev environment, per CLAUDE.md).

- [ ] **Step 6: Run the TinyTalkCore package suite to confirm no regressions**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, full suite green (this task doesn't touch the package, but confirms nothing upstream broke).

- [ ] **Step 7: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift
git commit -m "feat(ios): generalize story-detail fetch and populate libraryStories from real data"
```

---

### Task 4: LibraryView — real data and real card tap

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/LibraryView.swift`

**Interfaces:**
- Consumes: Task 3's `AppModel.openStory(_:)` and `AppModel.refreshLibrary()`.
- Produces: nothing new for later tasks.

No unit tests for this file (SwiftUI view, no test target covers it — see Task 3's note). Verified by build + the on-device test script at the end of this plan.

- [ ] **Step 1: Fetch on appear**

In `LibraryView.swift`, add an `.onAppear` to the outer `ZStack` (after the closing brace of the `VStack` at line 32, before `}` closes the `ZStack`):

```swift
    var body: some View {
        ZStack {
            TTA.Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 22) {
                        ForEach(Array(model.libraryStories.enumerated()), id: \.element.id) { index, summary in
                            card(for: summary, colorIndex: index)
                        }
                        newStoryTile
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            model.refreshLibrary()
        }
    }
```

- [ ] **Step 2: Replace the mock card tap with the real fetch**

Replace `card(for:colorIndex:)`'s button action (lines 61-64):

```swift
        return Button {
            guard isTappable else { return }
            model.openStory(summary)
        } label: {
```

- [ ] **Step 3: Add an empty-library state**

Per the spec, Library with zero stories should show the same copy Landing already uses, rather than just a bare "+ New story" tile. Replace the `ScrollView` block from Step 1 with a conditional:

```swift
                if model.libraryStories.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("No stories yet — make one with me first!")
                            .font(TTA.Typography.story(15, italic: true))
                            .foregroundColor(TTA.Palette.inkSoft)
                        newStoryTile
                            .frame(width: 160)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 22) {
                            ForEach(Array(model.libraryStories.enumerated()), id: \.element.id) { index, summary in
                                card(for: summary, colorIndex: index)
                            }
                            newStoryTile
                        }
                        .padding(20)
                    }
                }
```

- [ ] **Step 4: Update the file's stale top-of-file doc comment**

Replace the doc comment (lines 4-7), which still says real data "isn't wired up yet":

```swift
/// Grid of saved stories (design 1a's "Library"). Populated from the real
/// server via AppModel.refreshLibrary()/openStory() -- see AppModel.swift.
struct LibraryView: View {
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/LibraryView.swift
git commit -m "feat(ios): wire LibraryView to real story-list/detail data"
```

---

### Task 5: Landing's real "Read Stories" button

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`
- Modify: `ios/TinyTalkApp/TinyTalkApp/LandingView.swift`

**Interfaces:**
- Consumes: Task 3's `libraryStories` population (via `AppModel.connect()`'s new trigger below) and `AppScreen.library`.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Trigger `listStories()` on initial connect**

In `AppModel.swift`'s `connect()`, add right after the existing `updateSettings` call (after line 376, before `startPollingState()`):

```swift
        Task { await coordinator.updateSettings(targetTurns: storyTurnCount, pageCount: storybookPageCount) }
        // So Landing's "Read Stories" button (LandingView.swift) is
        // accurate from a cold launch, not just after a background/
        // foreground cycle or a concluded story -- a story saved in a
        // PREVIOUS session shouldn't require either of those first.
        Task { await coordinator.listStories() }
        startPollingState()
```

- [ ] **Step 2: Make "Read Stories" a real, conditional button**

In `LandingView.swift`, replace the static `Label` block (lines 52-64):

```swift
                    if model.libraryStories.isEmpty {
                        VStack(spacing: 9) {
                            Label("Read Stories", systemImage: "book.closed.fill")
                                .font(TTA.Typography.display(22))
                                .foregroundColor(TTA.Palette.cream.opacity(0.55))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(TTA.Palette.cream.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                            Text("No stories yet — make one with me first!")
                                .font(TTA.Typography.story(13.5, italic: true))
                                .foregroundColor(TTA.Palette.paper)
                        }
                    } else {
                        Button {
                            model.screen = .library
                        } label: {
                            Label("Read Stories", systemImage: "book.closed.fill")
                                .font(TTA.Typography.display(22))
                                .foregroundColor(TTA.Palette.cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(TTA.Palette.cream.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
```

- [ ] **Step 3: Update the file's stale top-of-file doc comment**

Replace the doc comment (lines 3-6), which still says the button "always renders the design's own empty-library state":

```swift
/// Home screen (design 1a). "Read Stories" is a real button once
/// model.libraryStories is non-empty (see AppModel.connect()'s
/// listStories() trigger) -- otherwise shows the same disabled-look empty
/// state as before.
struct LandingView: View {
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift ios/TinyTalkApp/TinyTalkApp/LandingView.swift
git commit -m "feat(ios): make Landing's Read Stories button real"
```

---

### Task 6: Remove the hidden Settings "Preview: Library" button

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing for later tasks. Independent of every other task in this plan — can be done in any order.

- [ ] **Step 1: Remove the "Preview: Library" button**

In `SettingsView.swift`'s `storybookPreviewCard`, remove this block (lines 361-364):

```swift
            previewButton("Preview: Library") {
                model.libraryStories = MockStories.librarySummaries
                model.screen = .library
            }
```

- [ ] **Step 2: Update the card's doc comment**

The remaining two preview buttons ("Preview: The End", "Preview: Reading") still use mock data and are unaffected by this plan, but Library is no longer one of the screens this comment should describe as not-yet-wired. Replace the doc comment (lines 342-345):

```swift
    /// Developer preview of the Reading/The End screens against mock data
    /// -- see MockStories.swift. Library is no longer previewed here: it
    /// shows real data via Landing's "Read Stories" button (LandingView.swift)
    /// once at least one story exists.
    private var storybookPreviewCard: some View {
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
git commit -m "fix(ios): remove hidden Library preview button now that real data is wired"
```

---

### Task 7: ReadingView — real page-audio round trip

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`
- Modify: `ios/TinyTalkApp/TinyTalkApp/ReadingView.swift`

**Interfaces:**
- Consumes: Task 2's `SessionCoordinator.synthesizePage(storyId:pageIndex:)`/`stopPageAudio()`.
- Produces: `AppModel.requestPageAudio(storyId: String, pageIndex: Int)`, `AppModel.stopPageAudio()`. Nothing later in this plan consumes these, but they follow the same public-method pattern as `requestPageImage` for consistency.

- [ ] **Step 1: Add `requestPageAudio`/`stopPageAudio` to AppModel**

Add right after `requestPageImage(storyId:pageIndex:)` (or, if Task 3 already landed, right after `openStory`/`refreshLibrary`):

```swift
    /// What ReadingView's 🔊 button calls -- mirrors requestPageImage()'s
    /// wrapping of the actor call, but with no dedup guard: unlike an
    /// image (fetched once, cached), each tap should always actually play
    /// audio again, even for a page already heard.
    func requestPageAudio(storyId: String, pageIndex: Int) {
        Task { [weak self] in
            await self?.coordinator?.synthesizePage(storyId: storyId, pageIndex: pageIndex)
        }
    }

    /// What ReadingView calls on page change/disappear to stop whatever
    /// page audio is currently playing or pending -- see
    /// SessionCoordinator.stopPageAudio()'s doc comment.
    func stopPageAudio() {
        Task { [weak self] in
            await self?.coordinator?.stopPageAudio()
        }
    }
```

- [ ] **Step 2: Remove the AVSpeechSynthesizer stand-in**

In `ReadingView.swift`, remove the `import AVFoundation` (line 1) and the `synthesizer` property (line 21):

```swift
import SwiftUI
import TinyTalkCore
import UIKit
```

```swift
struct ReadingView: View {
    @ObservedObject var model: AppModel

    @State private var pageIndex = 0
```

- [ ] **Step 3: Update the file's stale top-of-file doc comment**

Replace the doc comment (lines 6-16):

```swift
/// Paginated storybook reader (design 1a's "Reading"). Reached via a
/// Library card tap. The 🔊 replay button uses the real synthesize_page
/// wire round trip (AppModel.requestPageAudio()/stopPageAudio()) -- see
/// SessionCoordinator.swift's pendingPageAudioRequest.
struct ReadingView: View {
```

- [ ] **Step 4: Stop audio on page change and on disappear**

Replace `.onDisappear { synthesizer.stopSpeaking(at: .immediate) }` (line 64) and add an `.onChange` for page swipes, in `content(for:)`:

```swift
        .onDisappear { model.stopPageAudio() }
        .onChange(of: pageIndex) { _, _ in
            model.stopPageAudio()
        }
        .onAppear {
```

- [ ] **Step 5: Swap `replayCurrentPage`'s body for the real round trip**

Replace `replayCurrentPage(text:)` (lines 208-214). It needs the current page's story id and index, not just its text -- update its call site too:

```swift
    private func replayCurrentPage(storyId: String, pageIndex: Int, text: String) {
        guard !text.isEmpty else { return }
        model.stopPageAudio()
        model.requestPageAudio(storyId: storyId, pageIndex: pageIndex)
    }
```

Update the call site in `topBar` (lines 172-175) to pass the new parameters:

```swift
            Button {
                guard let storyId = model.selectedStory?.id, pages.indices.contains(pageIndex) else { return }
                replayCurrentPage(storyId: storyId, pageIndex: pageIndex, text: pages[pageIndex].text)
            } label: {
```

- [ ] **Step 6: Run the TinyTalkCore package suite to confirm no regressions**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, full suite green (this task doesn't touch the package).

- [ ] **Step 7: Build the app target to verify it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift ios/TinyTalkApp/TinyTalkApp/ReadingView.swift
git commit -m "feat(ios): wire ReadingView's page-audio button to the real synthesize_page round trip"
```

---

## On-device verification (after all tasks land)

Per CLAUDE.md's testing mandate: none of this is verifiable by the test suite alone (no simulator coverage for real audio/network behavior). Once all seven tasks are merged to this worktree's branch:

1. **Where the code lives:** `.claude/worktrees/library-reading-screens-design/` (this worktree).
2. **Server restart needed?** No — zero server-side changes in this plan.
3. **iOS rebuild needed?** Yes — every task changes `ios/` code. Full path to open in Xcode:
   `open ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/library-reading-screens-design/ios/TinyTalkApp/TinyTalkApp.xcodeproj`
   (Recreate `Local.xcconfig` from `Local.xcconfig.example` first if this worktree is fresh — see CLAUDE.md's fresh-worktree gotcha.)
4. **Test script:**
   - Play a full story to conclusion (or use an already-saved one from a previous session). Confirm Landing's "Read Stories" button is now solid/tappable (not the old dimmed "No stories yet" look) — this confirms `listStories()` fired on connect and `libraryStories` populated.
   - Tap "Read Stories" → Library should show real saved stories with real titles/page counts/dates, not the five mock ones (Pip the Noisy Fox, The Cookies That Ran Away, etc.).
   - Tap a `.done` story card → should navigate to Reading and show that story's real pages (and real illustrations, if that story has any — confirming Task 4's `openStory()` correctly feeds `ReadingView`'s already-generic image code).
   - On a Reading page, tap 🔊 → should hear the real TTS voice (Kokoro, not the iOS system voice) reading that page's text, with a short network delay before it starts (unlike the old instant on-device synthesis).
   - Swipe to a new page while audio is playing → audio should stop immediately, not keep playing over the new page.
   - With zero saved stories (a fresh install, or via Settings if there's a way to clear story data): confirm Library shows "No stories yet — make one with me first!" instead of just a bare "+" tile, and confirm Landing's button still shows its original dimmed/disabled look.
