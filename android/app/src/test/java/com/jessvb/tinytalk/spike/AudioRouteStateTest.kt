package com.jessvb.tinytalk.spike

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioRouteStateTest {
    @Test
    fun `route only once until restored`() {
        val r = AudioRouteState()
        assertTrue(r.shouldRoute())
        assertFalse(r.shouldRoute())
        assertTrue(r.shouldRestoreAfterStop())
        assertTrue(r.shouldRoute())
    }

    @Test
    fun `restore when nothing is routed is a no-op`() {
        val r = AudioRouteState()
        assertFalse(r.shouldRestoreAfterStop())
        assertFalse(r.shouldRestoreAfterRun(runGen = 1, currentGen = 1, speaking = false))
    }

    @Test
    fun `stop then speak in FIFO order leaves audio routed for the new run`() {
        val r = AudioRouteState()
        r.shouldRoute() // run 1
        assertTrue(r.shouldRestoreAfterStop()) // stop's cleanup
        assertTrue(r.shouldRoute()) // the next speak's routing, queued after it
        assertTrue(r.routed)
    }

    @Test
    fun `natural end of an old run never undoes a newer run's routing`() {
        val r = AudioRouteState()
        r.shouldRoute() // run 1
        // run 1 ended, but speak() for run 2 already bumped the generation
        assertFalse(r.shouldRestoreAfterRun(runGen = 1, currentGen = 2, speaking = true))
        assertTrue(r.routed)
        assertFalse(r.shouldRoute()) // run 2 reuses the routing
    }

    @Test
    fun `natural end of the current run restores`() {
        val r = AudioRouteState()
        r.shouldRoute()
        assertTrue(r.shouldRestoreAfterRun(runGen = 3, currentGen = 3, speaking = false))
        assertFalse(r.routed)
    }

    @Test
    fun `stale temp files are those of earlier generations only`() {
        val p = "sentence_tts_"
        assertTrue(AudioRouteState.isStaleTempFile("sentence_tts_4_0.wav", p, beforeGen = 5))
        assertFalse(AudioRouteState.isStaleTempFile("sentence_tts_5_0.wav", p, beforeGen = 5))
        assertFalse(AudioRouteState.isStaleTempFile("sentence_tts_6_2.wav", p, beforeGen = 5))
        assertFalse(AudioRouteState.isStaleTempFile("other_4_0.wav", p, beforeGen = 5))
        // Unparseable leftovers with our prefix are junk from an older build: delete them.
        assertTrue(AudioRouteState.isStaleTempFile("sentence_tts_garbage.wav", p, beforeGen = 5))
    }
}
