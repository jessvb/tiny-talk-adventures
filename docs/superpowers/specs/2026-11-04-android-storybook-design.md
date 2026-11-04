# Android storybook (Library, Reading, The End) — Design Spec

Issue #88 (Android demo-mode client), follow-on to Phase 1 (PR #93). Written
2026-11-04 after the author said "Port iOS" and opted out of the question
round; every choice below that the author did not make is marked **(my call)**.
Illustrations are a separate, later spec (see Non-goals).

> **Status (2026-11-04):** implemented on branch `worktree-android-storybook`; unit,
> lint and silent on-device smoke tests pass; the 12-step on-device run (below) is the
> author's, with sound, and has not happened yet. Defaults 7 turns / 5 pages were
> confirmed from iOS `AppModel.swift` and `server/tinytalk/config.py`.

## Context

Android Phase 1 gives a child a spoken story with Elsie (on-phone Whisper,
Groq chat, phone TTS) but nothing is kept: when the arc finishes
(`SessionEvent.StoryFinished`) the transcript just shows "The end" and a fresh
story begins. The Landing screen's "Read Stories" is a disabled placeholder
("Coming later"). iOS demo mode already does all of this
(`2026-09-19-demo-mode-parity-design.md`, Phase 1): finish a story, Elsie
rewrites it into a titled, paged storybook, the child lands on The End screen,
and Library/Reading let them read it and hear any page read aloud, with
"Finish this story" and parent-adjustable story length.

## Goals

1. A finished story becomes a saved storybook on the phone: title, N pages of
   text, and the "one true thing we learned" epilogue when real animal facts
   were shared.
2. Landing's "Read Stories" opens a Library (newest first); a card opens
   Reading (swipe pages, 🔊 reads a page aloud); both match iOS behavior and
   copy.
3. When a story finishes, the app navigates to The End automatically; "Read
   it now" is greyed with "Elsie is still writing this one…" until the
   rewrite finishes, and shows "Couldn't finish this storybook" if it fails.
4. "Finish this story" works from the Story screen mid-story.
5. Parents can set story length (turns 4–12) and storybook pages (3–10) in
   Settings, applying to the NEXT story, as on iOS.
6. Everything is verifiable without sound (JVM tests with fakes); on-device
   steps are listed at the end.

## Non-goals

- **Illustrations / page art** (Cloudflare FLUX). Separate spec; pages here
  are text-only and the Reading layout leaves a place for the picture so
  that spec drops in. **(my call: store a `hasImage` flag per page now so the
  file format does not change later.)**
- **Sync to a home server.** Android is demo-only; there is no home Mac to
  sync to. Stories stay on the phone.
