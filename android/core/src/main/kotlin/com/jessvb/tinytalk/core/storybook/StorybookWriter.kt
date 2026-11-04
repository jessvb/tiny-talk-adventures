package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.ConversationTurn
import com.jessvb.tinytalk.core.Safety
import com.jessvb.tinytalk.core.Speaker
import com.jessvb.tinytalk.core.chat.ChatCompleting
import com.jessvb.tinytalk.core.chat.ChatMessage
import com.jessvb.tinytalk.core.rethrowIfFatal
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A finished storybook rewrite. [epilogue] is derived from a real shared fact, never model-written. */
data class WrittenStorybook(val title: String, val pages: List<String>, val epilogue: String?)

/**
 * Kotlin port of StorybookWriter.swift (itself a port of server/tinytalk/storybook.py's rewrite
 * pass): turns a finished story's transcript into a title, prose pages and an optional
 * fact-grounded epilogue using the phone's chat client. Same prompts, same tolerant JSON
 * extraction, and ONE attempt budget shared by its two retryable failures (an unparseable
 * reply, a kid-safety flag).
 */
class StorybookWriter(
    private val chat: ChatCompleting,
    maxAttempts: Int = DEFAULT_MAX_ATTEMPTS,
) {
    private val maxAttempts = maxOf(1, maxAttempts)

    /**
     * Null means "failed": the reply never parsed, or stayed unsafe, after every attempt, or the
     * chat call itself threw. The caller keeps the raw transcript either way.
     */
    suspend fun write(
        turns: List<ConversationTurn>,
        sharedFacts: List<Pair<String, String>>,
        pageCount: Int,
    ): WrittenStorybook? {
        // The epilogue is always a real fact the story shared, never something the model
        // invents: the model's own "epilogue" text is ignored.
        val epilogue = epilogue(sharedFacts)
        val messages = mutableListOf(
            ChatMessage("system", SYSTEM_PROMPT),
            ChatMessage("user", buildPrompt(turns, sharedFacts, pageCount)),
        )
        for (attempt in 1..maxAttempts) {
            val raw = try {
                chat.complete(messages.toList()).trim()
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                t.rethrowIfFatal()
                return null
            }

            val parsed = parse(raw)
            if (parsed == null) {
                if (attempt < maxAttempts) {
                    messages += ChatMessage("assistant", raw)
                    messages += ChatMessage("user", PARSE_RETRY_PROMPT)
                    continue
                }
                return null
            }

            val blocked = (listOf(parsed.first) + parsed.second + listOfNotNull(epilogue))
                .flatMap { Safety.findBlocked(it) }
                .distinct()
                .sorted()
            if (blocked.isEmpty()) return WrittenStorybook(parsed.first, parsed.second, epilogue)
            if (attempt < maxAttempts) {
                messages += ChatMessage("assistant", raw)
                messages += ChatMessage("user", safetyRetryPrompt(blocked.joinToString(", ")))
            }
        }
        return null
    }

    companion object {
        /** Mirrors config.STORYBOOK_REWRITE_RETRY_ATTEMPTS. */
        const val DEFAULT_MAX_ATTEMPTS = 3

        internal const val SYSTEM_PROMPT =
            "You are writing a children's picture-book story for a young child, " +
                "aged about three to six, to read or be read to again later.\n" +
                "\n" +
                "Rules you always follow:\n" +
                "- Keep everything gentle and wholesome. No violence, no weapons, no death, " +
                "no frightening peril.\n" +
                "- Keep the story grounded in the real world: no magic, no talking " +
                "plants or objects, no impossible physics. Animal characters can " +
                "talk and think like people, but everything else about the world " +
                "should be realistic.\n" +
                "- Write plain prose only: no emoji, no asterisks, no stage directions."

        internal const val PARSE_RETRY_PROMPT =
            "That wasn't valid JSON. Reply again with ONLY the JSON object, in the " +
                "exact same shape as before -- no other text before or after it."

        internal fun safetyRetryPrompt(terms: String) =
            "That version isn't appropriate for a young child's storybook -- it " +
                "mentioned: $terms. Rewrite the whole story again from scratch, same " +
                "characters and events, but leave out any mention of that. Reply with " +
                "ONLY the JSON object again, in the same shape as before."

        /** The one place the epilogue wording lives; null when no fact was shared. */
        fun epilogue(sharedFacts: List<Pair<String, String>>): String? =
            sharedFacts.firstOrNull()?.let { (animal, fact) -> "And one true thing we learned about the $animal: $fact" }

        internal fun buildPrompt(
            turns: List<ConversationTurn>,
            facts: List<Pair<String, String>>,
            pageCount: Int,
        ): String {
            val transcript = turns.joinToString("\n") { turn ->
                val speaker = if (turn.speaker == Speaker.CHILD) "Child" else "Storyteller"
                "$speaker: ${turn.text}"
            }
            var factsSection = ""
            var epilogueKey = ""
            if (facts.isNotEmpty()) {
                val factsList = facts.joinToString("; ") { "${it.first}: ${it.second}" }
                factsSection = "Real facts this story actually used: $factsList. If natural, " +
                    "close with one of these as a one-sentence epilogue, phrased for " +
                    "a young child.\n\n"
                epilogueKey = ", \"epilogue\": \"one true, real fact from the story, in one sentence\""
            }
            return "You are turning a story a child and a storyteller made up together " +
                "into a picture-book version for the child to read again later.\n\n" +
                "Here is the full conversation, in order:\n$transcript\n\n" +
                factsSection +
                "Rewrite this as a children's storybook: continuous third-person " +
                "narration that captures the same characters, events, and facts -- " +
                "NOT a dialogue transcript, and don't write \"the child said\" or " +
                "\"the storyteller said\" anywhere. Split it into exactly $pageCount " +
                "pages. Reply with ONLY a JSON object, no other text, in this exact " +
                "shape:\n" +
                "{\"title\": \"...\", \"pages\": [{\"text\": \"...\"}, ...]" + epilogueKey + "}"
        }

        /**
         * Extracts (title, pages) from the model's raw reply, tolerant of prose around the JSON
         * object (a small model does not reliably follow "reply with ONLY json"). Null if nothing
         * usable is found. Deliberately ignores any "epilogue" the model returned.
         */
        internal fun parse(raw: String): Pair<String, List<String>>? {
            val start = raw.indexOf('{')
            val end = raw.lastIndexOf('}')
            if (start < 0 || end <= start) return null
            val obj = try {
                Json.parseToJsonElement(raw.substring(start, end + 1)) as? JsonObject
            } catch (e: Exception) {
                null
            } ?: return null
            val title = (obj["title"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
            if (title.isNullOrEmpty()) return null
            val rawPages = obj["pages"] as? JsonArray ?: return null
            if (rawPages.isEmpty()) return null
            val pages = rawPages.map { entry ->
                val text = ((entry as? JsonObject)?.get("text") as? JsonPrimitive)?.takeIf { it.isString }
                    ?: return null
                text.content.trim()
            }
            return title to pages
        }
    }
}
