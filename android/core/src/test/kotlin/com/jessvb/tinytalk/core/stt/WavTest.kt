package com.jessvb.tinytalk.core.stt

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Test

class WavTest {
    @Test
    fun headerAndPayload() {
        val pcm = shortArrayOf(1, -2, 0x1234, Short.MIN_VALUE)
        val wav = wavFromPcm16(pcm, 16000)
        assertEquals(44 + 8, wav.size)
        val b = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(at: Int) = String(wav, at, 4, Charsets.US_ASCII)
        assertEquals("RIFF", tag(0))
        assertEquals(36 + 8, b.getInt(4))
        assertEquals("WAVE", tag(8))
        assertEquals("fmt ", tag(12))
        assertEquals(16, b.getInt(16))
        assertEquals(1, b.getShort(20).toInt())
        assertEquals(1, b.getShort(22).toInt())
        assertEquals(16000, b.getInt(24))
        assertEquals(32000, b.getInt(28))
        assertEquals(2, b.getShort(32).toInt())
        assertEquals(16, b.getShort(34).toInt())
        assertEquals("data", tag(36))
        assertEquals(8, b.getInt(40))
        for (i in pcm.indices) assertEquals(pcm[i], b.getShort(44 + 2 * i))
    }

    @Test
    fun stereoFields() {
        val b = ByteBuffer.wrap(wavFromPcm16(ShortArray(2), 24000, 2)).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(2, b.getShort(22).toInt())
        assertEquals(96000, b.getInt(28))
        assertEquals(4, b.getShort(32).toInt())
    }
}
