package com.jessvb.tinytalk.voice

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LoopConditionsTest {
    private val ok = LoopConditions(
        onStoryScreen = true, foreground = true, consent = true,
        micPermission = true, listeningAvailable = true, halted = false, paused = false,
    )

    @Test fun runsOnlyWhenEverythingHolds() {
        assertTrue(ok.shouldRun)
        assertFalse(ok.copy(onStoryScreen = false).shouldRun)
        assertFalse(ok.copy(foreground = false).shouldRun)
        assertFalse(ok.copy(consent = false).shouldRun)
        assertFalse(ok.copy(micPermission = false).shouldRun)
        assertFalse(ok.copy(listeningAvailable = false).shouldRun)
        assertFalse(ok.copy(halted = true).shouldRun)
        assertFalse(ok.copy(paused = true).shouldRun)
    }

    @Test fun defaultIsStopped() {
        assertFalse(LoopConditions().shouldRun)
    }
}
