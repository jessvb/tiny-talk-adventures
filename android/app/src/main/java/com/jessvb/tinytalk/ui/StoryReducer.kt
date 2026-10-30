package com.jessvb.tinytalk.ui

import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.voice.LoopState

enum class LineSpeaker { CHILD, ELSIE }

data class TranscriptLine(val id: Long, val speaker: LineSpeaker, val text: String)

enum class BannerKind { KEY_MISSING, KEY_REJECTED, KEY_RATE_LIMITED, RETRY }

/** Why the selected listening mode cannot be used yet (on-phone listening only). */
enum class ListeningNotice { LOADING, FAILED }

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
    /** The selected listening mode cannot listen yet (still loading, or failed to load); null = fine. */
    val listeningNotice: ListeningNotice? = null,
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
    /** The selected speech recognition cannot be used yet (on-phone model loading or failed). */
    data class ListeningUnavailable(val notice: ListeningNotice) : StoryInput
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
    const val LISTENING_LOADING_MESSAGE =
        "Elsie is getting her ears ready on this phone. This takes a few seconds after the app opens, then she starts listening by herself."
    const val LISTENING_LOAD_FAILED_MESSAGE =
        "Elsie can't listen: listening on this phone could not start. Close the app completely and open it again. A grown-up can also turn on \"Better listening\" in Settings (it sends your child's voice to the cloud)."

    fun listeningMessage(notice: ListeningNotice): String = when (notice) {
        ListeningNotice.LOADING -> LISTENING_LOADING_MESSAGE
        ListeningNotice.FAILED -> LISTENING_LOAD_FAILED_MESSAGE
    }

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
        is StoryInput.ListeningUnavailable -> state.copy(listeningNotice = input.notice, loopState = LoopState.IDLE)
        StoryInput.ListeningReady -> state.copy(listeningNotice = null)
        StoryInput.ChatKeyMissing -> state.copy(banner = Banner(BannerKind.KEY_MISSING, KEY_NEEDED_MESSAGE, showSettings = true))
        StoryInput.ChatKeyPresent ->
            if (state.banner?.kind == BannerKind.KEY_MISSING) state.copy(banner = null) else state
    }

    /** Header/avatar caption (iOS StoryView.stateLabel). */
    fun stateLabel(state: StoryUiState): String = when {
        state.listeningNotice == ListeningNotice.LOADING -> "Elsie is getting ready"
        state.listeningNotice == ListeningNotice.FAILED -> "Elsie can't listen"
        state.micPermissionMissing || state.micUnavailable != null -> "Mic is off"
        else -> when (state.loopState) {
            LoopState.IDLE -> "Ready when you are"
            LoopState.LISTENING -> "Elsie is listening"
            LoopState.THINKING -> "Elsie is thinking…"
            LoopState.SPEAKING -> "Elsie is talking"
        }
    }

    /**
     * [stateLabel], but "Mic is off" when the parent/child muted the microphone with the mic
     * button ([muted]; the ViewModel calls this `listeningPaused`) and nothing worse is wrong.
     */
    fun displayLabel(state: StoryUiState, muted: Boolean): String =
        if (muted && !state.micPermissionMissing && state.micUnavailable == null && state.listeningNotice == null) "Mic is off"
        else stateLabel(state)

    /** TalkBack text for the mic button: the action it will perform. */
    fun micButtonDescription(muted: Boolean): String = if (muted) "Unmute microphone" else "Mute microphone"

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
