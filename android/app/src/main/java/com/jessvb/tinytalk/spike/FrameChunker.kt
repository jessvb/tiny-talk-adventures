package com.jessvb.tinytalk.spike

/** Re-slices arbitrary-length PCM pushes into fixed-size frames, carrying leftovers. */
class FrameChunker(private val frameSize: Int = 512) {
    private var pending = ShortArray(0)

    fun push(samples: ShortArray, length: Int): List<ShortArray> {
        require(length in 0..samples.size) { "length $length out of range 0..${samples.size}" }
        val buf = pending + samples.copyOf(length)
        val frames = ArrayList<ShortArray>()
        var offset = 0
        while (buf.size - offset >= frameSize) {
            frames.add(buf.copyOfRange(offset, offset + frameSize))
            offset += frameSize
        }
        pending = buf.copyOfRange(offset, buf.size)
        return frames
    }
}
