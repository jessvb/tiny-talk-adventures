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

    func testAdultThemesAreUnsafe() {
        XCTAssertFalse(Safety.isSafe("He was drunk on alcohol and lit a cigarette."))
        XCTAssertFalse(Safety.isSafe("She stood there completely naked."))
    }

    func testEvilQueenFairyTaleTropeStaysSafe() {
        // "evil" alone doesn't trigger; only "pure evil" does
        XCTAssertTrue(Safety.isSafe("The evil queen cast a spell on the princess."))
        XCTAssertTrue(Safety.isSafe("The evil witch lived in the dark forest."))
    }

    func testInnocentMatchesAndLighterUsageStaysSafe() {
        // "matches" and "lighter" have innocent uses; only dangerous actions trigger
        XCTAssertTrue(Safety.isSafe("The sky grew lighter as morning came."))
        XCTAssertTrue(Safety.isSafe("Her red mitten matches her hat!"))
    }

    func testBareMateBreedrounsAreNotBlocked() {
        // "mate" and "breed" as nouns (not verbs/gerunds) are not blocked
        XCTAssertTrue(Safety.isSafe("His mates ran on ahead through the meadow."))
        XCTAssertTrue(Safety.isSafe("The friendliest breed of dog is the golden retriever."))
    }

    func testCaseInsensitivityOfBlockedWords() {
        // Uppercase "GUN" should still be detected
        XCTAssertFalse(Safety.isSafe("The hunter had a GUN."))
    }

    func testBlockedWordsInMultipleFormsAreUnsafe() {
        // Covers various forms of blocked words (past tense, plural, gerund, etc.)
        XCTAssertFalse(Safety.isSafe("He picked up the knife."))
        XCTAssertFalse(Safety.isSafe("There was blood everywhere."))
        XCTAssertFalse(Safety.isSafe("The monster attacking the village was terrifying."))
        XCTAssertFalse(Safety.isSafe("It was a nightmare full of pure evil."))
        XCTAssertFalse(Safety.isSafe("She screamed in terror, trapped forever in the tower."))
    }

    func testPlayingWithMatchesOrALighterIsUnsafe() {
        // Dangerous actions with matches/lighter must be caught
        XCTAssertFalse(Safety.isSafe("He was playing with matches near the curtains."))
        XCTAssertFalse(Safety.isSafe("She played with a lighter she found on the table."))
    }

    func testReproductionContentVariantsAreUnsafe() {
        // Multiple forms of reproduction-related content
        XCTAssertFalse(Safety.isSafe("Foxes are mating right now."))
        XCTAssertFalse(Safety.isSafe("The rabbits started breeding early this year."))
        XCTAssertFalse(Safety.isSafe("She is pregnant with a litter of kittens."))
        XCTAssertFalse(Safety.isSafe("The pregnancy lasts about two months."))
        XCTAssertFalse(Safety.isSafe("Animals reproduce in many different ways."))
    }

    func testExplicitSexualContentIsUnsafe() {
        // Sexual content in various forms
        XCTAssertFalse(Safety.isSafe("Let's talk about sex."))
        XCTAssertFalse(Safety.isSafe("That website has sexual content."))
        XCTAssertFalse(Safety.isSafe("He was watching porn."))
        XCTAssertFalse(Safety.isSafe("That's a porno movie."))
        XCTAssertFalse(Safety.isSafe("It's a pornography site."))
        XCTAssertFalse(Safety.isSafe("The image was pornographic."))
        XCTAssertFalse(Safety.isSafe("She was nude in the painting."))
        XCTAssertFalse(Safety.isSafe("The statue depicts nudity."))
        XCTAssertFalse(Safety.isSafe("The scene was erotic."))
        XCTAssertFalse(Safety.isSafe("He started to masturbate."))
        XCTAssertFalse(Safety.isSafe("Masturbation is a private act."))
        XCTAssertFalse(Safety.isSafe("She had an orgasm."))
    }

    func testWholesomeTextWithNoBlockedWordsIsSafe() {
        XCTAssertTrue(Safety.isSafe("The fox ran through the sunny meadow."))
        XCTAssertTrue(Safety.isSafe("The dragon sneezed and made a rainbow!"))
    }

    func testSubstringMatchesInsideOtherWordsDoNotTrigger() {
        // Word boundary must be respected
        XCTAssertTrue(Safety.isSafe("The race had begun at last."))
        XCTAssertTrue(Safety.isSafe("She was a knifemaker's daughter."))
    }
}
