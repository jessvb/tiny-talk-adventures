package com.jessvb.tinytalk.voice

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/**
 * The "Elsie is thinking" chime, ported from the iOS app (WaitingDitty.swift) and generated in
 * code (no audio asset): a gentle four-note major arpeggio (C5, E5, G5, C6), each note a soft
 * bell (instant attack, exponential decay), followed by a silent tail so that looping the buffer
 * needs no separate pacing. Mono PCM16 at [SAMPLE_RATE].
 */
object WaitingDitty {
    const val SAMPLE_RATE = 24_000

    private val NOTES = doubleArrayOf(523.25, 659.25, 783.99, 1046.50)
    private const val NOTE_SECONDS = 0.18
    private const val GAP_SECONDS = 0.35

    /**
     * iOS uses 0.08 because call-mode audio there was far too loud. Here the chime plays on the
     * media stream, which the parent controls with the media volume, so it is a little higher
     * (still gentle; it must stay clearly quieter than Elsie's own voice).
     */
    private const val AMPLITUDE = 0.12

    val samples: ShortArray = run {
        val noteLen = (NOTE_SECONDS * SAMPLE_RATE).toInt()
        val gapLen = (GAP_SECONDS * SAMPLE_RATE).toInt()
        val out = ShortArray(NOTES.size * noteLen + gapLen)
        var at = 0
        for (frequency in NOTES) {
            for (i in 0 until noteLen) {
                val t = i.toDouble() / SAMPLE_RATE
                val envelope = exp(-6.0 * t / NOTE_SECONDS)
                out[at++] = (sin(2.0 * PI * frequency * t) * envelope * AMPLITUDE * Short.MAX_VALUE).toInt().toShort()
            }
        }
        out // the trailing gap stays zero
    }
}
