# Android Storybook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A finished Android story becomes a saved, titled, paged storybook the child can find in a Library, read page by page with 🔊 narration, and reach via an automatic The End screen; plus "Finish this story" and parent-set story length.

**Architecture:** Pure-Kotlin units in `:core` (store, writer, library, settings) behind small interfaces; `DemoSession` gains a concluding path and emits the finished story's data; the ViewModel owns a `StoryLibrary` and feeds new Compose screens. Text-only pages (illustrations are a later spec).

**Tech Stack:** Kotlin, coroutines, `kotlinx.serialization` JSON (already a `:core` dependency, used by `GroqChatClient`; it works on both JVM and Android), Jetpack Compose (Material3 + `HorizontalPager`).

**Spec:** `docs/superpowers/specs/2026-11-04-android-storybook-design.md` (read it first). iOS sources of truth to port: `ios/TinyTalkCore/Sources/TinyTalkCore/{StorybookWriter,LocalStoryStore,DemoStoryLibrary,TheEndLookup}.swift`, `ios/TinyTalkApp/TinyTalkApp/{LibraryView,ReadingView,TheEndView}.swift`, and their tests under `ios/TinyTalkCore/Tests`.

## Global Constraints

- Free/local only; story text goes only to Groq (already consented) and never into logs (log class names only).
- Defaults: story length 7 turns (range 4–12), storybook pages 5 (range 3–10); clamp on read.
- Copy is verbatim from iOS: "Your Stories", "No stories yet — make one with me first!", "+ New story" (iOS shows "+" and "New story"), "Elsie is still writing this one…", "Couldn't finish this storybook", "You wrote a whole story!", "The End.", "Read it now", "Back home", "PAGE n", "swipe to turn the page", "Finish this story".
- Epilogue is ALWAYS `"And one true thing we learned about the {animal}: {fact}"` from the first shared fact, or none; the model's epilogue is ignored.
- Android regex has no `UNICODE_CHARACTER_CLASS`: use `core/text/WordBoundary.kt`. Catch `Throwable` at coroutine entry points (`rethrowIfFatal`).
- No real audio from tests or commands without asking the author (CLAUDE.md). Never run `connectedDebugAndroidTest` without `-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true`.
- After any `:core` change run the silent on-device `CoreOnDeviceSmokeTest` (JVM tests miss Android-runtime differences).
- Commands: `bash $CLAUDE_JOB_DIR/tmp/t2.sh :core:test :app:testDebugUnitTest :app:lintDebug` style via Gradle from `android/` with Android Studio's JDK as `JAVA_HOME`. Commit after each task; trailer lines per the session's attribution reminder.

## Review Focus

- Child barges in on the final reply → The End must still appear once idle (test in Task 5).
- The End must not appear while the final reply is still being spoken (Task 5).
- A new story starting while the previous rewrite runs → the previous story's data must not change under it; builds serialized (Tasks 3, 4).
- Rewrite fails / key problem → transcript kept, status `FAILED`, story still listed (Task 3).
- App killed mid-rewrite → `PENDING` stories re-queued once on next launch, never stuck forever (Task 3).
- Corrupt or half-written story file → skipped, never crashes the Library (Task 1).
- Leaving Reading while a page is being read → speech stops (Task 7).

---

### Task 1: `LocalStory`, `StoryStore`, `StorySettings`

**Files:**
- Create: `android/core/src/main/kotlin/com/jessvb/tinytalk/core/storybook/LocalStory.kt`, `StoryStore.kt`, `StorySettings.kt`
- Test: `android/core/src/test/kotlin/com/jessvb/tinytalk/core/storybook/StoryStoreTest.kt`, `StorySettingsTest.kt`

