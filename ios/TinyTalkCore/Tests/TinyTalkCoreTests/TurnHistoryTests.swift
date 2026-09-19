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
}
