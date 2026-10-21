package com.jessvb.tinytalk.core.voice

import com.jessvb.tinytalk.core.voice.LoopState.IDLE
import com.jessvb.tinytalk.core.voice.LoopState.LISTENING
import com.jessvb.tinytalk.core.voice.LoopState.SPEAKING
import com.jessvb.tinytalk.core.voice.LoopState.THINKING
import org.junit.Assert.assertEquals
import org.junit.Test

class TurnStateMachineTest {

    /** A machine driven into [state] the normal way; for THINKING/SPEAKING the current turn is 1. */
    private fun machineIn(state: LoopState): TurnStateMachine {
        val m = TurnStateMachine()
        if (state == IDLE) return m
        m.onStart()
        if (state == LISTENING) return m
        m.onSpeechStart()
        m.onUtterance()
        if (state == THINKING) return m
        m.onResponseText(m.turnId)
        check(m.state == SPEAKING)
        return m
    }

    private enum class Ev { START, STOP, MIC_LOST, SPEECH_START, UTTERANCE, RESPONSE, RESPONSE_STALE, ERROR, ERROR_STALE, TURN_END, TURN_END_STALE, PLAYBACK_DONE, PLAYBACK_DONE_STALE }

    private fun TurnStateMachine.fire(ev: Ev): Action {
        val cur = turnId
        return when (ev) {
            Ev.START -> onStart()
            Ev.STOP -> onStop()
            Ev.MIC_LOST -> onMicLost()
            Ev.SPEECH_START -> onSpeechStart()
            Ev.UTTERANCE -> onUtterance()
            Ev.RESPONSE -> onResponseText(cur)
            Ev.RESPONSE_STALE -> onResponseText(cur - 1)
            Ev.ERROR -> onError(cur)
            Ev.ERROR_STALE -> onError(cur - 1)
            Ev.TURN_END -> onTurnEnd(cur)
            Ev.TURN_END_STALE -> onTurnEnd(cur - 1)
            Ev.PLAYBACK_DONE -> onPlaybackFinished(cur)
            Ev.PLAYBACK_DONE_STALE -> onPlaybackFinished(cur - 1)
        }
    }

    private val none = Action.NONE
    private val ign = Action.IGNORE
    private val speak = Action(speak = true)

    /** Every (state, event) pair: expected next state, action, and whether turnId was bumped. */
    private data class Row(val from: LoopState, val ev: Ev, val to: LoopState, val action: Action, val bump: Boolean = false)

    private val table = listOf(
        // IDLE: only START does anything; nothing else may touch mic/TTS/network.
        Row(IDLE, Ev.START, LISTENING, none),
        Row(IDLE, Ev.STOP, IDLE, ign),
        Row(IDLE, Ev.MIC_LOST, IDLE, ign),
        Row(IDLE, Ev.SPEECH_START, IDLE, ign),
        Row(IDLE, Ev.UTTERANCE, IDLE, ign),
        Row(IDLE, Ev.RESPONSE, IDLE, ign),
        Row(IDLE, Ev.RESPONSE_STALE, IDLE, ign),
        Row(IDLE, Ev.ERROR, IDLE, ign),
        Row(IDLE, Ev.ERROR_STALE, IDLE, ign),
        Row(IDLE, Ev.TURN_END, IDLE, ign),
        Row(IDLE, Ev.TURN_END_STALE, IDLE, ign),
        Row(IDLE, Ev.PLAYBACK_DONE, IDLE, ign),
        Row(IDLE, Ev.PLAYBACK_DONE_STALE, IDLE, ign),
        // LISTENING
        Row(LISTENING, Ev.START, LISTENING, ign),
        Row(LISTENING, Ev.STOP, IDLE, Action(stopTts = true, cancelInFlight = true)),
        Row(LISTENING, Ev.MIC_LOST, IDLE, Action(stopTts = true, cancelInFlight = true)),
        Row(LISTENING, Ev.SPEECH_START, LISTENING, none),
        Row(LISTENING, Ev.UTTERANCE, THINKING, Action(submitUtterance = true), bump = true),
        Row(LISTENING, Ev.RESPONSE, LISTENING, ign), // e.g. a reply queued before a barge-in
        Row(LISTENING, Ev.RESPONSE_STALE, LISTENING, ign),
        Row(LISTENING, Ev.ERROR, LISTENING, ign),
        Row(LISTENING, Ev.ERROR_STALE, LISTENING, ign),
        Row(LISTENING, Ev.TURN_END, LISTENING, ign),
        Row(LISTENING, Ev.TURN_END_STALE, LISTENING, ign),
        Row(LISTENING, Ev.PLAYBACK_DONE, LISTENING, ign),
        Row(LISTENING, Ev.PLAYBACK_DONE_STALE, LISTENING, ign),
        // THINKING (turn 1 in flight)
        Row(THINKING, Ev.START, THINKING, ign),
        Row(THINKING, Ev.STOP, IDLE, Action(stopTts = true, cancelInFlight = true)),
        Row(THINKING, Ev.MIC_LOST, IDLE, Action(stopTts = true, cancelInFlight = true)),
        Row(THINKING, Ev.SPEECH_START, LISTENING, Action(cancelInFlight = true)), // Review Focus 4
        Row(THINKING, Ev.UTTERANCE, THINKING, ign),
        Row(THINKING, Ev.RESPONSE, SPEAKING, speak),
        Row(THINKING, Ev.RESPONSE_STALE, THINKING, ign),
        Row(THINKING, Ev.ERROR, SPEAKING, speak), // speaks the friendly line
        Row(THINKING, Ev.ERROR_STALE, THINKING, ign),
        Row(THINKING, Ev.TURN_END, LISTENING, none), // turn over without any reply: don't hang
        Row(THINKING, Ev.TURN_END_STALE, THINKING, ign),
        Row(THINKING, Ev.PLAYBACK_DONE, THINKING, ign),
        Row(THINKING, Ev.PLAYBACK_DONE_STALE, THINKING, ign),
        // SPEAKING (turn 1's reply playing)
        Row(SPEAKING, Ev.START, SPEAKING, ign),
        Row(SPEAKING, Ev.STOP, IDLE, Action(stopTts = true, cancelInFlight = true)),
        Row(SPEAKING, Ev.MIC_LOST, IDLE, Action(stopTts = true, cancelInFlight = true)),
        Row(SPEAKING, Ev.SPEECH_START, LISTENING, Action(stopTts = true)), // barge-in
        Row(SPEAKING, Ev.UTTERANCE, SPEAKING, ign),
        Row(SPEAKING, Ev.RESPONSE, SPEAKING, ign), // duplicate
        Row(SPEAKING, Ev.RESPONSE_STALE, SPEAKING, ign),
        Row(SPEAKING, Ev.ERROR, SPEAKING, ign),
        Row(SPEAKING, Ev.ERROR_STALE, SPEAKING, ign),
        Row(SPEAKING, Ev.TURN_END, SPEAKING, ign), // TurnEnd follows ResponseText; playback decides
        Row(SPEAKING, Ev.TURN_END_STALE, SPEAKING, ign),
        Row(SPEAKING, Ev.PLAYBACK_DONE, LISTENING, none),
        Row(SPEAKING, Ev.PLAYBACK_DONE_STALE, SPEAKING, ign),
    )

