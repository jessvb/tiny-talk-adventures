# Android Demo-Mode Client — Design Spec

Issue: #88. Status: approved by the author 2026-10-19.

## Context and intent

Tiny Talk Adventures exists today as an iPhone app plus a home-Mac server.
Its away-from-home **demo mode** (specs `2026-09-09-away-from-home-demo-mode`
and `2026-09-19-demo-mode-parity`) already runs the whole product without the
Mac: Groq for the chat model and Whisper speech-to-text, Cloudflare Workers AI
(FLUX) for page illustrations, the phone's own text-to-speech, and a local,
file-backed storybook.

The author wants to put the app in the hands of **parents who live in other
cities** (not local to the author, so no hand-holding, no shared WiFi, no home
server) so their kids can try it and the author can learn from it. Those
parents use Android phones, so this sub-project builds a **native Android
app that does everything iOS demo mode does**, distributed as a **sideloaded
APK**. Server mode is out of scope.

The README has long listed Android (Pixel 3) as a deferred secondary target;
iOS demo mode being complete and on-device confirmed is what unblocks it.

## Goals

1. A parent installs an APK, opens it, and a child can hold a spoken story
   conversation with Elsie with **no setup beyond granting the microphone
   permission** (the author's keys are baked in).
2. Feature parity with iOS demo mode: Onboarding, Landing, Story (voice loop,
   interrupt/barge-in, "Finish this story"), The End, Library, Reading
   (including 🔊 page narration), Settings (story length, page count, voice,
   keys), kid-safe content handling, animal facts, object recognition (camera),
   and page illustrations.
3. A parent can replace the baked-in keys in Settings (Groq; Cloudflare
   account id + token; optional API Ninjas animal-facts key). Clearing an
   override falls back to the baked-in key.
4. Behaves acceptably on the Pixel 3 (the author's only Android device;
   older, slower hardware is the main audio risk).
5. Logic stays aligned with iOS: same prompts, same safety word-list
   behavior, same story arc and storybook rewrite rules, so a story from the
   Android app feels like one from the iPhone.

## Non-goals and anti-goals

- Server mode, the WebSocket protocol client, Mac discovery/connection UI.
- Sync-to-home. Testers have no home server; stories live on the phone only.
- Play Store listing, auto-update, crash reporting backends, analytics,
  accounts, or any production-distribution concern (CLAUDE.md: pet-project
  scope).
- Kotlin Multiplatform / sharing code with the Swift package. The Swift code
  is hand-ported; the two codebases are kept aligned by reading, not tooling.
- Any change to iOS or server behavior. (Prompts/wordlists are *read* from
  those sources of truth; if one is found wrong, file an issue.)
- Tablets, landscape, or accessibility beyond what Compose gives for free.
- **Anti-goal:** shipping a build where the shared key is committed to the
  repo (the repo is public) or where an uncaught missing-key state leaves a
  child on a silent, dead screen.

## Constraints

Inherited from CLAUDE.md, applied to this platform:

- **Free/local-first.** Demo mode already uses Groq/Cloudflare free tiers;
  Android keeps to that. No new paid service.
- **Privacy.** This is a real step beyond "data stays on household devices":
  with the shared key, *story text from other families' children is sent to the
  cloud chat model (Groq) and story prompts to Cloudflare*, billed against the
  author's key; speech is recognised on the phone by default (see the
  2026-10-21 decision below), unless a parent turns on the optional cloud
  "better listening" switch. This was accepted for the author's own household in demo mode; for
  outside testers it must be **disclosed plainly** in Onboarding/Settings and
  in the tester instructions, and testers must be people who agreed to try
  it. No audio is stored by the app beyond what iOS demo mode stores.
- **Kid-safe content.** Port `Safety.swift` (deterministic word filter) and
  all guidance prompts verbatim in behavior; the same retry-on-unsafe logic.
- **Isolated environments.** No global installs beyond Android Studio itself.
  The Gradle wrapper pins the Gradle version; the JDK is Android Studio's
  bundled one (or a pinned one); the SDK lives under `~/Library/Android/sdk`.
  Nothing is `pip`/`brew`-installed into system Python.
- **Secrets.** The baked-in keys come from a gitignored local file (e.g.
  `android/local.secrets.properties`, with a committed `.example`), read by
  Gradle into `BuildConfig` — mirroring iOS's `Local.xcconfig` pattern. Anything
  in an APK is extractable, so the author should use **dedicated, revocable
  keys with limits** for the test round; the tester instructions say so to the
  author, not to testers.

## Decisions made with the author

