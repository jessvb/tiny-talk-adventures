package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.ConversationTurn
import com.jessvb.tinytalk.core.Speaker
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.ChatMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors ios StorybookWriterTests (itself mirroring server/tests/test_storybook.py). */
class StorybookWriterTest {
    /** Replies in order, repeating the last one; records every message list it was given. */
    private class ScriptedChat(vararg replies: String) : ChatCompleting {
        private val script = replies.toList()
        val received = mutableListOf<List<ChatMessage>>()
        var error: Throwable? = null
        val callCount get() = received.size
        override suspend fun complete(messages: List<ChatMessage>): String {
            received += messages.toList()
            error?.let { throw it }
            return script[minOf(received.size - 1, script.size - 1)]
        }
    }

    private val turns = listOf(
        ConversationTurn(Speaker.CHILD, "tell me about a fox"),
        ConversationTurn(Speaker.AGENT, "Once there was a clever fox."),
    )

    private fun json(
        title: String = "A Story",
        pages: List<String> = listOf("Once upon a time."),
        epilogue: String? = null,
    ): String {
        val o = buildMap<String, kotlinx.serialization.json.JsonElement> {
            put("title", JsonPrimitive(title))
            put("pages", JsonArray(pages.map { JsonObject(mapOf("text" to JsonPrimitive(it))) }))
            if (epilogue != null) put("epilogue", JsonPrimitive(epilogue))
        }
        return JsonObject(o).toString()
    }

    private suspend fun write(
        chat: ScriptedChat,
        facts: List<Pair<String, String>> = emptyList(),
        pageCount: Int = 5,
        maxAttempts: Int = StorybookWriter.DEFAULT_MAX_ATTEMPTS,
    ) = StorybookWriter(chat, maxAttempts).write(turns, facts, pageCount)

    // ---- result shape

    @Test fun `parses a valid rewrite and grounds the epilogue in the real fact`() = runTest {
        val chat = ScriptedChat(json(title = "The Clever Fox", pages = listOf("Page one.", "Page two.")))
        val r = write(chat, facts = listOf("fox" to "foxes have excellent hearing"))!!
        assertEquals("The Clever Fox", r.title)
        assertEquals(listOf("Page one.", "Page two."), r.pages)
        assertEquals("And one true thing we learned about the fox: foxes have excellent hearing", r.epilogue)
    }

    @Test fun `tolerates prose wrapped around the JSON`() = runTest {
        val chat = ScriptedChat("Sure! Here you go:\n" + json(title = "Wrapped") + "\nHope that helps.")
        assertEquals("Wrapped", write(chat)?.title)
    }

    @Test fun `omits the epilogue when no facts were shared`() = runTest {
        assertNull(write(ScriptedChat(json()))!!.epilogue)
    }

    @Test fun `discards a fabricated epilogue when no facts were shared`() = runTest {
        assertNull(write(ScriptedChat(json(epilogue = "Foxes live forever.")))!!.epilogue)
    }

    @Test fun `ignores the models own epilogue even when facts were shared`() = runTest {
        val chat = ScriptedChat(json(epilogue = "Something the model made up."))
        val r = write(chat, facts = listOf("fox" to "foxes have excellent hearing"))!!
        assertEquals("And one true thing we learned about the fox: foxes have excellent hearing", r.epilogue)
    }

    @Test fun `uses the first shared fact only`() = runTest {
        val r = write(ScriptedChat(json()), facts = listOf("fox" to "first fact", "owl" to "second fact"))!!
        assertEquals("And one true thing we learned about the fox: first fact", r.epilogue)
    }

    // ---- prompt shape

    @Test fun `prompt carries the transcript, page count and kid-safety framing`() = runTest {
        val chat = ScriptedChat(json())
        write(chat, pageCount = 3)
        val messages = chat.received[0]
        assertEquals("system", messages[0].role)
        assertTrue(messages[0].content.contains("Keep everything gentle and wholesome"))
        // The live-dialogue rules must not leak into a one-shot rewrite.
        assertFalse(messages[0].content.contains("asking the child what should happen next"))
        val user = messages[1].content
        assertTrue(user.contains("Child: tell me about a fox"))
        assertTrue(user.contains("Storyteller: Once there was a clever fox."))
        assertTrue(user.contains("exactly 3 pages"))
    }

