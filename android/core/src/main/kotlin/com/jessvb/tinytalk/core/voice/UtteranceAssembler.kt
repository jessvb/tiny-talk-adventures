package com.jessvb.tinytalk.core.voice

import com.jessvb.tinytalk.core.audio.SpeechEvent

/** One utterance ready for speech-to-text: pre-roll + speech + a short trimmed tail. */
class AssembledUtterance(
    val pcm16: ShortArray,
    /** How much pre-SpeechStart audio the utterance begins with (less than requested if history was short). */
    val startedWithPreRollMs: Int,
)

/**
 * Turns mic frames plus [SpeechEvent]s from a [com.jessvb.tinytalk.core.audio.SpeechDetector]
 * into utterances that do not clip the first word (Review Focus 5).
 *
 * - Every frame goes into a rolling [PreRollBuffer], whatever the voice loop is doing
 *   (listening, thinking, Elsie speaking): this class has no idea of loop state on purpose.
 * - On SpeechStart the utterance begins with the last [preRollMs] of audio *before* the
 *   SpeechStart frame. The detector only fires on the 3rd voiced frame (~96 ms attack), and
 *   a child's onset/breath comes before that; 600 ms covers attack + onset + margin.
 * - On SpeechEnd the detector has just seen [hangoverFrames] silent frames in a row, so the
 *   last voiced audio ended exactly that many frames ago; the utterance keeps at most
 *   [tailTrimMs] after that point and drops the rest of the hangover.
 * - The voiced part (SpeechStart frame to last voiced frame, excluding pre-roll and tail)
 *   shorter than [minUtteranceMs] is a blip and yields null. iOS has no minimum beyond the
 *   detector's own 3-frame attack, so the default is 0 (any detected speech counts).
 * - An utterance reaching [maxUtteranceMs] (pre-roll included) is cut and returned at once;
 *   the rest of that speech, until SpeechEnd, is discarded. Bounds memory; a child talking
 *   for 30 s without a 0.7 s pause is not expected.
 *
 * Not thread-safe: call [onFrame] and [reset] from one thread (the capture thread), or only
 * [reset] after that thread has stopped. Allocates the max-length buffer once; per frame it
 * only copies samples.
 */
class UtteranceAssembler(
    preRollMs: Int = 600,
    tailTrimMs: Int = 300,
    minUtteranceMs: Int = 0,
    maxUtteranceMs: Int = 30_000,
    private val hangoverFrames: Int = 22,
    private val sampleRate: Int = 16000,
) {
    private enum class Mode { IDLE, COLLECTING, DISCARDING }

    private val preRoll = PreRollBuffer(preRollMs, sampleRate)
    private val tailSamples = samples(tailTrimMs)
    private val minSamples = samples(minUtteranceMs)
    private val maxSamples = samples(maxUtteranceMs)
    private val buf = ShortArray(maxSamples)
    private var len = 0
    private var speechStartAt = 0
    private var preRollSamples = 0
    private var mode = Mode.IDLE

    private fun samples(ms: Int) = (ms.toLong() * sampleRate / 1000).toInt()

    fun onFrame(frame: ShortArray, event: SpeechEvent): AssembledUtterance? {
        val result = when (event) {
            SpeechEvent.SpeechStart -> {
                begin(frame)
                if (len >= maxSamples) cut() else null
            }
            SpeechEvent.None -> when (mode) {
                Mode.COLLECTING -> {
                    append(frame)
                    if (len >= maxSamples) cut() else null
                }
                else -> null
            }
            SpeechEvent.SpeechEnd -> when (mode) {
                Mode.COLLECTING -> finish(frame)
                else -> {
                    mode = Mode.IDLE
                    null
                }
            }
        }
        // After any snapshot, so the pre-roll is strictly audio *before* the SpeechStart frame.
        preRoll.push(frame)
        return result
    }

    fun reset() {
        preRoll.clear()
        len = 0
        mode = Mode.IDLE
    }

    private fun begin(frame: ShortArray) {
        val history = preRoll.snapshot()
        val keep = minOf(history.size, maxSamples)
        System.arraycopy(history, history.size - keep, buf, 0, keep)
        len = keep
        preRollSamples = keep
        speechStartAt = keep
        mode = Mode.COLLECTING
        append(frame)
    }

    private fun append(frame: ShortArray) {
        val n = minOf(frame.size, maxSamples - len)
        System.arraycopy(frame, 0, buf, len, n)
        len += n
    }

    private fun cut(): AssembledUtterance {
        mode = Mode.DISCARDING
        return AssembledUtterance(buf.copyOf(len), preRollMs())
    }

    private fun finish(frame: ShortArray): AssembledUtterance? {
        append(frame)
        mode = Mode.IDLE
        val lastVoicedEnd = maxOf(speechStartAt, len - hangoverFrames * frame.size)
        if (lastVoicedEnd - speechStartAt < minSamples) return null
        val end = minOf(len, lastVoicedEnd + tailSamples)
        return AssembledUtterance(buf.copyOf(end), preRollMs())
    }

    private fun preRollMs() = (preRollSamples.toLong() * 1000 / sampleRate).toInt()
}
