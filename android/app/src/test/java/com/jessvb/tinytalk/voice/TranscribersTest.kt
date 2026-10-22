package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class TranscribersTest {
    private class Fake(val tag: String) : SpeechTranscribing, AutoCloseable {
        var calls = 0
        var closed = false
        override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String { calls++; return tag }
        override fun close() { closed = true }
    }

    private class CountingFactory : TranscriberFactory {
        val made = mutableListOf<Fake>()
        override fun create(mode: SttMode): SpeechTranscribing = Fake(mode.name).also { made += it }
        override fun isAvailable(mode: SttMode) = true
    }

    @Test fun usesTheModeReadAtEachCall() = runBlocking {
        var mode = SttMode.ON_DEVICE
        val t = ModeSwitchingTranscriber({ mode }, CountingFactory())
        assertEquals("ON_DEVICE", t.transcribe(ShortArray(1), 16000))
        mode = SttMode.CLOUD
        assertEquals("CLOUD", t.transcribe(ShortArray(1), 16000))
        mode = SttMode.ON_DEVICE
        assertEquals("ON_DEVICE", t.transcribe(ShortArray(1), 16000))
    }

    @Test fun buildsEachTranscriberOnceAndKeepsItWarm() = runBlocking {
        var mode = SttMode.ON_DEVICE
        val f = CountingFactory()
        val t = ModeSwitchingTranscriber({ mode }, f)
        repeat(3) { t.transcribe(ShortArray(1), 16000) }
        mode = SttMode.CLOUD
        repeat(2) { t.transcribe(ShortArray(1), 16000) }
        assertEquals(listOf("ON_DEVICE", "CLOUD"), f.made.map { it.tag })
        assertEquals(listOf(3, 2), f.made.map { it.calls })
    }

    @Test fun closeClosesWhatWasBuilt() = runBlocking {
        val f = CountingFactory()
        val t = ModeSwitchingTranscriber({ SttMode.CLOUD }, f)
        t.transcribe(ShortArray(1), 16000)
        t.close()
        assertTrue(f.made.single().closed)
    }

    @Test fun notReadyTranscriberFailsClearly() = runBlocking {
        try {
            NotReadyTranscriber().transcribe(ShortArray(1), 16000)
            fail("expected IllegalStateException")
        } catch (e: IllegalStateException) {
            assertEquals("on-device speech recognition is not installed yet", e.message)
        }
    }

    @Test fun appFactoryCloudIsAvailableOnDeviceNotYet() {
        val f = AppTranscriberFactory(groqKey = { "fake-key" })
        assertTrue(f.isAvailable(SttMode.CLOUD))
        assertFalse(f.isAvailable(SttMode.ON_DEVICE)) // flips to true in Task 4b-B
        assertTrue(f.create(SttMode.ON_DEVICE) is NotReadyTranscriber)
        assertFalse(f.create(SttMode.CLOUD) is NotReadyTranscriber)
    }
}
