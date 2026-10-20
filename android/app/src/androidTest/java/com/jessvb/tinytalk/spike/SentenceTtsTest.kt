package com.jessvb.tinytalk.spike

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

private const val TAG = "TinyTalkSpike"

class SentenceTtsTest {
    private val logs = CopyOnWriteArrayList<String>()
    private lateinit var tts: SentenceTts

    @Before
    fun setUp() {
        assumeTrue(
            "audible test; pass -Pandroid.testInstrumentationRunnerArguments.audible=true",
            InstrumentationRegistry.getArguments().getString("audible") == "true",
        )
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        tts = SentenceTts(ctx, { Log.i(TAG, it); logs += it })
        // Wait for engine init (ready or unavailable).
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline &&
            logs.none { it.startsWith("TTS ready") || it.startsWith("TTS UNAVAILABLE") }
        ) Thread.sleep(50)
        assumeTrue("TTS not ready: $logs", logs.any { it.startsWith("TTS ready") })
    }

    @After
    fun tearDown() {
        if (::tts.isInitialized) tts.close()
    }

    @Test
    fun speaksParagraphAndFinishes() {
        val t0 = System.currentTimeMillis()
        tts.speak(TEST_PARAGRAPH)
        assertTrue(tts.isSpeaking)
        val deadline = t0 + 60_000
        while (tts.isSpeaking && System.currentTimeMillis() < deadline) Thread.sleep(50)
        val total = System.currentTimeMillis() - t0
        assertFalse("still speaking after 60 s: $logs", tts.isSpeaking)
        Log.i(TAG, "RESULT paragraph total ms=$total firstAudioMs=${tts.lastFirstAudioLatencyMs} frames=${tts.framesWritten} ${tts.engineInfo}")
        assertTrue("no audio written: $logs", tts.framesWritten > 0)
        assertTrue(tts.lastFirstAudioLatencyMs > 0)
    }

    @Test
    fun stopHaltsAudioImmediatelyAndIsIdempotent() {
        tts.stop() // safe when idle
        tts.speak(TEST_PARAGRAPH)
        val deadline0 = System.currentTimeMillis() + 15_000
        while (tts.framesWritten == 0L && System.currentTimeMillis() < deadline0) Thread.sleep(10)
        assertTrue("no audio within 15 s: $logs", tts.framesWritten > 0)
        Thread.sleep(500) // stop mid-playback, with later sentences still synthesizing
        tts.stop()
        assertFalse(tts.isSpeaking)
        val framesAtStop = tts.framesWritten
        tts.stop() // twice
        assertFalse(tts.isSpeaking)
        Thread.sleep(4000) // later sentences would have been synthesized/played by now
        assertEquals("audio written after stop()", framesAtStop, tts.framesWritten)
        assertFalse(tts.isSpeaking)
        Log.i(TAG, "RESULT stop: framesAtStop=$framesAtStop firstAudioMs=${tts.lastFirstAudioLatencyMs}")

        // Usable again after stop.
        tts.speak("Hello again.")
        val deadline = System.currentTimeMillis() + 20_000
        while (tts.isSpeaking && System.currentTimeMillis() < deadline) Thread.sleep(50)
        assertFalse(tts.isSpeaking)
        assertTrue(tts.framesWritten > framesAtStop)
    }

    @Test
    fun repeatedFirstAudioLatency() {
        val latencies = ArrayList<Long>()
        repeat(3) {
            tts.speak("Hello there. This is a short test.")
            val deadline = System.currentTimeMillis() + 20_000
            while (tts.isSpeaking && System.currentTimeMillis() < deadline) Thread.sleep(50)
            latencies += tts.lastFirstAudioLatencyMs
        }
        Log.i(TAG, "RESULT first-audio latencies ms=$latencies")
        assertTrue(latencies.all { it > 0 })
    }
}
