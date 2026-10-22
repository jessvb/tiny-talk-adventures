# Android Phase 1 (voice loop): results

Issue #88, draft PR #93, branch `worktree-android-demo-mode`. Plan:
`docs/superpowers/plans/2026-10-21-android-phase1-voice-loop.md`. Spec:
`docs/superpowers/specs/2026-10-19-android-demo-mode-client-design.md`.

Status: built and reviewed silently. **Nothing audible has been run.** Task 4b-B
(the on-device recognizer) is now installed and verified silently on the Pixel 3
from WAV files; it has not yet heard a live voice.

## What was built (by task)

1. Gradle `:core` module plus audio basics (frame chunker, speech events, speech detector).
2. `Safety`: kid-safe word lists, matched against the iOS `Safety.swift`.
3. Story arc and conversation state (`StoryArc`, `DemoConversation`), stop-phrase handling.
4. Groq chat client and Groq Whisper client, WAV encoding, typed key errors.
5. Animal-fact tracker and client (232-entry animal table, same as iOS).
6. `DemoSession`: per-turn orchestration, safety gate, key-problem mapping, turn timeout.
7. Key handling: build-time keys, Keystore-encrypted overrides, key resolver, STT mode persistence.
4b-A. `TranscriptCleaner` (collapses a child's repeated words).
4b-B. `OnDeviceTranscriber`: Whisper tiny.en (int8) through sherpa-onnx, on the phone. The
   model is packaged in the APK, loaded at app start in the background, and the Story
   screen says "Elsie is getting her ears ready" until it is loaded (then listening starts
   by itself) or a parent-facing notice if it fails to load.
8. `VoiceLoop`: mic capture, voice detection with pre-roll, spoken replies, interruptions.
9. Compose design system, Navigator, consent store, Onboarding and Landing screens.
10. Story and Settings screens, ViewModel and `LoopCoordinator`, key banners, Better listening dialog, Reset consent.

Not built: storybook, Library, illustrations.

## Silent verification (2026-10-22, Pixel 3 install only, app not launched)

- `./gradlew :core:test test assembleDebug --rerun-tasks`: BUILD SUCCESSFUL.
- `:core` JVM tests: 147 run, 0 failures, 0 skipped.
- App JVM unit tests: 95 run, 0 failures, 0 skipped.
- Debug APK: 155,194,076 bytes (about 155 MB; multi-ABI native libraries).
  With the on-device recognizer and speech model included, the debug APK is
  about 139 MB (down from 155 MB), because only the arm64 native libraries
  (what the Pixel 3 uses) are bundled now.
- APK installed with `adb install -r` on serial 8BDX18J4R (Success), not launched.
- Secret hygiene: the only secret-named tracked file that is a config file is
  `android/local.secrets.properties.example`; `android/local.secrets.properties`
  is gitignored (`android/.gitignore:4`); no `gsk_` strings, no keystore or
  `.jks` files, no long token-like strings in tracked Android files; nothing
  large tracked under `android/stt-spike/downloads` or `testdata/wav`.
- Task 4b-B (2026-10-22, silent, headless instrumented tests reading WAV files,
  nothing recorded or played): debug APK now 139,322,136 bytes (arm64 only, model
  included); exactly one `lib/arm64-v8a/libonnxruntime.so` in the APK. On the Pixel 3:
  model load 1.18 s (1.86 s on the first launch after an install, which also unpacks
  the model), warm decodes 0.64-0.87 s for 1.5-2.7 s of speech, 3/3 synthetic adult
  WAVs transcribed word-for-word, a cancelled decode returns in 58 ms, and Whisper and
  the SileroVad voice detector run side by side in one process (replay attack 64 ms).
- Earlier silent checks from the task reviews: word lists match iOS, animal
  table matches iOS, consent wording verbatim, voice-loop replay test on the
  phone (silent, from a file): attack 64-96 ms, at least 504 ms of lead-in kept.

## NOT verified (everything audible or on-screen)

- First word with a real child voice (clipping).
- Elsie's own sound being picked up and interrupting her (echo self-barge-in).
- Spoken-reply timing when interrupting (SentenceTts).
- A real end-to-end conversation.
- The on-device recognizer with a live voice, especially a child's (only synthetic
  adult voices from files have been tried), and how long the first reply takes after
  opening the app.
