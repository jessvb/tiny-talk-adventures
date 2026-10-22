package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.stt.GroqWhisperClient
import com.jessvb.tinytalk.core.stt.SpeechTranscribing

/**
 * The transcriber seam: the ONE place that maps an [SttMode] to a [SpeechTranscribing].
 * Task 4b-B swaps the on-device branch of [AppTranscriberFactory] for `OnDeviceTranscriber`.
 */
interface TranscriberFactory {
    fun create(mode: SttMode): SpeechTranscribing

    /** False when [create] for this mode can only fail (nothing to listen with). */
    fun isAvailable(mode: SttMode): Boolean
}

/** Placeholder for the on-device recogniser until Task 4b-B installs it. Never sends anything. */
class NotReadyTranscriber : SpeechTranscribing {
    override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String =
        throw IllegalStateException("on-device speech recognition is not installed yet")
}

/**
 * CLOUD -> Groq Whisper (only after the parent confirmed "better listening");
 * ON_DEVICE -> not installed yet.
 */
class AppTranscriberFactory(private val groqKey: () -> String?) : TranscriberFactory {
    override fun create(mode: SttMode): SpeechTranscribing = when (mode) {
        SttMode.CLOUD -> GroqWhisperClient(apiKey = groqKey)
        // TODO(Task 4b-B): return OnDeviceTranscriber(context) here (load it warm at app start)
        //  and make isAvailable(ON_DEVICE) true.
        SttMode.ON_DEVICE -> NotReadyTranscriber()
    }

    override fun isAvailable(mode: SttMode): Boolean = when (mode) {
        SttMode.CLOUD -> true
        SttMode.ON_DEVICE -> false // TODO(Task 4b-B): true once OnDeviceTranscriber is wired in.
    }
}

/**
 * Gives DemoSession one long-lived transcriber that follows the Settings switch without
 * rebuilding the session. Rule: the mode is read once at the START of each utterance's
 * transcription, so a switch takes effect from the next utterance and never changes one in
 * flight. In practice the switch can only change while the Story screen is not shown, and
 * leaving the Story screen stops the loop (which cancels any in-flight turn), so no turn ever
 * straddles a change. Each mode's transcriber is built lazily once and kept warm.
 */
class ModeSwitchingTranscriber(
    private val mode: () -> SttMode,
    private val factory: TranscriberFactory,
) : SpeechTranscribing, AutoCloseable {
    private val built = HashMap<SttMode, SpeechTranscribing>()

    private fun forMode(m: SttMode): SpeechTranscribing = synchronized(built) {
        built.getOrPut(m) { factory.create(m) }
    }

    override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String =
        forMode(mode()).transcribe(pcm16, sampleRate)

    override fun close() {
        val all = synchronized(built) { built.values.toList().also { built.clear() } }
        all.forEach { (it as? AutoCloseable)?.close() }
    }
}
