package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.audio.SpeechDetector
import com.jessvb.tinytalk.core.rethrowIfFatal
import com.jessvb.tinytalk.core.audio.SpeechEvent
import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.session.SessionEvent
import com.jessvb.tinytalk.core.session.TurnSession
import com.jessvb.tinytalk.core.voice.Action
import com.jessvb.tinytalk.core.voice.LoopState
import com.jessvb.tinytalk.core.voice.SpokenLines
import com.jessvb.tinytalk.core.voice.TurnStateMachine
import com.jessvb.tinytalk.core.voice.UtteranceAssembler
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The spoken conversation loop: mic -> VAD -> SpeechDetector -> UtteranceAssembler ->
 * [TurnSession], and the session's replies -> [Speaker], with barge-in.
 *
 * Threads:
 * - Capture thread (the mic's own): [onFrame] runs VAD, detector and assembler (owned by that
 *   thread while running) and applies capture-side actions: `tts.stop()` on barge-in (cheap:
 *   SentenceTts does no binder/disk work on that path), `session.bargeIn` while thinking,
 *   `session.submitUtterance` for a finished utterance (both only launch/cancel coroutines).
 *   Nothing thrown in the frame path escapes: it halts the loop with one visible error.
 * - Dispatchers.Default: the [TurnSession.events] collector, the playback-finished poll and
 *   the halt after a mic loss / frame failure / revoked consent. Never Unconfined or
 *   Main.immediate: DemoSession sends while holding its own lock, so an inline collector
 *   calling back into the session could deadlock.
 * - Caller thread: [start] / [stop].
 *
 * Which thread each callback runs on (UI callers, Tasks 9/10, MUST post to the main thread):
 * - [onState]: capture thread, a Default thread, or the caller of start/stop.
 * - [onError]: the caller of [start] (consent / mic-start failure), otherwise a Default thread
 *   (session errors, mic loss, frame failure, consent revoked).
 * - [onKeyProblem], [onTranscript], [onReply], [onStoryFinished]: a Default thread (collector).
 * - [onLog]: any of the above.
 * None is called while holding the loop's state lock. [onState] calls are serialised by a
 * separate notify lock and delivered in order; an older state that loses a race to a newer
 * one is dropped, so the last delivered state is always the current one.
 *
 * Locks: [lock] guards [machine] and [pollJob] only; the session and speaker are always
 * called outside it. The one ordering race this opens (the collector's `tts.speak` landing
 * after the capture thread's barge-in `tts.stop`) is closed by re-checking the machine after
 * speaking and stopping again if the turn is no longer the one being spoken; [shutdown] moves
 * the machine to IDLE before stopping the speaker for the same reason.
 *
 * Playback completion: [Speaker] has no completion callback, so a coroutine polls
 * `isSpeaking` every [PLAYBACK_POLL_MS] after a speak (SentenceTts sets it synchronously in
 * speak(); an unavailable TTS reads as finished at once, so SPEAKING never sticks).
 *
 * Ownership: [vad], [tts] and [session] belong to the caller (one long-lived warm
 * SentenceTts for the app's lifetime, Phase 0); this class never closes them. The mic is
 * built once from [micFactory] with this loop's frame and loss callbacks.
 */
class VoiceLoop(
    micFactory: (onFrame: (ShortArray) -> Unit, onStopped: (String) -> Unit) -> MicSource,
    private val vad: SpeechProbability,
    private val detector: SpeechDetector,
    private val session: TurnSession,
    private val tts: Speaker,
    private val scope: CoroutineScope,
    /** Plays while a reply is awaited; owned by the caller like [tts]. */
    private val waiting: WaitingSound = NoWaitingSound,
    private val consentGiven: () -> Boolean,
    private val onState: (LoopState) -> Unit,
    private val onKeyProblem: (KeyProblemKind) -> Unit,
    private val onError: (String) -> Unit,
    private val onTranscript: (String) -> Unit = {},
    private val onReply: (String) -> Unit = {},
    private val onStoryFinished: () -> Unit = {},
    private val onLog: (String) -> Unit = {},
    private val assembler: UtteranceAssembler = UtteranceAssembler(),
    /** Where a self-halt's cleanup runs (never the capture thread); a test dispatcher in tests. */
    private val haltDispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    private val mic: MicSource = micFactory(::onFrame, ::onMicStopped)
    private val lock = Any()
    private val machine = TurnStateMachine()
    private val startStopLock = Any()
    private val notifyLock = Any()

    @Volatile private var running = false
    /** The child muted the mic: capture is closed but the loop (collector, reply, speech) lives on. */
    private var muted = false // guarded by startStopLock
    /** Bumped by every successful-or-attempted start (under startStopLock); tags halts. */
    @Volatile private var runId = 0L
    /** Set once per run by the first mic loss / frame failure / consent revocation. */
    private val halting = AtomicBoolean(false)
    private var collectorJob: Job? = null // guarded by startStopLock
    private var pollJob: Job? = null // guarded by lock
    private var stateSeq = 0L // guarded by lock
    private var deliveredSeq = 0L // guarded by notifyLock

    val state: LoopState get() = synchronized(lock) { machine.state }

    /**
     * Starts listening. Refuses (false: no mic, no network) until the parent has consented
     * (Review Focus 3), and reports a visible error if the mic cannot start (never silent).
     * Works again after a [stop] or after the loop halted itself (mic loss etc.).
     */
    fun start(): Boolean = synchronized(startStopLock) {
        if (running) return true
        if (!consentGiven()) {
            onLog("start refused: no consent")
            onError(NO_CONSENT_MESSAGE)
            return false
        }
        halting.set(false)
        collectorJob = scope.launch(Dispatchers.Default) {
            session.events.collect { event ->
                try {
                    handle(event)
                } catch (t: Throwable) {
                    // A throw here would end the collector and, unhandled, kill the app (#88).
                    // Halt with one visible, retryable error instead. Class name only.
                    t.rethrowIfFatal()
                    halt(LISTENING_FAILED_MESSAGE, "reply handling threw ${t.javaClass.name}")
                }
            }
        }
        transition { it.onStart() }
        running = true
        runId++
        val micOk = try {
            muted || mic.start() // muted: stay quiet until setMuted(false) opens the mic
        } catch (t: Throwable) {
            // Never leave running=true behind a throw: roll back and report once, like false.
            onLog("mic start threw ${t.javaClass.name}")
            try { mic.stop() } catch (_: Throwable) {}
            false
        }
        if (!micOk) {
            running = false
            collectorJob?.cancel()
            collectorJob = null
            transition { it.onStop() }
            onError(MIC_UNAVAILABLE_MESSAGE)
            return false
        }
        true
    }

    /**
     * Mutes or unmutes the microphone WITHOUT ending the turn in flight: capture closes and a
     * half-heard utterance is dropped, but the collector stays up, so a turn already submitted
     * still delivers its transcript and reply (and Elsie finishes what she is saying). Safe to
     * call while stopped: the setting applies to the next [start].
     */
    fun setMuted(muted: Boolean) {
        val failed = synchronized(startStopLock) {
            if (this.muted == muted) return
            this.muted = muted
            if (!running) return
            if (muted) {
                mic.stop() // joins the capture thread: detector/assembler are now ours
                detector.reset()
                vad.reset()
                assembler.reset()
                false
            } else {
                !openMicLocked()
            }
        }
        if (failed) halt(MIC_UNAVAILABLE_MESSAGE, "mic would not reopen after unmute")
    }

    /** startStopLock held. Opens the mic after an unmute; false if it would not start. */
    private fun openMicLocked(): Boolean {
        return try { mic.start() } catch (t: Throwable) {
            onLog("mic start threw ${t.javaClass.name}")
            try { mic.stop() } catch (_: Throwable) {}
            false
        }
    }

    /** Releases the mic, stops speech, cancels any in-flight turn, resets detection. Idempotent. */
    fun stop() {
        shutdown(lost = false)
    }

    /**
     * Returns false if the loop was not running (already stopped), or if [onlyRun] is given and
     * a newer run has started since (a stale halt must never stop a fresh run).
     */
    private fun shutdown(lost: Boolean, onlyRun: Long? = null): Boolean = synchronized(startStopLock) {
        if (!running) return false
        if (onlyRun != null && onlyRun != runId) return false
        running = false
        // IDLE first, then tts.stop(): a collector racing in speakFor() either re-checks
        // after this (sees IDLE, stops its own speech) or spoke before it (stopped below).
        var turn = 0
        transition { m -> (if (lost) m.onMicLost() else m.onStop()).also { turn = m.turnId } }
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
        true
    }

    /**
     * Halts the loop on its own (mic died, frame processing threw, consent revoked) with one
     * visible error. Runs the cleanup on Default, never on the capture thread: the cleanup
     * joins that thread, and a concurrent [stop] holding startStopLock may be joining it too.
     */
    private fun halt(userMessage: String, why: String) {
        if (!halting.compareAndSet(false, true)) return
        onLog("voice loop halted: $why")
        val run = runId // the run this failure belongs to
        scope.launch(haltDispatcher) {
            if (shutdown(lost = true, onlyRun = run)) onError(userMessage)
        }
    }

    /** Capture thread, once, when the mic stopped by itself (read error etc.). */
    private fun onMicStopped(reason: String) {
        if (running) halt(MIC_UNAVAILABLE_MESSAGE, "mic stopped: $reason")
    }

    /** Capture thread. Never throws. */
    private fun onFrame(frame: ShortArray) {
        if (!running || halting.get()) return
        try {
            processFrame(frame)
        } catch (t: Throwable) {
            halt(LISTENING_FAILED_MESSAGE, "frame processing threw ${t.javaClass.name}")
        }
    }

    private fun processFrame(frame: ShortArray) {
        val event = detector.onProbability(vad.probability(frame))
        val utterance = assembler.onFrame(frame, event)
        if (event == SpeechEvent.SpeechStart) {
            var turn = 0
            val a = transition { m -> m.onSpeechStart().also { turn = m.turnId } }
            if (a.stopTts) tts.stop()
            if (a.cancelInFlight) session.bargeIn(turn)
        }
        if (utterance != null) {
            // Consent can be revoked while running: no audio leaves for transcription after that.
            if (!consentGiven()) {
                halt(NO_CONSENT_MESSAGE, "consent revoked while running")
                return
            }
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

    /** Applies [f] to the machine under [lock]; reports a state change after releasing it. */
    private inline fun transition(f: (TurnStateMachine) -> Action): Action {
        var changed: LoopState? = null
        var seq = 0L
        val action = synchronized(lock) {
            val before = machine.state
            val a = f(machine)
            if (machine.state != before) {
                changed = machine.state
                seq = ++stateSeq
            }
            a
        }
        changed?.let { notifyState(it, seq) }
        return action
    }

    private fun notifyState(s: LoopState, seq: Long) {
        synchronized(notifyLock) {
            if (seq <= deliveredSeq) return // a newer state was already delivered
            deliveredSeq = seq
            // The chime follows THINKING exactly: it starts when the child's turn is submitted
            // and is stopped by the very state change (SPEAKING / LISTENING / IDLE) that comes
            // before a reply is spoken, so it can never play over Elsie.
            try {
                if (s == LoopState.THINKING) waiting.start() else waiting.stop()
            } catch (t: Throwable) {
                t.rethrowIfFatal()
                onLog("waiting chime failed: ${t.javaClass.name}")
            }
            onState(s)
        }
    }

    companion object {
        const val SAMPLE_RATE = 16000
        const val PLAYBACK_POLL_MS = 100L
        const val MIC_UNAVAILABLE_MESSAGE = "Microphone unavailable. Check that the app may use the microphone and nothing else is using it."
        const val NO_CONSENT_MESSAGE = "A grown-up needs to agree to the privacy note before Elsie can listen."
        const val LISTENING_FAILED_MESSAGE = "Listening stopped because something went wrong. Tap to start again."
    }
}
