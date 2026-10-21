package com.jessvb.tinytalk.core.session

import com.jessvb.tinytalk.core.Safety
import com.jessvb.tinytalk.core.StoryArc
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.ChatMessage
import com.jessvb.tinytalk.core.chat.GroqException
import com.jessvb.tinytalk.core.facts.AnimalFactFetching
import com.jessvb.tinytalk.core.facts.AnimalFactTracker
import com.jessvb.tinytalk.core.facts.AnimalFactsCache
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private const val GENERIC =
    "Elsie's cloud brain is having trouble -- let's try again in a moment."

private class FakeStt(var next: suspend () -> String = { "hello" }) : SpeechTranscribing {
    override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int) = next()
}

private class FakeChat(var next: suspend (List<ChatMessage>) -> String = { "Once upon a time." }) : ChatCompleting {
    val requests = mutableListOf<List<ChatMessage>>()
    override suspend fun complete(messages: List<ChatMessage>): String {
        requests.add(messages)
        return next(messages)
    }
}

private class FakeFetcher : AnimalFactFetching {
    override suspend fun fetchFacts(canonical: String): List<String>? = listOf("it lives in forests")
}

@OptIn(ExperimentalCoroutinesApi::class)
class DemoSessionTest {
    @get:Rule val tmp = TemporaryFolder()

    private val prompt = "SYS"
    private val introGuidance = StoryArc(7).recordTurn("hello")
    private val nudge = "No animal has been part of the story yet. Before continuing, warmly " +
        "ask the child what animal should be in the story."
    private val sttFailure =
        "You didn't hear anything new from the child just now -- it might " +
            "have been background noise. Don't mention this or ask them to " +
            "repeat themselves. Instead, gently continue the story yourself " +
            "using what's already happened, and end with an easy, inviting " +
            "question so they have a natural opening to jump back in."

    private fun TestScope.make(
        chat: FakeChat = FakeChat(),
        stt: FakeStt = FakeStt(),
        targetTurns: Int = 7,
        timeoutMs: Long = 60_000,
        resetGate: CompletableDeferred<Unit>? = null,
    ): DemoSession {
        val tracker = AnimalFactTracker(FakeFetcher(), AnimalFactsCache(File(tmp.root, "c${System.nanoTime()}.json")))
        return DemoSession(
            chat, stt, tracker, backgroundScope, prompt, targetTurns, timeoutMs,
            resetFacts = { resetGate?.await(); resets++; tracker.reset() },
        )
    }

    private var resets = 0

    private fun TestScope.collect(session: DemoSession): MutableList<SessionEvent> {
        val out = mutableListOf<SessionEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { session.events.collect { out.add(it) } }
        return out
    }

    private val pcm = ShortArray(10)

    @Test fun happyPathEventsAndSystemMessage() = runTest {
        val chat = FakeChat()
        val s = make(chat)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(
            listOf(
                SessionEvent.TranscriptFinal("hello", 1),
                SessionEvent.ResponseText("Once upon a time.", 1),
                SessionEvent.TurnEnd(1),
            ),
            ev,
        )
        assertEquals(
            listOf(ChatMessage("system", "$prompt\n\n$introGuidance\n\n$nudge"), ChatMessage("user", "hello")),
            chat.requests[0],
        )
    }

    @Test fun childAndAgentTurnsRecorded() = runTest {
        val chat = FakeChat()
        val s = make(chat)
        collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        val m = chat.requests[1]
        assertEquals(listOf("system", "user", "assistant", "user"), m.map { it.role })
        assertEquals("Once upon a time.", m[2].content)
    }

    @Test fun animalFactGuidanceAppended() = runTest {
        val chat = FakeChat()
        val s = make(chat, FakeStt { "the fox ran" })
        collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        val g = StoryArc(7).recordTurn("the fox ran")
        val sys = chat.requests[0][0].content
        assertTrue(sys, sys.startsWith("$prompt\n\n$g\n\nThe story just mentioned a fox."))
    }

    @Test fun unsafeReplyBecomesFallback() = runTest {
        val s = make(FakeChat { "They wanted to kill the dragon." })
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(SessionEvent.ResponseText(Safety.SAFE_FALLBACK, 1), ev[1])
    }

    @Test fun blankTranscript() = runTest {
        val chat = FakeChat()
        val s = make(chat, FakeStt { "  " })
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(SessionEvent.TranscriptFinal("  ", 1), ev[0])
        assertEquals(listOf("system"), chat.requests[0].map { it.role })
        assertEquals("$prompt\n\n$introGuidance\n\n$nudge\n\n$sttFailure", chat.requests[0][0].content)
        assertEquals(3, ev.size)
    }

