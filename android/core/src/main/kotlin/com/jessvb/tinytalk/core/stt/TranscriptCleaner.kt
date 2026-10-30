package com.jessvb.tinytalk.core.stt

/**
 * Tidies speech-recognition output. Whisper tiny.en returns empty or doubled text
 * for short replies ("Yes, yes", "Okay. Okay.", "[BLANK_AUDIO]").
 *
 * Rules:
 * 1. Bracketed/parenthesized groups ("[BLANK_AUDIO]", "(music)", "[Music]") are
 *    non-speech annotations and are dropped.
 *    A truncated marker ("[BLANK_AUD", "IO]", "(silence") is not speech either: any
 *    whitespace-delimited token still holding a bracket or parenthesis is dropped, as is a
 *    bare marker like BLANK_AUDIO (capital words joined by underscores; "OK"/"USA" stay).
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
    // Not plain `\s`: OpenJDK's `\s` is ASCII-only, Android's (ICU) is all Unicode White_Space,
    // so a no-break space would collapse on the phone but not in JVM tests (#88). This class is
    // exactly Unicode White_Space on both runtimes.
    private val whitespace = Regex("""[\s\p{Z}\u0085]+""")

    // Bare markers Whisper sometimes emits without brackets: BLANK_AUDIO, MUSIC_PLAYING.
    // Needs an underscore, so ordinary shouted words (NO, OK, USA) are kept.
    private val bareMarker = Regex("""[A-Z]+(_[A-Z]+)+""")

    private fun isNonSpeechToken(t: String): Boolean =
        t.any { it == '[' || it == ']' || it == '(' || it == ')' } || bareMarker.matches(t)

    fun clean(raw: String): String {
        val text = raw.replace(annotation, " ").replace(whitespace, " ").trim()
            .split(' ').filterNot { isNonSpeechToken(it) }.joinToString(" ")
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
