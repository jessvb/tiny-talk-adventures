package com.jessvb.tinytalk

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jessvb.tinytalk.core.audio.SpeechDetector
import com.jessvb.tinytalk.core.chat.GroqChatClient
import com.jessvb.tinytalk.core.facts.AnimalFactTracker
import com.jessvb.tinytalk.core.facts.AnimalFactsApiClient
import com.jessvb.tinytalk.core.facts.AnimalFactsCache
import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.keys.KeyStore
import com.jessvb.tinytalk.core.session.DemoSession
import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.voice.LoopState
import com.jessvb.tinytalk.keys.AppKeys
import com.jessvb.tinytalk.keys.KeyStatus
import com.jessvb.tinytalk.keys.Secrets
import com.jessvb.tinytalk.keys.SecretsStore
import com.jessvb.tinytalk.keys.SettingsStores
import com.jessvb.tinytalk.spike.MicCapture
import com.jessvb.tinytalk.spike.SentenceTts
import com.jessvb.tinytalk.spike.SileroVad
import com.jessvb.tinytalk.ui.NavState
import com.jessvb.tinytalk.ui.Navigator
import com.jessvb.tinytalk.ui.Screen
import com.jessvb.tinytalk.ui.SharedPrefsConsentStore
import com.jessvb.tinytalk.ui.StoryInput
import com.jessvb.tinytalk.ui.StoryReducer
import com.jessvb.tinytalk.ui.StoryUiState
import com.jessvb.tinytalk.voice.AppTranscriberFactory
import com.jessvb.tinytalk.voice.LoopConditions
import com.jessvb.tinytalk.voice.ModeSwitchingTranscriber
import com.jessvb.tinytalk.voice.TranscriberFactory
import com.jessvb.tinytalk.voice.VoiceLoop
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import java.io.File

/** Everything the Settings screen shows. Key values are never exposed, only their status. */
data class SettingsUiState(
    val keyStatus: Map<KeyName, KeyStatus> = emptyMap(),
    val sttMode: SttMode = SttMode.ON_DEVICE,
    val voices: List<SentenceTts.VoiceOption> = emptyList(),
    val voicesLoading: Boolean = true,
    val voiceName: String? = null,
)

/**
 * The app container. Lives above the activity (survives rotation / font-scale / dark-mode
 * recreation), so the Navigator, DemoSession, the one warm SentenceTts, SileroVad and the
 * VoiceLoop are created once and never restarted by an activity recreation.
 *
 * Threads:
 * - Main: Navigator, [story]/[settings] state, [conditions]. Every VoiceLoop callback is
 *   re-posted to Main with a dispatching (never immediate) launch before it touches state.
 * - [workScope] (Dispatchers.Default, child of viewModelScope): DemoSession turns, the
 *   VoiceLoop's collector/poller, the audio warm-up, and the one [commands] consumer that
 *   calls VoiceLoop.start/stop sequentially off the main thread (start opens the mic; stop
 *   joins the capture thread).
 * - Dispatchers.IO: key reads/writes (Keystore) and TTS voice listing (binder).
 *
 * Lifecycle rule: the loop runs exactly while [LoopConditions.shouldRun] holds: on STORY, app
 * in the foreground (MainActivity onStart/onStop, ignoring configuration changes), consent,
 * mic permission, a usable transcriber, not halted by a mic failure, not paused.
 */
class TinyTalkViewModel(app: Application) : AndroidViewModel(app) {
    private val consentStore = SharedPrefsConsentStore(app)
    val navigator = Navigator(consentStore)

    private val keys: KeyStore = SecretsStore(app)
    private val prefs = SettingsStores(app)
    private val groq = AppKeys.resolver(KeyName.GROQ, keys)
    private val apiNinjas = AppKeys.resolver(KeyName.API_NINJAS, keys)

    // The transcriber seam (Task 4b-B plugs OnDeviceTranscriber into AppTranscriberFactory).
    private val transcriberFactory: TranscriberFactory = AppTranscriberFactory(groqKey = { groq.current() })
    @Volatile private var sttMode: SttMode = prefs.mode
    private val transcriber = ModeSwitchingTranscriber({ sttMode }, transcriberFactory)

    private val workScope = CoroutineScope(
        SupervisorJob(viewModelScope.coroutineContext.job) + Dispatchers.Default,
    )

