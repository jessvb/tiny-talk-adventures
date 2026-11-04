package com.jessvb.tinytalk.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class WaitingDittyTest {
    private val rate = WaitingDitty.SAMPLE_RATE

    @Test fun `one loop is four 180 ms notes plus a 350 ms silent tail`() {
        assertEquals((4 * 0.18 * rate + 0.35 * rate).toInt(), WaitingDitty.samples.size)
    }

    @Test fun `each note is audible and the tail is silent so the loop breathes`() {
        val note = (0.18 * rate).toInt()
        for (n in 0 until 4) {
            val peak = (n * note until n * note + note / 4).maxOf { abs(WaitingDitty.samples[it].toInt()) }
            assertTrue("note $n peak $peak", peak > 1000)
        }
        val tail = WaitingDitty.samples.drop(4 * note)
        assertTrue(tail.all { it.toInt() == 0 })
    }

    @Test fun `it stays gentle and never clips`() {
        val peak = WaitingDitty.samples.maxOf { abs(it.toInt()) }
        assertTrue("peak $peak", peak < Short.MAX_VALUE / 3)
    }

    @Test fun `notes decay like a bell`() {
        val note = (0.18 * rate).toInt()
        val early = (0 until note / 4).maxOf { abs(WaitingDitty.samples[it].toInt()) }
        val late = (note * 3 / 4 until note).maxOf { abs(WaitingDitty.samples[it].toInt()) }
        assertTrue(late < early / 2)
    }
}
