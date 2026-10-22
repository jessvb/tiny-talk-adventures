package com.jessvb.tinytalk.ui

import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.voice.LoopState

enum class LineSpeaker { CHILD, ELSIE }

data class TranscriptLine(val id: Long, val speaker: LineSpeaker, val text: String)

enum class BannerKind { KEY_MISSING, KEY_REJECTED, KEY_RATE_LIMITED, RETRY, LISTENING_NOT_INSTALLED }

/** A parent-facing notice above the transcript. [showSettings] adds a Settings button. */
data class Banner(val kind: BannerKind, val message: String, val showSettings: Boolean)

data class StoryUiState(
    val loopState: LoopState = LoopState.IDLE,
    val lines: List<TranscriptLine> = emptyList(),
    val banner: Banner? = null,
    /** RECORD_AUDIO not granted: show "Allow microphone". */
    val micPermissionMissing: Boolean = false,
    /** The mic failed or the loop halted itself; the message is shown with a Retry button. */
    val micUnavailable: String? = null,
    /** The arc finished: show "The end!" until the child starts talking again. */
    val storyFinished: Boolean = false,
    val nextLineId: Long = 0,
)

/** Everything that can change the Story screen. VoiceLoop callbacks are mapped onto these. */
sealed interface StoryInput {
    data class LoopStateChanged(val state: LoopState) : StoryInput
    data class Transcript(val text: String) : StoryInput
    data class Reply(val text: String) : StoryInput
    data class KeyProblem(val kind: KeyProblemKind) : StoryInput
    data class Error(val message: String) : StoryInput
    /** A turn completed successfully. */
    data object TurnEnd : StoryInput
    data object NewStory : StoryInput
    data class MicUnavailable(val message: String) : StoryInput
    data object MicRetry : StoryInput
    data object PermissionMissing : StoryInput
    data object PermissionGranted : StoryInput
    data object StoryFinished : StoryInput
    /** The selected speech recognition is not available in this build (Task 4b-B pending). */
    data object ListeningNotInstalled : StoryInput
    data object ListeningReady : StoryInput
}

/** Pure Story-screen state transitions (JVM-tested; no Android imports). */
object StoryReducer {
    const val KEY_MISSING_MESSAGE =
        "Elsie can't think right now — a grown-up can add a key in Settings."
    const val KEY_REJECTED_MESSAGE =
        "Elsie's key wasn't accepted — a grown-up can check or replace the key in Settings."
    const val KEY_RATE_LIMITED_MESSAGE =
        "Elsie has done a lot of thinking and needs a rest. This may pass in a little while, or a grown-up can add a key in Settings."
    const val LISTENING_NOT_INSTALLED_MESSAGE =
        "Elsie can't listen yet: listening on this phone isn't installed in this version of the app. A grown-up can turn on \"Better listening\" in Settings (it sends your child's voice to the cloud)."

    fun reduce(state: StoryUiState, input: StoryInput): StoryUiState = when (input) {
        is StoryInput.LoopStateChanged -> state.copy(
            loopState = input.state,
            // The loop running again proves the mic works; IDLE alone proves nothing (halts report it).
            micUnavailable = if (input.state == LoopState.IDLE) state.micUnavailable else null,
        )
        is StoryInput.Transcript ->
            if (input.text.isBlank()) state
            else state.append(LineSpeaker.CHILD, input.text).copy(storyFinished = false)
        is StoryInput.Reply -> state.append(LineSpeaker.ELSIE, input.text).clearTurnBanner()
        is StoryInput.KeyProblem -> state.copy(banner = keyBanner(input.kind))
        is StoryInput.Error -> state.copy(banner = Banner(BannerKind.RETRY, input.message, showSettings = false))
        StoryInput.TurnEnd -> state.clearTurnBanner()
        StoryInput.NewStory -> state.copy(lines = emptyList(), storyFinished = false)
        is StoryInput.MicUnavailable -> state.copy(micUnavailable = input.message, loopState = LoopState.IDLE)
        StoryInput.MicRetry -> state.copy(micUnavailable = null)
        StoryInput.PermissionMissing -> state.copy(micPermissionMissing = true, loopState = LoopState.IDLE)
        StoryInput.PermissionGranted -> state.copy(micPermissionMissing = false)
        StoryInput.StoryFinished -> state.copy(storyFinished = true)
        StoryInput.ListeningNotInstalled -> state.copy(
            banner = Banner(BannerKind.LISTENING_NOT_INSTALLED, LISTENING_NOT_INSTALLED_MESSAGE, showSettings = true),
        )
        StoryInput.ListeningReady ->
            if (state.banner?.kind == BannerKind.LISTENING_NOT_INSTALLED) state.copy(banner = null) else state
    }

    /** Header/avatar caption (iOS StoryView.stateLabel). */
    fun stateLabel(state: StoryUiState): String = when {
        state.micPermissionMissing || state.micUnavailable != null -> "Mic is off"
        else -> when (state.loopState) {
            LoopState.IDLE -> "Ready when you are"
            LoopState.LISTENING -> "Elsie is listening"
            LoopState.THINKING -> "Elsie is thinking…"
            LoopState.SPEAKING -> "Elsie is talking"
        }
    }

    private fun keyBanner(kind: KeyProblemKind) = when (kind) {
        KeyProblemKind.MISSING -> Banner(BannerKind.KEY_MISSING, KEY_MISSING_MESSAGE, showSettings = true)
        KeyProblemKind.REJECTED -> Banner(BannerKind.KEY_REJECTED, KEY_REJECTED_MESSAGE, showSettings = true)
        KeyProblemKind.RATE_LIMITED -> Banner(BannerKind.KEY_RATE_LIMITED, KEY_RATE_LIMITED_MESSAGE, showSettings = true)
    }

    private fun StoryUiState.append(speaker: LineSpeaker, text: String) = copy(
        lines = lines + TranscriptLine(nextLineId, speaker, text),
        nextLineId = nextLineId + 1,
    )

    /** A successful turn clears key/retry banners, not the listening-not-installed one. */
    private fun StoryUiState.clearTurnBanner() =
        if (banner != null && banner.kind != BannerKind.LISTENING_NOT_INSTALLED) copy(banner = null) else this
}
