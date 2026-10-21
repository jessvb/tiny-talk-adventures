package com.jessvb.tinytalk.core.audio

enum class SpeechEvent { None, SpeechStart, SpeechEnd }

/** Debounces per-chunk speech probabilities; mirrors iOS VoiceActivityDetector.updateSpeakingState. */
class SpeechDetector(
    private val threshold: Float = 0.5f,
    private val attackChunks: Int = 3,
    private val hangoverChunks: Int = 22,
) {
    private var speaking = false
    private var voicedStreak = 0
    private var silentStreak = 0

    fun onProbability(p: Float): SpeechEvent {
        if (p >= threshold) {
            silentStreak = 0
            if (!speaking) {
                voicedStreak++
                if (voicedStreak >= attackChunks) {
                    speaking = true
                    voicedStreak = 0
                    return SpeechEvent.SpeechStart
                }
            }
        } else {
            voicedStreak = 0
            if (speaking) {
                silentStreak++
                if (silentStreak >= hangoverChunks) {
                    speaking = false
                    silentStreak = 0
                    return SpeechEvent.SpeechEnd
                }
            }
        }
        return SpeechEvent.None
    }

    fun reset() {
        speaking = false
        voicedStreak = 0
        silentStreak = 0
    }
}
