package com.jessvb.tinytalk.core.voice

enum class LoopState { IDLE, LISTENING, THINKING, SPEAKING }

/**
 * What the voice loop must do after a [TurnStateMachine] transition. [ignore] means the
 * event did not apply (wrong state or a stale turnId) and nothing changed.
 */
data class Action(
    val stopTts: Boolean = false,
    val cancelInFlight: Boolean = false,
    val submitUtterance: Boolean = false,
    /** Speak something now: the reply for ResponseText, the friendly line for an error. */
    val speak: Boolean = false,
    val ignore: Boolean = false,
) {
    companion object {
        val NONE = Action()
        val IGNORE = Action(ignore = true)
    }
}

/**
 * Pure turn-taking state machine for the Android voice loop (the iOS equivalent is the
 * ConversationStateMachine driven by SessionCoordinator; this one has no server paths).
 *
 * - [turnId] increases once per submitted utterance and never resets (not even on stop),
 *   so every event of an earlier turn is recognisably stale.
 * - A reply/error/turn-end is accepted only while THINKING for the current turnId;
 *   playback-finished only while SPEAKING for the current turnId.
 * - Speech while SPEAKING is a barge-in (stop TTS); speech while THINKING cancels the
 *   in-flight request (Review Focus 4), unlike iOS, which mutes the mic while waiting.
 *
 * Not thread-safe: the caller serialises calls (VoiceLoop holds one lock around them).
 */
class TurnStateMachine {
    var state: LoopState = LoopState.IDLE
        private set
    var turnId: Int = 0
        private set

    fun onStart(): Action {
        if (state != LoopState.IDLE) return Action.IGNORE
        state = LoopState.LISTENING
        return Action.NONE
    }

    fun onStop(): Action {
        if (state == LoopState.IDLE) return Action.IGNORE
        state = LoopState.IDLE
        return Action(stopTts = true, cancelInFlight = true)
    }

    fun onSpeechStart(): Action = when (state) {
        LoopState.IDLE -> Action.IGNORE
        LoopState.LISTENING -> Action.NONE
        LoopState.THINKING -> {
            state = LoopState.LISTENING
            Action(cancelInFlight = true)
        }
        LoopState.SPEAKING -> {
            state = LoopState.LISTENING
            Action(stopTts = true)
        }
    }

    /** An assembled utterance is ready. */
    fun onUtterance(): Action {
        if (state != LoopState.LISTENING) return Action.IGNORE
        turnId++
        state = LoopState.THINKING
        return Action(submitUtterance = true)
    }

    fun onResponseText(turnId: Int): Action = speakIfCurrent(turnId)

    /** An Error or KeyProblem for a turn: Elsie speaks a short friendly line instead of a reply. */
    fun onError(turnId: Int): Action = speakIfCurrent(turnId)

    /** The turn ended without a reply having been accepted: go back to listening rather than hang. */
    fun onTurnEnd(turnId: Int): Action {
        if (state != LoopState.THINKING || turnId != this.turnId) return Action.IGNORE
        state = LoopState.LISTENING
        return Action.NONE
    }

    fun onPlaybackFinished(turnId: Int): Action {
        if (state != LoopState.SPEAKING || turnId != this.turnId) return Action.IGNORE
        state = LoopState.LISTENING
        return Action.NONE
    }

    private fun speakIfCurrent(turnId: Int): Action {
        if (state != LoopState.THINKING || turnId != this.turnId) return Action.IGNORE
        state = LoopState.SPEAKING
        return Action(speak = true)
    }
}
