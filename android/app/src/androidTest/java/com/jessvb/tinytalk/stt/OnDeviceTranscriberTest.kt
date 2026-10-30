package com.jessvb.tinytalk.stt

import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.spike.SentenceTts
import com.jessvb.tinytalk.spike.SileroVad
import com.jessvb.tinytalk.voice.ListeningAvailability
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File

private const val TAG = "TinyTalkSttTest"

/**
 * SILENT check of on-device listening: loads the real Whisper tiny.en model from the APK and
 * transcribes WAV files. No AudioRecord, AudioTrack, TextToSpeech or MediaPlayer: nothing is
 * recorded or played (SentenceTts.decodeWav only parses a file).
 *
 * WAVs come from android/stt-spike/testdata/wav (synthetic adult voices, named uNN_Voice.wav)
 * and are not committed; push a few first:
 *   adb shell mkdir -p /sdcard/Android/data/com.jessvb.tinytalk/files/stt-wav
 *   adb push android/stt-spike/testdata/wav/u01_Daniel.wav /sdcard/Android/data/com.jessvb.tinytalk/files/stt-wav/
 * The WAV checks are skipped (Assume) when none are present; the load check always runs.
 */
class OnDeviceTranscriberTest {
    companion object {
        private lateinit var stt: OnDeviceTranscriber
        private var loadWallMs = 0L

        @BeforeClass @JvmStatic
        fun loadOnce() {
            val ctx = InstrumentationRegistry.getInstrumentation().targetContext
            stt = OnDeviceTranscriber(ctx)
            val t0 = SystemClock.elapsedRealtime()
            val nativeMs = stt.load()
            loadWallMs = SystemClock.elapsedRealtime() - t0
            Log.i(TAG, "load: wall=$loadWallMs ms (unpack + native), native=$nativeMs ms")
        }

        @AfterClass @JvmStatic
        fun close() = stt.close()

        /** android/stt-spike/utterances.tsv */
        private val REFERENCE = mapOf(
            "u01" to "The little fox wants to find a red balloon",
            "u02" to "Can the bunny build a boat",
            "u03" to "I want a dragon who is friendly",
            "u04" to "Yes",
            "u05" to "A big cat",
            "u06" to "No thank you",
            "u07" to "Let us name her Luna",
            "u08" to "The bear has three blue hats",
            "u09" to "Maybe the owl can fly to the moon",
            "u10" to "I think the turtle is hungry",
            "u11" to "They went up the hill and found seven shiny stones",
            "u12" to "My name is Max and I am six",
            "u13" to "Can we make the frog jump over the river",
            "u14" to "The princess and the penguin are best friends",
            "u15" to "What if the castle was made of cheese",
            "u16" to "Okay",
            "u17" to "A purple elephant with wings",
            "u18" to "The ducks said quack quack quack",
            "u19" to "Mia and Noah found a magic door in the garden",
            "u20" to "He is scared of the dark forest",
            "u21" to "Tell me more about the sleepy giraffe",
            "u22" to "The end",
            "u23" to "I want the monkey to eat twelve bananas",
            "u24" to "The puppy and the kitten had a picnic by the lake",
        )

        private fun words(s: String) = s.lowercase().split(Regex("[^a-z0-9']+")).filter { it.isNotEmpty() }
    }