    private val session = DemoSession(
        chat = GroqChatClient(apiKey = { groq.current() }),
        stt = transcriber,
        facts = AnimalFactTracker(
            AnimalFactsApiClient(apiKey = { apiNinjas.current() }),
            AnimalFactsCache(File(app.filesDir, "animal_facts.json")),
        ),
        scope = workScope,
    )

    private class Audio(val tts: SentenceTts, val vad: SileroVad, val loop: VoiceLoop)

    /** Built once on a background thread at app start: TTS engine warm-up takes ~5 s. */
    private val audio: Deferred<Audio> = workScope.async {
        val tts = SentenceTts(app, ::log)
        prefs.voiceName?.let { tts.setVoice(it) }
        val vad = SileroVad(app)
        val loop = VoiceLoop(
            micFactory = { onFrame, onStopped -> MicCapture(onFrame, ::log, onStopped) },
            vad = vad,
            detector = SpeechDetector(),
            session = session,
            tts = tts,
            scope = workScope,
            consentGiven = { consentStore.accepted },
            onState = { s -> onMain { dispatch(StoryInput.LoopStateChanged(s)) } },
            onKeyProblem = { k -> onMain { dispatch(StoryInput.KeyProblem(k)) } },
            onError = { m -> onMain { onLoopError(m) } },
            onTranscript = { t -> onMain { dispatch(StoryInput.Transcript(t)) } },
            onReply = { t -> onMain { dispatch(StoryInput.Reply(t)) } },
            onStoryFinished = { onMain { dispatch(StoryInput.StoryFinished) } },
            onLog = ::log,
        )
        Audio(tts, vad, loop)
    }

    private sealed interface Command {
        data class Apply(val run: Boolean) : Command
        data object NewStory : Command
    }

    /** Start/stop requests, applied in order by one consumer on [workScope]. */
    private val commands = Channel<Command>(Channel.UNLIMITED)

    private val _story = MutableStateFlow(StoryUiState())
    val story: StateFlow<StoryUiState> = _story.asStateFlow()

    private val _paused = MutableStateFlow(false)
    val listeningPaused: StateFlow<Boolean> = _paused.asStateFlow()

    private val _settings = MutableStateFlow(SettingsUiState(sttMode = sttMode, voiceName = prefs.voiceName))
    val settings: StateFlow<SettingsUiState> = _settings.asStateFlow()

    // Main thread only.
    private var conditions = LoopConditions()
    private var commanded = false

    init {
        workScope.launch {
            val loop = audio.await().loop
            for (cmd in commands) {
                when (cmd) {
                    is Command.Apply -> if (cmd.run) loop.start() else loop.stop()
                    Command.NewStory -> {
                        // Stop first so nothing of the old story is still spoken or in flight.
                        val wasRunning = loop.state != LoopState.IDLE
                        loop.stop()
                        session.newStory()
                        if (wasRunning) loop.start()
                    }
                }
            }
        }
        viewModelScope.launch { navigator.state.collect(::onNav) }
    }

    // ---- Navigation and lifecycle (main thread) ----

    private fun onNav(nav: NavState) {
        val onStory = nav.screen == Screen.STORY
        if (onStory && !conditions.onStoryScreen) {
            // Entering the Story screen is a fresh attempt: clear a previous mic failure / pause.
            conditions = conditions.copy(halted = false, paused = false)
            _paused.value = false
            dispatch(StoryInput.MicRetry)
            refreshListeningAvailability()
            refreshPermission()
        }
        conditions = conditions.copy(onStoryScreen = onStory, consent = consentStore.accepted)
        reconcile()
    }

    /** MainActivity.onStart / onStop (not called for configuration changes). */
    fun setForeground(foreground: Boolean) {
        if (foreground == conditions.foreground) return
        if (foreground) {
            conditions = conditions.copy(halted = false)
            refreshPermission()
        }
        conditions = conditions.copy(foreground = foreground)
        reconcile()
    }

    fun onPermissionResult(granted: Boolean) {
        setPermission(granted)
        reconcile()
    }

    private fun refreshPermission() {
        val granted = getApplication<Application>()
            .checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        setPermission(granted)
    }

    private fun setPermission(granted: Boolean) {
        conditions = conditions.copy(micPermission = granted)
        dispatch(if (granted) StoryInput.PermissionGranted else StoryInput.PermissionMissing)
    }