- Layout at large font sizes and in dark mode on the device (the screen was off
  during earlier attempts).

## Audible run: step-by-step script

This is the hands-on test. Each scenario says what it checks in plain words,
what to do, what you should see or hear, and what to note if it does not
happen. Button names are as they appear in the app (they may differ by a word).
Do the scenarios in order; later ones assume the earlier setup. Write down
anything odd, with roughly what time it happened, so the phone's log can be
read afterwards. The wording "pass" below means "this is what we hope to see".

### A. Before you start

1. **Give the app a key to think with.** Elsie's replies come from a cloud
   chat model that needs a Groq key. There is no key in the app until you
   supply one (the repo is public, so a key can never be committed). Two ways:
   - **Quickest, no rebuild:** open the app, go to **Settings** (the gear), find
     the **Groq key** field, paste your key, and save. The status line changes
     from "no key" to "Using your key". This is stored encrypted on the phone.
   - **Built into the app (what you asked for as the default):** on the Mac,
     copy `android/local.secrets.properties.example` to
     `android/local.secrets.properties` (same folder), put your key after
     `GROQ_API_KEY=` and save. That file is ignored by git. Then rebuild and
     reinstall the app (the key is baked in at build time, so changing the file
     does nothing until you rebuild). Use a dedicated key with a usage limit
     that you can revoke, because anything inside an APK can be pulled out.
   Either way the message "Elsie needs a key to think" disappears once a key
   exists. (Until you do one of these, that message is the app working as
   designed.)
2. **Listening on the phone.** In the default mode the app turns your child's
   voice into words on the phone (Better listening off). Right after the app
   opens this takes a few seconds to get ready: if you reach the Story screen
   quickly it may say "Elsie is getting ready" with a note about getting her ears
   ready. Pass: that note disappears by itself within a few seconds and she starts
   listening, without leaving the screen. If instead it says "Elsie can't listen"
   with a note to close and reopen the app, note it (on-phone listening failed to
   load); as a stand-in you can turn on **Settings > Better listening** (this sends
   the voice to the cloud, so only do that for testing).
3. **Prepare the phone and room.** Quiet room, phone flat on a table about
   40 cm (a ruler length and a bit) from you, headphones unplugged, media
   volume at about the middle. Close other apps that use the microphone.
4. **Start from a clean slate** (optional but recommended): on the Mac run
   `~/Library/Android/sdk/platform-tools/adb shell pm clear com.jessvb.tinytalk`
   so the app behaves like a first launch (this also forgets any key you typed
   into Settings, so do it BEFORE step 1).

### B. First launch and permission

5. **Consent screen.** Open the app. You should see a screen titled
   "Before we start" with the paragraph about the voice being turned into words
   on the phone. Check that it does not mention a company name, and that
   "Not now" does nothing except show "Nothing is sent until you agree."
   Pass: you cannot get past this screen without tapping **I agree**.
6. **Microphone permission.** After **I agree**, Android asks to allow the
   microphone. Tap **Allow** (the "only while using the app" choice is fine).
   Pass: you land on the Landing screen and nothing is spoken yet.
7. **Permission denied (optional second pass).** Do step 4 again, repeat, and
   this time tap **Don't allow**. Pass: the app still opens; going to the Story
   screen shows an "Allow microphone" (or "Microphone unavailable") message with
   a button, instead of silence. Tapping the button asks again.

### C. A normal conversation

8. **Start a story.** Landing > **Create a Story**. Pass: the screen stays on,
   Elsie's picture looks like she is listening, and the transcript is empty.
   There is a **Pause** / **Listen** button at the bottom to stop and restart
   listening.
