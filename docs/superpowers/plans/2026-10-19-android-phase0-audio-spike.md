# Android Phase 0 — Toolchain + Audio Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get a buildable Android project onto the Pixel 3 and answer one question with measurements: can the phone's speaker, mic, Silero VAD and Android TTS support interruptible conversation (barge-in) well enough to build Phases 1-4?

**Architecture:** One Gradle project at `android/` with a single `app` module (Kotlin, Jetpack Compose). All spike code lives in package `com.jessvb.tinytalk.spike` and is **throwaway**; keeping any of it is a new decision. The only piece designed to survive is the VAD speech-start/end state machine, written as pure Kotlin with JVM unit tests so Phase 1 can move it into the `core` module.

**Tech Stack:** Kotlin, Jetpack Compose, Gradle (wrapper-pinned), `AudioRecord` (`VOICE_COMMUNICATION`), `AcousticEchoCanceler`, `AudioTrack`, `android.speech.tts.TextToSpeech`, ONNX Runtime for Android, JUnit. Exact library versions: look up current stable versions (context7 or official docs) at implementation time; do not guess.

**Spec:** `docs/superpowers/specs/2026-10-19-android-demo-mode-client-design.md` (Phase 0, Risks, and "Further calls made by Claude").

## Global Constraints

- Native Kotlin + Jetpack Compose; no cross-platform framework.
- `android/` is a new top-level directory beside `ios/` and `server/`; do not modify `ios/` or `server/`.
- Secrets never committed: the repo is public. Baked-in keys (not used in Phase 0) will come from gitignored `android/local.secrets.properties` with a committed `.example`.
- Isolated environments: no global installs beyond Android Studio; Gradle version pinned by the wrapper; SDK in `~/Library/Android/sdk`.
- Pixel 3 (Android 9-12) is the target device; mic, speaker and AEC cannot be tested on an emulator, so verification is on the real phone.
- Phase 0 pass criteria (verbatim from spec): with the phone speaker (no headphones), Elsie's own voice does not trigger the VAD, and a child's interruption stops her within about a second, in a quiet room.
- If the spike fails, stop and report to the author; do not start Phase 1.
- Silero VAD uses the same model file as iOS (`ios/TinyTalkApp/TinyTalkApp/silero_vad.onnx`, 16 kHz, 512-sample windows + 64 samples of context, `state` shape `[2,1,128]`, inputs `input`/`state`/`sr`, outputs `output`/`stateN`).
- Starting values ported from iOS, to be re-tuned on-device (not trusted): speech threshold 0.5, attack 3 consecutive chunks, hangover 22 chunks.
- Commits are small, one per task or finer. Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Mic permission denied or revoked: the spike screen must say so, not crash or sit silent.
2. Device has no `AcousticEchoCanceler` or it fails to enable: the spike must report this plainly; it is itself a key finding.
3. No English TTS voice installed or TTS init fails: report it, don't hang.
4. VAD fed shorter or misaligned audio chunks (AudioRecord returns arbitrary read sizes): the framing code must emit exactly 512-sample windows and carry leftovers.
5. Barge-in while TTS is between sentences (queue empty) or mid-synthesis: stop must flush everything and not play stale audio afterward.

---

## File Structure

```
android/
  settings.gradle.kts, build.gradle.kts, gradle.properties, gradlew, gradle/wrapper/*
  .gitignore                          (build outputs, local.properties, local.secrets.properties, *.jks)
  local.secrets.properties.example    (placeholders only; unused in Phase 0)
  app/
    build.gradle.kts
    src/main/AndroidManifest.xml
    src/main/assets/silero_vad.onnx   (copied from iOS bundle)
    src/main/java/com/jessvb/tinytalk/
      MainActivity.kt                 (hosts SpikeScreen)
      spike/SpikeScreen.kt            (Compose: buttons + live log + metrics)
      spike/MicCapture.kt             (AudioRecord + AEC + framing to 512-sample windows)
      spike/SpeechDetector.kt         (pure Kotlin attack/hangover state machine)
      spike/SileroVad.kt              (ONNX Runtime wrapper: window -> probability)
      spike/SentenceTts.kt            (TextToSpeech -> per-sentence PCM -> AudioTrack queue)
      spike/BargeInSpike.kt           (wires capture + VAD + TTS; logs metrics)
    src/test/java/com/jessvb/tinytalk/spike/
      SpeechDetectorTest.kt
      FrameChunkerTest.kt
docs/superpowers/specs/2026-10-19-android-phase0-results.md   (written in Task 6)
```