    @Test fun bargeInDuringTranscriptionDropsTurn() = runTest {
        val gate = CompletableDeferred<String>()
        val chat = FakeChat()
        val s = make(chat, FakeStt { gate.await() })
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        s.bargeIn(2)
        gate.complete("late")
        runCurrent()
        assertTrue(ev.isEmpty())
        assertTrue(chat.requests.isEmpty())
    }

    @Test fun bargeInDuringChatDropsReply() = runTest {
        val gate = CompletableDeferred<String>()
        val chat = FakeChat { gate.await() }
        val s = make(chat)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(1, chat.requests.size)
        s.bargeIn(2)
        gate.complete("late reply")
        runCurrent()
        assertEquals(listOf<SessionEvent>(SessionEvent.TranscriptFinal("hello", 1)), ev)
    }

    @Test fun newerUtteranceSupersedesOlder() = runTest {
        val gate = CompletableDeferred<String>()
        var calls = 0
        val chat = FakeChat { if (calls++ == 0) gate.await() else "second" }
        val s = make(chat)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        gate.complete("first")
        runCurrent()
        assertTrue(ev.none { it is SessionEvent.ResponseText && it.turnId == 1 })
        assertTrue(ev.contains(SessionEvent.ResponseText("second", 2)))
        assertTrue(ev.contains(SessionEvent.TurnEnd(2)))
    }

    private fun errorCase(ex: Exception, expected: (Int) -> SessionEvent) = runTest {
        var fail = true
        val chat = FakeChat { if (fail) throw ex else "ok" }
        val s = make(chat)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(listOf(SessionEvent.TranscriptFinal("hello", 1), expected(1)), ev)
        fail = false
        ev.clear()
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        assertEquals(SessionEvent.TurnEnd(2), ev.last())
    }

    @Test fun keyMissing() = errorCase(GroqException.KeyMissing()) { SessionEvent.KeyProblem(KeyProblemKind.MISSING, it) }
    @Test fun keyRejected() = errorCase(GroqException.KeyRejected()) { SessionEvent.KeyProblem(KeyProblemKind.REJECTED, it) }
    @Test fun rateLimited() = errorCase(GroqException.RateLimited(3)) { SessionEvent.KeyProblem(KeyProblemKind.RATE_LIMITED, it) }
    @Test fun networkError() = errorCase(GroqException.Network(RuntimeException("x"))) { SessionEvent.Error(GENERIC, it) }
    @Test fun failureError() = errorCase(GroqException.Failure("HTTP 500")) { SessionEvent.Error(GENERIC, it) }
    @Test fun genericException() = errorCase(IllegalStateException("boom")) { SessionEvent.Error(GENERIC, it) }

    @Test fun sttFailureIsGenericError() = runTest {
        val s = make(stt = FakeStt { throw IllegalStateException("on-device") })
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(listOf<SessionEvent>(SessionEvent.Error(GENERIC, 1)), ev)
    }

    @Test fun hungRequestTimesOutThenRecovers() = runTest {
        var hang = true
        val chat = FakeChat { if (hang) awaitCancellation() else "fine" }
        val s = make(chat, timeoutMs = 1_000)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        advanceTimeBy(999)
        assertTrue(ev.none { it is SessionEvent.Error })
        advanceTimeBy(2)
        runCurrent()
        assertEquals(SessionEvent.Error(GENERIC, 1), ev.last())
        hang = false
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        assertEquals(SessionEvent.TurnEnd(2), ev.last())
    }

    @Test fun storyFinishesAndResets() = runTest {
        val chat = FakeChat { "The end." }
        val s = make(chat, targetTurns = 4)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(
            listOf(
                SessionEvent.TranscriptFinal("hello", 1),
                SessionEvent.ResponseText("The end.", 1),
                SessionEvent.TurnEnd(1),
                SessionEvent.StoryFinished,
            ),
            ev,
        )
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        // fresh arc (INTRO guidance), fresh conversation, fresh facts (nudge again)
        assertEquals(
            listOf(ChatMessage("system", "$prompt\n\n$introGuidance\n\n$nudge"), ChatMessage("user", "hello")),
            chat.requests[1],
        )
    }

    @Test fun graceCeilingForcesFinish() = runTest {
        val chat = FakeChat { "and then more story" }
        val s = make(chat, targetTurns = 4)
        val ev = collect(s)
        for (i in 1..8) {
            s.submitUtterance(i, pcm, 16000)
            runCurrent()
        }
        assertEquals(SessionEvent.StoryFinished, ev.last())
        assertEquals(1, ev.count { it == SessionEvent.StoryFinished })
    }

    @Test fun newStoryMidTurnDropsEventsAndResets() = runTest {
        val gate = CompletableDeferred<String>()
        var calls = 0
        val chat = FakeChat { if (calls++ == 0) gate.await() else "fresh" }
        val s = make(chat)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        s.newStory()
        gate.complete("stale")
        runCurrent()
        assertEquals(listOf<SessionEvent>(SessionEvent.TranscriptFinal("hello", 1)), ev)
        ev.clear()
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        assertEquals(listOf("system", "user"), chat.requests[1].map { it.role })
        assertEquals(SessionEvent.TurnEnd(2), ev.last())
    }

