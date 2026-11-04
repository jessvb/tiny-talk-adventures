package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.ConversationTurn
import com.jessvb.tinytalk.core.Speaker
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.ChatMessage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class StoryLibraryTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun reply(title: String) =
        """{"title":"$title","pages":[{"text":"Page one."},{"text":"Page two."}]}"""

    /** Hands out scripted replies; optionally holds each call until [gates] releases it. */
    private class FakeChat(private val onCall: suspend (Int, List<ChatMessage>) -> String) : ChatCompleting {
        var calls = 0
        override suspend fun complete(messages: List<ChatMessage>): String = onCall(++calls, messages)
    }

    private fun finished(text: String = "a fox", facts: List<Pair<String, String>> = emptyList()) = FinishedStory(
        turns = listOf(ConversationTurn(Speaker.CHILD, text), ConversationTurn(Speaker.AGENT, "Once there was a $text.")),
        sharedFacts = facts,
    )

    private val store by lazy { StoryStore(File(tmp.root, "stories")) }
    private var idCounter = 0
    private var clock = 0

    /**
     * A scope on the test scheduler that is NOT the test's backgroundScope: advanceUntilIdle()
     * deliberately skips background work, so builds launched there would never run.
     */
    private val scopes = mutableListOf<CoroutineScope>()
    private fun TestScope.libScope() = CoroutineScope(StandardTestDispatcher(testScheduler)).also { scopes += it }

    @After fun tearDown() { scopes.forEach { it.cancel() } }

    private fun library(chat: ChatCompleting, scope: kotlinx.coroutines.CoroutineScope) = StoryLibrary(
        store = store,
        writer = StorybookWriter(chat),
        scope = scope,
        newId = { "s${++idCounter}" },
        now = { "2026-11-04T10:00:%02dZ".format(++clock) },
    )

    @Test fun `begin saves the transcript as pending before any chat call`() = runTest {
        var statusAtCall: List<RewriteStatus>? = null
        val chat = FakeChat { _, _ -> statusAtCall = store.list().map { it.rewriteStatus }; reply("T") }
        val lib = library(chat, libScope())
        val id = lib.begin(finished(), pageCount = 5)
        assertEquals(RewriteStatus.PENDING, store.get(id)?.rewriteStatus) // synchronously, before the build runs
        advanceUntilIdle()
        assertEquals(listOf(RewriteStatus.PENDING), statusAtCall)
    }

    @Test fun `a successful build saves title pages and epilogue as done`() = runTest {
        val lib = library(FakeChat { _, _ -> reply("The Fox") }, libScope())
        val id = lib.begin(finished(facts = listOf("fox" to "foxes hear well")), pageCount = 2)
        advanceUntilIdle()
        val s = lib.detail(id)!!
        assertEquals(RewriteStatus.DONE, s.rewriteStatus)
        assertEquals("The Fox", s.title)
        assertEquals(listOf("Page one.", "Page two."), s.pages.map { it.text })
        assertEquals("And one true thing we learned about the fox: foxes hear well", s.epilogue)
        assertEquals(2, s.pageCount)
    }

    @Test fun `a done story's summary reports its actual page count`() = runTest {
        // The writer returns 2 pages although 5 were asked for (iOS accepts that); the Library
        // must say "2 pages", not the target.
        val lib = library(FakeChat { _, _ -> reply("The Fox") }, libScope())
        lib.begin(finished(), pageCount = 5)
        assertEquals(5, lib.summaries.value.single().pageCount) // pending: the target
        advanceUntilIdle()
        assertEquals(2, lib.summaries.value.single().pageCount)
    }

    @Test fun `summaries are newest first and update as builds finish`() = runTest {
        var n = 0
        val lib = library(FakeChat { _, _ -> reply("Story ${++n}") }, libScope())
        val a = lib.begin(finished("a fox"), 5)
        val b = lib.begin(finished("a bear"), 5)
        assertEquals(listOf(b, a), lib.summaries.value.map { it.id })
        assertTrue(lib.summaries.value.all { it.status == RewriteStatus.PENDING })
        advanceUntilIdle()
        assertTrue(lib.summaries.value.all { it.status == RewriteStatus.DONE })
        assertEquals(listOf("Story 2", "Story 1"), lib.summaries.value.map { it.title })
    }

    @Test fun `a failed build keeps the transcript and marks the story failed`() = runTest {
        val lib = library(FakeChat { _, _ -> "never json" }, libScope())
        val id = lib.begin(finished("a fox"), 5)
        advanceUntilIdle()
        val s = lib.detail(id)!!
        assertEquals(RewriteStatus.FAILED, s.rewriteStatus)
        assertEquals(2, s.turns.size)
        assertNull(s.title)
        assertEquals(RewriteStatus.FAILED, lib.summaries.value.single().status)
    }

    @Test fun `a chat call that throws marks the story failed without crashing`() = runTest {
        val lib = library(FakeChat { _, _ -> throw IllegalStateException("boom") }, libScope())
        val id = lib.begin(finished(), 5)
        advanceUntilIdle()
        assertEquals(RewriteStatus.FAILED, lib.detail(id)!!.rewriteStatus)
    }

    @Test fun `builds run one at a time and each story keeps its own result`() = runTest {
        val gate1 = CompletableDeferred<Unit>()
        var concurrent = 0
        var maxConcurrent = 0
        val chat = FakeChat { call, messages ->
            concurrent++; maxConcurrent = maxOf(maxConcurrent, concurrent)
            if (call == 1) gate1.await()
            val child = messages[1].content.substringAfter("Child: ").substringBefore("\n")
            concurrent--
            reply("About $child")
        }
        val lib = library(chat, libScope())
        val a = lib.begin(finished("a fox"), 5)
        val b = lib.begin(finished("a bear"), 5)
        advanceUntilIdle()
        assertEquals(1, chat.calls) // the second build waits for the first
        assertEquals(RewriteStatus.PENDING, lib.detail(b)!!.rewriteStatus)
        gate1.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, maxConcurrent)
        assertEquals("About a fox", lib.detail(a)!!.title)
        assertEquals("About a bear", lib.detail(b)!!.title)
    }

    @Test fun `requeuePending rebuilds pending stories once and leaves done and failed alone`() = runTest {
        store.save(LocalStory("p1", "2026-11-01T00:00:00Z", finished().turns, emptyList(), 5))
        store.save(LocalStory("d1", "2026-11-02T00:00:00Z", finished().turns, emptyList(), 5, title = "Done", pages = listOf(LocalPage("x")), rewriteStatus = RewriteStatus.DONE))
        store.save(LocalStory("f1", "2026-11-03T00:00:00Z", finished().turns, emptyList(), 5, rewriteStatus = RewriteStatus.FAILED))
        val chat = FakeChat { _, _ -> reply("Rescued") }
        val lib = library(chat, libScope())
        lib.requeuePending()
        lib.requeuePending() // calling twice must not build twice
        advanceUntilIdle()
        assertEquals(1, chat.calls)
        assertEquals("Rescued", lib.detail("p1")!!.title)
        assertEquals("Done", lib.detail("d1")!!.title)
        assertEquals(RewriteStatus.FAILED, lib.detail("f1")!!.rewriteStatus)
    }

    @Test fun `latestStatus follows the newest story only`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val chat = FakeChat { call, _ -> if (call == 1) gate.await(); reply("T") }
        val lib = library(chat, libScope())
        assertNull(lib.latestStatus.value)
        val a = lib.begin(finished("a fox"), 5)
        val b = lib.begin(finished("a bear"), 5)
        assertEquals(b to RewriteStatus.PENDING, lib.latestStatus.value)
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(b to RewriteStatus.DONE, lib.latestStatus.value)
        assertEquals(RewriteStatus.DONE, lib.detail(a)!!.rewriteStatus)
    }

    @Test fun `summaries load existing stories on construction`() = runTest {
        store.save(LocalStory("old", "2026-11-01T00:00:00Z", finished().turns, emptyList(), 4, title = "Old One", pages = listOf(LocalPage("x")), rewriteStatus = RewriteStatus.DONE))
        val lib = library(FakeChat { _, _ -> reply("T") }, libScope())
        assertEquals(listOf("Old One"), lib.summaries.value.map { it.title })
    }
}
