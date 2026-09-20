import XCTest
@testable import TinyTalkCore

final class StoryArcTests: XCTestCase {
    // MARK: - hasStarted (mirrors story_arc.py's has_started)

    func testAFreshArcHasNotStartedAndRecordingATurnStartsIt() {
        let arc = StoryArc(targetTurns: 7)
        XCTAssertFalse(arc.hasStarted)
        _ = arc.recordTurn(childText: "hello")
        XCTAssertTrue(arc.hasStarted)
    }

    func testAnExplicitConclusionAloneDoesNotCountAsStartingTheArc() {
        // forceConcludeGuidance()/markDone() deliberately leave turnCount
        // alone (see story_arc.py), so they don't flip hasStarted either.
        let arc = StoryArc(targetTurns: 7)
        _ = arc.forceConcludeGuidance()
        arc.markDone()
        XCTAssertFalse(arc.hasStarted)
    }

    // MARK: - Brief's required tests

    func testFirstTurnIsIntro() {
        let arc = StoryArc(targetTurns: 7)
        XCTAssertEqual(arc.stage, .intro)
    }

    func testStageAdvancesWithTurnCount() {
        let arc = StoryArc(targetTurns: 7)
        // setupEnd = round(7/4) = 2, risingEnd = round(7*2/3) = 5
        _ = arc.recordTurn(childText: "turn 1") // -> INTRO's own guidance, turnCount now 1
        XCTAssertEqual(arc.stage, .intro) // stageForTurn(1) == intro
        _ = arc.recordTurn(childText: "turn 2") // turnCount 2 <= setupEnd(2) -> setup
        XCTAssertEqual(arc.stage, .setup)
        _ = arc.recordTurn(childText: "turn 3") // turnCount 3 > 2, <= risingEnd(5) -> risingAction
        XCTAssertEqual(arc.stage, .risingAction)
        _ = arc.recordTurn(childText: "t4")
        _ = arc.recordTurn(childText: "t5") // turnCount 5 <= risingEnd(5) -> still risingAction
        XCTAssertEqual(arc.stage, .risingAction)
        _ = arc.recordTurn(childText: "t6") // turnCount 6 <= targetTurns(7) -> climax
        XCTAssertEqual(arc.stage, .climax)
        _ = arc.recordTurn(childText: "t7") // turnCount 7 <= targetTurns(7) -> still climax
        XCTAssertEqual(arc.stage, .climax)
        _ = arc.recordTurn(childText: "t8") // turnCount 8 > targetTurns -> resolution
        XCTAssertEqual(arc.stage, .resolution)
    }

    func testChildStopPhraseForcesResolutionGuidance() {
        let arc = StoryArc(targetTurns: 7)
        let guidance = arc.recordTurn(childText: "I'm done, that's enough")
        XCTAssertTrue(guidance.contains("wrap up the story"))
    }

    func testGraceCeilingForcesConclusion() {
        let arc = StoryArc(targetTurns: 3) // graceCeiling = 6
        for i in 1...6 {
            _ = arc.recordTurn(childText: "turn \(i)")
        }
        let forced = arc.recordTurn(childText: "turn 7") // turnCount 7 > graceCeiling(6)
        XCTAssertTrue(forced.contains("This must be the last reply"))
        arc.recordReply(replyText: "anything at all")
        XCTAssertTrue(arc.isDone)
    }

    func testNaturalConclusionPhraseMarksDone() {
        let arc = StoryArc(targetTurns: 7)
        _ = arc.recordTurn(childText: "turn 1")
        arc.recordReply(replyText: "And they all lived happily ever after. The end.")
        XCTAssertTrue(arc.isDone)
        XCTAssertEqual(arc.stage, .done)
    }

    func testOrdinaryReplyDoesNotMarkDone() {
        let arc = StoryArc(targetTurns: 7)
        _ = arc.recordTurn(childText: "turn 1")
        arc.recordReply(replyText: "The fox kept walking through the meadow.")
        XCTAssertFalse(arc.isDone)
    }

