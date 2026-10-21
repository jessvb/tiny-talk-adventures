package com.jessvb.tinytalk.core.voice

/**
 * Rolling window of the most recent [capacityMs] of mono PCM16 audio (a ring buffer, no
 * per-push allocation). Fed every mic frame, in every loop state, so the start of an
 * utterance can include audio captured *before* the speech detector fired SpeechStart
 * (see iOS SessionCoordinator.preRollBuffer: 200 ms clipped first words on-device, 500 ms
 * fixed it there).
 *
 * Methods are synchronized, so it is safe to call from any thread; in practice only the
 * capture thread uses it.
 */
class PreRollBuffer(capacityMs: Int, sampleRate: Int = 16000) {
    private val capacity = (capacityMs.toLong() * sampleRate / 1000).toInt()
    private val ring = ShortArray(capacity)
    private var writePos = 0 // next index to write
    private var size = 0

    @Synchronized
    fun push(frame: ShortArray) {
        if (capacity == 0) return
        // Only the last `capacity` samples of an oversized frame can survive.
        val skip = maxOf(0, frame.size - capacity)
        var src = skip
        var remaining = frame.size - skip
        while (remaining > 0) {
            val n = minOf(remaining, capacity - writePos)
            System.arraycopy(frame, src, ring, writePos, n)
            writePos = (writePos + n) % capacity
            src += n
            remaining -= n
        }
        size = minOf(capacity, size + frame.size - skip)
    }

    /** The buffered samples, oldest first: exactly the last [capacityMs] worth, or fewer if history is shorter. */
    @Synchronized
    fun snapshot(): ShortArray {
        val out = ShortArray(size)
        val start = (writePos - size + capacity) % maxOf(capacity, 1)
        val firstPart = minOf(size, capacity - start)
        System.arraycopy(ring, start, out, 0, firstPart)
        System.arraycopy(ring, 0, out, firstPart, size - firstPart)
        return out
    }

    @Synchronized
    fun clear() {
        writePos = 0
        size = 0
    }
}
