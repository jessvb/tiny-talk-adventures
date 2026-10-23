package com.jessvb.tinytalk.spike

/**
 * Pure bookkeeping for one speech run (one generation) of n sentences. A run is finished only when
 * every sentence is accounted for (played, skipped or failed), regardless of callback order. A
 * sentence whose synthesis callback never arrives is failed by [expire] once no synthesis progress
 * has been seen for [timeoutMs]. Stale generations are ignored. Thread-safe.
 */
class RunTracker(private val timeoutMs: Long) {
    class Expired(val gen: Int, val idx: Int, val runFinished: Boolean)

    private var gen = -1
    private var n = 0
    private var arrived = BooleanArray(0)
    private var done = BooleanArray(0)
    private var doneCount = 0
    private var lastProgress = 0L

    @Synchronized
    fun begin(gen: Int, n: Int, now: Long) {
        this.gen = gen
        this.n = n
        arrived = BooleanArray(n)
        done = BooleanArray(n)
        doneCount = 0
        lastProgress = now
    }

    /** Ends tracking (stop/close); everything afterwards is stale. */
    @Synchronized
    fun cancel() {
        gen = -1
        n = 0
        doneCount = 0
    }

    /** Synthesis callback (success or failure) for a sentence. False if stale, duplicate or already expired. */
    @Synchronized
    fun arrived(gen: Int, idx: Int, now: Long): Boolean {
        if (!valid(gen, idx) || arrived[idx] || done[idx]) return false
        arrived[idx] = true
        lastProgress = now
        return true
    }

    @Synchronized
    fun isDone(gen: Int, idx: Int): Boolean = !valid(gen, idx) || done[idx]

    /** Marks a sentence played/skipped/failed. Returns true exactly when this completes the run. */
    @Synchronized
    fun done(gen: Int, idx: Int): Boolean {
        if (!valid(gen, idx) || done[idx]) return false
        done[idx] = true
        doneCount++
        return doneCount == n
    }

    /** Fails the lowest sentence that never reported back, if synthesis has made no progress for the timeout. */
    @Synchronized
    fun expire(now: Long): Expired? {
        if (n == 0 || doneCount == n || now - lastProgress < timeoutMs) return null
        val idx = (0 until n).firstOrNull { !arrived[it] && !done[it] } ?: return null
        done[idx] = true
        doneCount++
        lastProgress = now
        return Expired(gen, idx, doneCount == n)
    }

    private fun valid(gen: Int, idx: Int) = gen == this.gen && n > 0 && idx in 0 until n
}
