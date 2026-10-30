# Android Phase 1 — Voice Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A parent can install the debug APK, give consent, grant the mic, and a child can hold a spoken story conversation with Elsie (listen -> **on-device** speech recognition -> Groq chat with the iOS prompts/arc/safety/animal-fact guidance -> spoken reply, interruptible), using a baked-in Groq key that Settings can override. **The child's voice never leaves the phone by default**; only text goes to the cloud. An optional, off-by-default "better listening" switch sends audio to Groq Whisper instead. No storybook yet (Phase 2).

**Architecture:** A pure-Kotlin/JVM `core` module holds everything portable (ported from `ios/TinyTalkCore`, which is the source of truth) and is unit-tested with `./gradlew test` and OkHttp `MockWebServer` — no device, no audio. The `app` module holds Android specifics: the Phase 0 audio pieces (`MicCapture`, `SileroVad`, `SentenceTts`), a `VoiceLoop` that drives core's `DemoSession`, key storage, and Compose screens.

**Tech Stack:** On-device STT: sherpa-onnx 1.13.8 (`OfflineRecognizer`) running Whisper `tiny.en` int8, 2 threads (chosen by the 2026-10-21 spike: `docs/superpowers/specs/2026-10-21-android-stt-spike-results.md`). Kotlin 2.4.21, AGP 9.4.1 / Gradle 9.8.2 (already pinned), Jetpack Compose (BOM 2026.09.00), kotlinx.coroutines, kotlinx.serialization, OkHttp (+ `mockwebserver` for tests), JUnit. Look up current stable versions when adding each dependency (context7 / official docs); do not guess.

**Spec:** `docs/superpowers/specs/2026-10-19-android-demo-mode-client-design.md`. Phase 0 findings: `docs/superpowers/specs/2026-10-19-android-phase0-results.md` (GO accepted 2026-10-21).

## Global Constraints

