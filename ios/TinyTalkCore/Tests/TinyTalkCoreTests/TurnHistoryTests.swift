import XCTest
@testable import TinyTalkCore

final class TurnHistoryTests: XCTestCase {
    func testAChildLineThenAnElsieLineAppendInOrder() {
        var history = TurnHistory()
        history.observe(transcript: "a dragon", transcriptTurnId: 1, reply: "", replyTurnId: nil)
        history.observe(transcript: "a dragon", transcriptTurnId: 1, reply: "The dragon yawned.", replyTurnId: 1)
        XCTAssertEqual(history.turns.map(\.speaker), [.child, .elsie])
        XCTAssertEqual(history.turns.map(\.text), ["a dragon", "The dragon yawned."])
    }

    func testRepeatedPollTicksForTheSameTurnDoNotDuplicateIt() {
        var history = TurnHistory()
        for _ in 0..<5 {
            history.observe(transcript: "a dragon", transcriptTurnId: 1, reply: "The dragon yawned.", replyTurnId: 1)
        }
        XCTAssertEqual(history.turns.count, 2)
    }

    func testARepeatedPhraseInADifferentTurnStillGetsItsOwnBubble() {
        var history = TurnHistory()
        history.observe(transcript: "hi", transcriptTurnId: 1, reply: "Hello!", replyTurnId: 1)
        history.observe(transcript: "hi", transcriptTurnId: 2, reply: "Hello!", replyTurnId: 2)
        XCTAssertEqual(history.turns.count, 4)
    }

    func testThePreviousTurnsTextIsNotDuplicatedWhileTheNextTurnHasNoTextYet() {
        // The coordinator's lastTranscript/lastReply keep holding turn 1's
        // text (and turn id) after the child starts talking again -- see
        // SessionCoordinator.lastTranscriptTurnId's doc comment.
        var history = TurnHistory()
        history.observe(transcript: "hi", transcriptTurnId: 1, reply: "Hello!", replyTurnId: 1)
        history.observe(transcript: "hi", transcriptTurnId: 1, reply: "Hello!", replyTurnId: 1)
        history.observe(transcript: "a cat", transcriptTurnId: 2, reply: "Hello!", replyTurnId: 1)
        XCTAssertEqual(history.turns.map(\.text), ["hi", "Hello!", "a cat"])
    }

    func testEmptyTextAndMissingTurnIdsAreIgnored() {
        var history = TurnHistory()
        history.observe(transcript: "", transcriptTurnId: 1, reply: "", replyTurnId: 1)
        history.observe(transcript: "hi", transcriptTurnId: nil, reply: "Hello!", replyTurnId: nil)
        XCTAssertTrue(history.turns.isEmpty)
    }

    func testClearEmptiesTheHistoryAndForgetsWhatWasAlreadyShown() {
        var history = TurnHistory()
        history.observe(transcript: "hi", transcriptTurnId: 1, reply: "Hello!", replyTurnId: 1)
        history.clear()
        XCTAssertTrue(history.turns.isEmpty)
        // A brand-new story's first turn reuses turn id 1's slot on the
        // client -- it must not be mistaken for the one just cleared.
        history.observe(transcript: "hi", transcriptTurnId: 1, reply: "Hello!", replyTurnId: 1)
        XCTAssertEqual(history.turns.count, 2)
    }

    // MARK: - Keeping history across a coordinator replacement (#23)
    //
    // A backgrounding (or unexpected-drop) disconnect throws the old
    // SessionCoordinator away, and the reconnect builds a fresh one -- the
    // history must survive that, without the server's replayed reply (or
    // the fresh coordinator's own turn numbering) duplicating or swallowing
    // bubbles.

    func testHistoryIsKeptWhenTheCoordinatorIsReplaced() {
        var history = TurnHistory()
        history.observe(transcript: "hi", transcriptTurnId: 1, reply: "Hello!", replyTurnId: 1)
        history.coordinatorReplaced(resumingTurnId: nil)
        XCTAssertEqual(history.turns.map(\.text), ["hi", "Hello!"])
        history.coordinatorReplaced(resumingTurnId: 1)
        XCTAssertEqual(history.turns.map(\.text), ["hi", "Hello!"])
    }

