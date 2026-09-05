# Kid-Facing iOS UI — Design Notes

Status: In progress (core loop implemented; scope confirmed by user 2026-09-05)

## Context

The iOS phone client's approved spec
(`2026-08-14-ios-phone-client-design.md`) deliberately scoped `ContentView`
as a bare-bones debug harness and listed "any real UI polish, kid-facing
design, or app 'look'" as a non-goal. This is that deferred piece.

The visual design comes from a Claude Design project ("Tiny Talk Adventures
app design", project id `d19c0d00-d971-4dc6-ac5b-1a06aaf11025`), which
explored three visual directions and landed on **1a, "Storybook-literal"**
(paper/ink/wood/page-edge textures) as the one to implement. Its own
"Assumptions & reasoning" notes were read from this repo directly (the real
state machine, `story_arc.py`'s stages, `story_store.py`'s turn-list shape)
rather than invented, so the screen flow below matches what the design
already intended.

This was a fast-tracked pass -- imported and implemented in one session at
the user's direction, skipping a dedicated brainstorming session, since the
Design project itself already served as the visual spec. This doc exists so
that intent isn't lost, per this repo's normal convention of one spec per
sub-project.

## Scope decision

The design's own interactive prototype covers seven screens: Onboarding,
Landing, Story Creation, The End, Library, Reading, Settings. Cross-checking
against the actual server surface found real gaps for three of them:

- **No arc-stage wire message.** `story_arc.py` tracks a 5-stage narrative
  arc server-side, but `protocol.py` has no message carrying it to the
  client -- the design's "the big moment" progress dots have no real data
  source yet.
- **No story-conclude action.** Nothing in the protocol lets the client ask
  the server to wrap up the current story on demand -- the design's "Finish
  this story" menu item has nothing to call.
- **No story list/read API.** `story_store.py`'s own docstring says it's
  "deliberately minimal ... no read/list/browse API," explicitly left for
  the not-yet-started storybook-persistence sub-project.

Given that, this pass builds **Onboarding, Landing, the live Story screen,
and Settings** -- the four screens with real data behind them today -- and
defers Library, Reading, and The End until the arc-stage protocol message
and persistence read API exist. Confirmed with the user
(`AskUserQuestion`, 2026-09-05) rather than assumed.

Landing's "Read Stories" button still renders -- using the design's own
built-in empty-library state (disabled + "No stories yet — make one with me
first!") -- since that's already the correct real state with zero saved
stories.

## Asset gap (resolved)

The design project's photo assets (`assets/elsie-library.jpeg`,
`uploads/ElsieTheElephant.jpeg`) are each larger than the design-sync
`get_file` API's 256KiB read cap and came back truncated
(`"truncated":true` in the response, confirmed by rendering the partial
JPEG -- the bottom two-thirds decoded as solid color). There is no
larger-file read path available.

Resolved: the user supplied the same photo at full resolution directly
(dropped into a local screenshots folder), confirmed complete by
rendering it. It's bundled at `Assets.xcassets/Elsie.imageset/elsie.jpeg`
and used via a new `ElsieImage` view (a `GeometryReader`-based crop/zoom
helper approximating CSS's `background-size`/`background-position`) for
both the avatar's tight face crop and the Landing/Onboarding full-bleed
backgrounds -- see `ElsieImage.swift`.

## Font substitution

The design specifies Baloo 2 (chunky rounded, for anything tappable) and
Lora (serif, for anything read) from Google Fonts. Neither is bundled --
sourcing and licensing the real font files is left for a follow-up, not
done here to avoid guessing at font-hosting URLs mid-implementation. San
Francisco's built-in `.rounded` and `.serif` designs stand in for now (see
`DesignSystem.swift`'s `TTA.Typography`) -- both ship with iOS already and
land close to the same intent.

## Full-bleed rendering bug (resolved)

The first on-device pass rendered with black bars above/below the app's
content on every screen, and the native camera picker sheet only covered
part of the screen too. Root cause: `Info.plist` had no `UILaunchScreen`
key. Without one, iOS runs the whole app window -- SwiftUI content and any
natively-presented UIKit view controller alike -- in a legacy
compatibility-sized canvas rather than the device's real screen bounds,
letterboxed on a modern device. This predates this pass (the scaffold
never declared one), just never surfaced before because the original
bare-bones debug UI never had full-bleed colored content to make the gap
visible. Fixed by adding `UILaunchScreen: {}` to `project.yml`'s
`info.properties`. Confirmed fixed via on-device-equivalent (Simulator)
screenshots on Onboarding, Landing, and Settings; the camera picker itself
can only be verified on a real device (the Simulator has no camera
hardware at all, so `requestCameraAccess()` short-circuits before ever
presenting it) but shares the identical root cause, already proven fixed.

## Architecture

Four new SwiftUI screens plus a small design-system layer, all under
`ios/TinyTalkApp/TinyTalkApp/`, layered on top of the existing
`AppModel`/`SessionCoordinator` with **no changes to `TinyTalkCore` or the
wire protocol**:

- **`DesignSystem.swift`** -- palette (`TTA.Palette`, lifted directly from
  the design's own color spec), type helpers (`TTA.Typography`),
  `ChunkyButtonStyle` (the design's signature "5-6px bottom edge" pressable
  button) and `IconButtonStyle`.
- **`ElsieAvatar.swift`** -- the circular character avatar (real photo, via
  `ElsieImage`) with a listening-ring animation driven by real
  `SessionState`/mute, used on all four screens.
- **`ElsieImage.swift`** -- crops/zooms the bundled Elsie photo to
  approximate CSS `background-size`/`background-position`, for both the
  avatar's tight face crop and the Landing/Onboarding full-bleed
  backgrounds.
- **`AppModel.swift`** -- unchanged session/connection logic (moved out of
  `ContentView.swift` verbatim), plus:
  - `AppScreen` (`.onboarding`/`.landing`/`.creating`/`.settings`) as
    `AppModel.screen`, replacing the old flat single-view UI.
  - `StoryTurn`/`AppModel.turns` -- a small client-side-only chat history,
    built by watching `currentTurnId` change during the existing 100ms poll
    loop. `SessionCoordinator` only ever exposes the *current* turn's
    transcript/reply (by design -- see its own doc comments), not a
    running history, so there was nothing to bind a scrolling chat view to
    without this. Reset on disconnect/new-story, same as `debugLog`.
- **`OnboardingView.swift` / `LandingView.swift` / `StoryView.swift` /
  `SettingsView.swift`** -- the four screens, each `@ObservedObject`-bound
  to the same `AppModel`.
- **`ContentView.swift`** -- now just a `switch` over `AppModel.screen`,
  plus the existing scenePhase-driven background/foreground handling
  (unchanged from the prior version).

## Data flow

`AppModel.screen` starts at `.onboarding` unless `UserDefaults`'s
`hasCompletedOnboarding` flag is already set (persisted the same way
`serverAddress` already is). Screen transitions with side effects live as
`AppModel` methods (`finishOnboarding()` requests mic permission then
navigates; `startStory()` navigates then calls the existing
`connectResumingIfPending()`; `goHome()` disconnects then navigates) so a
view never has to sequence permission/connection logic itself. Pure
navigation (opening Settings, the back button) is a plain
`model.screen = ...` assignment from the view.

## Error handling

Unchanged from the existing client -- `lastErrorMessage`,
`objectRecognitionHint`, and the disconnect/reconnect/resume logic in
`AppModel`/`SessionCoordinator` are untouched. The Story screen surfaces
`lastErrorMessage` as a dismissible banner instead of the old plain `Text`.

## Testing approach

Same split as the rest of this client: `TinyTalkCore`'s existing XCTest
suite is untouched and still passes (88 tests, unaffected -- no changes to
that package). The new SwiftUI layer has no automated tests of its own
(matches this client's existing approach: `ContentView`/`AppModel` were
never unit-tested either, since SwiftUI view code and `AppModel`'s
UIKit/AVFoundation calls aren't meaningfully testable without a real
device/simulator running the app). Verified by an `xcodebuild` compile
against a simulator destination; real verification is on-device, per the
session's own final instructions.

## Open questions / risks

- Whether SF Rounded/Serif read as close enough to Baloo 2/Lora on a real
  device, or whether it's worth the follow-up work to source and bundle
  the real font files.
- Whether to build Library/Reading/The End against mock local data as a
  separate follow-up (for visual review only) before the arc-stage
  protocol message and persistence read API exist for real, or wait until
  both are built.
- `ElsieImage`'s crop parameters (`zoom`/`anchorX`/`anchorY` per call site)
  were tuned by eye against Simulator screenshots, not derived from any
  precise face-position data -- may need further on-device nudging.
- `AppModel.turns`' turn_id-boundary heuristic (see its doc comment) can in
  principle miss a poll tick right as a new turn starts; low-stakes for a
  presentation-only chat history, unconfirmed whether it's ever visible in
  practice.
