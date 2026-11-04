package com.jessvb.tinytalk.spike

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import com.jessvb.tinytalk.voice.SpeechProbability
import java.nio.FloatBuffer
import java.nio.LongBuffer

/**
 * Silero VAD (same model file as iOS). Contract per iOS VoiceActivityDetector.swift:
 * input float32 [1, 576] = 64 context samples + 512 new, state float32 [2,1,128],
 * sr int64 scalar (shape []) = 16000; outputs `output` ([1,1] probability) and `stateN`.
 * Not thread-safe: call from one thread.
 */
class SileroVad(context: Context) : AutoCloseable, SpeechProbability {
    private val env = OrtEnvironment.getEnvironment()
    private val session: OrtSession = context.assets.open(MODEL_ASSET).use {
        env.createSession(it.readBytes(), OrtSession.SessionOptions())
    }
    private var state = FloatArray(STATE_SIZE)
    private val ctx = FloatArray(CONTEXT)

    /** Human-readable input/output info of the loaded model, for the spike log. */
    fun modelInfo(): String =
        "inputs=${session.inputInfo} outputs=${session.outputInfo}"

    override fun probability(frame512: ShortArray): Float {
        require(frame512.size == FRAME) { "expected $FRAME samples, got ${frame512.size}" }
        val input = FloatArray(CONTEXT + FRAME)
        System.arraycopy(ctx, 0, input, 0, CONTEXT)
        for (i in 0 until FRAME) input[CONTEXT + i] = frame512[i] / 32768f

        val tensors = ArrayList<OnnxTensor>(3)
        try {
            tensors += OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, input.size.toLong()))
            tensors += OnnxTensor.createTensor(env, FloatBuffer.wrap(state), longArrayOf(2, 1, 128))
            tensors += OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(16000L)), longArrayOf())
            val feeds = mapOf("input" to tensors[0], "state" to tensors[1], "sr" to tensors[2])
            session.run(feeds).use { result ->
                @Suppress("UNCHECKED_CAST")
                val out = (result.get("output").get().value as Array<FloatArray>)[0][0]
                @Suppress("UNCHECKED_CAST")
                val sn = result.get("stateN").get().value as Array<Array<FloatArray>>
                val newState = FloatArray(STATE_SIZE)
                var k = 0
                for (a in sn) for (b in a) for (v in b) newState[k++] = v
                state = newState
                System.arraycopy(input, input.size - CONTEXT, ctx, 0, CONTEXT)
                return out
            }
        } finally {
            tensors.forEach { it.close() }
        }
    }

    override fun reset() {
        state = FloatArray(STATE_SIZE)
        ctx.fill(0f)
    }

    override fun close() {
        session.close()
    }

    companion object {
        const val MODEL_ASSET = "silero_vad.onnx"
        private const val FRAME = 512
        private const val CONTEXT = 64
        private const val STATE_SIZE = 2 * 1 * 128
    }
}