    func testForceConcludeGuidanceDoesNotAdvanceTurnCount() {
        let arc = StoryArc(targetTurns: 7)
        _ = arc.recordTurn(childText: "turn 1")
        let stageBefore = arc.stage
        let guidance = arc.forceConcludeGuidance()
        XCTAssertTrue(guidance.contains("This must be the last reply"))
        XCTAssertEqual(arc.stage, stageBefore)
    }

    func testMarkDoneIsUnconditional() {
        let arc = StoryArc(targetTurns: 7)
        arc.markDone()
        XCTAssertTrue(arc.isDone)
        XCTAssertEqual(arc.stage, .done)
    }

    // MARK: - Additional tests from Python suite for expanded coverage

    func testNewArcStartsAtIntroAndIsNotDone() {
        let arc = StoryArc()
        XCTAssertEqual(arc.stage, .intro)
        XCTAssertFalse(arc.isDone)
    }

    func testStageProgressesThroughAllBoundariesForDefaultTarget() {
        // target_turns=7 (default): intro 1, setup 2, rising_action 3-5, climax 6-7,
        // resolution 8-10.
        let arc = StoryArc()
        var expected: [StoryStage] = []
        expected.append(contentsOf: Array(repeating: StoryStage.intro, count: 1))
        expected.append(contentsOf: Array(repeating: StoryStage.setup, count: 1))
        expected.append(contentsOf: Array(repeating: StoryStage.risingAction, count: 3))
        expected.append(contentsOf: Array(repeating: StoryStage.climax, count: 2))
        expected.append(contentsOf: Array(repeating: StoryStage.resolution, count: 3))

        for (turnNumber, expectedStage) in expected.enumerated() {
            _ = arc.recordTurn(childText: "we walked into the forest")
            XCTAssertEqual(arc.stage, expectedStage, "turn \(turnNumber + 1)")
        }
    }

    func testCustomTargetTurnsScalesBoundaries() {
        // target_turns=8: intro 1, setup 2, rising_action 3-5, climax 6-8.
        let arc = StoryArc(targetTurns: 8)
        var expected: [StoryStage] = []
        expected.append(contentsOf: Array(repeating: StoryStage.intro, count: 1))
        expected.append(contentsOf: Array(repeating: StoryStage.setup, count: 1))
        expected.append(contentsOf: Array(repeating: StoryStage.risingAction, count: 3))
        expected.append(contentsOf: Array(repeating: StoryStage.climax, count: 3))

        for expectedStage in expected {
            _ = arc.recordTurn(childText: "a squirrel found an acorn")
            XCTAssertEqual(arc.stage, expectedStage)
        }
    }

    func testRecordTurnReturnsGuidanceMatchingCurrentStage() {
        let arc = StoryArc()
        let guidance = arc.recordTurn(childText: "we walked into the forest")
        XCTAssertTrue(guidance.lowercased().contains("start of the story"))
    }

    func testIntroGuidanceDoesNotMentionConflict() {
        // The first turn should just set the scene -- introducing a
        // problem/challenge/conflict is SETUP's job, starting turn 2.
        let arc = StoryArc()
        let guidance = arc.recordTurn(childText: "we walked into the forest").lowercased()  // turn 1 -- intro
        XCTAssertFalse(guidance.contains("problem"))
        XCTAssertFalse(guidance.contains("challenge"))
        XCTAssertFalse(guidance.contains("conflict"))
    }

    func testSetupGuidanceInstructsIntroducingAConflictRightAway() {
        // Real on-device testing found stories had no conflict/tension at
        // all -- SETUP must explicitly tell the model to introduce a
        // problem/challenge, not just describe the setting.
        let arc = StoryArc()
        arc.recordTurn(childText: "we walked into the forest")  // turn 1 -- intro
        let guidance = arc.recordTurn(childText: "a fox appeared")  // turn 2 -- setup
        let lower = guidance.lowercased()
        XCTAssertTrue(
            lower.contains("problem") || lower.contains("challenge") || lower.contains("conflict"),
            "Setup guidance should mention problem, challenge, or conflict"
        )
    }