    @Test fun `facts appear in the prompt and add the epilogue key only when present`() = runTest {
        val withFacts = ScriptedChat(json())
        write(withFacts, facts = listOf("fox" to "foxes have excellent hearing"))
        val p = withFacts.received[0][1].content
        assertTrue(p.contains("Real facts this story actually used: fox: foxes have excellent hearing."))
        assertTrue(p.contains("\"epilogue\": \"one true, real fact from the story, in one sentence\""))

        val without = ScriptedChat(json())
        write(without)
        val q = without.received[0][1].content
        assertFalse(q.contains("Real facts this story actually used"))
        assertFalse(q.contains("\"epilogue\""))
    }

    // ---- failure handling

    @Test fun `returns null on unparseable output after every attempt`() = runTest {
        val chat = ScriptedChat("this is not json at all")
        assertNull(write(chat))
        assertEquals(StorybookWriter.DEFAULT_MAX_ATTEMPTS, chat.callCount)
    }

    @Test fun `returns null when the chat client throws`() = runTest {
        val chat = ScriptedChat(json()).apply { error = IllegalStateException("boom") }
        assertNull(write(chat))
    }

    @Test fun `cancellation still propagates`() = runTest {
        val chat = ScriptedChat(json()).apply { error = CancellationException("cancelled") }
        var cancelled = false
        try { write(chat) } catch (e: CancellationException) { cancelled = true }
        assertTrue(cancelled)
    }

    @Test fun `retries and succeeds once a later attempt parses`() = runTest {
        val chat = ScriptedChat("this is not json at all", json(title = "A Story"))
        assertEquals("A Story", write(chat)?.title)
        assertEquals(2, chat.callCount)
    }

    @Test fun `parse retry asks for valid JSON again`() = runTest {
        val chat = ScriptedChat("this is not json at all", json())
        write(chat)
        assertTrue(chat.received[1].last().content.lowercase().contains("valid json"))
        // the bad reply is shown back to the model
        assertTrue(chat.received[1].any { it.role == "assistant" && it.content == "this is not json at all" })
    }

    @Test fun `an empty title or no pages is treated as unparseable`() = runTest {
        assertNull(write(ScriptedChat(json(title = "  "))))
        assertNull(write(ScriptedChat(json(pages = emptyList()))))
    }

    // ---- kid-safety retry

    @Test fun `retries and saves once a later attempt is safe`() = runTest {
        val chat = ScriptedChat(json(title = "The Knife Fight"), json(title = "The Big Adventure"))
        assertEquals("The Big Adventure", write(chat)?.title)
        assertEquals(2, chat.callCount)
    }

    @Test fun `safety retry tells the model what to avoid`() = runTest {
        val chat = ScriptedChat(json(title = "The Knife Fight"), json(title = "A Story"))
        write(chat)
        assertTrue(chat.received[1].last().content.lowercase().contains("knife"))
    }

    @Test fun `gives up after the configured number of safety attempts`() = runTest {
        val chat = ScriptedChat(json(title = "The Knife Fight"))
        assertNull(write(chat))
        assertEquals(StorybookWriter.DEFAULT_MAX_ATTEMPTS, chat.callCount)
    }

    @Test fun `an unsafe page fails the storybook`() = runTest {
        assertNull(write(ScriptedChat(json(pages = listOf("The knight had to kill the dragon.")))))
    }

    @Test fun `an unsafe grounded epilogue fails the storybook`() = runTest {
        // The epilogue comes from the real shared fact, so an unsafe FACT must be caught even
        // though the model's own text is spotless.
        assertNull(write(ScriptedChat(json()), facts = listOf("shark" to "sharks can kill")))
    }

    @Test fun `parse failures and safety hits share one attempt budget`() = runTest {
        val chat = ScriptedChat("not json", json(title = "The Knife Fight"), "not json again")
        assertNull(write(chat))
        assertEquals(3, chat.callCount)
    }

    @Test fun `max attempts is honoured`() = runTest {
        val chat = ScriptedChat("not json")
        write(chat, maxAttempts = 1)
        assertEquals(1, chat.callCount)
    }
}
