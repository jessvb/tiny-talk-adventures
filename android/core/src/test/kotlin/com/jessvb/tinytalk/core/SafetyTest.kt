package com.jessvb.tinytalk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafetyTest {
    @Test
    fun findsBlockedWord() {
        assertEquals(listOf("knife"), Safety.findBlocked("The knife was sharp"))
    }

    @Test
    fun caseInsensitiveWholeWord() {
        assertEquals(listOf("knife"), Safety.findBlocked("KNIFE"))
        for (safe in listOf("class", "assume", "Hello", "shell", "shell-shocked", "Shelley")) {
            assertTrue("'$safe' should be safe", Safety.isSafe(safe))
        }
    }

    @Test
    fun hyphenAndApostropheAreWordBoundaries() {
        // Same as NSRegularExpression: '-' and '\'' are non-word characters.
        assertEquals(listOf("hell"), Safety.findBlocked("hell-bent"))
        assertEquals(listOf("kill"), Safety.findBlocked("kill's"))
    }

    @Test
    fun accentedLettersAreWordCharacters() {
        // Same as NSRegularExpression: an adjacent letter, accented or not, prevents a match.
        for (safe in listOf("éhell", "hellé", "Hellö", "hell\u0301")) {
            assertTrue("'$safe' should be safe", Safety.isSafe(safe))
        }
        assertEquals(listOf("hell"), Safety.findBlocked("é hell"))
    }

    @Test
    fun longerTermReportedWhenShorterFailsBoundary() {
        assertEquals(listOf("asshole"), Safety.findBlocked("what an asshole"))
        assertEquals(listOf("killing"), Safety.findBlocked("killing"))
    }

    @Test
    fun multipleHitsLowercasedDistinctInOrder() {
        assertEquals(
            listOf("gun", "knife", "kill"),
            Safety.findBlocked("A GUN, a Knife, another gun, then KILL and knife"),
        )
    }

    @Test
    fun multiWordPhrasesMatch() {
        assertEquals(listOf("pure evil"), Safety.findBlocked("It was Pure  Evil".replace("  ", " ")))
        assertEquals(listOf("playing with matches"), Safety.findBlocked("He was playing with matches"))
    }

    @Test
    fun safePhrasesMaskedFirst() {
        assertTrue(Safety.isSafe("a shooting star"))
        assertTrue(Safety.isSafe("SHOOTING STARS"))
        assertEquals(listOf("shooting"), Safety.findBlocked("shooting"))
        assertEquals(listOf("shooting"), Safety.findBlocked("shooting stars and shooting"))
    }

    @Test
    fun filterReplyFallsBack() {
        val fallback = "Hmm, let's take the story somewhere else! What should happen next?"
        assertEquals(fallback, Safety.SAFE_FALLBACK)
        assertEquals(fallback, Safety.filterReply(""))
        assertEquals(fallback, Safety.filterReply("kill"))
        assertEquals("A friendly dragon waved.", Safety.filterReply("A friendly dragon waved."))
    }

    @Test
    fun everyCategoryHasBlockedRepresentative() {
        val reps = mapOf(
            "violence" to "blood",
            "violence-last" to "shooting",
            "frightening" to "nightmare",
            "frightening-phrase" to "monster attacking",
            "adultThemes" to "naked",
            "realWorldDanger" to "poison",
            "realWorldDanger-phrase" to "jump off a cliff",
            "reproduction" to "pregnant",
            "profanity" to "damn",
        )
        for ((cat, word) in reps) {
            assertFalse("$cat: '$word' should be blocked", Safety.isSafe("the $word here"))
            assertEquals(listOf(word), Safety.findBlocked("the $word here"))
        }
    }
}
