package com.jessvb.tinytalk.core.stt

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptCleanerTest {
    private val cases = listOf(
        // collapse: whole text is one unit repeated
        "Yes, yes" to "Yes",
        "Okay. Okay." to "Okay",
        "Yes yes yes" to "Yes",
        "The fox ran. The fox ran." to "The fox ran",
        "no no no" to "no",
        "Are you sure? Are you sure?" to "Are you sure?",
        "Wow! wow!" to "Wow!",
        "Café café" to "Café",
        "  Yes,   YES  " to "Yes",
        // Unicode spaces (no-break, thin, ideographic) are whitespace on JVM and Android alike
        "Yes, yes" to "Yes",
        "hello there　friend" to "hello there friend",
        // not collapsed
        "I said yes, yes, I did" to "I said yes, yes, I did",
        "No no no, stop" to "No no no, stop",
        "Yes. No. Yes." to "Yes. No. Yes.",
        "The fox ran. The fox ran away." to "The fox ran. The fox ran away.",
        // normal text
        "The fox ran home." to "The fox ran home.",
        "Okay." to "Okay.",
        "  hello   there \n friend " to "hello there friend",
        // empty / punctuation / non-speech
        "" to "",
        "   " to "",
        "." to "",
        "..." to "",
        "?!" to "",
        "[BLANK_AUDIO]" to "",
        "[Music]" to "",
        "(silence)" to "",
        "[MUSIC] (music) ." to "",
        "[BLANK_AUDIO] yes" to "yes",
        "(music) hello" to "hello",
        "hello [BLANK_AUDIO] world" to "hello world",
        "😀" to "",
        "7" to "7",
    )

    @Test fun exactCases() {
        for ((input, expected) in cases) {
            assertEquals("clean(\"$input\")", expected, TranscriptCleaner.clean(input))
        }
    }

    @Test fun idempotent() {
        for ((input, _) in cases) {
            val once = TranscriptCleaner.clean(input)
            assertEquals("idempotence for \"$input\"", once, TranscriptCleaner.clean(once))
        }
    }
}