    private fun wavFiles(): List<File> {
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "stt-wav")
        return dir.listFiles { f -> f.isFile && f.name.endsWith(".wav", ignoreCase = true) }
            ?.sortedBy { it.name }.orEmpty()
    }

    private fun pcm(file: File): ShortArray {
        val wav = SentenceTts.decodeWav(file) ?: error("${file.name}: not mono 16-bit PCM WAV")
        assertEquals("${file.name}: sample rate", OnDeviceTranscriber.SAMPLE_RATE, wav.sampleRate)
        return wav.pcm
    }

    @Test
    fun modelLoadsAndIsAvailable() {
        assertTrue(stt.isLoaded)
        assertEquals(ListeningAvailability.READY, stt.availability.value)
    }

    @Test
    fun transcribesTheKeyWords() = runBlocking {
        val files = wavFiles()
        assumeTrue("no WAVs in files/stt-wav; push some with adb to run this check", files.isNotEmpty())
        stt.transcribe(pcm(files.first()), OnDeviceTranscriber.SAMPLE_RATE) // warm-up, untimed
        for (file in files) {
            val id = file.name.substringBefore('_')
            val ref = REFERENCE[id] ?: error("${file.name}: no reference text for $id")
            val audio = pcm(file)
            val t0 = SystemClock.elapsedRealtime()
            val text = stt.transcribe(audio, OnDeviceTranscriber.SAMPLE_RATE)
            val ms = SystemClock.elapsedRealtime() - t0
            val refWords = words(ref)
            val got = words(text).toSet()
            val overlap = refWords.count { it in got }.toDouble() / refWords.size
            // Test data is synthetic adult speech, so logging the text here is fine.
            Log.i(TAG, "${file.name}: audio=${audio.size * 1000 / 16000} ms latency=$ms ms overlap=%.2f text=\"$text\"".format(overlap))
            assertTrue("${file.name}: empty transcript", text.isNotBlank())
            assertTrue("${file.name}: only %.0f%% of the reference words".format(overlap * 100), overlap >= 0.6)
        }
    }

    /**
     * Both native ONNX Runtimes live in this one process at the same time: the one statically
     * linked into libsherpa-onnx-jni.so (Whisper) and onnxruntime-android's libonnxruntime.so
     * (SileroVad), interleaved while both models are loaded.
     */
    @Test
    fun whisperAndSileroVadWorkSideBySide() = runBlocking {
        val file = wavFiles().firstOrNull()
        assumeTrue("no WAVs in files/stt-wav; push some with adb to run this check", file != null)
        val audio = pcm(file!!)
        SileroVad(InstrumentationRegistry.getInstrumentation().targetContext).use { vad ->
            val speech = (0 until audio.size / 512).maxOf { k -> vad.probability(audio.copyOfRange(k * 512, (k + 1) * 512)) }
            val text = stt.transcribe(audio, OnDeviceTranscriber.SAMPLE_RATE)
            vad.reset()
            val silence = vad.probability(ShortArray(512))
            Log.i(TAG, "side by side: vad max speech p=%.2f, silence p=%.2f, whisper ${text.length} chars".format(speech, silence))
            assertTrue("VAD heard no speech (p=$speech)", speech > 0.5f)
            assertTrue(text.isNotBlank())
        }
    }

    /**
     * The caller's timeout must take effect at once even though the native decode cannot be
     * interrupted, and the next decode must still work (it waits for the abandoned one).
     */
    @Test
    fun aCancelledDecodeReturnsAtOnceAndTheNextOneStillWorks() = runBlocking {
        val file = wavFiles().firstOrNull()
        assumeTrue("no WAVs in files/stt-wav; push some with adb to run this check", file != null)
        val audio = pcm(file!!)
        val t0 = SystemClock.elapsedRealtime()
        try {
            withTimeout(50) { stt.transcribe(audio, OnDeviceTranscriber.SAMPLE_RATE) }
            fail("a decode finished in under 50 ms; cannot check cancellation")
        } catch (e: TimeoutCancellationException) {
            // expected
        }
        val cancelMs = SystemClock.elapsedRealtime() - t0
        val t1 = SystemClock.elapsedRealtime()
        val next = stt.transcribe(audio, OnDeviceTranscriber.SAMPLE_RATE)
        val nextMs = SystemClock.elapsedRealtime() - t1
        Log.i(TAG, "cancel: returned after $cancelMs ms; next decode took $nextMs ms (incl. waiting for the abandoned one)")
        assertTrue("cancellation took $cancelMs ms", cancelMs < 300)
        assertTrue(next.isNotBlank())
    }
}
