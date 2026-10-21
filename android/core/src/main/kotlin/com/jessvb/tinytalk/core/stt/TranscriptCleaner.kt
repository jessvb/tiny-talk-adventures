package com.jessvb.tinytalk.core.stt

/**
 * Tidies speech-recognition output. Whisper tiny.en returns empty or doubled text
 * for short replies ("Yes, yes", "Okay. Okay.", "[BLANK_AUDIO]").
 *
 * Rules:
 * 1. Bracketed/parenthesized groups ("[BLANK_AUDIO]", "(music)", "[Music]") are
 *    non-speech annotations and are dropped.
 * 2. Whitespace is trimmed and collapsed; text with no letter/digit becomes "".
 * 3. If the ENTIRE text is one word-group repeated back to back (>= 2 times,
 *    compared case-insensitively, ignoring punctuation), it collapses to one copy.
 *    The survivor is the FIRST occurrence exactly as written, minus trailing
 *    `, ; : .` (so "Okay. Okay." -> "Okay"), but a trailing `?` or `!` is kept
 *    ("Are you sure? Are you sure?" -> "Are you sure?").
 *    Partial or non-immediate repetition is untouched ("No no no, stop").
 *    Accepted trade-off: emphasis like "no no no" ALONE collapses to "no".
 */
object TranscriptCleaner {
    private val annotation = Regex("""\[[^\]]*]|\([^)]*\)""")
    private val whitespace = Regex("""\s+""")

    fun clean(raw: String): String {
        val text = raw.replace(annotation, " ").replace(whitespace, " ").trim()
        if (!text.codePoints().anyMatch { Character.isLetterOrDigit(it) }) return ""

        val tokens = text.split(' ')
        val norm = tokens.map { t ->
            buildString { t.codePoints().forEach { if (Character.isLetterOrDigit(it)) appendCodePoint(Character.toLowerCase(it)) } }
        }
        val n = tokens.size
        for (p in 1..n / 2) {
            if (n % p != 0) continue
            if ((p until n).all { norm[it] == norm[it - p] } && norm.take(p).any { it.isNotEmpty() }) {
                return tokens.take(p).joinToString(" ").trimEnd(',', ';', ':', '.', ' ')
            }
        }
        return text
    }
}
