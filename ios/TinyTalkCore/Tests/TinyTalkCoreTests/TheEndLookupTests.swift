import XCTest
@testable import TinyTalkCore

final class TheEndLookupTests: XCTestCase {
    func testNeverRequestsWhileTheStoryHasNotConcluded() {
        var lookup = TheEndLookup()
        for _ in 0..<5 {
            XCTAssertFalse(lookup.shouldRequest(readyToShowTheEnd: false))
        }
    }

    func testRequestsOnceWhenTheStoryConcludesNotOnEveryPollTick() {
        var lookup = TheEndLookup()
        XCTAssertTrue(lookup.shouldRequest(readyToShowTheEnd: true))
        for _ in 0..<5 {
            XCTAssertFalse(lookup.shouldRequest(readyToShowTheEnd: true), "the flag stays latched true for the rest of the story; asking again every ~100ms tick is what this guard exists to prevent")
        }
    }

    /// The bug found on-device testing PR #50 (2026-09-21): finish a story,
    /// use New Story on the SAME session (no Home, so no new coordinator),
    /// finish again -- and The End never appeared until the phone was locked
    /// and unlocked. The guard used to be set once and cleared only on a
    /// disconnect, but the coordinator's own newStory() takes
    /// readyToShowTheEnd back to false, so the second conclusion never asked
    /// for the story list that navigation waits on.
    func testRequestsAgainForASecondStoryOnTheSameCoordinator() {
        var lookup = TheEndLookup()
        XCTAssertTrue(lookup.shouldRequest(readyToShowTheEnd: true), "story 1 concluded")
        XCTAssertFalse(lookup.shouldRequest(readyToShowTheEnd: true))

        // New Story: newStory() resets the coordinator's readyToShowTheEnd.
        XCTAssertFalse(lookup.shouldRequest(readyToShowTheEnd: false))

        XCTAssertTrue(lookup.shouldRequest(readyToShowTheEnd: true), "story 2 concluded on the same coordinator: must look up again")
        XCTAssertFalse(lookup.shouldRequest(readyToShowTheEnd: true))
    }

    /// A disconnect tears the coordinator down; the replacement may already
    /// report ready (e.g. a foreground reconnect after the story concluded
    /// while the app was away) without ever having passed through false.
    func testResetLetsAReplacementCoordinatorAskEvenIfTheFlagNeverDropped() {
        var lookup = TheEndLookup()
        XCTAssertTrue(lookup.shouldRequest(readyToShowTheEnd: true))
        lookup.reset()
        XCTAssertTrue(lookup.shouldRequest(readyToShowTheEnd: true))
    }

    /// The coordinator half of the same invariant, which TheEndLookup relies
    /// on: newStory() must take readyToShowTheEnd back to false, and a
    /// second story concluding on the SAME coordinator must raise it again.
    func testTheCoordinatorRaisesReadyToShowTheEndAgainForASecondStory() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        // Story 1 concludes: its concluding reply plays out, then the server
        // announces the rewrite.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("The end.", turnId: 1)))
        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        connection.emit(.message(.rewritingStarted))
        try? await Task.sleep(nanoseconds: 10_000_000)

        var ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "story 1 concluded")

        // Story 1's background rewrite must actually finish server-side
        // before a second one can genuinely begin (issue #32: the server's
        // own REWRITING gate silently ignores new_story otherwise) --
        // rewritingDone here stands in for that ~3.5min real-hardware wait.
        connection.emit(.message(.rewritingDone))
        try? await Task.sleep(nanoseconds: 10_000_000)

        // New Story on the same coordinator, no disconnect in between.
        await coordinator.newStory()
        ready = await coordinator.readyToShowTheEnd
        XCTAssertFalse(ready, "newStory() must start a fresh conclusion-tracking cycle")

        // Story 2 (turn ids keep counting, so its first utterance is turn 2)
        // concludes the same way.
        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.responseText("The end, again.", turnId: 2)))
        connection.emit(.audio(Data([1, 2, 3])))
        connection.emit(.message(.turnEnd(turnId: 2)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        connection.emit(.message(.rewritingStarted))
        try? await Task.sleep(nanoseconds: 10_000_000)

        ready = await coordinator.readyToShowTheEnd
        XCTAssertTrue(ready, "story 2 concluded on the same coordinator: The End must be reachable again")

        runLoop.cancel()
    }
}
