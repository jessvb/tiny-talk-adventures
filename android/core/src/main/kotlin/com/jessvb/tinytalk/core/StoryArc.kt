package com.jessvb.tinytalk.core

import kotlin.math.roundToInt

enum class StoryStage { INTRO, SETUP, RISING_ACTION, CLIMAX, RESOLUTION, DONE }

/**
 * Kotlin port of StoryArc.swift (itself a port of server/tinytalk/story_arc.py).
 * Deliberately deterministic (regex + turn counting). Thread-safe.
 */
class StoryArc(private val targetTurns: Int = 7) {
    private val graceCeiling = targetTurns + 3
    private val lock = Any()
    private var turnCount = 0
    private var done = false

    val stage: StoryStage
        get() = synchronized(lock) { if (done) StoryStage.DONE else stageForTurn(turnCount) }

    val isDone: Boolean
        get() = synchronized(lock) { done }

    /** True once the first turn has been recorded. */
    val hasStarted: Boolean
        get() = synchronized(lock) { turnCount > 0 }

    private fun stageForTurn(turn: Int): StoryStage {
        if (turn <= 1) return StoryStage.INTRO
        // roundToInt is half-up; identical to Swift's half-away-from-zero for positives.
        val setupEnd = (targetTurns.toDouble() / 4).roundToInt()
        val risingEnd = (targetTurns.toDouble() * 2 / 3).roundToInt()
        if (turn <= setupEnd) return StoryStage.SETUP
        if (turn <= risingEnd) return StoryStage.RISING_ACTION
        if (turn <= targetTurns) return StoryStage.CLIMAX
        return StoryStage.RESOLUTION
    }

    fun recordTurn(childText: String): String = synchronized(lock) {
        turnCount += 1
        if (turnCount > graceCeiling) return FORCED_GUIDANCE
        if (matches(childText, CHILD_STOP_PHRASES)) return GUIDANCE.getValue(StoryStage.RESOLUTION)
        GUIDANCE.getValue(stageForTurn(turnCount))
    }

    fun recordReply(replyText: String) = synchronized(lock) {
        if (turnCount > graceCeiling) {
            done = true
        } else if (matches(replyText, CONCLUSION_PHRASES)) {
            done = true
        }
    }

    /** Guidance for an explicitly-requested conclusion; does NOT touch turnCount. */
    fun forceConcludeGuidance(): String = FORCED_GUIDANCE

    fun markDone() = synchronized(lock) { done = true }

    private companion object {
        const val FORCED_GUIDANCE =
            "This must be the last reply. Resolve the problem from earlier in " +
                "the story and bring it to a warm, complete ending right now. Do not " +
                "ask what should happen next. The story is over. End your reply " +
                "with the words \"The end.\""

        val GUIDANCE: Map<StoryStage, String> = mapOf(
            StoryStage.INTRO to
                "You're at the very start of the story. Introduce the setting and characters.",
            StoryStage.SETUP to
                "You're at the start of the story. Continue introducing the setting " +
                "and characters, and introduce a problem, challenge, or conflict for " +
                "them to face. Every good story needs something for the " +
                "characters to overcome -- don't wait to introduce it.",
            StoryStage.RISING_ACTION to
                "The story is building. Keep developing the problem or " +
                "challenge from the start of the story, raise the stakes a " +
                "little, and let the child's ideas shape what happens next.",
            StoryStage.CLIMAX to
                "The story is nearing its big moment. Build toward an exciting " +
                "(but still gentle) turning point where the problem or challenge " +
                "comes to a head.",
            StoryStage.RESOLUTION to
                "It's time to resolve the problem from earlier in the story and " +
                "wrap up the story warmly and happily in this reply or the next " +
                "one. If you conclude it now, do not ask what should happen " +
                "next. Instead, end your reply with the words \"The end.\"",
        )

        val CHILD_STOP_PHRASES = listOf(
            "the end", "i'm done", "im done", "stop the story",
            "that's enough", "thats enough", "no more story", "i want to stop",
        )

        val CONCLUSION_PHRASES = listOf(
            "the end", "happily ever after", "lived happily", "the story is over",
        )

        fun matches(text: String, phrases: List<String>): Boolean {
            val lower = text.lowercase()
            return phrases.any { Regex("\\b" + Regex.escape(it) + "\\b").containsMatchIn(lower) }
        }
    }
}
