package com.jessvb.tinytalk.core

import java.util.regex.Pattern

/**
 * Kotlin port of ios/TinyTalkCore/.../Safety.swift (itself a port of
 * server/tinytalk/safety.py). Zero-latency denylist, not semantic moderation.
 * Word lists are copied verbatim from the Swift source; do not edit them here
 * without changing the iOS/server originals.
 */
object Safety {
    const val SAFE_FALLBACK = "Hmm, let's take the story somewhere else! What should happen next?"

    private val violence = listOf(
        "blood", "gun", "guns", "knife", "knives", "kill", "kills", "killed", "killing",
        "dead", "die", "dies", "died", "fight", "fights", "fighting",
        "hurt", "hurts", "hurting", "stab", "stabbed", "stabbing",
        "shoot", "shoots", "shooting",
    )

    private val frightening = listOf(
        "monster attacking", "terrifying", "nightmare", "screamed in terror",
        "trapped forever", "pure evil", "demon", "demons",
    )

    private val adultThemes = listOf("drunk", "alcohol", "cigarette", "naked")

    private val realWorldDanger = listOf(
        "play with matches", "playing with matches", "played with matches",
        "play with a lighter", "playing with a lighter", "played with a lighter",
        "poison", "drown", "drowned", "drowning", "jump off a cliff",
    )

    private val reproduction = listOf(
        "mating", "breeding", "pregnant", "pregnancy", "reproduce", "reproduces",
        "reproducing", "reproduction", "sex", "sexual", "porn", "porno",
        "pornography", "pornographic", "nude", "nudity", "erotic",
        "masturbate", "masturbation", "orgasm",
    )

    private val profanity = listOf(
        "damn", "hell", "shit", "fuck", "ass", "asshole", "bitch", "crap",
        "bastard", "piss", "dick", "whore", "slut",
    )

    private val allBlocked =
        violence + frightening + adultThemes + realWorldDanger + reproduction + profanity

    // Deliberately does NOT include "kiss" -- see safety.py's own comment.
    private val safePhrases = listOf("shooting star", "shooting stars")

    // UNICODE_CHARACTER_CLASS makes \b Unicode-aware, matching ICU (NSRegularExpression).
    private const val FLAGS =
        Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE or Pattern.UNICODE_CHARACTER_CLASS

    private fun wholeWord(terms: List<String>): Pattern =
        Pattern.compile("\\b(?:${terms.joinToString("|") { Pattern.quote(it) }})\\b", FLAGS)

    private val blockedPattern = wholeWord(allBlocked)
    private val safePattern = wholeWord(safePhrases)

    /**
     * Every distinct blocked word/phrase matched in [text], lowercased, in the
     * order each first appears. The safe-phrase mask runs first.
     */
    fun findBlocked(text: String): List<String> {
        val masked = safePattern.matcher(text).replaceAll("")
        val found = LinkedHashSet<String>()
        val m = blockedPattern.matcher(masked)
        while (m.find()) found.add(m.group().lowercase())
        return found.toList()
    }

    fun isSafe(text: String): Boolean = findBlocked(text).isEmpty()

    fun filterReply(text: String): String =
        if (text.isNotEmpty() && isSafe(text)) text else SAFE_FALLBACK
}