9. **Three turns.** Say, clearly and not too fast, "Once upon a time there was
   a little fox." Wait. Pass: your words appear in the transcript; Elsie's
   picture shows she is thinking, then speaking; Elsie says one to three short
   sentences and usually asks what should happen next; her words also appear in
   the transcript. Answer twice more ("The fox found a red balloon", "It floated
   away"). Pass: she keeps the story going and the replies are gentle.
   - Note how long the wait is between you stopping and her starting.
10. **A fact about an animal.** In one turn mention a real animal ("a
    penguin"). Pass: within a turn or two Elsie may weave in a true fact about it
    (needs no extra key, but a fact only appears if one can be fetched).

### D. Interrupting and being heard

11. **Interrupting Elsie.** While she is mid-sentence in a longer reply, say
    "Stop! A dragon!" Pass: Elsie stops talking almost at once (about a second),
    your words appear in the transcript, and she answers the dragon.
    Note: if she keeps talking over you, or stops but your words are missing.
12. **The first word is not clipped.** After Elsie finishes, start talking the
    instant she stops. Say a sentence beginning with a clear first word, such as
    "Purple dragons like cake." Pass: the transcript starts with "Purple"
    (not "dragons like cake"). Try this five times; note how often the first
    word goes missing. If you can, have a child try it too, because a child's
    voice is the real test.
13. **Elsie must not interrupt herself.** Ask for a long story part, then stay
    completely silent and do not touch the phone while she speaks the whole reply.
    Pass: she finishes without cutting herself off and without a stray extra line
    appearing in the transcript. Repeat once with the volume turned all the way
    up. Fail sign: she stops mid-sentence by herself, or your transcript shows
    words you did not say (her own voice being heard).

### E. When things go wrong (these should be visible, never silent)

14. **A wrong key.** Settings > Groq key > type a junk word (for example
    `wrong`) > save, then go back to the story and say something. Pass: Elsie
    says "Hmm, I can't think right now. Could you ask a grown-up to help me?"
    and a banner tells a grown-up to open Settings. Then Settings > **Use
    built-in key** (or paste your real key) and speak again. Pass: the banner
    clears after the next good reply.
15. **No internet.** Mid-story, switch the phone to airplane mode, then speak.
    Pass: after a short wait Elsie says "Oops, my thinking slipped. Let's try
    that again in a moment!" and a retry banner shows. Turn airplane mode off and
    speak again. Pass: it recovers and the banner clears after the next reply.
16. **Microphone taken away, then "Try again".** (This is what "mic loss, then
    Retry" meant.) It tests what happens if another app grabs the microphone in
    the middle of a story, such as a phone call or a voice recorder. While in the
    Story screen, start a recording in another app (or ask someone to call the
    phone), then return to Tiny Talk. Pass: instead of sitting there silently,
    the Story screen shows "Microphone unavailable" with a **Try again** button.
    Close the other app, tap **Try again**, and speak. Pass: listening resumes.
17. **Leaving and coming back.** Mid-story press the phone's Home button, wait
    ten seconds, and reopen the app. Pass: it returns to the story and listening
    resumes. Also leave the Story screen open and untouched for two full minutes.
    Pass: the screen does not turn off by itself.

### F. Moving around the app

18. **Settings in the middle of a story.** In a story with a few lines in the
    transcript, tap the gear (Settings), then Back. Pass: the same transcript is
    still there. Then go Back to Landing and tap **Create a Story** again. Pass:
    the transcript is empty (a new story).
19. **New Story while Elsie is talking.** While she is mid-reply, tap **New
    Story**. Pass: she stops, the transcript clears, and nothing from the old
    story appears or is spoken afterwards.
20. **Better listening.** Settings > turn on **Better listening**. Pass: a
    message explains your child's voice would be sent to the cloud, with a way to
    cancel. Tap cancel and check the switch is still off. Turn it on and confirm,
    speak once, then turn it off again.
21. **Reset consent.** Settings > **Reset consent**. Pass: you are back at the
    "Before we start" screen, and when you look at Settings after agreeing again,
    Better listening is off.

### G. Things I will read from the phone's log afterwards

Roughly when each odd thing happened (item 11-13 especially), the first reply
delay after launch (the speech engine takes a few seconds the first time), and
whether any "Microphone unavailable" or crash occurred. You do not need to read
the log; just note the times.

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
