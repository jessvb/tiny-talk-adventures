package com.jessvb.tinytalk.spike

import org.junit.Assert.assertEquals
import org.junit.Test

class SpeechDetectorTest {
    private val hi = 0.9f
    private val lo = 0.1f

    private fun SpeechDetector.feed(p: Float, n: Int): List<SpeechEvent> =
        List(n) { onProbability(p) }.filter { it != SpeechEvent.None }

    @Test
    fun `two above then below does not start`() {
        val d = SpeechDetector()
        assertEquals(emptyList<SpeechEvent>(), d.feed(hi, 2) + d.feed(lo, 1))
    }

    @Test
    fun `three consecutive above start exactly once`() {
        val d = SpeechDetector()
        assertEquals(listOf(SpeechEvent.SpeechStart), d.feed(hi, 10))
    }

    @Test
    fun `end fires on 22nd below chunk only`() {
        val d = SpeechDetector()
        d.feed(hi, 3)
        assertEquals(emptyList<SpeechEvent>(), d.feed(lo, 21))
        assertEquals(listOf(SpeechEvent.SpeechEnd), d.feed(lo, 1))
        assertEquals(emptyList<SpeechEvent>(), d.feed(lo, 30))
    }

    @Test
    fun `above chunk inside hangover resets it`() {
        val d = SpeechDetector()
        d.feed(hi, 3)
        d.feed(lo, 21)
        assertEquals(emptyList<SpeechEvent>(), d.feed(hi, 1))
        assertEquals(emptyList<SpeechEvent>(), d.feed(lo, 21))
        assertEquals(listOf(SpeechEvent.SpeechEnd), d.feed(lo, 1))
    }

    @Test
    fun `reset returns to idle`() {
        val d = SpeechDetector()
        d.feed(hi, 3)
        d.feed(lo, 10)
        d.reset()
        // Idle: no end ever fires, and attack needs a fresh 3 chunks.
        assertEquals(emptyList<SpeechEvent>(), d.feed(lo, 30))
        assertEquals(emptyList<SpeechEvent>(), d.feed(hi, 2))
        assertEquals(listOf(SpeechEvent.SpeechStart), d.feed(hi, 1))
    }
}
