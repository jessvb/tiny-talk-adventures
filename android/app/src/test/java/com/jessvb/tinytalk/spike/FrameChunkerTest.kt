package com.jessvb.tinytalk.spike

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameChunkerTest {
    @Test
    fun `300 then 724 samples yield two frames and no leftover`() {
        val chunker = FrameChunker()
        val first = chunker.push(ShortArray(300) { it.toShort() }, 300)
        assertTrue(first.isEmpty())
        val second = chunker.push(ShortArray(724) { (300 + it).toShort() }, 724)
        assertEquals(2, second.size)
        assertTrue(second.all { it.size == 512 })
        // Nothing left over: a further 512 yields exactly one frame.
        assertEquals(1, chunker.push(ShortArray(512), 512).size)
    }

    @Test
    fun `100 samples yield no frames`() {
        assertTrue(FrameChunker().push(ShortArray(100), 100).isEmpty())
    }

    @Test
    fun `frames preserve sample order`() {
        val chunker = FrameChunker()
        chunker.push(ShortArray(300) { it.toShort() }, 300)
        val frames = chunker.push(ShortArray(724) { (300 + it).toShort() }, 724)
        val flat = frames.flatMap { it.toList() }
        assertEquals((0 until 1024).map { it.toShort() }, flat)
    }

    @Test
    fun `length smaller than array only uses length samples`() {
        val frames = FrameChunker(frameSize = 4).push(shortArrayOf(1, 2, 3, 4, 5, 6), 5)
        assertEquals(1, frames.size)
        assertEquals(listOf<Short>(1, 2, 3, 4), frames[0].toList())
    }
}
