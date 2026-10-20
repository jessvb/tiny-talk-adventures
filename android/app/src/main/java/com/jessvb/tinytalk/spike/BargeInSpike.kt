package com.jessvb.tinytalk.spike

/**
 * Barge-in spike: speaks a paragraph while the mic + VAD keep running. The existing capture callback
 * forwards each SpeechStart to [onSpeechStart] (capture thread). If TTS is audibly playing, the start is
 * counted (false trigger in a silent run / real interruption otherwise), TTS is stopped, and the
 * SpeechStart -> stopped latency is logged. SentenceTts.stop() only holds its lock briefly (the
 * AudioTrack writes are non-blocking), so calling it from the capture thread is safe.
 */
class BargeInSpike(
    private val tts: SentenceTts,
    private val startMic: () -> Boolean,
    private val micRunning: () -> Boolean,
    private val stopMic: () -> Unit,
    private val onLog: (String) -> Unit,
    private val onSummary: (String) -> Unit,
    private val stats: BargeInStats = BargeInStats { System.nanoTime() / 1_000_000 },
) {
    private var micStartedByUs = false
    @Volatile private var active = false

    @Synchronized
    fun start(paragraph: String) {
        stats.reset()
        if (!active) {
            val alreadyRunning = micRunning()
            if (alreadyRunning) {
                onLog("barge-in: mic already running (leaving it on after the run)")
            } else {
                startMic()
            }
            micStartedByUs = !alreadyRunning && micRunning()
        }
        if (!micRunning()) {
            if (micStartedByUs) { stopMic(); micStartedByUs = false }
            invalidate("mic failed to start")
            return
        }
        active = true
        onSummary(stats.summary())
        onLog("barge-in run started")
        tts.speak(paragraph)
    }

    /** Poll from the UI: if the mic died mid-run (Stop mic tapped, read error) the run proves nothing. */
    @Synchronized
    fun checkMic() {
        if (active && !micRunning()) invalidate("mic stopped mid-run")
    }

    private fun invalidate(reason: String) {
        active = false
        tts.stop()
        stats.markInvalid("mic not running")
        onLog("MIC NOT RUNNING - run invalid ($reason)")
        onSummary(stats.summary())
    }

    /** Called on the capture thread for every SpeechStart event. */
    fun onSpeechStart() {
        if (!active) return
        if (!stats.onSpeechStart(tts.isSpeaking)) return
        tts.stop()
        if (tts.isSpeaking) onLog("barge-in: tts.stop() returned but isSpeaking still true")
        val latency = stats.onStopped()
        onLog("barge-in: SpeechStart during playback; stopped after $latency ms")
        onSummary(stats.summary())
    }

    /** Idempotent. Stops speech, and the mic if this run started it. */
    @Synchronized
    fun stop() {
        if (!active) {
            tts.stop()
            return
        }
        active = false
        tts.stop()
        if (micStartedByUs) stopMic()
        micStartedByUs = false
        onLog("barge-in run stopped: ${stats.summary()}")
    }
}
