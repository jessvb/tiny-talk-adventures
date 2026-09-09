import XCTest
@testable import TinyTalkCore

final class SafetyTests: XCTestCase {
    func testPlainWholesomeTextIsSafe() {
        XCTAssertTrue(Safety.isSafe("The fox went for a walk in the sunny meadow."))
    }

    func testViolentWordIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("The knight had to kill the dragon."))
    }

    func testProfanityIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("What the hell is that."))
    }

    func testReproductionWordIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("The rabbits started breeding."))
    }

    func testFrighteningPhraseIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("It was pure evil."))
    }

    func testRealWorldDangerPhraseIsUnsafe() {
        XCTAssertFalse(Safety.isSafe("The kids were playing with matches."))
    }

    func testWordBoundaryDoesNotFalsePositive() {
        // "begun" contains "gun" as a substring but must not match.
        XCTAssertTrue(Safety.isSafe("The adventure had begun."))
    }

    func testShootingStarIsSafeButShootingAloneIsNot() {
        XCTAssertTrue(Safety.isSafe("She wished on a shooting star."))
        XCTAssertFalse(Safety.isSafe("He kept shooting at the target."))
    }

    func testSafePhraseDoesNotMaskADangerousUseElsewhereInTheSameSentence() {
        XCTAssertFalse(Safety.isSafe("She wished on a shooting star while shooting arrows at the target."))
    }

    func testInnocentFairyTaleKissStaysSafe() {
        XCTAssertTrue(Safety.isSafe("The prince gave the princess a goodnight kiss."))
    }

    func testFilterReplyPassesThroughSafeText() {
        XCTAssertEqual(Safety.filterReply("A gentle story about a fox."), "A gentle story about a fox.")
    }

    func testFilterReplyReplacesUnsafeText() {
        XCTAssertEqual(Safety.filterReply("Someone got killed."), Safety.safeFallback)
    }

    func testFilterReplyReplacesEmptyText() {
        XCTAssertEqual(Safety.filterReply(""), Safety.safeFallback)
    }
}
