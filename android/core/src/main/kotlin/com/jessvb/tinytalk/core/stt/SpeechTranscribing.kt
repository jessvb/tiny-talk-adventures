package com.jessvb.tinytalk.core.stt

interface SpeechTranscribing {
    suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String
}
