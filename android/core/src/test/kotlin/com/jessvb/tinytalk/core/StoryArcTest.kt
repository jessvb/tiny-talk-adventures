package com.jessvb.tinytalk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StoryArcTest {
    private val forcedPrefix = "This must be the last reply."

    /** (setupEnd, risingEnd) from Swift's round-half-away-from-zero formula. */
    private val boundaries = mapOf(
        4 to (1 to 3), 5 to (1 to 3), 6 to (2 to 4), 7 to (2 to 5), 8 to (2 to 5),
        9 to (2 to 6), 10 to (3 to 7), 11 to (3 to 7), 12 to (3 to 8),
    )

    private fun stageAfterTurns(arc: StoryArc, n: Int): StoryStage {
        repeat(n) { arc.recordTurn("a") }
        return arc.stage
    }

    @Test fun stagesForTargetSeven() {
        val expected = listOf(
            StoryStage.INTRO, StoryStage.SETUP, StoryStage.RISING_ACTION,
            StoryStage.RISING_ACTION, StoryStage.RISING_ACTION, StoryStage.CLIMAX,
            StoryStage.CLIMAX, StoryStage.RESOLUTION,
        )
        expected.forEachIndexed { i, st ->
            assertEquals("turn ${i + 1}", st, stageAfterTurns(StoryArc(7), i + 1))
        }
    }

    @Test fun stageBoundariesForAllTargets() {
        for ((target, ends) in boundaries) {
            val (setupEnd, risingEnd) = ends
            for (turn in 1..target + 1) {
                val expected = when {
                    turn <= 1 -> StoryStage.INTRO
                    turn <= setupEnd -> StoryStage.SETUP
                    turn <= risingEnd -> StoryStage.RISING_ACTION
                    turn <= target -> StoryStage.CLIMAX
                    else -> StoryStage.RESOLUTION
                }
                assertEquals("target $target turn $turn", expected, stageAfterTurns(StoryArc(target), turn))
            }
        }
    }

    @Test fun stageBeforeAnyTurnIsIntroAndNotStarted() {
        val arc = StoryArc(7)
        assertEquals(StoryStage.INTRO, arc.stage)
        assertFalse(arc.hasStarted)
        arc.recordTurn("hi")
        assertTrue(arc.hasStarted)
    }

    @Test fun guidancePerStageIsVerbatim() {
        val arc = StoryArc(7)
        assertEquals(
            "You're at the very start of the story. Introduce the setting and characters.",
            arc.recordTurn("a"),
        )
        assertTrue(arc.recordTurn("a").startsWith("You're at the start of the story. Continue introducing"))
        assertTrue(arc.recordTurn("a").startsWith("The story is building."))
        arc.recordTurn("a"); arc.recordTurn("a")
        assertTrue(arc.recordTurn("a").startsWith("The story is nearing its big moment."))
        arc.recordTurn("a")
        assertTrue(arc.recordTurn("a").startsWith("It's time to resolve the problem"))
    }

    @Test fun childStopPhraseGivesResolutionGuidanceAtAnyStage() {
        val resolution = StoryArc(7).also { repeat(8) { _ -> it.recordTurn("a") } }.recordTurn("a")
        assertTrue(resolution.startsWith("It's time to resolve"))
        assertEquals(resolution, StoryArc(7).recordTurn("I'm done"))
        assertEquals(resolution, StoryArc(7).recordTurn("I'M DONE"))
        assertEquals(resolution, StoryArc(7).recordTurn("i'm done"))
        assertEquals(resolution, StoryArc(7).recordTurn("that's enough please"))
        assertEquals(resolution, StoryArc(7).recordTurn("The End"))
    }

    @Test fun stopPhraseDoesNotMatchInsideOtherWords() {
        val intro = StoryArc(7).recordTurn("a")
        assertEquals(intro, StoryArc(7).recordTurn("the endless river"))
    }

    @Test fun pastGraceCeilingForcesEndingThenDone() {
        val arc2 = StoryArc(7)
        repeat(10) { arc2.recordTurn("a") }
        val forced = arc2.recordTurn("a")
        assertTrue(forced.startsWith(forcedPrefix))
        assertTrue(forced.endsWith("\"The end.\""))
        assertFalse(arc2.isDone)
        arc2.recordReply("something that does not conclude")
        assertTrue(arc2.isDone)
        assertEquals(StoryStage.DONE, arc2.stage)
    }

    @Test fun turnTenIsNotYetForced() {
        val arc = StoryArc(7)
        repeat(9) { arc.recordTurn("a") }
        assertFalse(arc.recordTurn("a").startsWith(forcedPrefix))
    }

    @Test fun conclusionPhrasesInReplyMarkDone() {
        for (reply in listOf("And they lived happily ever after.", "The end.", "They lived happily.", "the story is over")) {
            val arc = StoryArc(7)
            arc.recordTurn("a")
            arc.recordReply(reply)
            assertTrue(reply, arc.isDone)
        }
        val arc = StoryArc(7)
        arc.recordTurn("a")
        arc.recordReply("The endless river flowed on.")
        assertFalse(arc.isDone)
    }

    @Test fun forceConcludeDoesNotAdvanceTurnCount() {
        val arc = StoryArc(7)
        assertTrue(arc.forceConcludeGuidance().startsWith(forcedPrefix))
        assertFalse(arc.hasStarted)
        assertEquals(StoryStage.INTRO, arc.stage)
    }

    @Test fun markDoneForcesDone() {
        val arc = StoryArc(7)
        arc.markDone()
        assertTrue(arc.isDone)
        assertEquals(StoryStage.DONE, arc.stage)
    }
}
