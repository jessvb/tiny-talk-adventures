package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import com.jessvb.tinytalk.core.stt.GroqWhisperClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertSame
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
        override fun availability(mode: SttMode) = ListeningAvailability.READY
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

    private class FakeWarm : WarmTranscriber {
        override val availability = MutableStateFlow(ListeningAvailability.LOADING)
        override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int) = "on-device"
    }

    @Test fun onDeviceIsAvailableOnlyOnceItsModelHasLoaded() {
        val warm = FakeWarm()
        val f = AppTranscriberFactory(groqKey = { "fake-key" }, onDevice = warm)
        assertEquals(ListeningAvailability.LOADING, f.availability(SttMode.ON_DEVICE))
        assertFalse(f.isAvailable(SttMode.ON_DEVICE))

        warm.availability.value = ListeningAvailability.READY
        assertEquals(ListeningAvailability.READY, f.availability(SttMode.ON_DEVICE))
        assertTrue(f.isAvailable(SttMode.ON_DEVICE))

        warm.availability.value = ListeningAvailability.FAILED
        assertEquals(ListeningAvailability.FAILED, f.availability(SttMode.ON_DEVICE))
        assertFalse(f.isAvailable(SttMode.ON_DEVICE))
    }

    @Test fun onDeviceCreatesTheOneWarmInstanceAndCloudIsUnchanged() {
        val warm = FakeWarm()
        val f = AppTranscriberFactory(groqKey = { "fake-key" }, onDevice = warm)
        assertSame(warm, f.create(SttMode.ON_DEVICE))
        assertSame(warm, f.create(SttMode.ON_DEVICE))
        assertTrue(f.create(SttMode.CLOUD) is GroqWhisperClient)
        // Cloud availability never depends on the on-phone model.
        for (state in ListeningAvailability.entries) {
            warm.availability.value = state
            assertTrue(f.isAvailable(SttMode.CLOUD))
        }
    }
}
