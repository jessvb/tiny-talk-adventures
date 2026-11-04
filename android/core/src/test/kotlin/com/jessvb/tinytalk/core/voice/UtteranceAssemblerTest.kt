package com.jessvb.tinytalk.core.voice

import com.jessvb.tinytalk.core.audio.SpeechEvent
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class UtteranceAssemblerTest {
    private val f = 512 // frame size, 32 ms at 16 kHz

    /** Frame [k]'s samples are their global sample index (mod 32000). */
    private fun frame(k: Int) = ShortArray(f) { ((k * f + it) % 32000).toShort() }
    private fun range(fromSample: Int, toSampleExclusive: Int) =
        ShortArray(toSampleExclusive - fromSample) { ((fromSample + it) % 32000).toShort() }

    /** Feeds frames [from, to) with no event; returns any utterance produced (there should be none). */
    private fun UtteranceAssembler.quiet(from: Int, to: Int) {
        for (k in from until to) assertNull("frame $k", onFrame(frame(k), SpeechEvent.None))
    }

    /**
     * SpeechStart at [start], voiced frames through [lastVoiced], then 22 silent frames with
     * SpeechEnd on the 22nd (exactly how SpeechDetector behaves). Returns the SpeechEnd result.
     */
    private fun UtteranceAssembler.speak(start: Int, lastVoiced: Int, hangover: Int = 22): AssembledUtterance? {
        assertNull(onFrame(frame(start), SpeechEvent.SpeechStart))
        quiet(start + 1, lastVoiced + hangover)
        return onFrame(frame(lastVoiced + hangover), SpeechEvent.SpeechEnd)
    }

    @Test
    fun `utterance begins exactly preRollMs before the SpeechStart frame and keeps tailTrimMs after last voiced frame`() {
        val a = UtteranceAssembler(preRollMs = 600, tailTrimMs = 300)
        a.quiet(0, 40)
        val u = a.speak(start = 40, lastVoiced = 59)!!
        val first = 40 * f - 9600 // 600 ms = 9600 samples before frame 40
        val lastVoicedEnd = 60 * f
        assertEquals(600, u.startedWithPreRollMs)
        assertArrayEquals(range(first, lastVoicedEnd + 4800), u.pcm16) // + 300 ms tail
    }

    @Test
    fun `pre-roll covers the detector attack frames before SpeechStart`() {
        // Speech really began at frame 37; the detector fires SpeechStart on the 3rd voiced frame (39).
        val a = UtteranceAssembler(preRollMs = 600)
        a.quiet(0, 39)
        val u = a.speak(start = 39, lastVoiced = 50)!!
        val firstSample = u.pcm16[0].toInt()
        assert(firstSample <= 37 * f - 3200) { "onset not covered with >=200 ms margin: $firstSample" }
    }

    @Test
    fun `pre-roll is filled by frames pushed while Elsie was speaking or thinking`() {
        // The assembler is state-agnostic: every frame pushed (whatever the loop state) is history.
        val a = UtteranceAssembler(preRollMs = 600)
        a.quiet(0, 10) // "LISTENING"
        assertNotNull(a.speak(start = 10, lastVoiced = 20)) // first utterance, frames 10..42
        a.quiet(43, 80) // "THINKING" then "SPEAKING": no events, but frames keep flowing
        val u = a.speak(start = 80, lastVoiced = 90)!!
        assertEquals(600, u.startedWithPreRollMs)
        assertEquals((80 * f - 9600).toShort(), u.pcm16[0])
    }

    @Test
    fun `shorter history gives what exists`() {
        val a = UtteranceAssembler(preRollMs = 600)
        a.quiet(0, 5)
        val u = a.speak(start = 5, lastVoiced = 10)!!
        assertEquals(160, u.startedWithPreRollMs) // 5 frames * 32 ms
        assertArrayEquals(range(0, 11 * f + 4800), u.pcm16)
    }

    @Test
    fun `no pre-roll at all when SpeechStart is the first frame`() {
        val a = UtteranceAssembler(preRollMs = 600)
        val u = a.speak(start = 0, lastVoiced = 5)!!
        assertEquals(0, u.startedWithPreRollMs)
        assertArrayEquals(range(0, 6 * f + 4800), u.pcm16)
    }

    @Test
    fun `tail longer than the hangover is not invented`() {
        val a = UtteranceAssembler(preRollMs = 0, tailTrimMs = 2000)
        val u = a.speak(start = 0, lastVoiced = 5)!!
        assertArrayEquals(range(0, 28 * f), u.pcm16) // all 22 hangover frames, nothing more
    }

    @Test
    fun `utterance shorter than minUtteranceMs is dropped as a blip`() {
        val a = UtteranceAssembler(preRollMs = 600, minUtteranceMs = 300)
        a.quiet(0, 30)
        assertNull(a.speak(start = 30, lastVoiced = 32)) // 3 frames = 96 ms voiced
        val u = a.speak(start = 60, lastVoiced = 69) // 10 frames = 320 ms voiced
        assertNotNull(u)
    }

    @Test
    fun `default minimum keeps even the shortest detectable utterance (iOS has no minimum)`() {
        val a = UtteranceAssembler()
        assertNotNull(a.speak(start = 0, lastVoiced = 0))
    }

    @Test
    fun `utterance longer than maxUtteranceMs is cut and returned, rest discarded until SpeechEnd`() {
        val a = UtteranceAssembler(preRollMs = 600, maxUtteranceMs = 2000) // 32000 samples
        a.quiet(0, 30)
        assertNull(a.onFrame(frame(30), SpeechEvent.SpeechStart))
        var cut: AssembledUtterance? = null
        var k = 31
        while (cut == null && k < 200) {
            cut = a.onFrame(frame(k), SpeechEvent.None)
            k++
        }
        assertNotNull(cut)
        val first = 30 * f - 9600
        assertArrayEquals(range(first, first + 32000), cut!!.pcm16)
        a.quiet(k, k + 20) // still talking: discarded, nothing returned
        assertNull(a.onFrame(frame(k + 20), SpeechEvent.SpeechEnd))
        // A fresh utterance afterwards works normally.
        a.quiet(k + 21, k + 40)
        assertEquals(600, a.speak(start = k + 40, lastVoiced = k + 45)!!.startedWithPreRollMs)
    }

    @Test
    fun `back-to-back utterances do not leak samples into each other`() {
        val a = UtteranceAssembler(preRollMs = 600, tailTrimMs = 300)
        a.quiet(0, 20)
        val u1 = a.speak(start = 20, lastVoiced = 25)!! // SpeechEnd at frame 47
        val u2 = a.speak(start = 48, lastVoiced = 52)!! // starts immediately after
        assertArrayEquals(range(20 * f - 9600, 26 * f + 4800), u1.pcm16)
        // u2 is exactly its own 600 ms of history plus its own frames, contiguous.
        assertArrayEquals(range(48 * f - 9600, 53 * f + 4800), u2.pcm16)
    }

    @Test
    fun `SpeechEnd without a SpeechStart is ignored`() {
        val a = UtteranceAssembler()
        a.quiet(0, 10)
        assertNull(a.onFrame(frame(10), SpeechEvent.SpeechEnd))
    }

    @Test
    fun `reset clears the in-progress utterance and the pre-roll`() {
        val a = UtteranceAssembler(preRollMs = 600)
        a.quiet(0, 30)
        assertNull(a.onFrame(frame(30), SpeechEvent.SpeechStart))
        a.quiet(31, 40)
        a.reset()
        assertNull(a.onFrame(frame(40), SpeechEvent.SpeechEnd))
        val u = a.speak(start = 41, lastVoiced = 45)!!
        assertEquals(32, u.startedWithPreRollMs) // only frame 40 survived the reset
        assertArrayEquals(range(40 * f, 46 * f + 4800), u.pcm16)
    }
}