---

### Task 1: Prerequisites and a hello-world APK on the Pixel 3

**Files:**
- Create: `android/` project skeleton listed above (Gradle files, `app/build.gradle.kts`, manifest, `MainActivity.kt` showing a Compose `Text("Tiny Talk spike")`), `android/.gitignore`, `android/local.secrets.properties.example`
- Modify: `.gitignore` (root) only if needed; `README.md` "Android (Pixel 3): secondary target" section to list real prerequisites (Android Studio, USB debugging, `adb`) and the exact build/install commands

**Interfaces:**
- Produces: package `com.jessvb.tinytalk`; `./gradlew assembleDebug` and `./gradlew test` work from `android/`; `MainActivity` as launcher activity (later tasks replace its content with `SpikeScreen`).

- [ ] **Step 1: Confirm the author has installed Android Studio and enabled USB debugging on the Pixel 3** (see "Setup the author does" below). Verify: `ls ~/Library/Android/sdk/platform-tools/adb` exists; `~/Library/Android/sdk/platform-tools/adb devices` lists the Pixel 3 as `device` (not `unauthorized`).
- [ ] **Step 2: Create the Gradle project** with `minSdk` 26, `targetSdk`/`compileSdk` = current stable, Compose enabled, Kotlin DSL, `namespace` and `applicationId` `com.jessvb.tinytalk`. Generate the Gradle wrapper (via Android Studio's bundled Gradle, or a one-time `gradle wrapper`), pinned to a current stable Gradle version. Point `sdk.dir` via an untracked `android/local.properties`.
- [ ] **Step 3: Build.** Run `cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/android-demo-mode/android && ./gradlew assembleDebug`. Expected: `BUILD SUCCESSFUL`, APK at `app/build/outputs/apk/debug/app-debug.apk`.
- [ ] **Step 4: Install and launch.** Run `~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk` then `adb shell am start -n com.jessvb.tinytalk/.MainActivity`. Expected: `Success`, and "Tiny Talk spike" shows on the phone.
- [ ] **Step 5: Update README's Android section** with the prerequisites and the commands used in Steps 3-4, with full paths per CLAUDE.md's rule against bare relative paths.
- [ ] **Step 6: Commit** (`feat(android): scaffold Gradle project and hello-world app (#88)`).

### Task 2: Framing and the speech-detector state machine (pure Kotlin, JVM tests)

**Files:**
- Create: `android/app/src/main/java/com/jessvb/tinytalk/spike/SpeechDetector.kt`, `.../spike/FrameChunker.kt`
- Test: `android/app/src/test/java/com/jessvb/tinytalk/spike/SpeechDetectorTest.kt`, `FrameChunkerTest.kt`

**Interfaces:**
- Produces:
  - `class FrameChunker(frameSize: Int = 512) { fun push(samples: ShortArray, length: Int): List<ShortArray> }` — returns zero or more complete frames; carries leftovers between calls.
  - `enum class SpeechEvent { None, SpeechStart, SpeechEnd }`
  - `class SpeechDetector(threshold: Float = 0.5f, attackChunks: Int = 3, hangoverChunks: Int = 22) { fun onProbability(p: Float): SpeechEvent; fun reset() }`

- [ ] **Step 1: Write failing tests.** `FrameChunkerTest`: pushing 300 then 724 samples yields exactly 2 frames of 512 and leaves 0 left over; pushing 100 yields none; frames preserve sample order. `SpeechDetectorTest`: two above-threshold chunks then a below -> no `SpeechStart` (attack needs 3 consecutive); three consecutive above -> exactly one `SpeechStart`; after speech, 21 below-threshold chunks -> no `SpeechEnd`, the 22nd -> exactly one `SpeechEnd`; an above-threshold chunk inside the hangover resets it; `reset()` returns to idle. (Mirrors iOS `VoiceActivityDetector`'s debouncing.)
- [ ] **Step 2: Run** `./gradlew test` from `android/`. Expected: FAIL (classes not defined).
- [ ] **Step 3: Implement** both classes to the signatures above; no Android imports.
- [ ] **Step 4: Run** `./gradlew test`. Expected: PASS.
- [ ] **Step 5: Commit** (`feat(android): frame chunker and speech detector state machine (#88)`).

### Task 3: Mic capture with echo cancellation, and the spike screen

**Files:**
- Create: `.../spike/MicCapture.kt`, `.../spike/SpikeScreen.kt`
- Modify: `AndroidManifest.xml` (`RECORD_AUDIO`), `MainActivity.kt` (show `SpikeScreen`)

**Interfaces:**
- Consumes: `FrameChunker` (Task 2).
- Produces: `class MicCapture(onFrame: (ShortArray) -> Unit, onLog: (String) -> Unit) { fun start(); fun stop(); val aecAvailable: Boolean; val aecEnabled: Boolean; val audioSessionId: Int }` — 16 kHz mono 16-bit `AudioRecord`, `MediaRecorder.AudioSource.VOICE_COMMUNICATION`, `AcousticEchoCanceler` (and `NoiseSuppressor` if available) attached when available, reads on a background thread, delivers exact 512-sample frames. `SpikeScreen` exposes a shared scrolling log (`onLog`) and a live level readout.

- [ ] **Step 1: Implement `MicCapture` and the permission flow.** Request `RECORD_AUDIO` at runtime; if denied, show "Microphone permission denied" and do not start (Review Focus 1).
- [ ] **Step 2: Log device facts on start:** `Build.MODEL`, `Build.VERSION.SDK_INT`, `AcousticEchoCanceler.isAvailable()`, whether `setEnabled(true)` succeeded, `NoiseSuppressor.isAvailable()`. Missing AEC is logged as `AEC UNAVAILABLE` (Review Focus 2).
- [ ] **Step 3: Build, install, run on the Pixel 3** (commands from Task 1). Tap "Start mic" and speak. Expected: the level readout moves with speech; log shows the device facts above.
- [ ] **Step 4: Commit** (`feat(android): mic capture with AEC and spike screen (#88)`).

### Task 4: Silero VAD on-device

**Files:**
- Create: `.../spike/SileroVad.kt`; copy `ios/TinyTalkApp/TinyTalkApp/silero_vad.onnx` to `android/app/src/main/assets/silero_vad.onnx`
- Modify: `app/build.gradle.kts` (ONNX Runtime for Android dependency)

**Interfaces:**
- Consumes: `FrameChunker` frames and `SpeechDetector` (Task 2); `MicCapture` (Task 3).
- Produces: `class SileroVad(context: Context) : AutoCloseable { fun probability(frame512: ShortArray): Float; fun reset() }` — normalizes int16 to float in [-1,1], prepends the previous 64 samples as context (576-sample input), threads `stateN` back into `state` (zeros `[2,1,128]` at reset), passes `sr` = 16000, per the iOS notes. Inference failure throws; callers log it.

- [ ] **Step 1: Implement `SileroVad`** per the interface; load the model from assets once.
- [ ] **Step 2: Wire into the spike screen:** each captured frame -> `SileroVad.probability` -> `SpeechDetector.onProbability`; log `SpeechStart`/`SpeechEnd` with timestamps and show live probability.
- [ ] **Step 3: Run on the Pixel 3.** Say a sentence, then stay silent. Expected: exactly one `SpeechStart` near the beginning of the sentence and one `SpeechEnd` about 0.7 s after it ends (22 chunks x 32 ms); silence and a tapped table produce no `SpeechStart`. Log the per-frame inference time; flag it if it approaches 32 ms (cannot keep real time).
- [ ] **Step 4: Commit** (`feat(android): Silero VAD via ONNX Runtime (#88)`).

### Task 5: Sentence-by-sentence TTS to AudioTrack

**Files:**
- Create: `.../spike/SentenceTts.kt`

**Interfaces:**
- Produces: `class SentenceTts(context: Context, onLog: (String) -> Unit) { fun speak(text: String); fun stop(); val isSpeaking: Boolean; fun close() }` — splits text into sentences, synthesizes each with `TextToSpeech.synthesizeToFile` (to app cache), decodes to PCM, and queues to a single `AudioTrack` (usage `USAGE_VOICE_COMMUNICATION`, same audio session as `MicCapture` where feasible so the AEC has the render reference). `stop()` cancels pending synthesis, flushes the queue and the `AudioTrack` so no stale audio plays afterward (Review Focus 5). Logs time from `speak()` to first audio written (first-sentence latency). If TTS init fails or no English voice exists, log `TTS UNAVAILABLE` and return; never hang (Review Focus 3).

- [ ] **Step 1: Implement `SentenceTts`** per the interface.
- [ ] **Step 2: Add a "Speak test paragraph" button** (a fixed ~5-sentence paragraph).
- [ ] **Step 3: Run on the Pixel 3** with headphones unplugged. Expected: speech starts, sentences play without gaps over about a second, "first audio" latency is logged. Record that latency.
- [ ] **Step 4: Commit** (`feat(android): per-sentence TextToSpeech playback (#88)`).

### Task 6: Barge-in spike, measurements, and the go/no-go

**Files:**
- Create: `.../spike/BargeInSpike.kt`; `docs/superpowers/specs/2026-10-19-android-phase0-results.md`
- Modify: `SpikeScreen.kt` (a "Barge-in test" button)

**Interfaces:**
- Consumes: `MicCapture`, `SileroVad`, `SpeechDetector`, `SentenceTts`.
- Produces: `class BargeInSpike(...) { fun start(paragraph: String); fun stop() }` — starts TTS and keeps mic + VAD running. Logs (a) every `SpeechStart` that occurs while TTS is audibly playing and nobody is speaking (a false trigger from Elsie's own voice), and (b) for each real interruption, the milliseconds from `SpeechStart` to `SentenceTts.stop()` completing and audio actually silent.

- [ ] **Step 1: Implement `BargeInSpike`.** On `SpeechStart` during playback, call `SentenceTts.stop()` and log the stop latency.
- [ ] **Step 2: Run the on-device test script** on the Pixel 3, phone speaker, no headphones, quiet room, phone on a table about 40 cm away:
  1. **False-trigger run:** start the test and stay completely silent for the whole paragraph, three times. Count `SpeechStart` events (target: 0).
  2. **Interruption run:** start, then say "stop, wait!" two sentences in, five times. Record each stop latency (target: about 1 s or under every time).
  3. **Volume check:** repeat run 1 at medium and at maximum media volume.
  4. Also log `AEC UNAVAILABLE` or enabled status from Task 3.
- [ ] **Step 3: Write `2026-10-19-android-phase0-results.md`** with the device facts, first-audio latency, VAD inference time, false-trigger counts per volume, stop latencies, AEC status, and a one-line verdict **GO** or **NO-GO** against the pass criteria. On NO-GO, list the options from the spec (push-to-talk, headphones-recommended mode, drop Pixel 3) with what the numbers suggest, and stop.
- [ ] **Step 4: Run** `./gradlew test` (all JVM tests pass) and commit (`feat(android): barge-in spike and Phase 0 results (#88)`). Push the branch.
- [ ] **Step 5: Report to the author** the verdict and the numbers; on GO, propose planning Phase 1 next.

---

## Setup the author does (before Task 1, Step 1)

1. Install Android Studio: `brew install --cask android-studio` (or download from developer.android.com/studio). Open it once and finish the setup wizard so it downloads the Android SDK and platform-tools into `~/Library/Android/sdk`.
2. On the Pixel 3: Settings > About phone > tap "Build number" 7 times; then Settings > System > Developer options > turn on "USB debugging".
3. Plug the Pixel 3 into the Mac with a USB cable and accept the "Allow USB debugging?" prompt on the phone.

## Self-review

- **Spec coverage:** Phase 0 of the spec (toolchain, hello-world on Pixel 3, capture + AEC, Silero VAD, TTS playback with barge-in, go/no-go with the spec's pass criteria and its NO-GO handling) maps to Tasks 1-6. Phases 1-4 are deliberately not in this plan; they depend on the Task 6 verdict.
- **Type consistency:** `FrameChunker`/`SpeechDetector` (Task 2) are the ones consumed in Tasks 3, 4 and 6; `MicCapture.audioSessionId` (Task 3) is what `SentenceTts` uses in Task 5.
- **Review Focus:** items 1-5 are exercised in Tasks 3 (1, 2), 5 (3, 5), 2 (4), and 6 (5).
