package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.audio.SpeechDetector
import com.jessvb.tinytalk.core.session.SessionEvent
import com.jessvb.tinytalk.core.session.TurnSession
import com.jessvb.tinytalk.core.voice.LoopState
import com.jessvb.tinytalk.core.voice.SpokenLines
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** JVM tests of VoiceLoop's wiring with fake mic / VAD / speaker / session (no Android, no audio). */
class VoiceLoopTest {
    private class FakeMic(val onFrame: (ShortArray) -> Unit, val onStopped: (String) -> Unit) : MicSource {
        var startResult = true
        var throwOnStart = false
        var starts = 0
        var stops = 0
        override fun start(): Boolean {
            starts++
            if (throwOnStart) throw IllegalStateException("aec setEnabled failed")
            return startResult
        }
        override fun stop() { stops++ }
    }

    private class FakeVad : SpeechProbability {
        @Volatile var p = 0f
        @Volatile var throwOnNext = false
        var resets = 0
        override fun probability(frame512: ShortArray): Float {
            if (throwOnNext) throw IllegalStateException("boom")
            return p
        }
        override fun reset() { resets++ }
    }

    private class FakeSpeaker : Speaker {
        val spoken = CopyOnWriteArrayList<String>()
        @Volatile var stops = 0
        @Volatile override var isSpeaking = false
        override fun speak(text: String) { spoken += text; isSpeaking = true }
        override fun stop() { stops++; isSpeaking = false }
    }

    private class FakeSession : TurnSession {
        val channel = Channel<SessionEvent>(Channel.UNLIMITED)
        override val events: Flow<SessionEvent> = channel.receiveAsFlow()
        val submits = CopyOnWriteArrayList<Int>()
        val bargeIns = CopyOnWriteArrayList<Int>()
        override fun submitUtterance(turnId: Int, pcm16: ShortArray, sampleRate: Int) { submits += turnId }
        override fun bargeIn(turnId: Int) { bargeIns += turnId }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val vad = FakeVad()
    private val speaker = FakeSpeaker()
    private val session = FakeSession()
    private val states = CopyOnWriteArrayList<LoopState>()
    private val errors = CopyOnWriteArrayList<String>()
    @Volatile private var consent = true
    private lateinit var mic: FakeMic

    private val loop = VoiceLoop(
        micFactory = { onFrame, onStopped -> FakeMic(onFrame, onStopped).also { mic = it } },
        vad = vad,
        detector = SpeechDetector(),
        session = session,
        tts = speaker,
        scope = scope,
        consentGiven = { consent },
        onState = { states += it },
        onKeyProblem = {},
        onError = { errors += it },
    )

    @After
    fun tearDown() {
        loop.stop()
        scope.cancel()
    }

    private fun eventually(what: String, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 3000
        while (!cond()) {
            if (System.currentTimeMillis() > deadline) throw AssertionError("timed out waiting for: $what")
            Thread.sleep(5)
        }
    }

    private fun frames(p: Float, n: Int) {
        vad.p = p
        repeat(n) { mic.onFrame(ShortArray(512)) }
    }

    /** Speech start (3 voiced frames) then speech end (22 silent frames). */
    private fun utterance() {
        frames(0.9f, 10)
        frames(0.1f, 22)
    }

    @Test
    fun `start without consent is refused with a visible message and no mic`() {
        consent = false
        assertFalse(loop.start())
        assertEquals(0, mic.starts)
        assertEquals(listOf(VoiceLoop.NO_CONSENT_MESSAGE), errors)
        assertEquals(LoopState.IDLE, loop.state)
    }

    @Test
    fun `mic that cannot start is reported and leaves the loop idle`() {
        mic.startResult = false
        assertFalse(loop.start())
        assertEquals(listOf(VoiceLoop.MIC_UNAVAILABLE_MESSAGE), errors)
        assertEquals(LoopState.IDLE, loop.state)
    }

    @Test
    fun `utterance is submitted, reply spoken, and playback end returns to listening`() {
        assertTrue(loop.start())
        utterance()
        assertEquals(listOf(1), session.submits)
        assertEquals(LoopState.THINKING, loop.state)
        session.channel.trySend(SessionEvent.ResponseText("Once upon a time.", 1))
        eventually("reply spoken") { speaker.spoken.contains("Once upon a time.") }
        assertEquals(LoopState.SPEAKING, loop.state)
        speaker.isSpeaking = false
        eventually("back to listening") { loop.state == LoopState.LISTENING }
    }

    @Test
    fun `speech while speaking stops TTS on the spot`() {
        loop.start()
        utterance()
        session.channel.trySend(SessionEvent.ResponseText("A fox.", 1))
        eventually("speaking") { loop.state == LoopState.SPEAKING }
        val before = speaker.stops
        frames(0.9f, 3)
        assertEquals(before + 1, speaker.stops)
        assertEquals(LoopState.LISTENING, loop.state)
    }

    @Test
    fun `key problem speaks the grown-up line`() {
        loop.start()
        utterance()
        session.channel.trySend(SessionEvent.KeyProblem(com.jessvb.tinytalk.core.session.KeyProblemKind.MISSING, 1))
        eventually("line spoken") { speaker.spoken.contains(SpokenLines.KEY_PROBLEM) }
    }

