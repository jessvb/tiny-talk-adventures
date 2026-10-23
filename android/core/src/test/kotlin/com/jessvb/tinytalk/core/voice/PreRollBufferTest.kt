package com.jessvb.tinytalk.core.voice

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PreRollBufferTest {
    /** Frames whose samples are their global index (mod 32000), so order is checkable. */
    private fun numbered(start: Int, n: Int) = ShortArray(n) { ((start + it) % 32000).toShort() }

    @Test
    fun `after 2 s of numbered samples snapshot is exactly the last capacity in order`() {
        val b = PreRollBuffer(capacityMs = 600, sampleRate = 16000)
        var idx = 0
        while (idx < 32000) {
            b.push(numbered(idx, 512))
            idx += 512
        }
        val snap = b.snapshot()
        assertEquals(9600, snap.size)
        assertArrayEquals(numbered(idx - 9600, 9600), snap)
    }

    @Test
    fun `shorter history returns what exists`() {
        val b = PreRollBuffer(capacityMs = 600, sampleRate = 16000)
        b.push(numbered(0, 512))
        b.push(numbered(512, 512))
        assertArrayEquals(numbered(0, 1024), b.snapshot())
    }

    @Test
    fun `empty buffer snapshot is empty`() {
        assertEquals(0, PreRollBuffer(500).snapshot().size)
    }

    @Test
    fun `frame larger than capacity keeps only its tail`() {
        val b = PreRollBuffer(capacityMs = 10, sampleRate = 16000) // 160 samples
        b.push(numbered(0, 512))
        assertArrayEquals(numbered(352, 160), b.snapshot())
    }

    @Test
    fun `wraparound across many partial frames stays ordered`() {
        val b = PreRollBuffer(capacityMs = 10, sampleRate = 16000) // 160 samples
        var idx = 0
        repeat(50) {
            b.push(numbered(idx, 37))
            idx += 37
        }
        assertArrayEquals(numbered(idx - 160, 160), b.snapshot())
    }

    @Test
    fun `clear empties it`() {
        val b = PreRollBuffer(500)
        b.push(numbered(0, 512))
        b.clear()
        assertEquals(0, b.snapshot().size)
        b.push(numbered(7, 3))
        assertArrayEquals(numbered(7, 3), b.snapshot())
    }
}