    func testResolutionAndForcedGuidanceBothInstructEndingWithTheEnd() {
        // Real on-device testing found stories never reliably concluded --
        // instructing the model to literally say "The end." both gives the
        // child a clear sense of closure and makes conclusion-phrase detection
        // far more reliable (it's already one of the conclusion phrases).
        let arc = StoryArc(targetTurns: 1)  // grace ceiling = 4; turn 2+ is already resolution
        arc.recordTurn(childText: "something happens")  // turn 1
        let resolutionGuidance = arc.recordTurn(childText: "something happens")  // turn 2
        XCTAssertEqual(arc.stage, .resolution)
        XCTAssertTrue(resolutionGuidance.lowercased().contains("\"the end."))

        arc.recordTurn(childText: "something happens")  // turn 3
        arc.recordTurn(childText: "something happens")  // turn 4 -- last turn within the grace ceiling
        let forcedGuidance = arc.recordTurn(childText: "something happens")  // turn 5 -- past the ceiling
        XCTAssertTrue(forcedGuidance.lowercased().contains("\"the end."))
    }

    func testAllChildStopPhrasesForceResolutionGuidanceEvenDuringSetup() {
        let phrases = [
            "the end",
            "I'm done",
            "im done",
            "stop the story",
            "that's enough",
            "thats enough",
            "no more story",
            "i want to stop",
        ]
        for phrase in phrases {
            let arc = StoryArc()
            let guidance = arc.recordTurn(childText: phrase)  // turn 1 -- would normally be intro
            XCTAssertTrue(guidance.lowercased().contains("wrap up the story"), "Failed for phrase: \(phrase)")
        }
    }

    func testAgentReplyWithConclusionPhraseSetsDone() {
        let arc = StoryArc()
        arc.recordTurn(childText: "we walked into the forest")
        arc.recordReply(replyText: "And they all lived happily ever after.")
        XCTAssertTrue(arc.isDone)
        XCTAssertEqual(arc.stage, .done)
    }

    func testAgentReplyWithoutConclusionPhraseDoesNotSetDone() {
        let arc = StoryArc()
        arc.recordTurn(childText: "we walked into the forest")
        arc.recordReply(replyText: "A friendly fox appeared and waved hello.")
        XCTAssertFalse(arc.isDone)
    }

    func testTurnCountPastGraceCeilingForcesGuidanceThenMarksDone() {
        let arc = StoryArc()  // target=7, grace ceiling=10
        for _ in 1...10 {
            arc.recordTurn(childText: "something happens")
            arc.recordReply(replyText: "something else happens, with no trigger phrase")
        }
        XCTAssertFalse(arc.isDone)  // still within the grace ceiling

        let guidance = arc.recordTurn(childText: "something happens")  // turn 11, past ceiling
        let expected = (
            "This must be the last reply. Resolve the problem from earlier in "
            + "the story and bring it to a warm, complete ending right now. Do not "
            + "ask what should happen next. The story is over. End your reply "
            + "with the words \"The end.\""
        )
        XCTAssertEqual(guidance, expected)
        arc.recordReply(replyText: "anything at all, even without a conclusion phrase")
        XCTAssertTrue(arc.isDone)
    }

    func testForceConcludeGuidanceIsTheSameAsGraceCeilingGuidance() {
        let targetTurns = 3
        let graceCeiling = targetTurns + 3  // matches StoryArc's own init formula
        let arc = StoryArc(targetTurns: targetTurns)
        for _ in 1...graceCeiling {
            arc.recordTurn(childText: "keep going")
        }
        let forcedByPeiling = arc.recordTurn(childText: "keep going")

        let fresh = StoryArc(targetTurns: targetTurns)
        XCTAssertEqual(fresh.forceConcludeGuidance(), forcedByPeiling)
    }

    func testForceConcludeGuidanceDoesNotAdvanceTurnCountExtended() {
        let arc = StoryArc(targetTurns: 5)
        arc.recordTurn(childText: "turn one")
        let stageBefore = arc.stage

        _ = arc.forceConcludeGuidance()

        XCTAssertEqual(arc.stage, stageBefore)
    }

    func testMarkDoneSetsIsDoneUnconditionally() {
        let arc = StoryArc(targetTurns: 5)
        XCTAssertFalse(arc.isDone)

        arc.markDone()

        XCTAssertTrue(arc.isDone)
        XCTAssertEqual(arc.stage, .done)
    }
}
