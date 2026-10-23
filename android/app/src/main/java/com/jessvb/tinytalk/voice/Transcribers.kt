package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.stt.GroqWhisperClient
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import kotlinx.coroutines.flow.StateFlow

/** Whether a listening mode can be used right now. */
enum class ListeningAvailability {
    READY,
    /** On-phone listening: the model is still loading (a few seconds after app start). */
    LOADING,
    /** On-phone listening: the model could not load (until the app is restarted). */
    FAILED,
}

/** A transcriber that must warm up before it can be used (the on-phone recogniser). */
interface WarmTranscriber : SpeechTranscribing {
    val availability: StateFlow<ListeningAvailability>
}

/** The transcriber seam: the ONE place that maps an [SttMode] to a [SpeechTranscribing]. */
interface TranscriberFactory {
    fun create(mode: SttMode): SpeechTranscribing

    fun availability(mode: SttMode): ListeningAvailability

    /** False when [create] for this mode can only fail (nothing to listen with yet). */
    fun isAvailable(mode: SttMode): Boolean = availability(mode) == ListeningAvailability.READY
}

/**
 * CLOUD -> Groq Whisper (only after the parent confirmed "better listening");
 * ON_DEVICE -> the one warm on-phone recogniser ([onDevice], owned and loaded by the app
 * container), available only once its model has actually loaded.
 */
class AppTranscriberFactory(
    private val groqKey: () -> String?,
    private val onDevice: WarmTranscriber,
) : TranscriberFactory {
    override fun create(mode: SttMode): SpeechTranscribing = when (mode) {
        SttMode.CLOUD -> GroqWhisperClient(apiKey = groqKey)
        SttMode.ON_DEVICE -> onDevice
    }

    override fun availability(mode: SttMode): ListeningAvailability = when (mode) {
        SttMode.CLOUD -> ListeningAvailability.READY
        SttMode.ON_DEVICE -> onDevice.availability.value
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
