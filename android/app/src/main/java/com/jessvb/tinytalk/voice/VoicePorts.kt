package com.jessvb.tinytalk.voice

/** Mic frame source ([com.jessvb.tinytalk.spike.MicCapture]); frames and loss reports come from its own thread. */
interface MicSource {
    /** True only if capture is actually running. */
    fun start(): Boolean

    /** Stops capture and waits for the capture thread to finish. Idempotent. */
    fun stop()
}

/** Per-frame speech probability ([com.jessvb.tinytalk.spike.SileroVad]). Called from the capture thread only. */
interface SpeechProbability {
    fun probability(frame512: ShortArray): Float
    fun reset()
}

/** Elsie's voice ([com.jessvb.tinytalk.spike.SentenceTts]). [stop] must be cheap from any thread. */
interface Speaker {
    fun speak(text: String)
    fun stop()
    val isSpeaking: Boolean
}