    @Test
    fun `transition table covers every state and event`() {
        assertEquals(LoopState.entries.size * Ev.entries.size, table.map { it.from to it.ev }.toSet().size)
    }

    @Test
    fun `transition table`() {
        for (row in table) {
            val m = machineIn(row.from)
            val idBefore = m.turnId
            val action = m.fire(row.ev)
            val where = "${row.from} --${row.ev}-->"
            assertEquals("$where state", row.to, m.state)
            assertEquals("$where action", row.action, action)
            assertEquals("$where turnId", if (row.bump) idBefore + 1 else idBefore, m.turnId)
        }
    }

    @Test
    fun `happy path through two turns`() {
        val m = TurnStateMachine()
        assertEquals(IDLE, m.state)
        m.onStart()
        assertEquals(LISTENING, m.state)
        m.onSpeechStart()
        assertEquals(Action(submitUtterance = true), m.onUtterance())
        assertEquals(THINKING, m.state)
        assertEquals(1, m.turnId)
        assertEquals(speak, m.onResponseText(1))
        assertEquals(SPEAKING, m.state)
        assertEquals(ign, m.onTurnEnd(1))
        assertEquals(none, m.onPlaybackFinished(1))
        assertEquals(LISTENING, m.state)
        m.onSpeechStart()
        m.onUtterance()
        assertEquals(2, m.turnId)
    }

    @Test
    fun `barge-in while speaking stops TTS, new utterance bumps turnId, old playback-finished is ignored`() {
        val m = machineIn(SPEAKING)
        assertEquals(Action(stopTts = true), m.onSpeechStart())
        assertEquals(Action(submitUtterance = true), m.onUtterance())
        assertEquals(2, m.turnId)
        assertEquals(ign, m.onPlaybackFinished(1)) // the stopped reply's poll noticing silence
        assertEquals(THINKING, m.state)
    }

    @Test
    fun `barge-in while thinking cancels and the late reply is never spoken`() {
        val m = machineIn(THINKING)
        assertEquals(Action(cancelInFlight = true), m.onSpeechStart())
        assertEquals(ign, m.onResponseText(1)) // arrived before the utterance finished
        m.onUtterance()
        assertEquals(ign, m.onResponseText(1)) // arrived after: stale turnId
        assertEquals(THINKING, m.state)
        assertEquals(speak, m.onResponseText(2))
    }

    @Test
    fun `turnId keeps increasing across stop and start so pre-stop events stay stale`() {
        val m = machineIn(THINKING)
        m.onStop()
        m.onStart()
        m.onSpeechStart()
        m.onUtterance()
        assertEquals(2, m.turnId)
        assertEquals(ign, m.onResponseText(1))
    }

    @Test
    fun `start works again after a mic loss, and turnId stays monotonic`() {
        val m = machineIn(SPEAKING)
        assertEquals(Action(stopTts = true, cancelInFlight = true), m.onMicLost())
        assertEquals(IDLE, m.state)
        assertEquals(none, m.onStart())
        assertEquals(LISTENING, m.state)
        m.onSpeechStart()
        m.onUtterance()
        assertEquals(2, m.turnId)
        assertEquals(ign, m.onResponseText(1))
    }
}
