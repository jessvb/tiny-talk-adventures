package com.jessvb.tinytalk.core

import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.ChatMessage
import com.jessvb.tinytalk.core.facts.AnimalFactFetching
import com.jessvb.tinytalk.core.facts.AnimalFactTracker
import com.jessvb.tinytalk.core.facts.AnimalFactsCache
import com.jessvb.tinytalk.core.session.DemoSession
import com.jessvb.tinytalk.core.session.SessionEvent
import com.jessvb.tinytalk.core.storybook.FinishedStory
import com.jessvb.tinytalk.core.storybook.LocalPage
import com.jessvb.tinytalk.core.storybook.LocalStory
import com.jessvb.tinytalk.core.storybook.RewriteStatus
import com.jessvb.tinytalk.core.storybook.StoryLibrary
import com.jessvb.tinytalk.core.storybook.StoryStore
import com.jessvb.tinytalk.core.storybook.StorybookWriter
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SILENT on-device smoke test of the storybook code in `:core` on Android's own runtime (see
 * [CoreOnDeviceSmokeTest] for why: JVM tests cannot see Android-only runtime differences).
 * No audio, no network, no keys: the chat is an in-memory fake.
 *
 * Run ONLY this class, and ALWAYS with the leave-installed flag (else Gradle uninstalls the app
 * and wipes consent, keys and settings):
 *   ./gradlew :app:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.class=com.jessvb.tinytalk.core.StorybookOnDeviceSmokeTest \
 *     -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true
 */
class StorybookOnDeviceSmokeTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "smoke-stories-${System.nanoTime()}")

    @After fun tearDown() {
        scope.cancel()
        dir.deleteRecursively()
    }

    private fun json(title: String) = """{"title":"$title","pages":[{"text":"Page one."},{"text":"Page two."}]}"""

    private class ScriptedChat(vararg val replies: String) : ChatCompleting {
        var calls = 0
        override suspend fun complete(messages: List<ChatMessage>) = replies[minOf(calls++, replies.size - 1)]
    }

    private val turns = listOf(
        ConversationTurn(Speaker.CHILD, "tell me about a fox"),
        ConversationTurn(Speaker.AGENT, "Once there was a clever fox."),
    )

    @Test fun storyStoreRoundTripsOnAndroid() {
        val store = StoryStore(dir)
        val story = LocalStory(
            "abc", "2026-11-04T10:00:00Z", turns, listOf("fox" to "foxes hear well"), 5,
            title = "The Fox", pages = listOf(LocalPage("Page one.")), epilogue = "e", rewriteStatus = RewriteStatus.DONE,
        )
        store.save(story)
        assertEquals(story, store.get("abc"))
        assertEquals(listOf("abc"), store.list().map { it.id })
    }

    @Test fun writerParsesWrappedJsonAndAppliesTheSafetyRetryOnAndroid() = runBlocking {
        // Prose around the JSON (extraction), then an unsafe title (the Android-ICU safety regex)
        // then a safe one: the retry must produce the third reply.
        val chat = ScriptedChat("Sure! " + json("The Knife Fight") + " Enjoy.", "Here: " + json("The Big Adventure"))
        val written = StorybookWriter(chat).write(turns, listOf("fox" to "foxes hear well"), 2)
        assertNotNull(written)
        assertEquals("The Big Adventure", written!!.title)
        assertEquals(2, written.pages.size)
        assertEquals("And one true thing we learned about the fox: foxes hear well", written.epilogue)
        assertEquals(2, chat.calls)
    }

    @Test fun libraryBuildsAStorybookEndToEndOnAndroid() = runBlocking {
        val lib = StoryLibrary(
            StoryStore(dir), StorybookWriter(ScriptedChat(json("The Fox"))), scope,
            newId = { "s1" }, now = { "2026-11-04T10:00:00Z" },
        )
        val id = lib.begin(FinishedStory(turns, emptyList()), 2)
        withTimeout(10_000) { while (lib.detail(id)?.rewriteStatus != RewriteStatus.DONE) kotlinx.coroutines.delay(20) }
        assertEquals("The Fox", lib.detail(id)!!.title)
        assertEquals("The Fox", lib.summaries.value.single().title)
    }

    @Test fun concludingStoryYieldsItsTranscriptOnAndroid() = runBlocking {
        val chat = ScriptedChat("Once upon a time.", "They all went home happily.")
        val stt = object : SpeechTranscribing {
            override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int) = "a fox"
        }
        val fetcher = object : AnimalFactFetching {
            override suspend fun fetchFacts(canonical: String): List<String>? = null
        }
        val cache = AnimalFactsCache(File(dir.parentFile, "smoke-facts-${System.nanoTime()}.json"))
        val s = DemoSession(chat, stt, AnimalFactTracker(fetcher, cache), scope)
        try {
            s.submitUtterance(1, ShortArray(1600), 16000)
            withTimeout(10_000) { s.events.take(3).toList() } // transcript, reply, turn end
            s.concludeStory(2)
            val rest = withTimeout(10_000) { s.events.take(3).toList() } // reply, turn end, finished
            val finished = rest.last() as SessionEvent.StoryFinished
            assertEquals(3, finished.story.turns.size)
            assertTrue(finished.story.turns.last().text.contains("went home"))
        } finally {
            s.close()
        }
    }
}
