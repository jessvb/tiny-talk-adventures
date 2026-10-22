package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.settings.SttModeStore
import com.jessvb.tinytalk.core.voice.LoopState
import com.jessvb.tinytalk.ui.Screen
import com.jessvb.tinytalk.ui.StoryInput
import com.jessvb.tinytalk.ui.StoryReducer
import com.jessvb.tinytalk.ui.StoryUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the coordinator needs from the voice loop ([VoiceLoop] in the app; a fake in tests). */
interface LoopControl {
    fun start(): Boolean
    fun stop()
    /** True while the loop is running (listening, thinking or speaking). */
    val isActive: Boolean
}

/** Starts a fresh story in the conversation session (DemoSession.newStory). */
fun interface StoryResetter {
    fun newStory()
}

/**
 * Decides when the voice loop runs and turns its callbacks into Story-screen state. Pure
 * Kotlin (no Android types) so the ordering logic is JVM-tested with a test dispatcher.
 *
 * Threads:
 * - "Main" methods ([onNav], [setForeground], [retryMic], ...) must be called on the [main]
 *   scope's thread; they own [conditions] and the reducer state.
 * - Loop callbacks ([onLoopState], [onTranscript], ...) may come from any thread; each is
 *   re-posted with `main.launch` (the production [main] must be a DISPATCHING main scope, never
 *   Main.immediate) before touching state.
 * - One consumer on [worker] applies start/stop/new-story commands strictly in order, under
 *   [controlLock], so [clear] can never race a start: after [clear] no command runs and the
 *   loop is stopped.
 *
 * Story generations: [runGen] is bumped by the consumer after it stopped the loop for a new
 * story. Content callbacks capture it when they fire and are dropped on Main if a new story
 * began meanwhile, so nothing from an old story lands in the new transcript. Loop-state
 * callbacks are not gated (they always describe the one loop, in order).
 */