    @Test fun closeIsIdempotentAndStopsFlow() = runTest {
        val s = make()
        val collected = backgroundScope.launch { s.events.toList() }
        s.close()
        s.close()
        runCurrent()
        assertTrue(collected.isCompleted)
        s.submitUtterance(1, pcm, 16000)
        s.bargeIn(2)
        s.newStory()
        runCurrent()
    }

    @Test fun bargeInAfterFinalTurnEndStillYieldsStoryFinishedOnceAndFreshStory() = runTest {
        val gate = CompletableDeferred<Unit>()
        var calls = 0
        val chat = FakeChat { if (calls++ == 0) "The end." else "A new tale begins." }
        val s = make(chat, targetTurns = 4, resetGate = gate)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        // facts reset is still pending (gated); the child talks over "The end."
        s.bargeIn(2)
        runCurrent()
        assertEquals(1, ev.count { it == SessionEvent.StoryFinished })
        assertTrue(ev.indexOf(SessionEvent.TurnEnd(1)) < ev.indexOf(SessionEvent.StoryFinished))
        s.submitUtterance(3, pcm, 16000)
        runCurrent()
        assertEquals(1, chat.requests.size) // waits for the pending reset
        gate.complete(Unit)
        runCurrent()
        assertEquals(2, chat.requests.size)
        assertEquals(
            listOf(ChatMessage("system", "$prompt\n\n$introGuidance\n\n$nudge"), ChatMessage("user", "hello")),
            chat.requests[1],
        )
        assertEquals(1, ev.count { it == SessionEvent.StoryFinished })
    }

    @Test fun newStoryDuringPendingFinishResetIsNotClobbered() = runTest {
        val gate = CompletableDeferred<Unit>()
        val chat = FakeChat { "The end." }
        val s = make(chat, targetTurns = 4, resetGate = gate)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        s.newStory()
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        assertEquals(1, chat.requests.size) // blocked behind both pending resets
        assertEquals(0, resets)
        gate.complete(Unit)
        runCurrent()
        assertEquals(3, resets) // finish-1, newStory, finish-2 (the latter after turn 2 ran)
        assertEquals(listOf("system", "user"), chat.requests[1].map { it.role })
        assertEquals(2, ev.count { it == SessionEvent.StoryFinished }) // turn 2 also says "The end."
        assertEquals(SessionEvent.StoryFinished, ev.last())
    }

    @Test fun cancellationIgnoringChatReplyIsDroppedAndDoesNotAdvanceArc() = runTest {
        val gate = CompletableDeferred<Unit>()
        var calls = 0
        val chat = FakeChat {
            if (calls++ == 0) {
                withContext(NonCancellable) { gate.await() }
                "The end."
            } else {
                "go on"
            }
        }
        val s = make(chat)
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        s.bargeIn(2)
        gate.complete(Unit)
        runCurrent()
        assertEquals(listOf<SessionEvent>(SessionEvent.TranscriptFinal("hello", 1)), ev)
        s.submitUtterance(3, pcm, 16000)
        runCurrent()
        assertTrue(ev.none { it == SessionEvent.StoryFinished })
        assertTrue(chat.requests[1].none { it.content == "The end." })
        assertEquals(SessionEvent.TurnEnd(3), ev.last())
    }

    private fun sttErrorCase(ex: Exception, expected: SessionEvent) = runTest {
        var fail = true
        val s = make(stt = FakeStt { if (fail) throw ex else "hi" })
        val ev = collect(s)
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        assertEquals(listOf(expected), ev)
        fail = false
        s.submitUtterance(2, pcm, 16000)
        runCurrent()
        assertEquals(SessionEvent.TurnEnd(2), ev.last())
    }

    @Test fun sttKeyMissing() = sttErrorCase(GroqException.KeyMissing(), SessionEvent.KeyProblem(KeyProblemKind.MISSING, 1))
    @Test fun sttKeyRejected() = sttErrorCase(GroqException.KeyRejected(), SessionEvent.KeyProblem(KeyProblemKind.REJECTED, 1))
    @Test fun sttRateLimited() = sttErrorCase(GroqException.RateLimited(null), SessionEvent.KeyProblem(KeyProblemKind.RATE_LIMITED, 1))

    @Test fun eventsDeliveredToLateCollector() = runTest {
        val s = make()
        s.submitUtterance(1, pcm, 16000)
        runCurrent()
        val got = s.events.take(3).toList()
        assertEquals(SessionEvent.TurnEnd(1), got[2])
    }
}
