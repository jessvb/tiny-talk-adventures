package com.jessvb.tinytalk.core.session

import com.jessvb.tinytalk.core.storybook.FinishedStory

enum class KeyProblemKind { MISSING, REJECTED, RATE_LIMITED }

/** Events a [DemoSession] emits; names mirror the iOS wire events (Protocol.swift). */
sealed interface SessionEvent {
    data class TranscriptFinal(val text: String, val turnId: Int) : SessionEvent
    data class ResponseText(val text: String, val turnId: Int) : SessionEvent
    data class TurnEnd(val turnId: Int) : SessionEvent
    data class Error(val message: String, val turnId: Int) : SessionEvent
    data class KeyProblem(val kind: KeyProblemKind, val turnId: Int) : SessionEvent
    /** The story ended; [story] is that story's own transcript and shared facts (for the library). */
    data class StoryFinished(val story: FinishedStory) : SessionEvent
}
