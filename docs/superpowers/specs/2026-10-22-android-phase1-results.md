# Android Phase 1 (voice loop): results

Issue #88, draft PR #93, branch `worktree-android-demo-mode`. Plan:
`docs/superpowers/plans/2026-10-21-android-phase1-voice-loop.md`. Spec:
`docs/superpowers/specs/2026-10-19-android-demo-mode-client-design.md`.

Status: built and reviewed silently. **Nothing audible has been run.** Task 4b-B
(installing the on-device recognizer) is also still pending.

## What was built (by task)

1. Gradle `:core` module plus audio basics (frame chunker, speech events, speech detector).
2. `Safety`: kid-safe word lists, matched against the iOS `Safety.swift`.
3. Story arc and conversation state (`StoryArc`, `DemoConversation`), stop-phrase handling.
4. Groq chat client and Groq Whisper client, WAV encoding, typed key errors.
5. Animal-fact tracker and client (232-entry animal table, same as iOS).
6. `DemoSession`: per-turn orchestration, safety gate, key-problem mapping, turn timeout.
7. Key handling: build-time keys, Keystore-encrypted overrides, key resolver, STT mode persistence.
4b-A. `TranscriptCleaner` (collapses a child's repeated words).
8. `VoiceLoop`: mic capture, voice detection with pre-roll, spoken replies, interruptions.
9. Compose design system, Navigator, consent store, Onboarding and Landing screens.
10. Story and Settings screens, ViewModel and `LoopCoordinator`, key banners, Better listening dialog, Reset consent.

Not built: Task 4b-B (on-device Whisper tiny.en recognizer; until then the loop
refuses to start in on-device mode), storybook, Library, illustrations.

## Silent verification (2026-10-22, Pixel 3 install only, app not launched)

- `./gradlew :core:test test assembleDebug --rerun-tasks`: BUILD SUCCESSFUL.
- `:core` JVM tests: 147 run, 0 failures, 0 skipped.
- App JVM unit tests: 95 run, 0 failures, 0 skipped.
- Debug APK: 155,194,076 bytes (about 155 MB; multi-ABI native libraries).
  Expected to grow about 130 MB when the on-device recognizer is added.
- APK installed with `adb install -r` on serial 8BDX18J4R (Success), not launched.
- Secret hygiene: the only secret-named tracked file that is a config file is
  `android/local.secrets.properties.example`; `android/local.secrets.properties`
  is gitignored (`android/.gitignore:4`); no `gsk_` strings, no keystore or
  `.jks` files, no long token-like strings in tracked Android files; nothing
  large tracked under `android/stt-spike/downloads` or `testdata/wav`.
- Earlier silent checks from the task reviews: word lists match iOS, animal
  table matches iOS, consent wording verbatim, voice-loop replay test on the
  phone (silent, from a file): attack 64-96 ms, at least 504 ms of lead-in kept.

## NOT verified (everything audible or on-screen)

- First word with a real child voice (clipping).
- Elsie's own sound being picked up and interrupting her (echo self-barge-in).
- Spoken-reply timing when interrupting (SentenceTts).
- A real end-to-end conversation.
- The on-device recognizer (not installed).
- Layout at large font sizes and in dark mode on the device (the screen was off
  during earlier attempts).

## Carry-over checklist for the audible run

1. Mic loss, then Retry.
2. Story -> Settings -> Story keeps the transcript; Landing -> Story clears it.
3. New Story while Elsie is speaking.
4. Elsie self-barge-in via echo (does her tail audio leak into the next utterance?).
5. First-word clipping with a real child voice.
6. SentenceTts is built on a background thread and ready before first use.
7. Consent -> microphone permission flow (and denial).
8. Key problem: banner pointing to Settings plus Elsie's spoken friendly line (try a deliberately wrong key).
9. Better listening dialog (turning it on, off, and cancelling).
10. Reset consent (returns to onboarding, Better listening is turned off).
11. From the plan: 3-turn conversation, interrupt once, Wi-Fi off mid-turn (retry line, recovery), background and return.

## Results (author run)

TBD (author run). Nothing here is measured yet.

- What worked: TBD
- What did not: TBD
- Voice detection retuning needed for child voices: TBD
- Speech stalls seen: TBD

## FIX BEFORE MERGE (final review to triage)

- Errors thrown inside the spoken-reply audio tasks are uncaught and would crash
  the app; wrap them and log only the error class (also the stop-failure log
  prints the message, not the class).
- A wedged audio task leaves the app stuck on "speaking" with no error; add a
  per-run deadline.
- A stale "halt" coroutine can kill a fresh run; add a run counter.

## Deferred minor items (plain language)

Build and tests
- Dependency versions are literals in build files; no JVM toolchain pinned; JUnit declared twice.
- Safety: no overlap test; word lists not mechanically compared to the Swift file.
- Conversation: several stop-phrase variants and edge cases untested.
- Chat/STT clients: no response size cap; a few WAV edge cases untested; a rare
  non-network error could leave a request unresumed (the session turn timeout is the backstop).
- Animal client borrows Groq-named helpers; its lock is held across a fetch, so a reset can wait up to 15 s; no concurrency tests.
- DemoSession: errors can be queued if the owner never closes it; a hung fact reset can eat into later turns' time; a superseded turn leaves the child's line without an agent line (matches iOS); a reply is kept in history even if its speech is interrupted (differs from iOS, accepted).
- Keys: every read decrypts from the Keystore (no cache); a multi-line key would break the build; losing the Keystore silently drops saved overrides (by design); a stale doc comment.
- Cleaner: doc line on child repeated words, and "Yes, yes, yes!" untested; fully doubled legit replies ("bye bye") collapse to one word (accepted).
- VoiceLoop: brief LISTENING->IDLE flicker on mic failure; Elsie's tail audio may leak into an interruption; the story-finished event has no turn id; switching audio routing on each interruption while capturing (from Phase 0); callbacks run under a lock (documented rule: do not block); `close()` does not wait for cleanup.
- UI: gold-on-wood small text contrast about 2.6-3.4:1 (iOS palette); Elsie's mood not exposed to TalkBack; gear glyph may render as an emoji; permission launcher could be hoisted; consent/mode saves on the main thread.
- Settings/Story: voice-list retry restarts on each Settings visit; New Story restart may briefly open the mic while backgrounding; a stale reply could land in a new transcript (narrow); a key banner race when saving then going Back; a few untested branches (generation gate, no-consent message, real-thread cleared check); Story -> Settings -> Story clears a child-set pause (intentional).
