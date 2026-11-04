package com.jessvb.tinytalk.spike

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin
import kotlin.random.Random

private const val TAG = "TinyTalkSpike"

class SileroVadTest {
    private lateinit var vad: SileroVad

    @Before
    fun setUp() {
        vad = SileroVad(InstrumentationRegistry.getInstrumentation().targetContext)
        Log.i(TAG, "SileroVad model info: ${vad.modelInfo()}")
    }

    @After
    fun tearDown() = vad.close()

    private fun noisyFrames(n: Int): List<ShortArray> {
        val rnd = Random(1)
        var t = 0
        return List(n) {
            ShortArray(512) {
                val s = 12000 * sin(2 * PI * 220 * t / 16000) * sin(2 * PI * 3 * t / 16000 * 50) +
                    rnd.nextInt(-4000, 4000)
                t++
                s.toInt().toShort()
            }
        }
    }

    @Test
    fun silenceGivesLowProbabilityAndTimings() {
        val times = ArrayList<Double>()
        val probs = ArrayList<Float>()
        repeat(50) {
            val t0 = System.nanoTime()
            probs += vad.probability(ShortArray(512))
            times += (System.nanoTime() - t0) / 1e6
        }
        Log.i(TAG, "silence probs max=${probs.max()} mean=${probs.average()}")
        Log.i(TAG, "inference ms per 512-sample frame: mean=${times.average()} max=${times.max()} (budget 32 ms)")
        assertTrue("silence max ${probs.max()}", probs.all { it < 0.2f })
    }

    @Test
    fun loudNoiseRunsAndIsFiniteInRange() {
        val probs = noisyFrames(40).map { vad.probability(it) }
        Log.i(TAG, "noise probs max=${probs.max()} mean=${probs.average()}")
        assertTrue(probs.all { it.isFinite() && it in 0f..1f })
    }

    @Test
    fun resetRestoresIdenticalOutput() {
        val frames = noisyFrames(10)
        val first = frames.map { vad.probability(it) }
        vad.reset()
        val second = frames.map { vad.probability(it) }
        assertEquals(first, second)
    }
}