    @Test
    fun `mic loss halts the loop visibly once and start works again`() {
        assertTrue(loop.start())
        utterance() // THINKING, turn 1 in flight
        mic.onStopped("AudioRecord.read error -6")
        eventually("idle after mic loss") { loop.state == LoopState.IDLE }
        eventually("error reported") { errors.isNotEmpty() }
        assertEquals(listOf(VoiceLoop.MIC_UNAVAILABLE_MESSAGE), errors)
        assertTrue(session.bargeIns.contains(1))
        assertTrue(speaker.stops >= 1)
        assertTrue(mic.stops >= 1)
        assertTrue(vad.resets >= 1)

        assertTrue("restart after loss", loop.start())
        assertEquals(2, mic.starts)
        assertEquals(LoopState.LISTENING, loop.state)
        utterance()
        assertEquals(listOf(1, 2), session.submits)
    }

    @Test
    fun `exception in frame processing never escapes, reports once and halts`() {
        loop.start()
        vad.throwOnNext = true
        repeat(20) { mic.onFrame(ShortArray(512)) } // must not throw
        eventually("error reported") { errors.isNotEmpty() }
        Thread.sleep(50) // give a (wrong) second report time to show up
        assertEquals(LoopState.IDLE, loop.state)
        assertEquals(listOf(VoiceLoop.LISTENING_FAILED_MESSAGE), errors)
        vad.throwOnNext = false
        assertTrue(loop.start())
    }

    @Test
    fun `consent revoked while running sends no audio and stops visibly`() {
        loop.start()
        consent = false
        utterance()
        assertEquals(emptyList<Int>(), session.submits)
        eventually("idle") { loop.state == LoopState.IDLE }
        eventually("error reported") { errors.isNotEmpty() } // reported right after the cleanup
        assertEquals(listOf(VoiceLoop.NO_CONSENT_MESSAGE), errors)
    }

    @Test
    fun `state notifications end on the latest state`() {
        loop.start()
        utterance()
        loop.stop()
        eventually("idle reported") { states.lastOrNull() == LoopState.IDLE }
        assertEquals(listOf(LoopState.LISTENING, LoopState.THINKING, LoopState.IDLE), states.toList())
    }

    @Test
    fun `a mic start that throws leaves the loop stopped and reports once`() {
        assertTrue(loop.start()) // builds the mic; then make the next start throw
        loop.stop()
        errors.clear()
        mic.throwOnStart = true
        assertFalse(loop.start())
        assertEquals(LoopState.IDLE, loop.state)
        assertEquals(listOf(VoiceLoop.MIC_UNAVAILABLE_MESSAGE), errors.toList())
        mic.throwOnStart = false
        assertTrue(loop.start()) // a later Retry works
        assertEquals(LoopState.LISTENING, loop.state)
    }

    @Test
    fun `a stale halt cannot stop a fresh run`() {
        val scheduler = TestCoroutineScheduler()
        lateinit var mic2: FakeMic
        val errors2 = CopyOnWriteArrayList<String>()
        val loop2 = VoiceLoop(
            micFactory = { onFrame, onStopped -> FakeMic(onFrame, onStopped).also { mic2 = it } },
            vad = FakeVad(),
            detector = SpeechDetector(),
            session = FakeSession(),
            tts = FakeSpeaker(),
            scope = scope,
            consentGiven = { true },
            onState = {},
            onKeyProblem = {},
            onError = { errors2 += it },
            haltDispatcher = StandardTestDispatcher(scheduler),
        )
        try {
            assertTrue(loop2.start())
            mic2.onStopped("read error") // queues the halt; it has not run yet
            loop2.stop() // the user leaves...
            assertTrue(loop2.start()) // ...and comes straight back: a fresh run
            val stopsBefore = mic2.stops
            scheduler.advanceUntilIdle() // the stale halt finally runs
            assertEquals(stopsBefore, mic2.stops)
            assertEquals(LoopState.LISTENING, loop2.state)
            assertTrue(errors2.isEmpty())
        } finally {
            loop2.stop()
        }
    }

    @Test
    fun `a halt for the current run still stops it`() {
        val scheduler = TestCoroutineScheduler()
        lateinit var mic2: FakeMic
        val errors2 = CopyOnWriteArrayList<String>()
        val loop2 = VoiceLoop(
            micFactory = { onFrame, onStopped -> FakeMic(onFrame, onStopped).also { mic2 = it } },
            vad = FakeVad(),
            detector = SpeechDetector(),
            session = FakeSession(),
            tts = FakeSpeaker(),
            scope = scope,
            consentGiven = { true },
            onState = {},
            onKeyProblem = {},
            onError = { errors2 += it },
            haltDispatcher = StandardTestDispatcher(scheduler),
        )
        assertTrue(loop2.start())
        mic2.onStopped("read error")
        scheduler.advanceUntilIdle()
        assertEquals(LoopState.IDLE, loop2.state)
        assertEquals(listOf(VoiceLoop.MIC_UNAVAILABLE_MESSAGE), errors2.toList())
    }
}
