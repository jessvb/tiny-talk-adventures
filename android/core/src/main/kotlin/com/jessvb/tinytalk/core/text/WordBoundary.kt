package com.jessvb.tinytalk.core.text

import java.util.regex.Pattern

/**
 * Whole-word matching that behaves the same on OpenJDK (unit tests) and on Android's
 * ICU-based java.util.regex (the phone), and like iOS's NSRegularExpression `\b`.
 *
 * Why not `\b`: what `\b` treats as a word character depends on the runtime and on flags.
 * OpenJDK needs `Pattern.UNICODE_CHARACTER_CLASS` to make it Unicode-aware, and Android
 * REJECTS that flag at compile time ("UNICODE_CHARACTER_CLASS flag not supported"), which
 * crashed the app on the first turn (issue #88). So the boundary is spelled out with
 * lookarounds over an explicit, flag-independent word-character class instead.
 *
 * Word character = letter, combining mark, number or underscore (`[\p{L}\p{M}\p{N}_]`), so
 * accented letters ("é") are letters, while apostrophes, hyphens, spaces and other
 * punctuation are not ("hell-bent" contains "hell"; "shell" and "Hello" do not; "kill's"
 * contains "kill").
 *
 * `(?<!W)(?:TERMS)(?!W)` equals `\b(?:TERMS)\b` whenever every term starts and ends with a
 * word character (then `\b` before the term can only mean "the previous character is not
 * a word character", and likewise after it), which [wordPattern] enforces.
 */
private const val WORD_CHAR = "[\\p{L}\\p{M}\\p{N}_]"

private val wordCharPattern: Pattern = Pattern.compile(WORD_CHAR)

private fun isWordChar(cp: Int): Boolean = wordCharPattern.matcher(String(Character.toChars(cp))).matches()

/**
 * One pattern matching any of [terms] as a whole word or phrase. Terms are quoted
 * (regex-literal) and tried in the given ORDER at each position, so the first listed term
 * wins a tie (callers rely on this, e.g. "asshole" listed after "ass" still reports
 * "asshole" because "ass" fails its trailing boundary there).
 *
 * [ignoreCase] uses CASE_INSENSITIVE | UNICODE_CASE, both supported on Android and OpenJDK.
 */
fun wordPattern(terms: Collection<String>, ignoreCase: Boolean = true): Pattern {
    require(terms.isNotEmpty()) { "no terms" }
    for (t in terms) {
        require(t.isNotEmpty() && isWordChar(t.codePointAt(0)) && isWordChar(t.codePointBefore(t.length))) {
            "term must start and end with a word character: \"$t\""
        }
    }
    val alternation = terms.joinToString("|") { Pattern.quote(it) }
    val flags = if (ignoreCase) Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE else 0
    return Pattern.compile("(?<!$WORD_CHAR)(?:$alternation)(?!$WORD_CHAR)", flags)
}

/** True if [text] contains [phrase] as a whole word or phrase (see [wordPattern]). */
fun containsWord(text: String, phrase: String, ignoreCase: Boolean = true): Boolean =
    wordPattern(listOf(phrase), ignoreCase).matcher(text).find()
