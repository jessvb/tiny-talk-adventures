package com.jessvb.tinytalk.core.text

import java.util.regex.Pattern
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WordBoundaryTest {
    private fun allMatches(p: Pattern, text: String): List<Pair<Int, String>> {
        val m = p.matcher(text)
        val out = mutableListOf<Pair<Int, String>>()
        while (m.find()) out.add(m.start() to m.group())
        return out
    }

    @Test fun hyphenApostropheSpaceArePunctuationNotWordChars() {
        assertTrue(containsWord("hell-bent", "hell"))
        assertTrue(containsWord("kill's", "kill"))
        assertTrue(containsWord("I'm done now", "i'm done"))
        assertTrue(containsWord("well, that's enough!", "that's enough"))
        assertFalse(containsWord("shell", "hell"))
        assertFalse(containsWord("Hello", "hell"))
        assertFalse(containsWord("the endless river", "the end"))
    }

    @Test fun lettersMarksDigitsUnderscoreAreWordChars() {
        assertFalse(containsWord("éhell", "hell"))
        assertFalse(containsWord("hellé", "hell"))
        assertFalse(containsWord("helĺ", "hell")) // combining acute accent
        assertFalse(containsWord("hell2", "hell"))
        assertFalse(containsWord("_hell", "hell"))
        assertFalse(containsWord("日hell", "hell"))
        assertTrue(containsWord("é hell é", "hell"))
        assertTrue(containsWord("«hell»", "hell"))
    }

    @Test fun caseHandling() {
        assertTrue(containsWord("KNIFE", "knife"))
        assertTrue(containsWord("ÉLAN", "élan")) // non-ASCII case folding (UNICODE_CASE)
        assertFalse(containsWord("KNIFE", "knife", ignoreCase = false))
        assertTrue(containsWord("knife", "knife", ignoreCase = false))
    }

    @Test fun termsAreQuotedLiterally() {
        assertTrue(containsWord("an x.y here", "x.y"))
        assertFalse(containsWord("an xzy here", "x.y"))
    }

    @Test fun alternationOrderDecidesTies() {
        val p = wordPattern(listOf("ass", "asshole", "shooting", "shooting star"))
        assertEquals(listOf(3 to "asshole"), allMatches(p, "an asshole"))
        // First listed alternative that fits wins, exactly like \b(?:...)\b.
        assertEquals(listOf(2 to "shooting"), allMatches(p, "a shooting star"))
    }

    @Test fun rejectsTermsThatWouldChangeBoundaryMeaning() {
        assertThrows(IllegalArgumentException::class.java) { wordPattern(emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { wordPattern(listOf("")) }
        assertThrows(IllegalArgumentException::class.java) { wordPattern(listOf("-x")) }
        assertThrows(IllegalArgumentException::class.java) { wordPattern(listOf("x'")) }
    }

    /**
     * Differential check against the OLD construction (`\b` + UNICODE_CHARACTER_CLASS, which
     * OpenJDK supports but Android does not): identical matches (positions and text) on a
     * randomized corpus mixing term fragments, accented letters, combining marks, digits,
     * underscores, hyphens, apostrophes and spaces.
     */
    @Test fun sameMatchesAsOldUnicodeWordBoundaryOnOpenJdk() {
        val terms = listOf("ass", "asshole", "hell", "kill", "killing", "shooting star", "i'm done", "x-ray tetra", "élan")
        val old = Pattern.compile(
            "\\b(?:${terms.joinToString("|") { Pattern.quote(it) }})\\b",
            Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE or Pattern.UNICODE_CHARACTER_CLASS,
        )
        val new = wordPattern(terms)
        val pieces = listOf(
            "ass", "hole", "hell", "kill", "ing", "shooting", " star", "i'm", " done", "x-ray", " tetra",
            "élan", "ÉLAN", "é", "é", "́", "2", "_", "-", "'", " ", ".", "s", "H", "日",
        )
        val rnd = Random(88)
        repeat(20_000) {
            val text = buildString { repeat(rnd.nextInt(1, 7)) { append(pieces[rnd.nextInt(pieces.size)]) } }
            assertEquals("text=\"$text\"", allMatches(old, text), allMatches(new, text))
        }
    }
}
