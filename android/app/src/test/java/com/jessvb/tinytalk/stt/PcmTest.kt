package com.jessvb.tinytalk.stt

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PcmTest {
    @Test fun int16MapsToMinusOneToJustUnderOne() {
        val out = pcm16ToFloat(shortArrayOf(0, Short.MIN_VALUE, Short.MAX_VALUE, 16384, -16384))
        assertArrayEquals(floatArrayOf(0f, -1f, 32767f / 32768f, 0.5f, -0.5f), out, 0f)
    }

    @Test fun emptyStaysEmpty() {
        assertEquals(0, pcm16ToFloat(ShortArray(0)).size)
    }
}
