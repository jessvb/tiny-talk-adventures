package com.jessvb.tinytalk.core.stt

interface SpeechTranscribing {
    suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String
}

/**
 * On-phone speech recognition could not run (model missing, corrupt or not loaded yet, or a
 * native failure). Distinct from cloud errors so the parent is not told "the cloud" failed.
 * Its message never contains audio or transcript text.
 */
class OnDeviceTranscriptionException(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)
