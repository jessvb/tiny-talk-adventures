# Library & Reading Screens: Real-Data Wiring — Design Notes

Status: Approved, not yet implemented (brainstormed 2026-09-14/15)

## Context

The kid-facing iOS UI shipped Library, Reading, and The End against
`MockStories.swift` only (the `storybook-ui-screens` plan, alongside PR #9).
Two later sub-projects unblocked pieces of this:

- `storybook-persistence` (2026-09-08) built the server APIs these screens
  need — `list_stories`, `get_story`, `synthesize_page` — all fully
  implemented and tested, but never called by anything except The End.
- PR #17 wired **only** The End screen to real data: `conclude_story`,
  auto-navigation, and a real `SavedStoryDetail` fetched via `getStory()`.
- `storybook-page-art` (2026-09-11, PR #27) added real per-page
  illustrations, but deliberately scoped its iOS work to the one real-data
  path that already existed (The End → "Read it now"). Its own spec
  explicitly named this gap: *"Library's story list and Reading's
  non-'just finished' path stay fully mock ... a separate, not-yet-
  brainstormed sub-project."*

This spec is that sub-project. Library still shows five hardcoded mock
stories (only reachable at all via a hidden Settings preview button);
Landing's "Read Stories" element is a non-interactive `Label` permanently
showing "No stories yet"; and Reading's 🔊 button speaks via a local
`AVSpeechSynthesizer` instead of the real `synthesize_page` round trip.

## Scope decisions made during brainstorming

- **No new "seam" for illustrations is needed.** PR #27 already built
  `ReadingView`'s image rendering generically against
  `model.selectedStory`/`model.pageImages`, with no awareness of how
  `selectedStory` was populated. Once Library's card tap fetches a real
  `SavedStoryDetail` (below), illustrations for library-browsed stories
  work with zero additional code from this sub-project.
- **Audio interaction model is unchanged.** Today's manual tap-per-page 🔊
  button (tap to hear the current page, stops on page change) stays
  exactly as is — no audiobook-style auto-advance. Only the backend swaps
  from `AVSpeechSynthesizer` to a real `synthesize_page` round trip.
- **Server-side: zero changes.** `list_stories`, `get_story`,
  `synthesize_page`, and `get_page_image` are all already implemented and
  tested. This entire sub-project is iOS-only.
- **Out of scope, tracked separately:** away-from-home demo mode's lack of
  a real data source (issues #24, #33) and issue #36 (reconnect can
  navigate to a stale story) — confirmed unrelated to this work; see that
  issue's own root cause (`handleAppForegrounded`'s conclusion heuristic)
  before touching that function for unrelated reasons.

## Design: Library screen

`AppModel` already calls `coordinator.listStories()` in two places (on
app-foreground-return, and when a story concludes) and already parks the
result in `coordinator.latestStoryList` — it's just never copied into the
`@Published libraryStories` array `LibraryView` reads. Fix:

- In the existing poll loop (`AppModel.swift`, where `storyList` is
  already read each tick), assign it into `libraryStories`.
- Add one new trigger: call `listStories()` on `LibraryView`'s `onAppear`,
  so opening Library is always fresh rather than depending on having
  recently backgrounded or concluded a story.
- Card tap: replace `MockStories.detail(forId:)` with the same pattern PR
  #17 established for The End — set a `.pending` placeholder, navigate to
  `.reading`, call `coordinator.getStory(storyId:)`, let the poll loop
  overwrite `selectedStory` once the real detail arrives. Generalize the
  existing `pendingTheEndDetailStoryId`-style dedup flag to cover both
  call sites, since they're now the same "fetch and wait for a story
  detail" operation triggered from two screens.
- Remove the hidden Settings "Preview: Library" button
  (`SettingsView.swift`, assigns `MockStories.librarySummaries`) — once
  real data flows, a debug button that injects fabricated stories
  alongside (or instead of) real ones is actively confusing, not useful.
  `MockStories.swift` itself can stay if anything still uses it for
  SwiftUI previews; confirm during implementation.

## Design: Landing's real "Read Stories" button

Currently a `Label` styled to look permanently disabled, hardcoded to
always show "No stories yet — make one with me first!" Fix: make it a
real `Button`, conditioned on `model.libraryStories.isEmpty` — tappable
and navigating to `.library` when at least one `.done` story exists,
otherwise keeping today's exact look and copy. Add a third `listStories()`
trigger on initial connect, so this is accurate from a cold launch too —
a story saved in a *previous* session shouldn't require one
background/foreground cycle before Landing notices it.

## Design: Reading screen's page audio

This is the one genuinely new protocol surface — `synthesize_page` has
zero iOS-side plumbing today (confirmed by grep: only doc-comment mentions
in `ReadingView.swift`).

- New `ClientMessage.synthesizePage(storyId:pageIndex:)` encoder, mirroring
  the existing `.getPageImage` pattern in `Protocol.swift`, plus a new
  `ServerEvent.pageAudioDone(storyId:pageIndex:)` decode case for the
  server's `page_audio_done` marker.
- `SessionCoordinator` gains a `pendingPageAudioRequest`, checked *before*
  the turn-scoped `isCurrentTurnAudio` gate in `consumeServerEvents()` —
  same before-the-gate placement as the real (already-shipped)
  `pendingPageImageRequests` mechanism, so incoming page audio isn't
  silently dropped or misrouted as live-turn audio — cleared on error
  (`.message(.error)` while a request is pending) and on disconnect
  (`handleConnectionLost`), same as the image case. Unlike images, this
  is a **single optional value, not a queue**: images prefetch every page
  at once (`TabView(.page)` firing `.onAppear` for 2+ pages mid-swipe,
  genuinely concurrent), but audio's manual tap-per-page model (above)
  never has more than one request in flight — a queue here would be
  unneeded machinery for a case that can't occur.
- **One real difference from images, not a copy-paste:** a page image is
  one binary frame; `synthesize_page` streams **multiple** PCM chunks
  (`server/tinytalk/session.py`'s handler does `async for pcm in
  self._tts.synthesize(text): send_bytes(pcm)`, then the done marker). So
  rather than buffering bytes into one slot like `pendingPageImageBytes`,
  each arriving chunk should be handed straight to `RealAudioEngine
  .enqueue()` as it arrives — real streaming playback, the same way
  live-turn audio already flows, not a decode-one-blob-then-play model.
  `page_audio_done` just signals "no more chunks for this page," clearing
  the pending-request entry and letting the UI's loading state end.
- `ReadingView`'s `replayCurrentPage` swaps its `AVSpeechSynthesizer` call
  for this new round trip via a new `AppModel` entry point (mirroring
  `requestPageImage`). Same stop-on-page-change/`onDisappear` behavior as
  today, now stopping `RealAudioEngine` playback instead of
  `synthesizer.stopSpeaking`.

## Error / empty states

- Library with zero stories: reuse Landing's existing empty-state copy
  ("No stories yet — make one with me first!") rather than inventing new
  copy.
- `get_story` returns an error (unknown id — shouldn't happen via normal
  navigation, but possible via a stale poll race): fall back to a
  "couldn't open this story" state rather than hanging on the `.pending`
  placeholder forever.
- `synthesize_page` error, or an empty page's text: no-op the 🔊 button,
  mirroring today's existing `guard !text.isEmpty` check.

## Testing

- `ProtocolTests.swift`: encode/decode round trip for
  `synthesizePage`/`pageAudioDone`, matching existing coverage style for
  `getPageImage`/`pageImageDone`.
- `SessionCoordinatorTests.swift`: polled-state test for
  `pendingPageAudioRequests` (mirroring
  `testListStoriesAndGetStoryUpdatePolledState`), a turn-gate-exemption
  test proving pending page audio doesn't leak into or get dropped by
  live-turn audio handling, and disconnect/error cleanup tests mirroring
  the existing page-image ones.
- `LibraryView`/`LandingView`/`ReadingView` real-data wiring: covered the
  same way the rest of this app's UI layer already is — manual on-device
  verification, per CLAUDE.md's testing mandate. There is no
  simulator-only coverage for the real audio round trip.

## Open questions / risks

- Whether `MockStories.swift` remains used anywhere (e.g. SwiftUI
  `#Preview` blocks) is a small implementation-time check, not a design
  decision — if unused anywhere after this change, it can be deleted in
  the same pass rather than left as dead code.
- No changes planned for away-from-home demo mode's story list/reading
  (issue #24 already tracks that its `DemoConnection` never emits the
  wire messages this sub-project relies on) — a synced-mode user would
  still see mock-free but real-server-side stories only when connected to
  the home server, unchanged from today.
