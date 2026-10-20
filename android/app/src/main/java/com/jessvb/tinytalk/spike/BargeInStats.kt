package com.jessvb.tinytalk.spike

/**
 * Bookkeeping for one barge-in test run. Pure (no Android); the clock is injectable.
 * Every SpeechStart while TTS is audibly playing is counted: in a silent run each is a false trigger
 * from Elsie's own voice; in an interruption run they are the real interruptions (and each gets a
 * stop latency).
 */
class BargeInStats(private val clockMs: () -> Long) {
    private var pendingStartMs: Long? = null
    private var falseTriggers = 0
    private val stops = mutableListOf<Long>()

    private var invalidReason: String? = null

    /** A run with no mic listening proves nothing; its summary must never look like a pass. */
    @Synchronized
    fun markInvalid(reason: String) {
        invalidReason = reason
    }

    @Synchronized
    fun isInvalid(): Boolean = invalidReason != null

    @Synchronized
    fun reset() {
        invalidReason = null
        pendingStartMs = null
        falseTriggers = 0
        stops.clear()
    }

    /** Returns true if this SpeechStart happened during playback (caller should stop the TTS). */
    @Synchronized
    fun onSpeechStart(ttsSpeaking: Boolean): Boolean {
        if (!ttsSpeaking) return false
        falseTriggers++
        pendingStartMs = clockMs()
        return true
    }

    /** Call once TTS.stop() returned and isSpeaking is false. Returns the latency, or null if none pending. */
    @Synchronized
    fun onStopped(): Long? {
        val t0 = pendingStartMs ?: return null
        pendingStartMs = null
        val latency = clockMs() - t0
        stops.add(latency)
        return latency
    }

    @Synchronized
    fun summary(): String = invalidReason?.let { "INVALID: $it" } ?: "false triggers=$falseTriggers, stops=[${stops.joinToString(", ") { "$it ms" }}]"
}