- **Native Kotlin + Jetpack Compose**, not a cross-platform framework. (Author
  has no Kotlin experience and delegated the implementation to Claude; the
  author's own choice was to build native.)
- **Baked-in keys + Settings override.** Author's words: "bake my key in, but
  also allow the parents to change it in settings."
- **Distribution:** a signed APK sent directly (sideloaded).
- **Scope:** everything iOS demo mode does, minus server mode.

## Decisions confirmed by the author after builder review

(The author replied "Go ahead" to these two proposals.)

- **Consent gate.** Onboarding includes a one-time parent "I agree" screen,
  in plain wording written by the builder, before the mic or any network call.
  It states that the child's speech and story text are sent to Groq and
  Cloudflare using the app author's key (or the parent's own, if set).
- **Exhausted/revoked/rate-limited key.** Elsie says a short friendly line
  (e.g. asks a grown-up for help) and the parent sees an error banner pointing
  to Settings to enter their own key. No kill switch beyond revoking the key.
  Missing, invalid (401/403), and rate-limited (429) keys are all handled, not
  just missing.

## Decision confirmed by the author 2026-10-21: speech recognition runs on the phone

(Replaces the original plan to send audio to Groq Whisper.)

- **The child's voice stays on the phone.** The default speech-to-text is an
  on-device model bundled in the app (candidates compared in a Phase 0b spike
  below). Only the resulting **text** is sent to the cloud chat model.
- **Optional "better listening" switch** in Settings that sends audio to Groq
  Whisper instead. Off by default, clearly labelled as sending the child's
  voice to the cloud. It is the escape hatch if on-device accuracy on child
  voices proves too poor.
- The app never writes recordings to disk (audio is held in memory only).
- **Consent wording** (approved draft, "the cloud" instead of vendor names):
  the parent is told the child's voice is turned into text on the phone and not
  saved, that only the text of the story conversation is sent to the cloud so
  Elsie can reply, that finished stories stay on the phone, and that the
  author's account pays for the cloud service until the parent enters their own
  key. Any claim about the cloud provider's retention or training policy goes in
  only once verified against the provider's current documentation, with a source.
- **Phase 0b (silent STT spike) precedes Phase 1:** compare 2-3 on-device
  candidates on the Pixel 3 for speed and accuracy using audio files with no
  playback; real child-voice accuracy needs the author's later testing.

## Decisions made by Claude (the author may override)

- **Project location:** a new top-level `android/` directory (sibling to
  `ios/` and `server/`), single Gradle project, two modules:
  - `core` — pure Kotlin/JVM (no Android imports): the ported `TinyTalkCore`
    logic (`DemoConnection`, conversation/story-arc, `StorybookWriter`,
    `Safety`, animal facts, `DemoStoryLibrary`/store, Groq/Cloudflare clients,
    wire-event types). Unit-tested on the Mac with plain `./gradlew test` — no
    device needed, which matters because there is no CI and no emulator audio.
  - `app` — Android specifics: Compose screens, audio capture/playback,
    VAD, TextToSpeech, camera + classifier, storage, settings.
- **Port fidelity:** keep the iOS architecture (a session coordinator driving
  a connection that emits the same event vocabulary, with `DemoConnection` as
  the only connection) rather than redesigning. It's the proven, on-device-
  confirmed design, and parity bugs are cheaper to diagnose when the shapes
  match. Server-only wire messages are dropped from the Android vocabulary
  rather than no-op'd. The iOS "force an explicit decision for every message"
  test has no analogue needed.
- **HTTP/JSON:** OkHttp + kotlinx.serialization; coroutines/Flow in place of
  Swift concurrency/AsyncStream.
- **VAD:** reuse the same Silero `.onnx` file via ONNX Runtime for Android.
- **Audio:** `AudioRecord` with `VOICE_COMMUNICATION` source (enables platform
  AEC/NS where the device provides it, the analogue of iOS `.voiceChat`) and
  `AudioTrack`; Oboe only if latency or AEC proves unacceptable on the Pixel 3.
- **TTS:** Android `TextToSpeech`, rendering to audio (`synthesizeToFile`) so
  playback goes through the same `AudioTrack` path that barge-in controls.
  Settings' voice picker lists installed English voices.
- **Object recognition:** a small on-device ImageNet classifier (TFLite or
  ONNX Runtime) behind the same confidence-threshold logic as
  `ObjectRecognition.swift`. Model choice to be verified against current
  information during planning.
- **Key storage:** user-entered overrides in EncryptedSharedPreferences (the
  Keychain analogue); baked-in keys from `BuildConfig`.