    private fun refreshListeningAvailability() {
        val ok = transcriberFactory.isAvailable(sttMode)
        conditions = conditions.copy(listeningAvailable = ok)
        dispatch(if (ok) StoryInput.ListeningReady else StoryInput.ListeningNotInstalled)
    }

    private fun reconcile() {
        val want = conditions.shouldRun
        if (want == commanded) return
        commanded = want
        commands.trySend(Command.Apply(want))
    }

    private fun onLoopError(message: String) {
        when (message) {
            VoiceLoop.MIC_UNAVAILABLE_MESSAGE, VoiceLoop.LISTENING_FAILED_MESSAGE -> {
                // The loop already stopped itself; keep it stopped until Retry.
                conditions = conditions.copy(halted = true)
                dispatch(StoryInput.MicUnavailable(message))
                reconcile()
            }
            VoiceLoop.NO_CONSENT_MESSAGE -> {
                conditions = conditions.copy(consent = consentStore.accepted)
                reconcile()
            }
            else -> dispatch(StoryInput.Error(message))
        }
    }

    // ---- Story screen actions (main thread) ----

    fun retryMic() {
        conditions = conditions.copy(halted = false)
        dispatch(StoryInput.MicRetry)
        refreshPermission()
        reconcile()
    }

    fun setListeningPaused(paused: Boolean) {
        _paused.value = paused
        conditions = conditions.copy(paused = paused)
        reconcile()
    }

    fun newStory() {
        dispatch(StoryInput.NewStory)
        commands.trySend(Command.NewStory)
    }

    // ---- Settings actions ----

    fun refreshSettings() {
        viewModelScope.launch(Dispatchers.IO) {
            val status = KeyName.entries.associateWith { KeyStatus.of(keys.get(it), Secrets.baked(it)) }
            _settings.update { it.copy(keyStatus = status, sttMode = sttMode, voiceName = prefs.voiceName) }
            val tts = audio.await().tts
            var voices = tts.englishVoices()
            var tries = 0
            while (voices.isEmpty() && tries++ < VOICE_LIST_RETRIES) { // engine may still be warming up
                delay(500)
                voices = tts.englishVoices()
            }
            _settings.update { it.copy(voices = voices, voicesLoading = false) }
        }
    }

    /** Stores a parent-entered key (blank clears it, falling back to the built-in key). */
    fun saveKey(name: KeyName, value: String?) {
        viewModelScope.launch(Dispatchers.IO) {
            keys.set(name, value)
            val status = KeyStatus.of(keys.get(name), Secrets.baked(name))
            _settings.update { it.copy(keyStatus = it.keyStatus + (name to status)) }
        }
    }

    /**
     * Only call after the parent confirmed the in-context disclosure: from now on the child's
     * voice is sent to the cloud for transcription.
     */
    fun enableCloudListening() = setSttMode(SttMode.CLOUD)

    fun useOnDeviceListening() = setSttMode(SttMode.ON_DEVICE)

    private fun setSttMode(mode: SttMode) {
        prefs.mode = mode // committed before anything can use it
        sttMode = mode
        _settings.update { it.copy(sttMode = mode) }
        if (conditions.onStoryScreen) {
            refreshListeningAvailability()
            reconcile()
        }
    }

    fun setVoice(name: String?) {
        prefs.voiceName = name
        _settings.update { it.copy(voiceName = name) }
        workScope.launch { audio.await().tts.setVoice(name) }
    }

    /** Parent withdrew consent: stop listening, forget consent, back to Onboarding. */
    fun revokeConsent() {
        conditions = conditions.copy(consent = false)
        reconcile()
        navigator.revokeConsent() // onNav re-reads consent (false) and keeps the loop stopped
    }

    // ---- plumbing ----

    private fun dispatch(input: StoryInput) {
        _story.update { StoryReducer.reduce(it, input) }
    }

    /** Always a real dispatch to Main (never inline on the calling VoiceLoop thread). */
    private fun onMain(block: () -> Unit) {
        viewModelScope.launch(Dispatchers.Main) { block() }
    }

    private fun log(msg: String) {
        Log.i(TAG, msg)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCleared() {
        commands.close()
        session.close()
        if (audio.isCompleted && !audio.isCancelled) {
            val a = audio.getCompleted()
            a.loop.stop()
            a.tts.close()
            a.vad.close()
        }
        transcriber.close()
        workScope.coroutineContext.job.cancel()
    }

    private companion object {
        const val TAG = "TinyTalk"
        const val VOICE_LIST_RETRIES = 16
    }
}