class LoopCoordinator(
    private val worker: CoroutineScope,
    private val main: CoroutineScope,
    private val loopProvider: suspend () -> LoopControl?,
    private val session: StoryResetter,
    private val modeStore: SttModeStore,
    private val listeningAvailable: (SttMode) -> Boolean,
    private val micPermission: () -> Boolean,
    private val consent: () -> Boolean,
) {
    private sealed interface Command {
        data class Apply(val run: Boolean) : Command
        data object NewStory : Command
    }

    private val commands = Channel<Command>(Channel.UNLIMITED)
    private val controlLock = Any()
    private var cleared = false // guarded by controlLock
    @Volatile private var loopRef: LoopControl? = null
    @Volatile private var runGen = 0

    private val _story = MutableStateFlow(StoryUiState())
    val story: StateFlow<StoryUiState> = _story.asStateFlow()

    private val _paused = MutableStateFlow(false)
    val paused: StateFlow<Boolean> = _paused.asStateFlow()

    /** The listening mode in force; read by the transcriber at the start of each utterance. */
    @Volatile var sttMode: SttMode = modeStore.mode
        private set

    // Main thread only.
    private var conditions = LoopConditions()
    private var commanded = false
    private var lastScreen: Screen? = null
    private var audioBroken = false

    init {
        worker.launch {
            val loop = loopProvider()
            if (loop == null) {
                main.launch {
                    audioBroken = true
                    conditions = conditions.copy(halted = true)
                    dispatch(StoryInput.MicUnavailable(AUDIO_SETUP_FAILED, canRetry = false))
                    reconcile()
                }
                return@launch
            }
            synchronized(controlLock) {
                if (cleared) return@launch
                loopRef = loop
            }
            for (cmd in commands) {
                synchronized(controlLock) {
                    if (cleared) return@launch
                    execute(loop, cmd)
                }
            }
        }
    }

    /** Worker thread, under [controlLock]. */
    private fun execute(loop: LoopControl, cmd: Command) {
        when (cmd) {
            is Command.Apply -> if (cmd.run) loop.start() else loop.stop()
            Command.NewStory -> {
                // Stop first so nothing of the old story is still spoken or in flight, then
                // start a new generation so late callbacks from the old story are dropped.
                val wasRunning = loop.isActive
                loop.stop()
                runGen++
                session.newStory()
                main.launch { dispatch(StoryInput.NewStory) }
                if (wasRunning) loop.start()
            }
        }
    }

    // ---- Main thread ----

    fun onNav(screen: Screen) {
        val onStory = screen == Screen.STORY
        // Back from Settings resumes the story; "Create a Story" from Landing starts a new one
        // (iOS #64: Home -> Create a Story must not resume the old session).
        if (onStory && lastScreen == Screen.LANDING) commands.trySend(Command.NewStory)
        lastScreen = screen
        if (onStory && !conditions.onStoryScreen) {
            // Entering the Story screen is a fresh attempt: clear a previous mic failure / pause.
            conditions = conditions.copy(paused = false)
            _paused.value = false
            clearHalt()
            refreshListeningAvailability()
            refreshPermission()
        }
        conditions = conditions.copy(onStoryScreen = onStory, consent = consent())
        reconcile()
    }

    /** Activity onStart / onStop (not for configuration changes). */
    fun setForeground(foreground: Boolean) {
        if (foreground == conditions.foreground) return
        if (foreground) {
            clearHalt()
            refreshPermission()
        }
        conditions = conditions.copy(foreground = foreground)
        reconcile()
    }

    fun onPermissionResult(granted: Boolean) {
        setPermission(granted)
        reconcile()
    }

    fun retryMic() {
        clearHalt()
        refreshPermission()
        reconcile()
    }

    fun setPaused(paused: Boolean) {
        _paused.value = paused
        conditions = conditions.copy(paused = paused)
        reconcile()
    }

    /** The UI transcript clears only once the consumer has stopped the old story's loop. */
    fun newStory() {
        commands.trySend(Command.NewStory)
    }

    /** Persists [mode] (the store commits synchronously) before anything can use it. */
    fun setSttMode(mode: SttMode) {
        modeStore.mode = mode
        sttMode = mode
        if (conditions.onStoryScreen) refreshListeningAvailability()
        reconcile()
    }

    /**
     * Consent withdrawn: stop listening and turn "better listening" off, so a later "I agree"
     * (whose text says the voice stays on this phone) is never followed by cloud audio.
     * The caller then sends the Navigator back to Onboarding.
     */
    fun revokeConsent() {
        conditions = conditions.copy(consent = false)
        reconcile()
        setSttMode(SttMode.ON_DEVICE)
    }

    /** Whether a Groq key (own or built-in) exists; shown up front, before the child speaks. */
    fun setChatKeyAvailable(available: Boolean) {
        dispatch(if (available) StoryInput.ChatKeyPresent else StoryInput.ChatKeyMissing)
    }

    /** ViewModel.onCleared: no command runs afterwards and the loop is stopped. */
    fun clear() {
        synchronized(controlLock) {
            cleared = true
            loopRef?.stop()
        }
        commands.cancel()
    }

    // ---- Loop callbacks (any thread) ----

    fun onLoopState(state: LoopState) {
        main.launch { dispatch(StoryInput.LoopStateChanged(state)) }
    }

    fun onTranscript(text: String) = postForThisStory(StoryInput.Transcript(text))
    fun onReply(text: String) = postForThisStory(StoryInput.Reply(text))
    fun onKeyProblem(kind: KeyProblemKind) = postForThisStory(StoryInput.KeyProblem(kind))
    fun onStoryFinished() = postForThisStory(StoryInput.StoryFinished)

    fun onLoopError(message: String) {
        val gen = runGen
        main.launch {
            when (message) {
                VoiceLoop.MIC_UNAVAILABLE_MESSAGE, VoiceLoop.LISTENING_FAILED_MESSAGE -> {
                    // The loop already stopped itself; keep it stopped until Retry.
                    conditions = conditions.copy(halted = true)
                    dispatch(StoryInput.MicUnavailable(message))
                    reconcile()
                }
                VoiceLoop.NO_CONSENT_MESSAGE -> {
                    conditions = conditions.copy(consent = consent())
                    reconcile()
                }
                else -> if (gen == runGen) dispatch(StoryInput.Error(message))
            }
        }
    }

    // ---- internals (Main) ----

    private fun postForThisStory(input: StoryInput) {
        val gen = runGen
        main.launch { if (gen == runGen) dispatch(input) }
    }

    /** Allows another start after a mic failure, unless the audio parts never built. */
    private fun clearHalt() {
        if (audioBroken) {
            dispatch(StoryInput.MicUnavailable(AUDIO_SETUP_FAILED, canRetry = false))
            return
        }
        conditions = conditions.copy(halted = false)
        dispatch(StoryInput.MicRetry)
    }

    private fun refreshPermission() = setPermission(micPermission())

    private fun setPermission(granted: Boolean) {
        conditions = conditions.copy(micPermission = granted)
        dispatch(if (granted) StoryInput.PermissionGranted else StoryInput.PermissionMissing)
    }

    private fun refreshListeningAvailability() {
        val ok = listeningAvailable(sttMode)
        conditions = conditions.copy(listeningAvailable = ok)
        dispatch(if (ok) StoryInput.ListeningReady else StoryInput.ListeningNotInstalled)
    }

    private fun reconcile() {
        val want = conditions.shouldRun
        if (want == commanded) return
        commanded = want
        commands.trySend(Command.Apply(want))
    }

    private fun dispatch(input: StoryInput) {
        _story.update { StoryReducer.reduce(it, input) }
    }

    companion object {
        const val AUDIO_SETUP_FAILED =
            "Elsie's ears and voice could not start on this phone. Close the app completely and open it again."
    }
}