- Deleting or renaming stories (iOS has neither).
- Object recognition, the server-mode wire protocol, `PendingDemoStore`.
- Reading-level setting (#86), per-page spinner (#85).
- A Library backed by anything but the local files.

## Decisions and alternatives

| Question | Decision | Rejected, and why |
|---|---|---|
| Architecture | Plain-Kotlin classes in `:core` (JVM-testable) behind small interfaces; `DemoSession` gains a concluding-turn path and a story-finished callback carrying the transcript; the ViewModel owns a `StoryLibrary` and exposes `StateFlow`s to new Compose screens. | Porting iOS's `DemoConnection`-as-fake-server: Android has no wire protocol, so emitting fake wire events would add a layer for nothing. |
| Persistence | `StoryStore`: one JSON file per story plus (later) image files, in the app's private `filesDir/stories/`. Lock-guarded, atomic write (temp file + rename). | Room/SQLite: heavier than a handful of small documents; iOS uses plain files. |
| Safety | Port `safety.find_blocked` use (already `Safety.findBlocked`) into the storybook writer's retry exactly as the server and iOS do. | Trusting the model's rewrite unfiltered: the end user is a child. |
| Storybook text | Faithful port of `StorybookWriter.swift` / `storybook.py`: same prompts, tolerant JSON extraction, 3 attempts shared between parse failures and safety hits, model epilogue ignored (epilogue derived from the first shared animal fact). | Re-inventing the prompts: they were tuned on-device. |
| Rewrite gating | None: a new story can start while a rewrite runs; builds are serialized (one at a time). | iOS demo mode makes the same choice; the server's gate protects local-GPU memory, which cloud backends don't have. |
| Reading narration | The phone's existing TTS (`SentenceTts`), per-page 🔊; the mic stays muted on non-story screens (`LoopConditions.onStoryScreen`). | A separate TTS engine: a second warm engine costs memory and cold start. |
| Story length defaults | turns 7 (as `DemoSession` today), pages 5. **(my call)** — copied from iOS defaults, to be checked against `config.py`/`SettingsView` during implementation. | — |

## Architecture

```
StoryScreen / LibraryScreen / ReadingScreen / TheEndScreen / SettingsScreen
        │ StateFlows + actions
TinyTalkViewModel ──▶ StoryLibrary ──▶ StoryStore (filesDir/stories/*.json)
        │                  └────────▶ StorybookWriter ──▶ ChatCompleting (Groq)
        └──▶ LoopCoordinator ──▶ VoiceLoop ──▶ DemoSession (conclude path)
```

### New `:core` units (pure Kotlin, no Android types)

| Unit | Purpose |
|---|---|
| `LocalStory` + `StoryStore` | Record and file store. Fields mirror iOS `LocalStory`: `id`, `createdAt` (ISO-8601), `turns` (speaker, text, interrupted), `sharedFacts` (animal, fact), `pageCount` (target at creation), `title?`, `pages` (`text`, `hasImage`), `epilogue?`, `rewriteStatus` (`PENDING`/`DONE`/`FAILED`), `illustrationsStatus?` (reserved). `list()` newest first, `get(id)`, `save(story)`, `update(id)`. |
| `StorybookWriter` | Port of `StorybookWriter.swift`. `suspend fun write(turns, sharedFacts, pageCount): WrittenStorybook?` (`null` = failed after every attempt or the chat call threw). |
| `StoryLibrary` | `begin(payload, pageCount)` saves the transcript as `PENDING`; `buildStorybook(id)` runs the writer and saves `DONE`/`FAILED`, one build at a time (a mutex); `list()`, `detail(id)`; exposes a `StateFlow` of summaries and a `rewriteState` (idle/writing/done/failed for the most recent story) so The End can reflect progress. |
| `StorySettings` | `turnCount` (4–12) and `pageCount` (3–10), clamped; read when a story starts. |

### Changes to existing units

- **`DemoSession`**
  - Accepts `StorySettings`-derived `targetTurns` per story (today a constructor
    value).
  - `concludeStory()`: cancel any in-flight turn (like a barge-in); run one
    turn with empty child text and `StoryArc.forceConcludeGuidance()`; mark
    the arc done unconditionally; then the same finish flow as a natural end.
  - The finish flow (natural or forced) emits `StoryFinished` carrying a
    `FinishedStory` (turns, shared facts) captured at that moment, before the
    conversation and arc are swapped for the next story, so the library never
    reads state of a story that already moved on.
  - `AnimalFactTracker` must expose the facts actually shared this story
    (iOS `sharedFacts`).
- **`VoiceLoop` / `LoopCoordinator`**: `onStoryFinished` passes the
  `FinishedStory` through; `LoopCoordinator` gains `concludeStory()` (a
  command applied on the worker like New Story) and a `finishedStories`
  callback to the ViewModel.
- **`Navigator` / `Screen`**: add `LIBRARY`, `READING`, `THE_END`. Landing's
  "Read Stories" goes to LIBRARY; Library's "+ New story" goes to STORY (a new
  story, as Landing's Create a Story does); Reading's back goes to LIBRARY;
  The End's "Back home" goes to LANDING and "Read it now" goes to READING for
  that story.
- **`LoopConditions`**: the mic must be off on every new screen; they are not
  the Story screen, so the existing `onStoryScreen` rule already covers it.
  A test pins it.

### The End navigation (port of iOS `TheEndLookup` / `readyToShowTheEnd`)

When `StoryFinished` arrives and the final reply has finished PLAYING (the
loop is back to LISTENING, not merely when the event is emitted), navigate to
THE_END for the story just saved. The wait-for-playback rule is the Android
analogue of the iOS fix for "The End appears mid-speech" (#29); a test pins
it. "Read it now" is enabled when that story's `rewriteStatus == DONE`.
Barging in on the final reply must not strand the child (the iOS #47 shape):
if the finish event was emitted, The End still appears once the loop is idle.

## Screens (match iOS copy and layout; Android Compose in the existing `TTA`
design system)

- **Library:** header "Your Stories"; list of cards (title or placeholder,
  "<relative date> · N pages", and the states "Elsie is still writing this
  one…" / "Couldn't finish this storybook"); empty state "No stories yet —
  make one with me first!"; "+ New story" button; back to Landing.
- **Reading:** "PAGE n" label, page text, swipe (HorizontalPager) between
  pages, "swipe to turn the page" hint, 🔊 button per page (speaks the page;
  tapping again or leaving the screen stops it), the epilogue as a final
  block when present. A reserved image slot (hidden until the illustrations
  spec).
- **The End:** "You wrote a whole story!" / "The End."; "Read it now"
  (greyed + "Elsie is still writing this one…" while pending; "Couldn't
  finish this storybook" on failure); "Back home".
- **Story screen:** a "Finish this story" button (iOS `StoryView` line ~327),
  visible once at least one exchange exists; calls `concludeStory()`.
- **Settings:** two parent steppers/sliders, "Story length" (turns) and
  "Pages in the storybook", persisted in the existing settings store and
  applied to the next story (never retroactive: rebuild the arc only if the
  current story has not started, as iOS does).

## Error handling

- Rewrite fails (chat error, unparseable, unsafe after every attempt) →
  `FAILED`; Library/The End show "Couldn't finish this storybook"; the
  transcript is kept. No automatic retry (pet-project scope). **(my call)**
- Missing/rejected/rate-limited key during a rewrite → `FAILED` and the
  existing key banner logic is reused; nothing is lost because the
  transcript is saved first.
- The app is killed mid-rewrite → the story remains `PENDING` on disk;
  Library shows it as "still writing" forever unless re-run. **(my call)**
  On next launch, any `PENDING` story is re-queued once (cheap, bounded by
  the serialized build queue).
- Corrupt story file → skipped in `list()`, logged by class name only.
- Privacy: transcripts and storybooks never leave the phone except to Groq
  for the rewrite (the same trust as the live conversation, covered by the
  existing consent text). Logs never contain story text.

## Testing

JVM (`:core` and `:app` unit tests, no sound):
- `StorybookWriter`: parse retry, safety retry sharing the attempt budget,
  epilogue derived from the first shared fact and the model's epilogue
  ignored, `null` on chat failure — tests lifted from iOS
  `StorybookWriterTests`.
- `StoryStore`: round trip, newest-first, atomic write survives a crash
  between temp and rename, corrupt file skipped.
- `StoryLibrary`: begin → build → DONE/FAILED, serialized builds, summaries
  flow, pending re-queue.
- `DemoSession`: `concludeStory` cancels in flight, forces a concluding
  reply, marks done, emits `StoryFinished(FinishedStory)` with the story's
  own turns/facts even if a new story starts immediately.
- `LoopCoordinator`/navigation: The End waits for playback to finish; barge-in
  on the final reply still reaches The End; Library back/forward stack.
- `LoopConditions`: mic off on LIBRARY/READING/THE_END.
- Reducer/state tests for the screens' states (empty, writing, failed).
Silent on-device: `CoreOnDeviceSmokeTest` extended to exercise `StoryStore`
and `StorybookWriter` (JSON + regex paths) on Android's runtime, run with
`leaveApksInstalledAfterRun=true` (see memory: JVM tests miss Android
runtime differences).

## On-device verification (author, with sound; ~12 steps)

1. Settings shows Story length and Pages; change to 4 turns / 3 pages.
2. Create a Story; after ~4 exchanges Elsie ends it; The End appears only
   AFTER she finishes speaking.
3. "Read it now" is greyed with "Elsie is still writing this one…", then
   enables; tap it; Reading shows a title-less page 1 with 3 pages total.
4. 🔊 on a page reads it; swipe turns pages; leaving stops speech.
5. An animal-fact story ends with "And one true thing we learned about…".
6. Back to Library: the story is listed with date and "3 pages".
7. "Finish this story" mid-story ends it early and goes to The End.
8. Barge in on the last line of a story: The End still appears.
9. Turn the Groq key off (Settings) before finishing: The End shows
   "Couldn't finish this storybook"; the story is still listed.
10. Force-stop the app during "still writing"; reopen: it finishes or fails,
    not stuck forever.
11. The mic is silent on Library/Reading/The End (no orange dot).
12. Library "+ New story" starts a fresh story.

## Phasing and plan

One PR. Plan tasks in order: (1) `StorySettings` + `StoryStore` + `LocalStory`;
(2) `StorybookWriter` (port + tests); (3) `StoryLibrary`; (4) `DemoSession`
conclude path + `FinishedStory`; (5) wiring through `VoiceLoop`/
`LoopCoordinator`/ViewModel and The End navigation; (6) Navigator screens;
(7) Library, Reading, The End composables; (8) Story "Finish this story" and
Settings controls; (9) smoke test + docs. Each task: tests first, small
commits.

## Open questions / risks (my calls, flagged for the author)

- Defaults for pages (5) and turns (7) are copied from iOS and must be
  confirmed against `config.py` while implementing.
- Re-queuing `PENDING` stories on launch is my addition (iOS has the server
  to retry from); drop it if it surprises you.
- Narrating a page with `SentenceTts` shares the one warm TTS with Elsie's
  live voice; leaving Reading must call `stop()` so nothing is left speaking.
- The Reading layout reserves an image slot that is invisible until the
  illustrations spec; a visual check of spacing without it is needed.
