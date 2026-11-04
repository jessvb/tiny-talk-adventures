package com.jessvb.tinytalk.core.session

import kotlinx.coroutines.flow.Flow

/** What the voice loop needs from a conversation session ([DemoSession] in the app; fakes in tests). */
interface TurnSession {
    val events: Flow<SessionEvent>
    fun submitUtterance(turnId: Int, pcm16: ShortArray, sampleRate: Int)
    fun bargeIn(turnId: Int)

    /** Ends the story under way now ("Finish this story"); sessions without stories ignore it. */
    fun concludeStory(turnId: Int) {}
}