- **Persistence:** app-private files in the same JSON shape as
  `LocalStoryStore`.
- **minSdk:** the lowest level the chosen libraries allow (expect 26–28);
  target the current stable SDK. Pixel 3 tops out at Android 12 and must work.
- **Tooling:** the author installs Android Studio (gives JDK + SDK manager +
  logcat + device mirroring); builds and tests are driven by `./gradlew` from
  the terminal.

## Further calls made by Claude (after builder review; the author may override)

- **iOS is the source of truth.** Authoritative sources: `ios/TinyTalkCore/`
  (`DemoConnection`, `StorybookWriter`, `Safety`, `AnimalFacts`, `StoryArc`,
  `IllustrationPass`), `ios/TinyTalkApp/` for screens, and specs
  `2026-09-09-away-from-home-demo-mode` and `2026-09-19-demo-mode-parity`,
  read as of the port date. On-device-tuned numbers (VAD thresholds,
  barge-in timing, hang-guard timers, TTS pacing) are **starting values to
  re-tune on the Pixel 3**, not constants to trust. Prompts, safety lists and
  story-arc rules are ported verbatim.
- **Phase 0 go/no-go.** Pass means: with the phone speaker (no headphones),
  Elsie's own voice does not trigger the VAD, and a child's interruption stops
  her within about a second, in a quiet room. If it fails, work stops and the
  author decides between push-to-talk, a headphones-recommended mode, or
  dropping the Pixel 3 as a target. Phases 1-4 are planned assuming a pass.
- **TTS path.** Synthesize per sentence (`synthesizeToFile`, then queue to the
  `AudioTrack`) so the first sentence starts quickly and barge-in can drop the
  rest of the queue. Some start-up latency is acceptable; Phase 0 measures it.
- **Object recognition.** A different model than iOS's FastViT is acceptable.
  The threshold logic is ported but its numbers are re-tuned on-device; the
  weave-in guidance only needs a label string, so the exact label set need not
  match.
- **Signing.** The author holds a single release keystore, kept outside the
  repo and backed up. One APK version per test round; testers reinstall for
  updates. Tester instructions cover Android's "install unknown apps" step and
  the Play Protect warning.

## Phasing

Each phase ends with something installable on the Pixel 3 and an on-device
test script (CLAUDE.md's "Testing changes on-device" applies to every phase).

- **Phase 0 — Toolchain + audio spike.** Android Studio set up, a hello-world
  app on the Pixel 3, then the riskiest piece in isolation: capture with AEC,
  Silero VAD, and TTS playback with barge-in. Output is a go/no-go on audio
  quality, and the audio parameters. *Throwaway spike code; keeping it is a
  new decision.*
- **Phase 1 — Voice loop.** `core` module (conversation, Groq chat + Whisper,
  safety, story arc, animal facts) with JVM tests; Onboarding, Landing, Story,
  and Settings (keys, voice) screens; the spoken loop end to end.
- **Phase 2 — Storybook.** Finish-this-story, storybook rewrite, The End,
  local library, Library and Reading screens, 🔊 page narration, story-length
  and page-count settings.
- **Phase 3 — Pictures and camera.** Cloudflare FLUX illustrations (including
  the cold-start timeout, same-animal consistency, and resume-interrupted
  handling iOS needed), and object recognition.
- **Phase 4 — Shareable build.** Release-signed APK, keystore handling,
  tester instructions (install steps, the privacy disclosure, how to send
  feedback), and a README/CLAUDE.md update.

## What "done" looks like

The author hands the APK to a parent; the child talks to Elsie, finishes a
story, sees The End, finds it in Library, reads it with pictures, and 🔊 reads
a page aloud — all without the author's involvement. Confirmed on the Pixel 3,
and ideally on one non-Pixel Android phone via a friendly tester.

## Risks

- **Audio/echo/barge-in on Pixel 3-class hardware** — the biggest unknown;
  Phase 0 exists to retire it early. Fallback: push-to-talk or
  headphones-recommended mode (a scope decision for the author if reached).
- **Android TTS quality varies** by phone and installed engine; no control
  over what testers have. Mitigation: a clear "voices" setting and tester note.
- **Fragmentation** — only one test device. Testers' phones may differ.
- **Shared-key cost/abuse** — rate limits and revocation are the only guard.
- **Divergence from iOS over time** — accepted; this is a one-shot port.

## Left to the builder

Library/versions, module internals, exact audio parameters, UI details beyond
matching the iOS screens' look and behavior, the object-recognition model,
test breakdown, and the plan itself (to be produced with
`superpowers:writing-plans`).
