package com.jessvb.tinytalk.voice

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.core.audio.SpeechDetector
import com.jessvb.tinytalk.core.audio.SpeechEvent
import com.jessvb.tinytalk.core.voice.AssembledUtterance
import com.jessvb.tinytalk.core.voice.UtteranceAssembler
import com.jessvb.tinytalk.spike.SentenceTts
import com.jessvb.tinytalk.spike.SileroVad
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import kotlin.math.sqrt

private const val TAG = "TinyTalkVoiceReplay"

/**
 * SILENT first-word-clipping check (Review Focus 5): replays WAV files through the REAL
 * SileroVad + SpeechDetector + UtteranceAssembler. No AudioRecord, AudioTrack or
 * TextToSpeech: nothing is recorded or played.
 *
 * WAVs (16 kHz mono 16-bit, one continuous phrase each) are not committed; push them first:
 *   adb shell mkdir -p /sdcard/Android/data/com.jessvb.tinytalk/files/vad-replay
 *   adb push some.wav /sdcard/Android/data/com.jessvb.tinytalk/files/vad-replay/
 * The test is skipped (Assume) when none are present.
 */
class VoiceLoopReplayTest {
    private val sampleRate = 16000
    private val frameSize = 512
    private lateinit var vad: SileroVad

    @Before
    fun setUp() {
        vad = SileroVad(InstrumentationRegistry.getInstrumentation().targetContext)
    }

    @After
    fun tearDown() = vad.close()

    private fun replayFiles(): List<File> {
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "vad-replay")
        return dir.listFiles { f -> f.isFile && f.name.endsWith(".wav", ignoreCase = true) }
            ?.sortedBy { it.name }.orEmpty()
    }

    private fun rms(a: ShortArray, from: Int, to: Int): Double {
        if (to <= from) return 0.0
        var sum = 0.0
        for (i in from until to) sum += a[i].toDouble() * a[i]
        return sqrt(sum / (to - from))
    }

    @Test
    fun firstWordIsInsideTheUtteranceWithPreRoll() {
        val files = replayFiles()
        assumeTrue("no WAVs in files/vad-replay; push some with adb to run this check", files.isNotEmpty())
        for (file in files) replay(file)
    }

    private fun replay(file: File) {
        val wav = SentenceTts.decodeWav(file) ?: error("${file.name}: not mono 16-bit PCM WAV")
        assertEquals("${file.name}: sample rate", sampleRate, wav.sampleRate)

        // 1.5 s of digital silence before (so a pre-roll exists) and after (so SpeechEnd fires).
        val lead = sampleRate * 3 / 2
        val trail = sampleRate * 3 / 2
        val total = ((lead + wav.pcm.size + trail + frameSize - 1) / frameSize) * frameSize
        val signal = ShortArray(total)
        System.arraycopy(wav.pcm, 0, signal, lead, wav.pcm.size)
        val frames = total / frameSize

        // Independent ground truth: the first frame whose energy says "voice".
        val firstVoicedFrame = (0 until frames).first { k ->
            rms(signal, k * frameSize, (k + 1) * frameSize) > VOICED_RMS
        }

        vad.reset()
        val detector = SpeechDetector()
        val assembler = UtteranceAssembler()
        val utterances = ArrayList<AssembledUtterance>()
        var speechStartFrame = -1
        var vadMsTotal = 0.0
        for (k in 0 until frames) {
            val frame = signal.copyOfRange(k * frameSize, (k + 1) * frameSize)
            val t0 = System.nanoTime()
            val p = vad.probability(frame)
            vadMsTotal += (System.nanoTime() - t0) / 1e6
            val event = detector.onProbability(p)
            if (event == SpeechEvent.SpeechStart && speechStartFrame < 0) speechStartFrame = k
            assembler.onFrame(frame, event)?.let { utterances += it }
        }

        assertEquals("${file.name}: utterance count", 1, utterances.size)
        val u = utterances[0]
        val preRollSamples = u.startedWithPreRollMs * sampleRate / 1000
        val uttStart = speechStartFrame * frameSize - preRollSamples
        // The utterance really is that stretch of the signal (positions below are trustworthy).
        assertArrayEquals(
            "${file.name}: utterance content",
            signal.copyOfRange(uttStart, uttStart + u.pcm16.size),
            u.pcm16,
        )

        val firstVoicedSample = firstVoicedFrame * frameSize
        val leadBeforeVoiceMs = (firstVoicedSample - uttStart) * 1000 / sampleRate
        val attackDelayMs = (speechStartFrame - firstVoicedFrame) * frameSize * 1000 / sampleRate
        val openingRms = rms(u.pcm16, 0, minOf(u.pcm16.size, sampleRate / 5))
        Log.i(
            TAG,
            "${file.name}: preRoll=${u.startedWithPreRollMs} ms, firstVoicedFrame=$firstVoicedFrame, " +
                "speechStartFrame=$speechStartFrame, attackDelay=$attackDelayMs ms, " +
                "audio before first voice in utterance=$leadBeforeVoiceMs ms, opening 200 ms rms=${"%.1f".format(openingRms)}, " +
                "utterance=${u.pcm16.size * 1000 / sampleRate} ms (source ${wav.pcm.size * 1000 / sampleRate} ms), " +
                "vad mean=${"%.2f".format(vadMsTotal / frames)} ms/frame",
        )

        assertTrue("${file.name}: speech never detected", speechStartFrame >= 0)
        assertTrue("${file.name}: utterance does not start with quiet pre-roll (rms $openingRms)", openingRms < QUIET_RMS)
        assertTrue(
            "${file.name}: first word clipped: only $leadBeforeVoiceMs ms before first voiced frame",
            leadBeforeVoiceMs >= MIN_LEAD_MS,
        )
        val lastVoicedFrame = (frames - 1 downTo 0).first { k ->
            rms(signal, k * frameSize, (k + 1) * frameSize) > VOICED_RMS
        }
        assertTrue(
            "${file.name}: end of speech cut off",
            uttStart + u.pcm16.size >= (lastVoicedFrame + 1) * frameSize,
        )
    }

    private companion object {
        const val VOICED_RMS = 300.0 // int16; the padding is digital silence
        const val QUIET_RMS = 100.0
        const val MIN_LEAD_MS = 100
    }
}
