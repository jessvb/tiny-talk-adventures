package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.audio.SpeechDetector
import com.jessvb.tinytalk.core.audio.SpeechEvent
import com.jessvb.tinytalk.core.session.DemoSession
import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.session.SessionEvent
import com.jessvb.tinytalk.core.voice.Action
import com.jessvb.tinytalk.core.voice.LoopState
import com.jessvb.tinytalk.core.voice.SpokenLines
import com.jessvb.tinytalk.core.voice.TurnStateMachine
import com.jessvb.tinytalk.core.voice.UtteranceAssembler
import com.jessvb.tinytalk.spike.MicCapture
import com.jessvb.tinytalk.spike.SentenceTts
import com.jessvb.tinytalk.spike.SileroVad
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The spoken conversation loop: mic -> Silero VAD -> SpeechDetector -> UtteranceAssembler
 * -> DemoSession, and DemoSession's replies -> SentenceTts, with barge-in.
 *
 * Threads:
 * - Capture thread (MicCapture's own): [onFrame] runs VAD, detector and assembler (all
 *   single-threaded, owned by that thread while running) and applies capture-side actions:
 *   `tts.stop()` on barge-in (cheap, Phase 0), `session.bargeIn` while thinking,
 *   `session.submitUtterance` for a finished utterance (both just launch/cancel coroutines).
 * - Dispatchers.Default: the [DemoSession.events] collector and the playback-finished poll.
 *   Never Unconfined/Main.immediate: DemoSession sends while holding its own lock, so an
 *   inline collector that called back into the session could deadlock.
 * - Caller thread: [start]/[stop].
 *
 * Locks: [lock] guards [machine] only. [onState] is invoked while holding it (so state
 * notifications can never arrive out of order); it must be cheap and must not call back into
 * this class. DemoSession and SentenceTts are always called outside [lock]. The one ordering
 * race this opens (the collector's `tts.speak` landing after the capture thread's barge-in
 * `tts.stop`) is closed by re-checking the machine after speaking and stopping again if the
 * turn is no longer the one being spoken.
 *
 * Playback completion: SentenceTts has no completion callback, so a coroutine polls
 * `tts.isSpeaking` every [PLAYBACK_POLL_MS] after a speak. SentenceTts sets isSpeaking
 * synchronously inside speak(), so the poll cannot see a stale "not speaking" before the
 * audio starts, and a TTS that is unavailable/ignores the text reads as finished at once, so
 * the loop never sticks in SPEAKING.
 *
 * Ownership: [vad], [tts] and [session] are owned by the caller (one long-lived warm
 * SentenceTts for the app's lifetime, Phase 0); this class never closes them. The mic is
 * built once from [micFactory] with this loop's frame callback.
 */
class VoiceLoop(
    micFactory: (onFrame: (ShortArray) -> Unit) -> MicCapture,
    private val vad: SileroVad,
    private val detector: SpeechDetector,
    private val session: DemoSession,
    private val tts: SentenceTts,
    private val scope: CoroutineScope,
    private val consentGiven: () -> Boolean,
    private val onState: (LoopState) -> Unit,
    private val onKeyProblem: (KeyProblemKind) -> Unit,
    private val onError: (String) -> Unit,
    private val onTranscript: (String) -> Unit = {},
    private val onReply: (String) -> Unit = {},
    private val onStoryFinished: () -> Unit = {},
    private val onLog: (String) -> Unit = {},
    private val assembler: UtteranceAssembler = UtteranceAssembler(),
) {
    private val mic: MicCapture = micFactory(::onFrame)
    private val lock = Any()
    private val machine = TurnStateMachine()
    private val startStopLock = Any()

    @Volatile private var running = false
    private var collectorJob: Job? = null // guarded by startStopLock
    private var pollJob: Job? = null // guarded by lock

    val state: LoopState get() = synchronized(lock) { machine.state }

    /**
     * Starts listening. Refuses (false: no mic, no network) until the parent has consented
     * (Review Focus 3), and reports a visible error if the mic cannot start (never silent).
     */
    fun start(): Boolean = synchronized(startStopLock) {
        if (running) return true
        if (!consentGiven()) {
            onLog("start refused: no consent")
            onError(NO_CONSENT_MESSAGE)
            return false
        }
        collectorJob = scope.launch(Dispatchers.Default) {
            session.events.collect { handle(it) }
        }
        transition { it.onStart() }
        running = true
        if (!mic.start()) {
            running = false
            collectorJob?.cancel()
            collectorJob = null
            transition { it.onStop() }
            onError(MIC_UNAVAILABLE_MESSAGE)
            return false
        }
        true
    }

    /** Releases the mic, stops speech, cancels any in-flight turn, resets detection. Idempotent. */
    fun stop() {
        synchronized(startStopLock) {
            if (!running) return
            running = false
            // IDLE first, then tts.stop(): a collector racing in speakFor() either re-checks
            // after this (sees IDLE, stops its own speech) or spoke before it (stopped below).
            var turn = 0
            transition { m -> m.onStop().also { turn = m.turnId } }
            synchronized(lock) {
                pollJob?.cancel()
                pollJob = null
            }
            tts.stop()
            mic.stop() // joins the capture thread: VAD/detector/assembler are now ours
            collectorJob?.cancel()
            collectorJob = null
            session.bargeIn(turn) // drop the in-flight turn; nothing it sends will be spoken
            detector.reset()
            vad.reset()
            assembler.reset()
        }
    }

    /** Capture thread. */
    private fun onFrame(frame: ShortArray) {
        if (!running) return
        val event = detector.onProbability(vad.probability(frame))
        val utterance = assembler.onFrame(frame, event)
        if (event == SpeechEvent.SpeechStart) {
            var turn = 0
            val a = transition { m -> m.onSpeechStart().also { turn = m.turnId } }
            if (a.stopTts) tts.stop()
            if (a.cancelInFlight) session.bargeIn(turn)
        }
        if (utterance != null) {
            var turn = 0
            val a = transition { m -> m.onUtterance().also { turn = m.turnId } }
            if (a.submitUtterance) {
                onLog("utterance ${utterance.pcm16.size * 1000 / SAMPLE_RATE} ms (pre-roll ${utterance.startedWithPreRollMs} ms) -> turn $turn")
                session.submitUtterance(turn, utterance.pcm16, SAMPLE_RATE)
            }
        }
    }

    /** Dispatchers.Default (collector). */
    private fun handle(event: SessionEvent) {
        when (event) {
            is SessionEvent.TranscriptFinal -> {
                val current = synchronized(lock) {
                    machine.state == LoopState.THINKING && machine.turnId == event.turnId
                }
                if (current) onTranscript(event.text)
            }
            is SessionEvent.ResponseText -> {
                if (transition { it.onResponseText(event.turnId) }.speak) {
                    onReply(event.text)
                    speakFor(event.turnId, event.text)
                }
            }
            is SessionEvent.TurnEnd -> transition { it.onTurnEnd(event.turnId) }
            is SessionEvent.Error -> {
                if (transition { it.onError(event.turnId) }.speak) {
                    onError(event.message)
                    speakFor(event.turnId, SpokenLines.TRY_AGAIN)
                }
            }
            is SessionEvent.KeyProblem -> {
                if (transition { it.onError(event.turnId) }.speak) {
                    onKeyProblem(event.kind)
                    speakFor(event.turnId, SpokenLines.KEY_PROBLEM)
                }
            }
            SessionEvent.StoryFinished -> onStoryFinished()
        }
    }

    private fun speakFor(turn: Int, text: String) {
        tts.speak(text)
        val stillOurs = synchronized(lock) {
            val ours = machine.state == LoopState.SPEAKING && machine.turnId == turn
            if (ours) {
                pollJob?.cancel()
                pollJob = scope.launch(Dispatchers.Default) { awaitPlayback(turn) }
            }
            ours
        }
        // A barge-in (or stop) slipped in between the state change and speak(): its
        // tts.stop() may have run before our speak(), so silence this reply now.
        if (!stillOurs) tts.stop()
    }

    private suspend fun awaitPlayback(turn: Int) {
        while (true) {
            delay(PLAYBACK_POLL_MS) // cancellable: stop()/a newer reply cancels this job
            if (!tts.isSpeaking) {
                transition { it.onPlaybackFinished(turn) }
                return
            }
        }
    }

    /** Applies [f] to the machine under [lock] and reports a state change, still under it. */
    private inline fun transition(f: (TurnStateMachine) -> Action): Action =
        synchronized(lock) {
            val before = machine.state
            val action = f(machine)
            if (machine.state != before) onState(machine.state)
            action
        }

    companion object {
        const val SAMPLE_RATE = 16000
        const val PLAYBACK_POLL_MS = 100L
        const val MIC_UNAVAILABLE_MESSAGE = "Microphone unavailable. Check that the app may use the microphone and nothing else is using it."
        const val NO_CONSENT_MESSAGE = "A grown-up needs to agree to the privacy note before Elsie can listen."
    }
}
