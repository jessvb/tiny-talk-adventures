package com.jessvb.tinytalk.voice

/**
 * When the voice loop may run: on the Story screen, app in the foreground, consent given,
 * RECORD_AUDIO granted, a usable transcriber for the current listening mode, not halted by a
 * mic failure (cleared by Retry or by re-entering the Story screen). [paused] (the mic button)
 * does NOT stop the loop: it only closes the microphone, so a turn in flight finishes.
 */
data class LoopConditions(
    val onStoryScreen: Boolean = false,
    val foreground: Boolean = false,
    val consent: Boolean = false,
    val micPermission: Boolean = false,
    val listeningAvailable: Boolean = false,
    val halted: Boolean = false,
    val paused: Boolean = false,
) {
    val shouldRun: Boolean
        get() = onStoryScreen && foreground && consent && micPermission && listeningAvailable &&
            !halted
}