    func testAReplayedReplyAlreadyOnScreenIsNotDuplicatedWhenResuming() {
        // Backgrounded while Elsie was still speaking turn 3, whose text had
        // already arrived: the server replays the whole held reply from the
        // top, so the same turn id + text comes back.
        var history = TurnHistory()
        history.observe(transcript: "a dragon", transcriptTurnId: 3, reply: "The dragon yawned.", replyTurnId: 3)
        history.coordinatorReplaced(resumingTurnId: 3)
        // The fresh coordinator has nothing yet, then the replay lands.
        history.observe(transcript: "", transcriptTurnId: nil, reply: "", replyTurnId: nil)
        history.observe(transcript: "", transcriptTurnId: nil, reply: "The dragon yawned.", replyTurnId: 3)
        history.observe(transcript: "", transcriptTurnId: nil, reply: "The dragon yawned.", replyTurnId: 3)
        XCTAssertEqual(history.turns.map(\.text), ["a dragon", "The dragon yawned."])
    }

    func testAReplyThatNeverArrivedBeforeTheDisconnectIsAppendedOnceWhenResuming() {
        // Backgrounded while still waiting on turn 3's reply: only the
        // child's line was on screen. The replay supplies the reply.
        var history = TurnHistory()
        history.observe(transcript: "a dragon", transcriptTurnId: 3, reply: "An earlier reply.", replyTurnId: 2)
        history.coordinatorReplaced(resumingTurnId: 3)
        history.observe(transcript: "", transcriptTurnId: nil, reply: "The dragon yawned.", replyTurnId: 3)
        history.observe(transcript: "", transcriptTurnId: nil, reply: "The dragon yawned.", replyTurnId: 3)
        XCTAssertEqual(history.turns.map(\.text), ["a dragon", "An earlier reply.", "The dragon yawned."])
    }

    func testTheTurnAfterAResumedReplayStillGetsItsOwnBubbles() {
        var history = TurnHistory()
        history.observe(transcript: "a dragon", transcriptTurnId: 3, reply: "The dragon yawned.", replyTurnId: 3)
        history.coordinatorReplaced(resumingTurnId: 3)
        history.observe(transcript: "", transcriptTurnId: nil, reply: "The dragon yawned.", replyTurnId: 3)
        history.observe(transcript: "it flew away", transcriptTurnId: 4, reply: "The dragon yawned.", replyTurnId: 3)
        history.observe(transcript: "it flew away", transcriptTurnId: 4, reply: "Off it went!", replyTurnId: 4)
        XCTAssertEqual(
            history.turns.map(\.text),
            ["a dragon", "The dragon yawned.", "it flew away", "Off it went!"]
        )
    }

    func testAFreshCoordinatorsRestartedTurnNumberingIsNotMistakenForAnAlreadyShownTurn() {
        // Backgrounded while idle: nothing to resume, so the fresh
        // coordinator numbers its first turn 1 again -- the same id the
        // old coordinator's first turn already used. Without resetting the
        // tracked ids, this turn's bubbles would be silently swallowed.
        var history = TurnHistory()
        history.observe(transcript: "once upon a time", transcriptTurnId: 1, reply: "there was a cat", replyTurnId: 1)
        history.coordinatorReplaced(resumingTurnId: nil)
        history.observe(transcript: "the cat sneezed", transcriptTurnId: 1, reply: "", replyTurnId: nil)
        history.observe(transcript: "the cat sneezed", transcriptTurnId: 1, reply: "Bless you!", replyTurnId: 1)
        XCTAssertEqual(
            history.turns.map(\.text),
            ["once upon a time", "there was a cat", "the cat sneezed", "Bless you!"]
        )
    }
}
