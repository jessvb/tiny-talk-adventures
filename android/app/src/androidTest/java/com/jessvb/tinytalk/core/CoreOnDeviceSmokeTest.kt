package com.jessvb.tinytalk.core

import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.ChatMessage
import com.jessvb.tinytalk.core.facts.AnimalFactFetching
import com.jessvb.tinytalk.core.facts.AnimalFactTracker
import com.jessvb.tinytalk.core.facts.AnimalFacts
import com.jessvb.tinytalk.core.facts.AnimalFactsCache
import com.jessvb.tinytalk.core.session.DemoSession
import com.jessvb.tinytalk.core.session.SessionEvent
import com.jessvb.tinytalk.core.stt.SpeechTranscribing
import com.jessvb.tinytalk.core.stt.TranscriptCleaner
import com.jessvb.tinytalk.core.stt.wavFromPcm16
import com.jessvb.tinytalk.core.text.containsWord
import com.jessvb.tinytalk.core.text.wordPattern
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.regex.Pattern
import kotlinx.coroutines.CoroutineExceptionHandler
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SILENT on-device smoke test of the pure-Kotlin `:core` module (issue #88 "Hello" crash).
 *
 * `:core` is a plain JVM module: its unit tests run on OpenJDK, and Android lint cannot see
 * it, so an API that OpenJDK supports but Android's runtime does not (the crash was
 * `Pattern.UNICODE_CHARACTER_CLASS`, rejected by Android's ICU-based java.util.regex) passes
 * every JVM test and only dies on the phone. These tests run the REAL `:core` code on the
 * device's own runtime.
 *
 * No audio, no network, no keys: nothing here touches android.media, TextToSpeech or
 * AudioRecord; the chat, transcriber and fact fetcher are in-memory fakes.
 *
 * Run ONLY this class, and ALWAYS with the leave-installed flag:
 *   ./gradlew :app:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.class=com.jessvb.tinytalk.core.CoreOnDeviceSmokeTest \
 *     -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true
 * Without that last flag, Gradle UNINSTALLS the app from the phone after the run, which
 * wipes the saved consent, parent-entered keys, voice/listening settings and the facts cache.
 */
class CoreOnDeviceSmokeTest {
    /** Records anything a session coroutine throws instead of letting it kill the test process. */
    private val escaped = CopyOnWriteArrayList<Throwable>()
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, t -> escaped.add(t) },
    )

    @After
    fun tearDown() = scope.cancel()

    // ---- (a) Safety ----

    @Test
    fun safetyInitializesAndMatchesWholeWords() {
        assertEquals("Hmm, let's take the story somewhere else! What should happen next?", Safety.SAFE_FALLBACK)
        val blocked = mapOf(
            "The knife was sharp" to listOf("knife"),
            "KNIFE" to listOf("knife"),
            "hell-bent" to listOf("hell"),
            "kill's" to listOf("kill"),
            "killing" to listOf("killing"),
            "an asshole" to listOf("asshole"),
            "A GUN, a Knife, another gun, then KILL and knife" to listOf("gun", "knife", "kill"),
            "He was playing with matches" to listOf("playing with matches"),
            "shooting stars and shooting" to listOf("shooting"),
        )
        for ((text, expected) in blocked) assertEquals(text, expected, Safety.findBlocked(text))
        val safe = listOf(
            "shell", "Hello", "class", "assume", "Shelley", "shell-shocked",
            "a shooting star", "SHOOTING STARS", "éhell", "hellé",
        )
        for (text in safe) assertTrue("'$text' should be safe", Safety.isSafe(text))
        assertEquals(Safety.SAFE_FALLBACK, Safety.filterReply("They wanted to kill the dragon."))
        assertEquals(Safety.SAFE_FALLBACK, Safety.filterReply(""))
        assertEquals("A friendly dragon waved.", Safety.filterReply("A friendly dragon waved."))
    }

    // ---- whole-word helper on Android's ICU regex ----

    @Test
    fun androidRejectsUnicodeCharacterClassButAcceptsUnicodeCase() {
        // The root cause of the #88 crash, pinned so a reintroduction is explained here.
        assertThrows(IllegalArgumentException::class.java) {
            Pattern.compile("\\bx\\b", Pattern.UNICODE_CHARACTER_CLASS)
        }
        // What wordPattern uses instead must compile and fold non-ASCII case on this runtime.
        val p = Pattern.compile("élan", Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE)
        assertTrue(p.matcher("ÉLAN").find())
    }

    @Test
    fun wordBoundaryHelperOnDevice() {
        assertTrue(containsWord("hell-bent", "hell"))
        assertTrue(containsWord("kill's", "kill"))
        assertTrue(containsWord("I'm done now", "i'm done"))
        assertTrue(containsWord("ÉLAN", "élan"))
        assertTrue(containsWord("«hell»", "hell"))
        for (text in listOf("shell", "Hello", "éhell", "hellé", "helĺ", "hell2", "_hell", "日hell")) {
            assertFalse("'$text' must not contain the word 'hell'", containsWord(text, "hell"))
        }
        assertFalse(containsWord("KNIFE", "knife", ignoreCase = false))
        assertFalse(containsWord("an xzy here", "x.y")) // quoted literally
        val m = wordPattern(listOf("ass", "asshole")).matcher("an asshole")
        assertTrue(m.find())
        assertEquals("asshole", m.group())
    }

    // ---- (b) AnimalFacts ----

    @Test
    fun animalFactsFindsAnimals() {
        assertEquals("fox", AnimalFacts.findNewAnimal("the fox ran", emptyList()))
        assertEquals("fox", AnimalFacts.findNewAnimal("A FOX hid", emptyList()))
        assertEquals("polar bear", AnimalFacts.findNewAnimal("a polar bear swam", emptyList()))
        assertNull(AnimalFacts.findNewAnimal("the foxglove bloomed", emptyList()))
        assertNull(AnimalFacts.findNewAnimal("Hello", emptyList()))
    }

    // ---- (c) StoryArc ----

    @Test
    fun storyArcPhraseMatching() {
        val stop = StoryArc(7).recordTurn("I'm done")
        assertTrue(stop, stop.startsWith("It's time to resolve the problem"))
        val notStop = StoryArc(7).recordTurn("the endless river")
        assertTrue(notStop, notStop.startsWith("You're at the very start"))

        val endless = StoryArc(7)
        endless.recordReply("They sailed down the endless river.")
        assertFalse(endless.isDone)
        val ended = StoryArc(7)
        ended.recordReply("And they all went home. The end.")
        assertTrue(ended.isDone)
    }

    // ---- (d) TranscriptCleaner ----

    @Test
    fun transcriptCleaner() {
        assertEquals("Yes", TranscriptCleaner.clean("Yes, yes"))
        assertEquals("Okay", TranscriptCleaner.clean("Okay. Okay."))
        assertEquals("", TranscriptCleaner.clean("[BLANK_AUDIO]"))
        assertEquals("", TranscriptCleaner.clean("[BLANK_AUD"))
        assertEquals("", TranscriptCleaner.clean("IO]"))
        assertEquals("hello", TranscriptCleaner.clean("hello [BLANK_AUD"))
        assertEquals("", TranscriptCleaner.clean("BLANK_AUDIO"))
        assertEquals("OK", TranscriptCleaner.clean("OK"))
        assertEquals("Hello there", TranscriptCleaner.clean("  Hello (music)  there "))
        assertEquals("Are you sure?", TranscriptCleaner.clean("Are you sure? Are you sure?"))
        // Same Unicode-whitespace handling as on the JVM (ICU's `\s` differs from OpenJDK's).
        assertEquals("Yes", TranscriptCleaner.clean("Yes, yes"))
        assertEquals("hello there friend", TranscriptCleaner.clean("hello there　friend"))
        assertEquals("Café", TranscriptCleaner.clean("Café café"))
    }

    // ---- facts cache (java.nio.file + kotlinx.serialization on this runtime) and WAV ----

    @Test
    fun animalFactsCacheRoundTripsOnDevice() {
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val file = File(dir, "smoke-cache-${System.nanoTime()}.json")
        try {
            val cache = AnimalFactsCache(file)
            assertEquals(emptyMap<String, List<String>>(), cache.load())
            cache.save(mapOf("fox" to listOf("it lives in forests", "it is quick")))
            cache.save(cache.load() + ("élan" to listOf("ünïcode")))
            assertEquals(
                mapOf("fox" to listOf("it lives in forests", "it is quick"), "élan" to listOf("ünïcode")),
                AnimalFactsCache(file).load(),
            )
        } finally {
            file.delete()
        }
    }

    @Test
    fun wavHeaderOnDevice() {
        val wav = wavFromPcm16(shortArrayOf(1, -2, 3), 16000)
        assertEquals(44 + 6, wav.size)
        assertEquals("RIFF", String(wav, 0, 4, Charsets.US_ASCII))
        assertEquals("WAVE", String(wav, 8, 4, Charsets.US_ASCII))
        assertEquals(1, wav[44].toInt())
        assertEquals(0, wav[45].toInt())
    }

    // ---- (e) DemoConversation ----

    @Test
    fun demoConversation() {
        val c = DemoConversation()
        c.addChild("  Hello ")
        c.addAgent("Hi there!", interrupted = true)
        assertEquals(
            listOf(
                ChatMessage("system", "sys"),
                ChatMessage("user", "Hello"),
                ChatMessage("assistant", "Hi there! ${DemoConversation.INTERRUPTED_MARKER}"),
            ),
            c.toMessages("sys"),
        )
    }

    // ---- (f) a full DemoSession turn ----

    private class FakeChat(private val reply: String) : ChatCompleting {
        override suspend fun complete(messages: List<ChatMessage>) = reply
    }

    private class FakeStt(private val text: String) : SpeechTranscribing {
        override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int) = text
    }

    private class FakeFetcher : AnimalFactFetching {
        override suspend fun fetchFacts(canonical: String): List<String>? = listOf("it lives in forests")
    }

    private fun session(reply: String, heard: String): DemoSession {
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val cache = AnimalFactsCache(File(dir, "smoke-facts-${System.nanoTime()}.json"))
        return DemoSession(FakeChat(reply), FakeStt(heard), AnimalFactTracker(FakeFetcher(), cache), scope)
    }

    private fun oneTurn(reply: String, heard: String): List<SessionEvent> = runBlocking {
        val s = session(reply, heard)
        try {
            s.submitUtterance(1, ShortArray(1600), 16000)
            withTimeout(10_000) { s.events.take(3).toList() }
        } finally {
            s.close()
            if (escaped.isNotEmpty()) throw AssertionError("a session coroutine threw", escaped.first())
        }
    }

    @Test
    fun fullTurnOnDevice() {
        val reply = "Once upon a time, a small fox found a red balloon. What happens next?"
        assertEquals(
            listOf(
                SessionEvent.TranscriptFinal("Hello", 1),
                SessionEvent.ResponseText(reply, 1),
                SessionEvent.TurnEnd(1),
            ),
            oneTurn(reply, "Hello"),
        )
    }

    @Test
    fun unsafeReplyReplacedOnDevice() {
        val events = oneTurn("Then the fox wanted to kill the dragon.", "Hello")
        assertEquals(SessionEvent.ResponseText(Safety.SAFE_FALLBACK, 1), events[1])
    }

    @Test
    fun anErrorInATurnIsTheRetryLineAndTheNextTurnWorksOnDevice() = runBlocking {
        var failure: Throwable? = ExceptionInInitializerError(IllegalArgumentException("x"))
        val chat = object : ChatCompleting {
            override suspend fun complete(messages: List<ChatMessage>): String {
                failure?.let { failure = null; throw it }
                return "A small fox waved."
            }
        }
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val cache = AnimalFactsCache(File(dir, "smoke-facts-${System.nanoTime()}.json"))
        val s = DemoSession(chat, FakeStt("Hello"), AnimalFactTracker(FakeFetcher(), cache), scope)
        try {
            s.submitUtterance(1, ShortArray(1600), 16000)
            val first = withTimeout(10_000) { s.events.take(2).toList() }
            assertEquals(SessionEvent.TranscriptFinal("Hello", 1), first[0])
            assertTrue(first[1].toString(), first[1] is SessionEvent.Error)
            s.submitUtterance(2, ShortArray(1600), 16000)
            val second = withTimeout(10_000) { s.events.take(3).toList() }
            assertEquals(SessionEvent.ResponseText("A small fox waved.", 2), second[1])
            assertEquals(SessionEvent.TurnEnd(2), second[2])
        } finally {
            s.close()
        }
        if (escaped.isNotEmpty()) throw AssertionError("a session coroutine threw", escaped.first())
    }
}