- **No real audio from tests or commands without asking the author** (CLAUDE.md). Every task verifies with `./gradlew test assembleDebug` (silent). Do not run `connectedDebugAndroidTest` for audio tests or launch audio features on a device. Task 11's audible run is gated on the author's explicit OK, and the author may not be available to test audio for a while: finish Tasks 1-10 silently, then stop at Task 11.
- iOS is the source of truth for prompts, word lists, story-arc rules, thresholds. Port **verbatim**; the reviewer diffs against the Swift file named in each task. Numbers tuned on iPhone audio (VAD 0.5/3/22, timers) are starting values to re-tune on the Pixel 3, not constants.
- `core` has **no Android imports**. Kotlin package `com.jessvb.tinytalk.core`; app package `com.jessvb.tinytalk`.
- Secrets never committed (public repo). Baked-in keys come from gitignored `android/local.secrets.properties` (committed `.example` has placeholders) via `BuildConfig`; user overrides live in encrypted storage; clearing an override falls back to the baked-in key.
- Privacy disclosure (spec): a one-time parent "I agree" screen, shown before the mic or any network call, using the author-approved wording in Task 9 ("the cloud", not vendor names; the child's voice stays on the phone and is not saved; only story text goes to the cloud). No microphone start, no network request, until consent is stored. If the parent turns on "better listening", the disclosure must be shown again in context before the first audio is sent.
- Key problems (missing, 401/403 rejected, 429 rate-limited) must never leave a silent dead screen: Elsie says a short friendly line asking for a grown-up and the parent sees a banner pointing to Settings.
- **Speech recognition is on-device by default** (author decision 2026-10-21, spike results above): Whisper `tiny.en` int8 via the sherpa-onnx AAR, 2 threads (Pixel 3 warm median 0.70 s per utterance, RTF 0.36; 4 threads gave no gain). Audio is held in memory only and never written to disk. The cloud `GroqWhisperClient` (`whisper-large-v3-turbo`, `language=en`) exists only behind the Settings switch "better listening" (**off by default**, labelled as sending the child's voice to the cloud). The Phase 0b zipformer candidate failed (75% WER, unexplained) and Vosk was slower/less accurate; neither is used.
- Groq chat: model `openai/gpt-oss-20b` (Groq's own current replacement note is in `GroqChatClient.swift`; re-verify it is still current at implementation time), host `https://api.groq.com`. Text only.
- **Native library clash (verified in the spike):** the sherpa-onnx AAR bundles its own `libonnxruntime.so` (ORT 1.28.2), which collides with the app's `onnxruntime-android:1.31.0` (`mergeDebugNativeLibs: 2 files found with path lib/arm64-v8a/libonnxruntime.so`). Task 4b must resolve this (preferred: the `sherpa-onnx-static-link-onnxruntime-1.13.8.aar` variant; fallback: run Silero VAD through sherpa-onnx's own VAD API and drop the direct ORT dependency). Never ship with `pickFirsts` mixing ORT versions.
- Whisper tiny.en is weak on one-word replies ("Yes" came back empty or doubled; "Okay" -> "Okay. Okay.") and on made-up words; the transcript cleaner (Task 4b) and the empty-transcript path must handle this. Child-speech accuracy is unmeasured (spike used adult synthetic voices); the author will test real voices later.
- APK size: expect about +130 MB (model ~104 MB, native libs ~32 MB). Model files are gitignored and fetched by `android/stt-spike/fetch-models.sh`; document how a build gets them.
- minSdk 26, compile/targetSdk 37, Pixel 3 (Android 12) must work. Commit trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; small commits; don't touch `ios/` or `server/`.
- Phase 0 carry-forwards that bind this phase: one long-lived warm `TextToSpeech` (cold start 4.8-5.9 s); per-sentence stalls are expected (shorter watchdog than 20 s, retry/skip); `MODIFY_AUDIO_SETTINGS` + explicit speaker routing; join the mic thread without a timeout before releasing native resources; no binder/disk work under the TTS lock during barge-in.

## Review Focus

1. Empty, whitespace, or doubled STT transcript (silence/noise; one-word replies like "Yes" -> "" or "Yes, yes"): Elsie continues the story gently (iOS `sttFailureGuidance`), a doubled reply is cleaned to one, no crash, no repeated prompt.
2. Offline / Groq 5xx / timeout: a friendly retry line and a banner that clears when the next turn succeeds; mic keeps listening.
3. Consent not yet given or revoked: no mic start, no network call; the app explains rather than going quiet.
4. Barge-in during "thinking" (before Elsie speaks): the in-flight request is cancelled and its late reply is dropped, never spoken after the child's new utterance.
5. First word clipped: an utterance that begins right at SpeechStart (child starts talking immediately after Elsie stops, or after a barge-in) must still include its first syllable; the pre-roll buffer must keep filling while Elsie is speaking and while the loop is THINKING, not only while LISTENING. Verify with a recorded-WAV replay through the VAD + buffer in a headless test (no sound).
6. App backgrounded or screen locked mid-turn: mic and TTS released; coming back resumes cleanly without a stale "speaking" state.

## File Structure

```
android/
  settings.gradle.kts, build.gradle.kts      (add :core)
  local.secrets.properties.example           (GROQ_API_KEY, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, API_NINJAS_KEY placeholders)
  core/build.gradle.kts
  core/src/main/kotlin/com/jessvb/tinytalk/core/
    audio/{FrameChunker,SpeechDetector}.kt        (moved from spike)
    Safety.kt  StoryArc.kt  DemoConversation.kt
    chat/{ChatCompleting,GroqChatClient,GroqErrors}.kt
    stt/{SpeechTranscribing,GroqWhisperClient,Wav,TranscriptCleaner}.kt
    facts/{AnimalFacts,AnimalFactTracker,AnimalFactsCache,AnimalFactsApiClient}.kt
    session/{SessionEvent,DemoSession,TurnStateMachine}.kt
    keys/KeyResolver.kt
    settings/SttMode.kt                          (ON_DEVICE | CLOUD, default ON_DEVICE)
  core/src/test/kotlin/...                        (one test file per class above)
  app/src/main/java/com/jessvb/tinytalk/
    keys/{SecretsStore,Secrets}.kt                (EncryptedSharedPreferences + BuildConfig)
    stt/OnDeviceTranscriber.kt                    (sherpa-onnx Whisper tiny.en; implements SpeechTranscribing)
    src/main/assets/stt/whisper-tiny.en/          (gitignored model files from fetch-models.sh)
    voice/VoiceLoop.kt
    ui/{DesignSystem,Navigation,OnboardingScreen,LandingScreen,StoryScreen,SettingsScreen}.kt
    TinyTalkApp.kt  MainActivity.kt
    spike/…                                       (kept only for MicCapture/SileroVad/SentenceTts reuse; remove unused spike screens)
```

---

### Task 1: `core` module; move the speech-detector pieces

**Files:** Create `android/core/build.gradle.kts` (Kotlin JVM library, JUnit, coroutines, serialization, OkHttp, mockwebserver); Modify `android/settings.gradle.kts`, `android/app/build.gradle.kts` (depend on `:core`); Move `FrameChunker.kt`, `SpeechDetector.kt` (+ their tests) from `app/.../spike/` to `core/.../audio/`, fixing imports.

**Interfaces:** Produces module `:core` and `com.jessvb.tinytalk.core.audio.{FrameChunker, SpeechEvent, SpeechDetector}` with the exact Phase 0 signatures.

- [ ] **Step 1:** Create the module and move the files with `git mv`; update spike code imports.
- [ ] **Step 2:** `cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/android-demo-mode/android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew test assembleDebug`. Expected: BUILD SUCCESSFUL, the moved tests (FrameChunkerTest, SpeechDetectorTest) pass in `:core`.
- [ ] **Step 3:** Commit (`refactor(android): add core module, move speech detector (#88)`).

### Task 2: `Safety` (port of `Safety.swift`)

**Files:** Create `core/.../Safety.kt`; Test `core/src/test/.../SafetyTest.kt`.

**Interfaces:** Produces `object Safety { const val SAFE_FALLBACK: String; fun findBlocked(text: String): List<String>; fun isSafe(text: String): Boolean; fun filterReply(text: String): String }`.

- [ ] **Step 1: Tests (fail first).** `findBlocked("The knife was sharp")` == `["knife"]`; matching is case-insensitive and whole-word (`"class"` and `"assume"` are NOT flagged by `"ass"`; `"Hello"` not flagged by `"hell"`); multiple hits are lowercased, distinct, in first-appearance order; `"a shooting star"` and `"SHOOTING STARS"` are safe (safe-phrase mask runs first) but `"shooting"` alone is blocked; `filterReply("")` and `filterReply("kill")` return `SAFE_FALLBACK` = `"Hmm, let's take the story somewhere else! What should happen next?"`; a clean reply is returned unchanged.
- [ ] **Step 2:** Run `./gradlew :core:test`; expect FAIL.
- [ ] **Step 3:** Implement with the word lists copied **verbatim** from `Safety.swift` (violence, frightening, adultThemes, realWorldDanger, reproduction, profanity, safePhrases) using a `\b(?:a|b|…)\b` case-insensitive regex built from escaped terms.
- [ ] **Step 4:** Run `./gradlew :core:test`; expect PASS. **Step 5:** Commit.

### Task 3: `StoryArc` and `DemoConversation`

**Files:** Create `core/.../StoryArc.kt`, `core/.../DemoConversation.kt`; Test `StoryArcTest.kt`, `DemoConversationTest.kt`. Source of truth: `StoryArc.swift`, `DemoConversation.swift`.

**Interfaces:** Produces
`enum class StoryStage { INTRO, SETUP, RISING_ACTION, CLIMAX, RESOLUTION, DONE }`;
`class StoryArc(targetTurns: Int = 7) { val stage; val isDone; val hasStarted; fun recordTurn(childText: String): String; fun recordReply(replyText: String); fun forceConcludeGuidance(): String; fun markDone() }`;
`enum class Speaker { CHILD, AGENT }`; `data class ConversationTurn(val speaker: Speaker, val text: String, val interrupted: Boolean = false)`;
`class DemoConversation(maxTurns: Int = 20) { val fullHistory: List<ConversationTurn>; fun addChild(text: String); fun addAgent(text: String, interrupted: Boolean = false); fun toMessages(systemPrompt: String): List<ChatMessage> }` (`ChatMessage(role, content)` is defined in Task 4; define it in this task if Task 4 hasn't landed, in `chat/ChatCompleting.kt`).

- [ ] **Step 1: Tests (fail first).** StoryArc with `targetTurns=7`: stage for turn 1 is INTRO; turn 2 SETUP (`round(7/4)=2`); turns 3-5 RISING_ACTION (`round(7*2/3)=5`); turns 6-7 CLIMAX; turn 8+ RESOLUTION. Child text `"I'm done"` returns the RESOLUTION guidance at any stage; turn 11 (target+3 grace ceiling is 10, so `turnCount > 10`) returns the forced "The end." guidance and the next `recordReply` sets `isDone`; a reply containing "happily ever after" (word-boundary) sets `isDone`; `forceConcludeGuidance()` does not advance the turn count; `markDone()` forces DONE. DemoConversation: empty/whitespace text is dropped; window keeps the last 20 turns while `fullHistory` keeps all; roles map child->"user", agent->"assistant"; an interrupted agent turn gets ` [interrupted by the child]` appended; `toMessages` starts with the system message.
- [ ] **Step 2:** Run `./gradlew :core:test`; expect FAIL. **Step 3:** Implement; guidance strings copied verbatim from `StoryArc.swift`; thread-safe (a lock or confinement) since turns run on coroutines. **Step 4:** PASS. **Step 5:** Commit.

### Task 4: Groq clients (chat and Whisper) with typed errors

**Files:** Create `core/.../chat/{ChatCompleting,GroqChatClient,GroqErrors}.kt`, `core/.../stt/{SpeechTranscribing,GroqWhisperClient,Wav}.kt`; Test `GroqChatClientTest.kt`, `GroqWhisperClientTest.kt`, `WavTest.kt` using `MockWebServer`. Source of truth: `GroqChatClient.swift`, `GroqWhisperClient.swift`.

**Interfaces:** Produces
`data class ChatMessage(val role: String, val content: String)`;
`interface ChatCompleting { suspend fun complete(messages: List<ChatMessage>): String }`;
`interface SpeechTranscribing { suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String }`;
`sealed class GroqException(message: String) : Exception(message) { class KeyRejected; class RateLimited(val retryAfterSeconds: Int?); class Failure(detail: String); class Network(cause: Throwable) }`;
`class GroqChatClient(apiKey: () -> String, model: String = "openai/gpt-oss-20b", host: String = "https://api.groq.com", reasoningEffort: String? = null, http: OkHttpClient = OkHttpClient()) : ChatCompleting`;
`class GroqWhisperClient(apiKey: () -> String, model: String = "whisper-large-v3-turbo", host: String = ..., http: OkHttpClient = ...) : SpeechTranscribing`;
`fun wavFromPcm16(pcm16: ShortArray, sampleRate: Int, channels: Int = 1): ByteArray` (the key is a provider so a Settings change takes effect without rebuilding clients).

- [ ] **Step 1: Tests (fail first).** Chat: request path `/openai/v1/chat/completions`, `Authorization: Bearer <key>`, JSON body has `model`, `messages`, `stream:false` and **omits** `reasoning_effort` when null but includes it when set; returns `choices[0].message.content`; HTTP 401/403 -> `KeyRejected`; 429 -> `RateLimited` (parses `Retry-After` when present); 500 -> `Failure`; connection refused/timeout -> `Network`; an empty `choices` array -> `Failure`. Whisper: path `/openai/v1/audio/transcriptions`, multipart with `model`, `language=en`, and a `file` part named `utterance.wav` of type `audio/wav`; same error mapping; returns the `text` field. Wav: 44-byte header, `RIFF`/`WAVE`/`fmt `/`data` markers, little-endian sample rate (16000) and byte rate, data length = 2 x samples, payload round-trips.
- [ ] **Step 2:** Run `./gradlew :core:test`; expect FAIL. **Step 3:** Implement with OkHttp (blocking calls inside `withContext(Dispatchers.IO)`; cancellable via `Call.cancel()` on coroutine cancellation) and kotlinx.serialization. **Step 4:** PASS. **Step 5:** Commit.

### Task 4b: On-device transcriber and transcript cleaner

> **Status (2026-10-22):** done. 4b-A (cleaner) earlier; 4b-B installed `OnDeviceTranscriber` with the static-link AAR (no duplicate `libonnxruntime.so`, no `pickFirsts`; non-arm64 ABIs excluded before the native merge). The model is copied into generated assets by the `sttModelAssets` Gradle task (no `android/.gitignore` change needed), unpacked to no-backup storage on first launch and loaded warm at app start. Verified silently on the Pixel 3 from WAV files only; see `docs/superpowers/specs/2026-10-22-android-phase1-results.md`.

**Files:** Create `core/.../stt/TranscriptCleaner.kt` (+ `TranscriptCleanerTest.kt`), `core/.../settings/SttMode.kt`, `app/.../stt/OnDeviceTranscriber.kt`; Modify `app/build.gradle.kts` (add `files("../stt-spike/downloads/libs/<AAR>")`; keep or replace direct `onnxruntime-android` per the clash fix), `android/.gitignore` (model assets). Source of truth for how to call sherpa-onnx: `android/stt-spike-app/` (the throwaway harness that already runs on the Pixel 3) and `android/stt-spike/PHASE-B-REPORT.md`.

**Interfaces:** Consumes `SpeechTranscribing` (Task 4). Produces
`object TranscriptCleaner { fun clean(raw: String): String }` (trims; collapses an immediately repeated sentence/word-group such as "Okay. Okay." or "Yes, yes" to one; drops lone punctuation; returns "" when nothing meaningful remains);
`enum class SttMode { ON_DEVICE, CLOUD }` (default `ON_DEVICE`);
`class OnDeviceTranscriber(context: Context, threads: Int = 2) : SpeechTranscribing, AutoCloseable` (loads Whisper tiny.en int8 once and keeps it warm: model load ~1.1 s, so load it at app start on a background thread; `transcribe` converts int16 PCM to float /32768 and returns `TranscriptCleaner.clean(text)`; never blocks the main thread; a missing model file produces a clear `IllegalStateException`, not a crash loop).

- [ ] **Step 1: Tests (fail first), JVM, cleaner only.** "Yes, yes" -> "Yes"; "Okay. Okay." -> "Okay"; "The fox ran. The fox ran." -> "The fox ran" (exact immediate repeat only); "Yes yes yes" -> "Yes"; "I said yes, yes, I did" stays unchanged (not an immediate full-text repeat); "." and "  " -> ""; normal sentences unchanged.
- [ ] **Step 2:** Run `./gradlew :core:test`; expect FAIL. **Step 3:** Implement the cleaner.
- [ ] **Step 4: Resolve the ORT clash.** Try the `sherpa-onnx-static-link-onnxruntime-1.13.8.aar` (fetch via `INCLUDE_OPTIONAL=1 bash android/stt-spike/fetch-models.sh`, which the author runs; if absent, stop and ask the author to run it) alongside `onnxruntime-android:1.31.0`; `./gradlew assembleDebug` must succeed with **no** duplicate-file error and without `pickFirsts`. If it cannot, fall back to sherpa-onnx's own Silero VAD API and remove the direct ORT dependency (then `SileroVad` must be re-based and its Phase 0 instrumented test re-run silently).
- [ ] **Step 5:** Implement `OnDeviceTranscriber` from the harness code. Verify **silently** that it compiles and that one WAV from `android/stt-spike/testdata/wav/` transcribes to the right text in a headless instrumented test (reads a file; no AudioTrack/AudioRecord; no sound), run filtered to that test class only with `-Pandroid.testInstrumentationRunnerArguments.class=<fqcn>`. Record the APK size (`ls -l app/build/outputs/apk/debug/app-debug.apk`).
- [ ] **Step 6:** Commit.

### Task 5: Animal facts (port of `AnimalFacts*.swift`)

**Files:** Create `core/.../facts/{AnimalFacts,AnimalFactTracker,AnimalFactsCache,AnimalFactsApiClient}.kt`; Test `AnimalFactsTest.kt`, `AnimalFactTrackerTest.kt`, `AnimalFactsApiClientTest.kt`. Source of truth: `AnimalFacts.swift`, `AnimalFactTracker.swift`, `AnimalFactsAPIClient.swift`, `AnimalFactsCache` (Swift).

**Interfaces:** Produces
`object AnimalFacts { fun findNewAnimal(transcript: String, excluding: Collection<String>): String?; fun extractFacts(c: AnimalCharacteristics): List<String> }`;
`interface AnimalFactFetching { suspend fun fetchFacts(canonical: String): List<String>? }`;
`class AnimalFactsApiClient(apiKey: () -> String?, host: String = <iOS default>, http: OkHttpClient = ...) : AnimalFactFetching` (a null/blank key makes every lookup a silent `null`);
`class AnimalFactsCache(file: java.io.File)` (JSON map `animal -> [facts]`, load/save);
`class AnimalFactTracker(fetcher: AnimalFactFetching, cache: AnimalFactsCache) { suspend fun recordTurn(transcript: String, stage: StoryStage): String; suspend fun sharedFacts(): List<Pair<String,String>>; suspend fun reset() }` (serialized with a `Mutex`).

- [ ] **Step 1: Tests (fail first).** `findNewAnimal("the fox ran")` -> the canonical name for fox; excludes already-facted/attempted animals; no animal -> null; tracker: first animal mention returns the weave-in text containing the fact (template copied from `AnimalFactTracker.swift`), a second mention of the same animal returns `""`; no animal yet during INTRO/SETUP returns the "ask the child what animal" nudge, but not during RISING_ACTION; a failed fetch returns `""` and still marks the animal attempted; cache hit skips the fetcher; `reset()` clears state; api client with a blank key returns `null` without any HTTP request (MockWebServer sees 0 requests).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; port the animal list and fact templates verbatim. **Step 4:** PASS. **Step 5:** Commit.

### Task 6: `DemoSession` — the turn loop

**Files:** Create `core/.../session/{SessionEvent,DemoSession}.kt`; Test `DemoSessionTest.kt` with fakes for `ChatCompleting`, `SpeechTranscribing`, `AnimalFactFetching`. Source of truth: `DemoConnection.swift` (`defaultSystemPrompt`, `runTurn`, `sttFailureGuidance`, error text), `Protocol.swift` event names.

**Interfaces:** Consumes Tasks 2-5 (`stt` is whichever `SpeechTranscribing` the app selects from `SttMode`). Produces
`sealed interface SessionEvent { data class TranscriptFinal(val text: String, val turnId: Int); data class ResponseText(val text: String, val turnId: Int); data class TurnEnd(val turnId: Int); data class Error(val message: String, val turnId: Int); data class KeyProblem(val kind: KeyProblemKind, val turnId: Int); object StoryFinished }` and `enum class KeyProblemKind { MISSING, REJECTED, RATE_LIMITED }`;
`class DemoSession(chat: ChatCompleting, stt: SpeechTranscribing, facts: AnimalFactTracker, scope: CoroutineScope, systemPrompt: String = DEFAULT_SYSTEM_PROMPT, targetTurns: Int = 7) { val events: SharedFlow<SessionEvent>; fun submitUtterance(turnId: Int, pcm16: ShortArray, sampleRate: Int); fun bargeIn(turnId: Int); fun newStory(); fun close(); companion object { const val DEFAULT_SYSTEM_PROMPT: String } }`.

- [ ] **Step 1: Tests (fail first).** Happy path: events in order `TranscriptFinal`, `ResponseText`, `TurnEnd`; the chat request's system message = system prompt + `"\n\n"` + arc guidance (+ fact guidance appended with `"\n\n"` when present); the child text and then the agent reply are added to the conversation. Unsafe model output (`"…kill…"`) is replaced by `Safety.SAFE_FALLBACK` before `ResponseText`. Blank or cleaner-emptied transcript: no child turn added, `sttFailureGuidance` text appended to guidance, chat still called. `bargeIn(turnId)` mid-transcription or mid-chat cancels the in-flight turn: no `ResponseText` is ever emitted for it, even if the fake chat returns afterwards (Review Focus 4). A new `submitUtterance` supersedes the previous turn. `GroqException.KeyRejected` -> `KeyProblem(REJECTED)`, `RateLimited` -> `KeyProblem(RATE_LIMITED)`, `Network`/`Failure` -> `Error("Elsie's cloud brain is having trouble -- let's try again in a moment.")`; the session stays usable for the next turn. After a reply makes the arc `isDone`, `StoryFinished` is emitted after `TurnEnd` and conversation/arc/facts reset for a new story. `newStory()` cancels in-flight work and resets all three.
- [ ] **Step 2:** FAIL. **Step 3:** Implement with a `Mutex`/single-writer state, one `Job` per turn, capturing conversation/arc once at turn start (as `runTurn` does). `DEFAULT_SYSTEM_PROMPT` copied verbatim from `DemoConnection.defaultSystemPrompt`. Object tracker guidance and the forced-conclude/storybook paths are **out of scope** (Phases 2-3). **Step 4:** PASS. **Step 5:** Commit.

### Task 7: Key resolution and secure storage

**Files:** Create `core/.../keys/KeyResolver.kt`, `app/.../keys/{Secrets,SecretsStore}.kt`; Modify `app/build.gradle.kts` (read `local.secrets.properties` into `BuildConfig`: `GROQ_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `API_NINJAS_KEY`; empty strings when the file is absent so CI-less builds still compile), `android/.gitignore`, `android/local.secrets.properties.example`; Test `KeyResolverTest.kt`.

**Interfaces:** Also persists the `SttMode` choice (`SharedPreferences`, default `ON_DEVICE`). Produces `class KeyResolver(baked: String, override: () -> String?) { fun current(): String? }` (override wins when non-blank, else baked when non-blank, else null) and `interface KeyStore { fun get(name: KeyName): String?; fun set(name: KeyName, value: String?) }` with `enum class KeyName { GROQ, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TOKEN, API_NINJAS }`; `SecretsStore(context): KeyStore` backed by encrypted storage (use the current recommended AndroidX/Keystore-backed API; verify `EncryptedSharedPreferences` has not been superseded before using it).

- [ ] **Step 1: Tests (fail first).** Override beats baked; blank/whitespace override falls through to baked; both blank -> null (drives `KeyProblem(MISSING)`); changing the override is visible on the next `current()` call without recreating the resolver.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Verify with `./gradlew assembleDebug` that a build with **no** `local.secrets.properties` succeeds, and confirm via `git status` that the real file is untracked. **Step 4:** PASS. **Step 5:** Commit.

### Task 8: `TurnStateMachine` and `VoiceLoop`

**Files:** Create `core/.../session/TurnStateMachine.kt` (+ `TurnStateMachineTest.kt`), `app/.../voice/VoiceLoop.kt`. Source of truth for utterance gating, minimum speech length and playback-complete handling: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift` (read its VAD-event and turn handling; do not port its server paths).

**Interfaces:** Produces
`enum class LoopState { IDLE, LISTENING, THINKING, SPEAKING }`;
`class TurnStateMachine { val state: LoopState; fun onSpeechStart(): Action; fun onSpeechEnd(): Action; fun onResponseText(turnId: Int): Action; fun onPlaybackFinished(): Action; fun onBargeIn(): Action }` where `Action` says whether to stop TTS, cancel the in-flight turn, submit the utterance, or ignore, and `turnId` increments per utterance, with stale `turnId`s ignored;
`class VoiceLoop(mic: MicCapture, vad: SileroVad, detector: SpeechDetector, session: DemoSession (built with the transcriber for the current `SttMode`), tts: SentenceTts, scope: CoroutineScope, consentGiven: () -> Boolean, onState: (LoopState) -> Unit, onKeyProblem: (KeyProblemKind) -> Unit, onError: (String) -> Unit) { fun start(): Boolean; fun stop() }`.

- [ ] **Step 1: Tests (fail first), JVM only for the state machine.** Idle -> speech start -> LISTENING -> speech end -> THINKING; response text -> SPEAKING; speech start while SPEAKING returns an action that stops TTS and cancels nothing in flight, starts a new utterance, and bumps `turnId`; speech start while THINKING cancels the in-flight turn (Review Focus 4); a `ResponseText` with a stale `turnId` is ignored; `onPlaybackFinished` returns to LISTENING; utterances shorter than the iOS minimum are ignored (take the exact threshold from `SessionCoordinator.swift`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement the machine, then `VoiceLoop`: frames from `MicCapture` -> `SileroVad.probability` -> `SpeechDetector` on the capture thread; buffer PCM between speech start and end **with an explicit rolling pre-roll of at least 500 ms** (author reports the first word is often clipped on the iPhone in both modes; the detector only fires SpeechStart after the 3-frame attack, about 100 ms, plus speech onset, so the utterance must start from audio captured *before* SpeechStart; put the pre-roll in a small pure `PreRollBuffer(capacityMs, sampleRate)` class in `core` with JVM tests: after pushing 2 s of numbered samples, `snapshot()` returns exactly the last `capacityMs` worth in order; shorter history returns what exists; the utterance handed to `submitUtterance` is pre-roll + audio until SpeechEnd, and the hangover tail after the speaker stops is trimmed to at most ~300 ms); on end call `session.submitUtterance(turnId, pcm, 16000)`; collect `session.events` on `scope`: `ResponseText` -> `tts.speak`, `KeyProblem`/`Error` -> callbacks plus a short spoken friendly line (use the exact words from the spec's key-exhausted decision). `start()` refuses (returns false) without consent (Review Focus 3). Keep `tts.stop()` on barge-in cheap (Phase 0 finding). Make Elsie's speech use one app-lifetime `SentenceTts`.
- [ ] **Step 4:** `./gradlew test assembleDebug`; expect PASS. **Step 5:** Commit.

### Task 9: Design system, navigation, Onboarding (with consent) and Landing

**Files:** Create `app/.../ui/{DesignSystem,Navigation,OnboardingScreen,LandingScreen}.kt`, `app/.../TinyTalkApp.kt`; Modify `MainActivity.kt`, manifest (`INTERNET`, `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`). Source of truth: `ios/TinyTalkApp/TinyTalkApp/{DesignSystem,OnboardingView,LandingView,ContentView}.swift`.

**Interfaces:** Produces `enum class Screen { ONBOARDING, LANDING, STORY, SETTINGS }`, a `Navigator` holding the current screen, and `ConsentStore { var accepted: Boolean }` (persisted with `SharedPreferences`; testable with a fake).

- [ ] **Step 1: Tests (fail first), JVM.** `Navigator`: starts at ONBOARDING until consent is accepted, then LANDING; declining consent keeps ONBOARDING and starts no mic/network; consent persists across a new `Navigator`/`ConsentStore` instance (fake storage).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Onboarding: the iOS onboarding content/look plus the consent screen and an "I agree" / "Not now" pair; mic permission is requested only after consent. **Approved consent wording (use as written; do not add a claim about the cloud provider's retention/training policy unless verified against that provider's current documentation with a source):** title "Before we start"; "Tiny Talk Adventures lets your child make up stories out loud with Elsie. To do that, your child's voice is turned into words **on this phone**, and **this app doesn't save recordings**. The words of the story conversation are sent to **the cloud** so Elsie can think of what to say next. Stories stay on this phone. The app creator's account pays for the cloud service for now; you can enter your own key in Settings. By tapping \"I agree\" you're saying you're a parent or guardian and you're happy with this." Declining keeps the screen and says nothing is sent until they agree. Landing mirrors the iOS Landing (Create a Story; Read Stories is shown but disabled until Phase 2, with a clear label). Colors/typography/Elsie imagery ported from `DesignSystem.swift` and the iOS assets (copy image assets into `app/src/main/res`; do not modify `ios/`). **Step 4:** `./gradlew test assembleDebug` PASS. **Step 5:** Commit.

### Task 10: Story and Settings screens; wire everything

**Files:** Create `app/.../ui/{StoryScreen,SettingsScreen}.kt`; Modify `TinyTalkApp.kt` (own the `DemoSession`, `VoiceLoop`, `SentenceTts` for the app's lifetime), remove unused spike screens (keep `MicCapture`, `SileroVad`, `SentenceTts`, `RunTracker`). Source of truth: `StoryView.swift`, `SettingsView.swift` (away-from-home parts only).

**Interfaces:** Consumes everything above. Produces `StoryViewModel` exposing `state: StateFlow<StoryUiState>` (loop state, transcript lines, banner) with pure reducers (`reduce(state, SessionEvent|LoopState|KeyProblemKind)`).

- [ ] **Step 1: Tests (fail first), JVM, reducers only.** A `KeyProblem(RATE_LIMITED)` event sets a banner pointing to Settings; the next successful `TurnEnd` clears it; `Error` sets the retry banner and the next success clears it; `TranscriptFinal` and `ResponseText` append transcript lines in order; a new story clears the transcript.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Story screen: Elsie avatar reflecting `LoopState`, transcript, "New Story" button, the banner, a visible "Microphone unavailable" / "Add a key in Settings" state instead of silence. Settings: fields for the Groq key and (stored for Phase 3) Cloudflare account id/token and API Ninjas key, each with a "using the built-in key / using your key" status and a "Use built-in key" clear action; a "better listening" switch (off by default; text: "Sends your child's voice to the cloud for more accurate listening"; turning it on shows the disclosure again before any audio is sent); voice picker listing installed English `TextToSpeech` voices, applied to the single warm `SentenceTts`; the privacy disclosure text. Lifecycle: `onStop` releases mic/TTS, `onStart` resumes (Review Focus 5). **Step 4:** `./gradlew test assembleDebug` PASS. **Step 5:** Commit.

### Task 11: Phase 1 acceptance (silent checks now; audible run gated)

**Files:** Modify `README.md` (Android section: run, keys file setup, what Phase 1 does), `CLAUDE.md` "Current focus" (one short paragraph); Create `docs/superpowers/specs/2026-10-21-android-phase1-results.md`.

- [ ] **Step 1 (silent):** `./gradlew test assembleDebug` all green; list the number of core JVM tests; record the debug APK size; install the APK with `adb install -r` but **do not launch audio features**. Confirm by `git ls-files android` that no secrets/keystore are tracked.
- [ ] **Step 2 (gated — STOP and ask the author before doing anything audible):** tell the author what will play, on which device, and for how long, and wait for an explicit yes. With the author at the phone: grant consent and mic; hold a 3-turn conversation; interrupt Elsie once; try with the built-in key then a deliberately wrong key in Settings (expect Elsie's friendly line and the banner pointing to Settings); turn Wi-Fi off mid-turn (expect the retry line and recovery); background and return the app.
- [ ] **Step 3:** Record observations in the results doc (what worked, what did not, VAD retuning needs on real child voices, TTS stalls seen) and commit. Do not claim anything measured that was not.

---

## Self-review

- **Spec coverage:** Phase 1 scope (core module with conversation/Groq chat/safety/arc/facts + JVM tests; on-device STT default with optional cloud switch (spec decision 2026-10-21); Onboarding, Landing, Story, Settings screens; spoken loop; keys baked + override; consent gate; key-exhausted handling; privacy disclosure) maps to Tasks 1-11. Storybook, Library/Reading, The End, finish-story, illustrations, object recognition are Phases 2-4 and explicitly excluded.
- **Types:** `ChatMessage` is shared by Tasks 3, 4, 6; `StoryStage` by Tasks 3, 5, 6; `KeyProblemKind` by Tasks 6, 8, 10; `SttMode`/`TranscriptCleaner` by Tasks 4b, 6, 7, 10; `LoopState` by Tasks 8, 10. Each is defined in the task that first produces it.
- **Review Focus:** 1 -> Tasks 4b, 6 tests; 2 -> Tasks 4, 6, 10 tests; 3 -> Tasks 8, 9 tests; 4 -> Tasks 6, 8 tests; 5 -> Task 8 (`PreRollBuffer` tests + WAV replay); 6 -> Task 10 lifecycle step (verified in Task 11 Step 2).
