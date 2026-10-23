package com.jessvb.tinytalk.spike

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RunTrackerTest {
    @Test
    fun inOrderCompletionFinishesOnlyAfterAll() {
        val t = RunTracker(1000)
        t.begin(1, 3, 0)
        for (i in 0..2) assertTrue(t.arrived(1, i, 10L * i))
        assertFalse(t.done(1, 0))
        assertFalse(t.done(1, 1))
        assertTrue(t.done(1, 2))
    }

    @Test
    fun lastSentenceFailingFirstDoesNotFinishRun() {
        val t = RunTracker(1000)
        t.begin(1, 3, 0)
        assertTrue(t.arrived(1, 2, 1)) // sync failure of last sentence
        assertFalse(t.done(1, 2))
        assertTrue(t.arrived(1, 0, 2))
        assertFalse(t.done(1, 0))
        assertTrue(t.arrived(1, 1, 3))
        assertTrue(t.done(1, 1))
    }

    @Test
    fun missingMiddleSentenceTimesOutAndRunStillFinishes() {
        val t = RunTracker(1000)
        t.begin(1, 3, 0)
        t.arrived(1, 0, 100)
        t.arrived(1, 2, 200)
        assertFalse(t.done(1, 0))
        assertFalse(t.done(1, 2))
        assertNull(t.expire(1100)) // 900 ms since last progress
        val e = t.expire(1300)!!
        assertEquals(1, e.idx)
        assertTrue(e.runFinished)
        assertTrue(t.isDone(1, 1))
        assertFalse(t.arrived(1, 1, 1400)) // late callback ignored
        assertNull(t.expire(5000))
    }

    @Test
    fun missingLastSentenceExpiresAfterOthersPlayed() {
        val t = RunTracker(1000)
        t.begin(1, 2, 0)
        t.arrived(1, 0, 10)
        assertFalse(t.done(1, 0))
        val e = t.expire(2000)!!
        assertEquals(1, e.idx)
        assertTrue(e.runFinished)
    }

    @Test
    fun staleGenerationIgnored() {
        val t = RunTracker(1000)
        t.begin(1, 2, 0)
        t.begin(2, 1, 5)
        assertFalse(t.arrived(1, 0, 6))
        assertFalse(t.done(1, 0))
        assertTrue(t.isDone(1, 0))
        assertTrue(t.arrived(2, 0, 7))
        assertTrue(t.done(2, 0))
        t.cancel()
        assertFalse(t.done(2, 0))
        assertNull(t.expire(100000))
    }
}
