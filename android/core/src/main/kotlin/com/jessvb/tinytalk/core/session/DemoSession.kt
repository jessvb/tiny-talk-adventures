package com.jessvb.tinytalk.core.session

import com.jessvb.tinytalk.core.DemoConversation
import com.jessvb.tinytalk.core.Safety
import com.jessvb.tinytalk.core.StoryArc
import com.jessvb.tinytalk.core.rethrowIfFatal
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.GroqException
import com.jessvb.tinytalk.core.facts.AnimalFactTracker
import com.jessvb.tinytalk.core.stt.OnDeviceTranscriptionException
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * Port of the turn logic in iOS DemoConnection (runTurn). Phase 1 only: no
 * object recognition, forced conclusion, storybook or settings.
 *
 * Concurrency: one lock ([lock]) guards [generation], [turnJob], [conversation],
 * [arc], [closed] and every send into [channel]. [generation] is bumped by
 * every submit / barge-in / newStory / close; a turn captures the generation
 * (plus its conversation and arc) once, under the lock, when it is submitted,
 * and every event it emits is sent only if the generation is still its own,
 * checked under the same lock as the send. So nothing a superseded, barged-in
 * or cancelled turn produces can ever reach the collector, even if its
 * network call returns late or ignores cancellation.
 */
class DemoSession(
    private val chat: ChatCompleting,
    private val stt: SpeechTranscribing,
    private val facts: AnimalFactTracker,
    private val scope: CoroutineScope,
    private val systemPrompt: String = DEFAULT_SYSTEM_PROMPT,
    private val targetTurns: Int = 7,
    private val turnTimeoutMs: Long = 60_000,
    /** Diagnostics only; never given transcripts, replies or exception messages. */
    private val log: (String) -> Unit = {},
    /** Test seam: how the per-story animal-fact state is cleared. */
    internal val resetFacts: suspend () -> Unit = { facts.reset() },
) : TurnSession {
    private val channel = Channel<SessionEvent>(Channel.UNLIMITED)

    /** Single-collector, lossless even if collection starts late. */
    override val events: Flow<SessionEvent> = channel.receiveAsFlow()

    private val lock = Any()
    private var generation = 0
    private var closed = false
    private var turnJob: Job? = null
    private var resetJob: Job? = null
    private var conversation = DemoConversation()
    private var arc = StoryArc(targetTurns)

    override fun submitUtterance(turnId: Int, pcm16: ShortArray, sampleRate: Int) {
        val job = synchronized(lock) {
            if (closed) return
            cancelInFlightLocked()
            val gen = ++generation
            val conv = conversation
            val storyArc = arc
            val pendingReset = resetJob
            val job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    withTimeout(turnTimeoutMs) {
                        pendingReset?.join()
                        runTurn(gen, turnId, pcm16, sampleRate, conv, storyArc)
                    }
                } catch (e: TimeoutCancellationException) {
                    emit(gen, SessionEvent.Error(GENERIC_ERROR, turnId))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: GroqException.KeyMissing) {
                    emit(gen, SessionEvent.KeyProblem(KeyProblemKind.MISSING, turnId))
                } catch (e: GroqException.KeyRejected) {
                    emit(gen, SessionEvent.KeyProblem(KeyProblemKind.REJECTED, turnId))
                } catch (e: GroqException.RateLimited) {
                    emit(gen, SessionEvent.KeyProblem(KeyProblemKind.RATE_LIMITED, turnId))
                } catch (e: OnDeviceTranscriptionException) {
                    emit(gen, SessionEvent.Error(ON_DEVICE_LISTENING_ERROR, turnId))
                } catch (t: Throwable) {
                    // Throwable, not Exception: an Error such as ExceptionInInitializerError
                    // (a class that fails to initialize on Android only, #88) must become the
                    // friendly retry line, never escape and kill the app. Class name only.
                    t.rethrowIfFatal()
                    log("turn $turnId failed: ${t.javaClass.name}")
                    emit(gen, SessionEvent.Error(GENERIC_ERROR, turnId))
                }
            }
            turnJob = job
            job
        }
        job.start() // outside the lock; a job cancelled meanwhile simply never runs
    }

    /** Abandons whatever is in flight; the child is talking again. */
    override fun bargeIn(turnId: Int) {
        synchronized(lock) {
            if (closed) return
            cancelInFlightLocked()
            generation++
        }
    }

    /** Cancels in-flight work and starts a fresh story. */
    fun newStory() {
        val reset = synchronized(lock) {
            if (closed) return
            cancelInFlightLocked()
            generation++
            conversation = DemoConversation()
            arc = StoryArc(targetTurns)
            newResetJobLocked()
        }
        reset.start()
    }

    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            generation++
            cancelInFlightLocked()
            channel.close()
        }
    }

    private fun cancelInFlightLocked() {
        turnJob?.cancel()
        turnJob = null
    }

    /** Sends [event] only if [gen] is still the current generation. */
    private fun emit(gen: Int, event: SessionEvent): Boolean = synchronized(lock) {
        if (closed || gen != generation) return false
        channel.trySend(event)
        true
    }

    /**
     * Operates only on [conv] / [storyArc], captured when the turn was
     * submitted (see the long comment on DemoConnection.runTurn): a concurrent
     * newStory must not leak this turn's reply into the new story.
     */
    private suspend fun runTurn(
        gen: Int,
        turnId: Int,
        pcm16: ShortArray,
        sampleRate: Int,
        conv: DemoConversation,
        storyArc: StoryArc,
    ) {
        val transcript = stt.transcribe(pcm16, sampleRate)
        if (!emit(gen, SessionEvent.TranscriptFinal(transcript, turnId))) return

        val trimmed = transcript.trim()
        if (trimmed.isNotEmpty()) conv.addChild(trimmed)

        var guidance = storyArc.recordTurn(transcript)
        val factGuidance = facts.recordTurn(transcript, storyArc.stage)
        if (factGuidance.isNotEmpty()) guidance += "\n\n" + factGuidance
        if (trimmed.isEmpty()) guidance += "\n\n" + STT_FAILURE_GUIDANCE

        val messages = conv.toMessages(systemPrompt + "\n\n" + guidance)
        val raw = chat.complete(messages).trim()
        val reply = Safety.filterReply(raw)

        // Everything that decides "the story finished" happens in ONE critical
        // section with the generation re-check and no suspension: ResponseText,
        // TurnEnd and (if the arc is done) the swap to a fresh story plus
        // StoryFinished. Once TurnEnd of the final reply is out, StoryFinished
        // follows even if a barge-in arrives a microsecond later (that barge-in
        // belongs to the new story). The arc only learns of the reply after the
        // gate, so a stale late reply cannot mark the shared arc done.
        var resetToStart: Job? = null
        synchronized(lock) {
            if (closed || gen != generation) return
            storyArc.recordReply(reply)
            channel.trySend(SessionEvent.ResponseText(reply, turnId))
            conv.addAgent(reply)
            channel.trySend(SessionEvent.TurnEnd(turnId))
            if (storyArc.isDone) {
                if (conversation === conv) conversation = DemoConversation()
                if (arc === storyArc) arc = StoryArc(targetTurns)
                resetToStart = newResetJobLocked()
                channel.trySend(SessionEvent.StoryFinished)
            }
        }
        // Not cancelled by a barge-in: it is its own job, joined by later turns.
        resetToStart?.start()
    }

    /** Lazy facts-reset job chained after any pending one; caller starts it outside the lock. */
    private fun newResetJobLocked(): Job {
        val previous = resetJob
        val job = scope.launch(start = CoroutineStart.LAZY) {
            previous?.join()
            try {
                resetFacts()
            } catch (t: Throwable) {
                t.rethrowIfFatal()
                log("facts reset failed: ${t.javaClass.name}")
            }
        }
        resetJob = job
        return job
    }

    companion object {
        private const val GENERIC_ERROR =
            "Elsie's cloud brain is having trouble -- let's try again in a moment."

        /** Shown (not spoken) when listening ON THIS PHONE failed; nothing went to the cloud. */
        const val ON_DEVICE_LISTENING_ERROR =
            "Elsie's ears on this phone had a hiccup -- let's try again in a moment. " +
                "If it keeps happening, close the app completely and open it again."

        private const val STT_FAILURE_GUIDANCE =
            "You didn't hear anything new from the child just now -- it might " +
                "have been background noise. Don't mention this or ask them to " +
                "repeat themselves. Instead, gently continue the story yourself " +
                "using what's already happened, and end with an easy, inviting " +
                "question so they have a natural opening to jump back in."

        /** Verbatim copy of DemoConnection.defaultSystemPrompt (itself config.py's SYSTEM_PROMPT). */
        const val DEFAULT_SYSTEM_PROMPT =
            "You are a warm, interesting storyteller telling a story out loud with a young, " +
                "intelligent child, aged about three to six. You and the child are making the " +
                "story up together. You like to subtly add educational facts to the story to make it " +
                "more interesting. Like any good arts major, you love to develop a good story arc.\n" +
                "\n" +
                "Rules you always follow:\n" +
                "- Reply with one to three short sentences. Never more. The child is " +
                "listening, not reading.\n" +
                "- Keep everything gentle and wholesome. No violence, no weapons, no death, " +
                "no frightening peril.\n" +
                "- End most replies by asking the child what should happen next.\n" +
                "- If the child interrupts you, follow their idea happily. Never scold them " +
                "for interrupting and never insist on finishing your previous sentence.\n" +
                "- Keep the story grounded in the real world: no magic, no talking " +
                "plants or objects, no impossible physics. Animal characters can " +
                "talk and think like people, but everything else about the world " +
                "should be realistic.\n" +
                "- Write plain spoken words only: no emoji, no asterisks, no stage " +
                "directions, no narration about yourself."
    }
}
