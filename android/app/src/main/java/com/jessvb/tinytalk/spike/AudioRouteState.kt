package com.jessvb.tinytalk.spike

/**
 * Pure bookkeeping for SentenceTts's audio routing (MODE_IN_COMMUNICATION + loudspeaker),
 * confined to SentenceTts's single audio-executor thread (not thread-safe by itself).
 *
 * Routing and restoring are binder calls, so they run on that executor, in FIFO order with
 * stop cleanups and synthesis requests. FIFO already orders "stop's restore" before "the
 * next speak's route". The one restore that can arrive out of order is the one posted when
 * a run ends naturally: it applies only if no newer run has started since.
 */
class AudioRouteState {
    var routed: Boolean = false
        private set

    /** True if the caller must route now (not already routed). */
    fun shouldRoute(): Boolean {
        if (routed) return false
        routed = true
        return true
    }

    /** A stop()/close() cleanup: always restore if routed. */
    fun shouldRestoreAfterStop(): Boolean {
        if (!routed) return false
        routed = false
        return true
    }

    /** A run [runGen] finished playing: restore only if it is still the current run and idle. */
    fun shouldRestoreAfterRun(runGen: Int, currentGen: Int, speaking: Boolean): Boolean {
        if (!routed || runGen != currentGen || speaking) return false
        routed = false
        return true
    }

    companion object {
        /** Temp files are named `<prefix><gen>_<idx>.wav`; stale = an older generation (or unparseable). */
        fun isStaleTempFile(name: String, prefix: String, beforeGen: Int): Boolean {
            if (!name.startsWith(prefix)) return false
            val gen = name.substring(prefix.length).substringBefore('_').toIntOrNull() ?: return true
            return gen < beforeGen
        }
    }
}