**Interfaces:**
- Produces:
  - `enum class RewriteStatus { PENDING, DONE, FAILED }`
  - `data class StoryTurn(val speaker: Speaker, val text: String, val interrupted: Boolean)` (reuse `core.Speaker`)
  - `data class LocalPage(val text: String, val hasImage: Boolean = false)`
  - `data class LocalStory(val id: String, val createdAtIso: String, val turns: List<StoryTurn>, val sharedFacts: List<Pair<String, String>>, val pageCount: Int, val title: String? = null, val pages: List<LocalPage> = emptyList(), val epilogue: String? = null, val rewriteStatus: RewriteStatus = RewriteStatus.PENDING)`
  - `class StoryStore(dir: File)`: `fun save(story: LocalStory)` (atomic: write `<id>.json.tmp` then rename), `fun get(id: String): LocalStory?`, `fun list(): List<LocalStory>` newest first by `createdAtIso`, skipping unreadable files.
  - `class StorySettings(turnCount: Int = 7, pageCount: Int = 5)` with clamped `val turnCount` (4–12) and `val pageCount` (3–10); `interface StorySettingsStore { var turnCount: Int; var pageCount: Int }`.

- [ ] **Step 1: Write failing tests**: `save then get round-trips every field`, `list is newest first`, `a corrupt json file is skipped and the rest still list`, `a leftover .tmp file is ignored`, `get unknown id returns null`; `StorySettingsTest`: values clamp to 4–12 / 3–10, defaults 7 / 5.
- [ ] **Step 2: Run** (`:core:test --tests '*storybook*'`) → FAIL, classes missing.
- [ ] **Step 3: Implement** with `kotlinx.serialization` (`@Serializable` data classes or `JsonObject`s, as `GroqChatClient` does); ids are filesystem-safe (reject path separators in `get`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(android): local story store and story settings (#88)`.

### Task 2: `StorybookWriter`

**Files:**
- Create: `android/core/src/main/kotlin/com/jessvb/tinytalk/core/storybook/StorybookWriter.kt`
- Test: `.../StorybookWriterTest.kt` (port the cases in `ios/TinyTalkCore/Tests/**/StorybookWriterTests.swift`)

**Interfaces:**
- Consumes: `ChatCompleting.complete(List<ChatMessage>): String`, `Safety.findBlocked`.
- Produces: `data class WrittenStorybook(val title: String, val pages: List<String>, val epilogue: String?)`; `class StorybookWriter(chat: ChatCompleting, maxAttempts: Int = 3)` with `suspend fun write(turns: List<StoryTurn>, sharedFacts: List<Pair<String, String>>, pageCount: Int): WrittenStorybook?`.

- [ ] **Step 1: Write failing tests**: valid JSON → title/pages; reply wrapped in prose → first `{` to last `}` extracted; unparseable then valid → success on attempt 2 (the parse-retry message sent); a reply with a blocked word → safety-retry message naming the terms, then success; unparseable + unsafe share the 3-attempt budget → `null`; chat throws → `null` (`CancellationException` still propagates); epilogue equals `And one true thing we learned about the elephant: <fact>` for the first shared fact and the model's own epilogue is ignored; no facts → `epilogue == null`; page list length differing from `pageCount` is accepted if non-empty (match iOS).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** by porting `StorybookWriter.swift` verbatim: system prompt, rewrite prompt (page count + transcript lines), `parseRetryPrompt`, `safetyRetryPrompt(terms)`, tolerant extraction.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(android): storybook writer, ported from iOS (#88)`.

### Task 3: `StoryLibrary`

**Files:**
- Create: `.../core/storybook/StoryLibrary.kt`
- Test: `.../StoryLibraryTest.kt`

**Interfaces:**
- Consumes: Task 1 `StoryStore`, `LocalStory`; Task 2 `StorybookWriter`; `kotlinx.coroutines.sync.Mutex`.
- Produces:
  - `data class FinishedStory(val turns: List<StoryTurn>, val sharedFacts: List<Pair<String, String>>)`
  - `data class StorySummary(val id: String, val createdAtIso: String, val title: String?, val pageCount: Int, val status: RewriteStatus)`
  - `class StoryLibrary(store: StoryStore, writer: StorybookWriter, scope: CoroutineScope, newId: () -> String, now: () -> String)` with: `val summaries: StateFlow<List<StorySummary>>`, `fun begin(story: FinishedStory, pageCount: Int): String` (saves `PENDING`, returns id, then queues a build), `fun detail(id: String): LocalStory?`, `fun requeuePending()`, `val latestStatus: StateFlow<Pair<String, RewriteStatus>?>` (id and status of the most recently begun story).

- [ ] **Step 1: Write failing tests** (fake `ChatCompleting`, temp dir): begin saves `PENDING` before any chat call; build success → `DONE` with title/pages/epilogue and `summaries` updates newest-first; writer returns null → `FAILED` with transcript intact; two begins run builds one at a time (second chat call starts only after first finishes) and each story gets its own result; `requeuePending` re-runs `PENDING` stories once and leaves `DONE`/`FAILED` alone; a build that throws leaves `FAILED`, never crashes the scope; `latestStatus` tracks the newest story only.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**; the build mutex guards read-build-save so a later story never overwrites an earlier one.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(android): story library with serialized storybook builds (#88)`.

### Task 4: `DemoSession` conclude path and finished-story data

**Files:**
- Modify: `android/core/src/main/kotlin/com/jessvb/tinytalk/core/session/{DemoSession,SessionEvent,TurnSession}.kt`, `.../DemoConversation.kt` (expose turns), `.../facts/AnimalFactTracker.kt` only if needed
- Test: extend `DemoSessionTest.kt`

**Interfaces:**
- Consumes: `FinishedStory` (Task 3), `AnimalFactTracker.sharedFacts()`, `StoryArc.forceConcludeGuidance()/markDone()`.
- Produces: `SessionEvent.StoryFinished` becomes `data class StoryFinished(val story: FinishedStory) : SessionEvent`; `DemoSession.concludeStory(turnId: Int)`; `DemoSession` takes `targetTurns: () -> Int` (read at each new story) instead of a constant; `DemoConversation.turns(): List<ConversationTurn>`.

- [ ] **Step 1: Write failing tests**: natural end emits `StoryFinished` whose `story.turns` are THAT story's turns even when a new story begins immediately; `sharedFacts` captured before the reset; `concludeStory` cancels an in-flight turn, sends the forced-conclusion guidance to the chat call, emits `ResponseText`/`TurnEnd`/`StoryFinished` in that order, and marks the arc done even if the reply lacks "The end."; `concludeStory` with an empty story still finishes safely; a settings change (`targetTurns`) applies only to the NEXT story (arc not rebuilt once started).
- [ ] **Step 2: Run** → FAIL (compile errors first; update existing callers/tests of `StoryFinished`).
- [ ] **Step 3: Implement**; capture turns and facts inside the existing critical section, before swapping the conversation, and fetch `sharedFacts()` before `resetFacts` runs (the reset job is chained after).
- [ ] **Step 4: Run** `:core:test` → PASS; then the silent smoke test per Global Constraints.
- [ ] **Step 5: Commit** `feat(android): conclude path and finished-story data in DemoSession (#88)`.

### Task 5: Wiring and The End navigation

**Files:**
- Modify: `android/app/src/main/java/com/jessvb/tinytalk/voice/{VoiceLoop,LoopCoordinator}.kt`, `TinyTalkViewModel.kt`, `ui/Navigation.kt`, `ui/StoryReducer.kt`
- Test: `.../voice/LoopCoordinatorTest.kt`, `.../ui/NavigatorTest.kt` (new cases)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `Screen { ONBOARDING, LANDING, STORY, SETTINGS, LIBRARY, READING, THE_END }`; `VoiceLoop.onStoryFinished: (FinishedStory) -> Unit`; `LoopCoordinator.concludeStory()` (worker command); ViewModel actions `finishStory()`, `openLibrary()`, `openStory(id)`, `backHome()`, and `val libraryStories: StateFlow<List<StorySummary>>`, `val theEnd: StateFlow<TheEndState?>` where `data class TheEndState(val storyId: String, val ready: Boolean, val failed: Boolean)`.

- [ ] **Step 1: Write failing tests**: finishing story → `StoryLibrary.begin` called once with the finished story and current `StorySettings.pageCount`; navigation to `THE_END` happens only after the loop returns to LISTENING/IDLE after the final reply (not on the event alone); barge-in on the final reply still ends at `THE_END` once idle; `THE_END.ready` flips true on `DONE`, `failed` on `FAILED`; "Back home" → LANDING; LIBRARY/READING/THE_END are not "story screen" so the loop's `shouldRun` is false (mic off) and `LoopConditions` test pins it; a new story begun while a rewrite runs does not change the earlier story's `TheEndState`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**; mirror iOS `TheEndLookup` "baseline" idea only if a test needs it (navigate for the story just saved by id, not "newest in library").
- [ ] **Step 4: Run** `:app:testDebugUnitTest` → PASS.
- [ ] **Step 5: Commit** `feat(android): finish flow and The End navigation (#88)`.

### Task 6: Settings values and requeue on launch

**Files:**
- Modify: `android/app/src/main/java/com/jessvb/tinytalk/keys/SettingsStores.kt` (implement `StorySettingsStore`), `TinyTalkViewModel.kt`
- Test: `.../keys/SettingsStoresTest.kt`

**Interfaces:** Consumes `StorySettingsStore`; produces ViewModel `val storyTurnCount/storybookPageCount: StateFlow<Int>` and `fun updateStorySettings(turnCount: Int, pageCount: Int)`; `requeuePending()` called once when the ViewModel starts.

- [ ] **Step 1: Failing tests**: values persist across a new `SettingsStores` instance, clamp on read, defaults 7/5 when unset.
- [ ] **Step 2–4: Run → implement → PASS.**
- [ ] **Step 5: Commit** `feat(android): story length settings persistence (#88)`.

### Task 7: Library, Reading and The End screens

**Files:**
- Create: `android/app/src/main/java/com/jessvb/tinytalk/ui/{LibraryScreen,ReadingScreen,TheEndScreen}.kt`
- Modify: `ui/LandingScreen.kt` ("Read Stories" enabled → `openLibrary`), `MainActivity.kt`/root composable (route the new screens)
- Test: `ui/StoryCardStateTest.kt` (pure helpers), `ui/RelativeDateTest.kt`

**Interfaces:** Consumes Task 5 ViewModel API; reuses `TTA` design system. Produces pure helpers `fun relativeDateLabel(createdAtIso: String, now: Instant): String` and `fun cardState(summary: StorySummary): CardState { READY, WRITING, FAILED }`.

- [ ] **Step 1: Failing tests** for `relativeDateLabel` (today/yesterday/N days/date) and `cardState`.
- [ ] **Step 2–4:** implement helpers and the three composables per the spec's Screens section; Reading uses `HorizontalPager`, shows the epilogue after the last page, narrates with the existing `SentenceTts.speak(pageText)`; `DisposableEffect` calls `stop()` on leave and on page change.
- [ ] **Step 5: Verify** `:app:lintDebug` passes (0 errors); **Commit** `feat(android): Library, Reading and The End screens (#88)`.

### Task 8: "Finish this story" and Settings controls

**Files:** Modify `ui/StoryScreen.kt`, `ui/SettingsScreen.kt`; Test `ui/StoryReducerTest.kt` (button-visibility rule).

**Interfaces:** Consumes ViewModel `finishStory()` and `updateStorySettings`; produces pure `fun canFinishStory(state: StoryUiState): Boolean` (true once any exchange exists and the story is not already finished).

- [ ] **Step 1: Failing test** for `canFinishStory`.
- [ ] **Step 2–4:** implement the button (iOS copy "Finish this story") and two parent controls "Story length" (4–12) and "Pages in the storybook" (3–10) in Settings.
- [ ] **Step 5: Commit** `feat(android): Finish this story and story length settings (#88)`.

### Task 9: Smoke test, docs, install

**Files:** Modify `android/app/src/androidTest/.../core/CoreOnDeviceSmokeTest.kt`, `README.md` (Android section), `CLAUDE.md` (focus paragraph), spec/plan status lines.

- [ ] **Step 1:** Extend the smoke test to run `StoryStore` round-trip and `StorybookWriter` (fake chat, JSON + safety regex) on Android's runtime.
- [ ] **Step 2: Run** `connectedDebugAndroidTest` with `-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true` (silent) → all pass.
- [ ] **Step 3:** `bash android/rebuild-and-install.sh` (no launch). Update docs; commit `docs/test: Android storybook smoke test and docs (#88)`; push; open a draft PR for the author's on-device run (the 12 steps in the spec).

## Self-review notes

- Spec coverage: goals 1–5 → Tasks 1–8; goal 6 + testing → Task 9; Non-goals have no tasks by design. The spec's "Open question: defaults" is resolved (7/5 confirmed from `AppModel.swift` and `config.py`).
