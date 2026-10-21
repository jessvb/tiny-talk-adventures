package com.jessvb.tinytalk.core.voice

/**
 * Short lines Elsie says herself when she cannot answer, so the child never meets a silent
 * dead screen. The parent-facing detail goes to a banner, not to the child.
 */
object SpokenLines {
    /** Groq key missing, rejected or rate-limited: ask for a grown-up (spec, key problems). */
    const val KEY_PROBLEM = "Hmm, I can't think right now. Could you ask a grown-up to help me?"

    /** Any other failure (offline, 5xx, timeout): a gentle retry. */
    const val TRY_AGAIN = "Oops, my thinking slipped. Let's try that again in a moment!"
}
