package com.jessvb.tinytalk.core.session

enum class KeyProblemKind { MISSING, REJECTED, RATE_LIMITED }

/** Events a [DemoSession] emits; names mirror the iOS wire events (Protocol.swift). */
sealed interface SessionEvent {
    data class TranscriptFinal(val text: String, val turnId: Int) : SessionEvent
    data class ResponseText(val text: String, val turnId: Int) : SessionEvent
    data class TurnEnd(val turnId: Int) : SessionEvent
    data class Error(val message: String, val turnId: Int) : SessionEvent
    data class KeyProblem(val kind: KeyProblemKind, val turnId: Int) : SessionEvent
    data object StoryFinished : SessionEvent
}
