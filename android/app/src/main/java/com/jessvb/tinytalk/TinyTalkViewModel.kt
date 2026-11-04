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
import com.jessvb.tinytalk.core.rethrowIfFatal
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
import com.jessvb.tinytalk.stt.OnDeviceTranscriber
import com.jessvb.tinytalk.ui.Navigator
import com.jessvb.tinytalk.ui.Screen
import com.jessvb.tinytalk.ui.SharedPrefsConsentStore
import com.jessvb.tinytalk.ui.StoryUiState
import com.jessvb.tinytalk.voice.AppTranscriberFactory
import com.jessvb.tinytalk.voice.DittyPlayer
import com.jessvb.tinytalk.voice.LoopControl
import com.jessvb.tinytalk.voice.LoopCoordinator
import com.jessvb.tinytalk.voice.ModeSwitchingTranscriber
import com.jessvb.tinytalk.voice.TranscriberFactory
import com.jessvb.tinytalk.voice.VoiceLoop
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Everything the Settings screen shows. Key values are never exposed, only their status. */
data class SettingsUiState(
    val keyStatus: Map<KeyName, KeyStatus> = emptyMap(),
    /** Whether this build has a built-in value for each key (drives truthful wording). */
    val bakedPresent: Map<KeyName, Boolean> = emptyMap(),
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
 * A thin wrapper: when the loop runs, and how its callbacks become Story state, lives in the
 * pure, JVM-tested [LoopCoordinator]. Threads:
 * - Main: Navigator, [LoopCoordinator] main methods, settings state.
 * - [workScope] (Dispatchers.Default, child of viewModelScope): DemoSession turns, the
 *   VoiceLoop's collector/poller, the audio build, and the coordinator's command consumer
 *   (start/stop off the main thread, in order).
 * - [mainScope]: a DISPATCHING Main scope the coordinator posts loop callbacks to.
 * - Dispatchers.IO: key reads/writes (Keystore) and TTS voice listing (binder).
 */
class TinyTalkViewModel(app: Application) : AndroidViewModel(app) {
    private val consentStore = SharedPrefsConsentStore(app)
    val navigator = Navigator(consentStore)

    private val keys: KeyStore = SecretsStore(app)
    private val prefs = SettingsStores(app)
    private val groq = AppKeys.resolver(KeyName.GROQ, keys)
    private val apiNinjas = AppKeys.resolver(KeyName.API_NINJAS, keys)

    private val workScope = CoroutineScope(SupervisorJob(viewModelScope.coroutineContext.job) + Dispatchers.Default)
    private val mainScope = CoroutineScope(SupervisorJob(viewModelScope.coroutineContext.job) + Dispatchers.Main)

    /** The one warm on-phone recogniser; its model loads in the background at start (init). */
    private val onDevice = OnDeviceTranscriber(app)

    // The transcriber seam: ON_DEVICE -> [onDevice] (available once loaded), CLOUD -> Groq.
    private val transcriberFactory: TranscriberFactory =
        AppTranscriberFactory(groqKey = { groq.current() }, onDevice = onDevice)

    private class Audio(val tts: SentenceTts, val vad: SileroVad, val loop: VoiceLoop, val ditty: DittyPlayer) {
        fun release() {
            loop.stop()
            ditty.close()
            tts.close()
            vad.close()
        }
    }

    private val audioLock = Any()
    private var builtAudio: Audio? = null // guarded by audioLock
    private var cleared = false // guarded by audioLock

    /** Completed by the background build in init; declared before the coordinator reads it. */
    private val audio = CompletableDeferred<Audio?>()

    val coordinator: LoopCoordinator = LoopCoordinator(
        worker = workScope,
        main = mainScope,
        loopProvider = { audioOrNull()?.loop?.let(::LoopAdapter) },
        session = { session.newStory() },
        modeStore = prefs,
        listeningAvailability = transcriberFactory::availability,
        micPermission = {
            app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        },
        consent = { consentStore.accepted },
    )

    private val transcriber: ModeSwitchingTranscriber = ModeSwitchingTranscriber({ coordinator.sttMode }, transcriberFactory)

    private val session: DemoSession = DemoSession(
        chat = GroqChatClient(apiKey = { groq.current() }),
        stt = transcriber,
        facts = AnimalFactTracker(
            AnimalFactsApiClient(apiKey = { apiNinjas.current() }),
            AnimalFactsCache(File(app.filesDir, "animal_facts.json")),
        ),
        scope = workScope,
        log = ::log,
    )

    val story: StateFlow<StoryUiState> get() = coordinator.story
    val listeningPaused: StateFlow<Boolean> get() = coordinator.paused

    private val _settings = MutableStateFlow(SettingsUiState(sttMode = coordinator.sttMode, voiceName = prefs.voiceName))
    val settings: StateFlow<SettingsUiState> = _settings.asStateFlow()

    init {
        // Built once on a background thread at app start: TTS engine warm-up takes ~5 s.
        workScope.launch {
            try {
                audio.complete(buildAudio(app))
            } catch (e: Throwable) {
                audio.completeExceptionally(e)
            }
        }
        // Loaded warm at start, NOT on the first utterance (that would add ~1 s to the first
        // reply). In parallel with the audio build, so neither delays or breaks the other.
        workScope.launch(Dispatchers.IO) {
            try {
                onDevice.load()
            } catch (e: Exception) {
                // The Story screen shows a parent-facing notice (availability FAILED).
                log("on-device listening unavailable: ${e.javaClass.simpleName}")
            }
        }
        // A load finishing while the Story screen is already shown starts listening by itself.
        viewModelScope.launch {
            onDevice.availability.collect { coordinator.onListeningAvailabilityChanged() }
        }
        viewModelScope.launch {
            navigator.state.collect { nav ->
                coordinator.onNav(nav.screen)
                if (nav.screen == Screen.STORY) checkChatKey()
            }
        }
    }

    private fun buildAudio(app: Application): Audio? {
        val tts = SentenceTts(app, ::log)
        val vad = try {
            SileroVad(app)
        } catch (e: Exception) {
            tts.close() // do not leak the TTS engine binding
            throw e
        }
        prefs.voiceName?.let { tts.setVoice(it) }
        val ditty = DittyPlayer(::log)
        val loop = VoiceLoop(
            micFactory = { onFrame, onStopped -> MicCapture(onFrame, ::log, onStopped) },
            vad = vad,
            detector = SpeechDetector(),
            session = session,
            tts = tts,
            scope = workScope,
            waiting = ditty,
            consentGiven = { consentStore.accepted },
            onState = coordinator::onLoopState,
            onKeyProblem = coordinator::onKeyProblem,
            onError = coordinator::onLoopError,
            onTranscript = coordinator::onTranscript,
            onReply = coordinator::onReply,
            onStoryFinished = coordinator::onStoryFinished,
            onLog = ::log,
        )
        val parts = Audio(tts, vad, loop, ditty)
        synchronized(audioLock) {
            if (cleared) { // the ViewModel went away while we were building
                parts.release()
                return null
            }
            builtAudio = parts
        }
        return parts
    }

    private class LoopAdapter(private val loop: VoiceLoop) : LoopControl {
        override fun start() = loop.start()
        override fun stop() = loop.stop()
        override fun setMuted(muted: Boolean) = loop.setMuted(muted)
        override val isActive: Boolean get() = loop.state != LoopState.IDLE
    }

    // ---- lifecycle and Story actions (main thread) ----

    /** MainActivity.onStart / onStop (not called for configuration changes). */
    fun setForeground(foreground: Boolean) = coordinator.setForeground(foreground)
    fun onPermissionResult(granted: Boolean) = coordinator.onPermissionResult(granted)
    fun retryMic() = coordinator.retryMic()
    fun setListeningPaused(paused: Boolean) = coordinator.setPaused(paused)
    fun newStory() = coordinator.newStory()

    /** Shows the parent banner up front when Elsie has no key to think with. */
    private fun checkChatKey() {
        viewModelScope.launch {
            val has = withContext(Dispatchers.IO) { groq.current() != null }
            coordinator.setChatKeyAvailable(has)
        }
    }

    // ---- Settings actions ----

    fun refreshSettings() {
        viewModelScope.launch(Dispatchers.IO) {
            val status = KeyName.entries.associateWith { KeyStatus.of(keys.get(it), Secrets.baked(it)) }
            val baked = KeyName.entries.associateWith { Secrets.baked(it).isNotBlank() }
            _settings.update {
                it.copy(keyStatus = status, bakedPresent = baked, sttMode = coordinator.sttMode, voiceName = prefs.voiceName)
            }
            val tts = audioOrNull()?.tts ?: run {
                _settings.update { it.copy(voicesLoading = false) }
                return@launch
            }
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
            if (name == KeyName.GROQ) {
                val has = groq.current() != null
                withContext(Dispatchers.Main) { coordinator.setChatKeyAvailable(has) }
            }
        }
    }

    /**
     * Only call after the parent confirmed the in-context disclosure: from now on the child's
     * voice is sent to the cloud for transcription.
     */
    fun enableCloudListening() = setSttMode(SttMode.CLOUD)

    fun useOnDeviceListening() = setSttMode(SttMode.ON_DEVICE)

    private fun setSttMode(mode: SttMode) {
        coordinator.setSttMode(mode)
        _settings.update { it.copy(sttMode = mode) }
    }

    fun setVoice(name: String?) {
        prefs.voiceName = name
        _settings.update { it.copy(voiceName = name) }
        workScope.launch { audioOrNull()?.tts?.setVoice(name) }
    }

    /** Parent withdrew consent: stop listening, turn better listening off, back to Onboarding. */
    fun revokeConsent() {
        coordinator.revokeConsent()
        _settings.update { it.copy(sttMode = coordinator.sttMode) }
        navigator.revokeConsent()
    }

    // ---- plumbing ----

    /** The audio parts, or null if building them failed (logged; never crashes the app). */
    private suspend fun audioOrNull(): Audio? = try {
        audio.await()
    } catch (t: Throwable) {
        // Throwable: buildAudio's failure is stored as-is, and an Error (e.g. a native-library
        // or class-init failure) rethrown here must not escape and kill the app (#88).
        t.rethrowIfFatal() // includes CancellationException
        log("audio setup failed: ${t.javaClass.name}")
        null
    }

    private fun log(msg: String) {
        Log.i(TAG, msg)
    }

    override fun onCleared() {
        coordinator.clear() // no queued command can start the mic after this; stops the loop
        session.close()
        val parts = synchronized(audioLock) {
            cleared = true
            builtAudio.also { builtAudio = null }
        }
        parts?.release() // a build still running releases its own parts when it finishes
        transcriber.close()
        onDevice.close() // idempotent; releases the recognizer after any decode in progress
        workScope.coroutineContext.job.cancel()
        mainScope.coroutineContext.job.cancel()
    }

    private companion object {
        const val TAG = "TinyTalk"
        const val VOICE_LIST_RETRIES = 16
    }
}
