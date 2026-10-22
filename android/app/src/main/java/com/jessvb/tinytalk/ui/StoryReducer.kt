package com.jessvb.tinytalk.ui

import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.voice.LoopState

enum class LineSpeaker { CHILD, ELSIE }

data class TranscriptLine(val id: Long, val speaker: LineSpeaker, val text: String)

enum class BannerKind { KEY_MISSING, KEY_REJECTED, KEY_RATE_LIMITED, RETRY }

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
    /** False when retrying cannot help (the audio parts never built): no "Try again" button. */
    val micUnavailableRetryable: Boolean = true,
    /** The selected listening mode has nothing to listen with in this build (Task 4b-B pending). */
    val listeningNotInstalled: Boolean = false,
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
    data class MicUnavailable(val message: String, val canRetry: Boolean = true) : StoryInput
    data object MicRetry : StoryInput
    data object PermissionMissing : StoryInput
    data object PermissionGranted : StoryInput
    data object StoryFinished : StoryInput
    /** The selected speech recognition is not available in this build (Task 4b-B pending). */
    data object ListeningNotInstalled : StoryInput
    data object ListeningReady : StoryInput
    /** Neither an own nor a built-in Groq key exists: Elsie cannot think at all. */
    data object ChatKeyMissing : StoryInput
    data object ChatKeyPresent : StoryInput
}

/** Pure Story-screen state transitions (JVM-tested; no Android imports). */
object StoryReducer {
    const val KEY_MISSING_MESSAGE =
        "Elsie can't think right now — a grown-up can add a key in Settings."
    const val KEY_REJECTED_MESSAGE =
        "Elsie's key wasn't accepted — a grown-up can check or replace the key in Settings."
    const val KEY_RATE_LIMITED_MESSAGE =
        "Elsie has done a lot of thinking and needs a rest. This may pass in a little while, or a grown-up can add a key in Settings."
    const val KEY_NEEDED_MESSAGE =
        "Elsie needs a key to think — a grown-up can add one in Settings."
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
        is StoryInput.MicUnavailable -> state.copy(
            micUnavailable = input.message,
            micUnavailableRetryable = input.canRetry,
            loopState = LoopState.IDLE,
        )
        StoryInput.MicRetry -> state.copy(micUnavailable = null, micUnavailableRetryable = true)
        StoryInput.PermissionMissing -> state.copy(micPermissionMissing = true, loopState = LoopState.IDLE)
        StoryInput.PermissionGranted -> state.copy(micPermissionMissing = false)
        // A StoryFinished on an empty transcript belongs to a story that was already replaced.
        StoryInput.StoryFinished -> if (state.lines.isEmpty()) state else state.copy(storyFinished = true)
        StoryInput.ListeningNotInstalled -> state.copy(listeningNotInstalled = true, loopState = LoopState.IDLE)
        StoryInput.ListeningReady -> state.copy(listeningNotInstalled = false)
        StoryInput.ChatKeyMissing -> state.copy(banner = Banner(BannerKind.KEY_MISSING, KEY_NEEDED_MESSAGE, showSettings = true))
        StoryInput.ChatKeyPresent ->
            if (state.banner?.kind == BannerKind.KEY_MISSING) state.copy(banner = null) else state
    }

    /** Header/avatar caption (iOS StoryView.stateLabel). */
    fun stateLabel(state: StoryUiState): String = when {
        state.listeningNotInstalled -> "Elsie can't listen yet"
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

    /** A successful turn proves the key works and the cloud answered: clear any banner. */
    private fun StoryUiState.clearTurnBanner() = if (banner != null) copy(banner = null) else this
}
