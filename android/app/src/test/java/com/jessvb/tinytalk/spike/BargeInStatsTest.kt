package com.jessvb.tinytalk.spike

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BargeInStatsTest {
    private var now = 1000L
    private val stats = BargeInStats { now }

    @Test fun silentRunHasNoTriggers() {
        assertEquals("false triggers=0, stops=[]", stats.summary())
    }

    @Test fun speechStartWhileIdleIsIgnored() {
        assertFalse(stats.onSpeechStart(ttsSpeaking = false))
        assertNull(stats.onStopped())
        assertEquals("false triggers=0, stops=[]", stats.summary())
    }

    @Test fun interruptionRecordsLatency() {
        assertTrue(stats.onSpeechStart(true))
        now += 120
        assertEquals(120L, stats.onStopped())
        assertEquals("false triggers=1, stops=[120 ms]", stats.summary())
    }

    @Test fun multipleInterruptionsAccumulate() {
        stats.onSpeechStart(true); now += 50; stats.onStopped()
        now += 1000
        stats.onSpeechStart(true); now += 700; stats.onStopped()
        assertEquals("false triggers=2, stops=[50 ms, 700 ms]", stats.summary())
    }

    @Test fun stoppedTwiceCountsOnce() {
        stats.onSpeechStart(true); now += 10
        stats.onStopped()
        assertNull(stats.onStopped())
        assertEquals("false triggers=1, stops=[10 ms]", stats.summary())
    }

    @Test fun invalidRunSummaryNeverLooksLikeAPass() {
        stats.markInvalid("mic not running")
        assertTrue(stats.isInvalid())
        assertEquals("INVALID: mic not running", stats.summary())
    }

    @Test fun resetClearsInvalid() {
        stats.markInvalid("mic not running")
        stats.reset()
        assertFalse(stats.isInvalid())
        assertEquals("false triggers=0, stops=[]", stats.summary())
    }

    @Test fun resetClearsEverything() {
        stats.onSpeechStart(true); now += 10; stats.onStopped()
        stats.onSpeechStart(true)
        stats.reset()
        assertNull(stats.onStopped())
        assertEquals("false triggers=0, stops=[]", stats.summary())
    }
}
