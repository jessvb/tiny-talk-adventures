# Storybook UI Screens (Library / Reading / The End) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three iOS screens deferred from PR #9 (Library, Reading,
The End) as real, working SwiftUI screens against realistic mock data,
reachable via a clearly-labeled developer preview in Settings — no live
WebSocket wiring to the real server API yet, since that API
(`ListStories`/`GetStory`/`SynthesizePage`/`story_list`/`story_detail`) is
still landing on the unmerged `worktree-storybook-persistence-design`
branch and its wire shapes are draft until that branch merges.

**Architecture:** New presentation-only Swift types
(`SavedStorySummary`/`SavedStoryDetail`/`StoryPage`/`RewriteStatus`) live in
`TinyTalkCore` (the testable Swift Package), shaped field-for-field like the
server's future wire messages so wiring in real data later is a type swap,
not a rewrite. Fixture content (`MockStories`) lives in the app target only.
Three new SwiftUI views (`TheEndView`, `LibraryView`, `ReadingView`) join
the existing `AppScreen` switch in `ContentView.swift`, reached via three
new preview buttons in `SettingsView.swift` — not from Landing's or
StoryView's real "Read Stories" affordances, which stay exactly as they are
today until the real server API lands (this project's own convention is no
fabricated toggles presented as real to the child user — see
`SettingsView.swift`'s existing doc comment).

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, XCTest/`swift test`
for `TinyTalkCore`, XcodeGen for the app target's `.xcodeproj` (existing
stack — nothing new). The 🔊 replay button in Reading uses `AVSpeechSynthesizer`
(the system voice) as a real, working stand-in for the eventual
`SynthesizePage`/Kokoro TTS round trip.

**Spec:** `docs/superpowers/specs/2026-09-08-storybook-persistence-design.md`
(server-side spec this extends — see its "Open questions / risks" section:
"Client-side behavior... is iOS work for a future sub-project"), the
original `docs/superpowers/specs/2026-09-05-kid-facing-ui-design.md`, and
the Claude Design canvas (`Tiny Talk Adventures.dc.html`, project
`d19c0d00-d971-4dc6-ac5b-1a06aaf11025`, design direction "1a") — the
canvas's own interactive prototype is the source of truth for the exact
markup/copy/navigation graph transcribed into the tasks below.

## Global Constraints

- **No live wire-up.** Do not add any WebSocket message encode/decode for
  `ListStories`/`GetStory`/`SynthesizePage`/`ConcludeStory` in this plan —
  those shapes are still draft on an unmerged branch. Every screen here
  reads from `AppModel`'s own `@Published` state, populated only by mock
  fixtures.
- **No fabricated toggles presented as real.** Per `SettingsView.swift`'s
  own existing convention, do not wire Landing's or StoryView's real "Read
  Stories" buttons to mock data — a real child user must never see
  fictional saved stories presented as their own. The three new screens
  are reachable only from a clearly-labeled "COMING SOON" preview section
  in Settings.
- **No illustration, no photo tie-in** — pages are text-only, per the
  storybook-persistence spec's explicit scope decision. "page art" boxes
  are static placeholder captions, not real images.
- **Deployment target 16, Swift 6.0 strict concurrency** — match
  `project.yml`; no iOS 17+-only APIs (e.g. use the single-value
  `.onChange(of:)` closure form, as `ContentView.swift` already does).
- **`TinyTalkCore` is the only place with unit tests here** — the app
  target (`TinyTalkApp`) has no XCTest target today (confirmed: no
  `TinyTalkAppTests` in the file tree) and none of the existing
  Onboarding/Landing/Story/Settings views have one either. Follow that
  existing convention: new SwiftUI view files are verified by a successful
  build plus the on-device/simulator check in Task 6, not new unit tests.
- **Fresh-worktree gotcha applies** — `ios/TinyTalkApp/Local.xcconfig`
  (gitignored) does not exist in this worktree yet. Task 2's first step
  creates it from `Local.xcconfig.example` before the first App-target
  build, per this repo's own CLAUDE.md.
- **XcodeGen regeneration** — `project.yml` uses a folder reference for
  `TinyTalkApp`'s sources; a plain `xcodegen generate` re-scan is needed
  after adding new files under `ios/TinyTalkApp/TinyTalkApp/` before Xcode
  (or `xcodebuild`) will see them. Every task that adds a new App-target
  file re-runs it.
- **Small, focused commits** — one commit per task, per this repo's
  CLAUDE.md working process.

---

### Task 1: `TinyTalkCore` — saved-story models + relative-date formatting

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SavedStoryTests.swift`

**Interfaces:**
- Produces: `StoryPage(text:)`, `RewriteStatus` (`.pending`/`.done`/`.failed`),
  `SavedStorySummary(id:title:createdAt:pageCount:rewriteStatus:)`,
  `SavedStoryDetail(id:title:pages:epilogue:rewriteStatus:)`,
  `relativeDateLabel(from:now:) -> String`. Used by Task 2 (`MockStories`),
  Task 3 (`TheEndView`), Task 4 (`LibraryView`), Task 5 (`ReadingView`),
  Task 6 (`AppModel`).

- [ ] **Step 1: Write the failing tests**

Create `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SavedStoryTests.swift`:

```swift
import XCTest
@testable import TinyTalkCore

final class SavedStoryTests: XCTestCase {
    func test_relativeDateLabel_sameCalendarDay_isToday() {
        let now = Date()
        let earlierToday = now.addingTimeInterval(-3600)
        XCTAssertEqual(relativeDateLabel(from: earlierToday, now: now), "today")
    }

    func test_relativeDateLabel_oneCalendarDayBack_isYesterday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(relativeDateLabel(from: yesterday, now: now), "yesterday")
    }

    func test_relativeDateLabel_threeDaysBack_showsDayCount() {
        let now = Date()
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(relativeDateLabel(from: threeDaysAgo, now: now), "3 days ago")
    }

    func test_relativeDateLabel_eightDaysBack_isOneWeekAgoSingular() {
        let now = Date()
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        XCTAssertEqual(relativeDateLabel(from: eightDaysAgo, now: now), "1 week ago")
    }

    func test_relativeDateLabel_fifteenDaysBack_showsWeekCount() {
        let now = Date()
        let fifteenDaysAgo = Calendar.current.date(byAdding: .day, value: -15, to: now)!
        XCTAssertEqual(relativeDateLabel(from: fifteenDaysAgo, now: now), "2 weeks ago")
    }

    func test_savedStorySummary_isIdentifiableById() {
        let summary = SavedStorySummary(id: "abc123", title: "Pip", createdAt: Date(), pageCount: 5, rewriteStatus: .done)
        XCTAssertEqual(summary.id, "abc123")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter SavedStoryTests`
Expected: FAIL — `error: cannot find 'relativeDateLabel' in scope` (and
similarly for `SavedStorySummary`, since `SavedStory.swift` doesn't exist
yet).

- [ ] **Step 3: Implement**

Create `ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift`:

```swift
import Foundation

/// One page of a saved story's rewritten storybook prose -- text only, no
/// illustration or photo tie-in (explicitly out of scope, see
/// docs/superpowers/specs/2026-09-08-storybook-persistence-design.md).
/// Field name matches the server's future `story_detail` wire message
/// (`pages: [{"text": ...}]`) so decoding real server JSON later is a
/// straight mapping, not a rewrite.
public struct StoryPage: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Mirrors story_store.py's `rewrite_status` field exactly (`"pending"`,
/// `"done"`, `"failed"`).
public enum RewriteStatus: String, Equatable, Sendable {
    case pending
    case done
    case failed
}

/// One row of the Library screen's grid -- the shape of one entry in the
/// server's future `story_list` wire message (`{id, title, created_at,
/// page_count, rewrite_status}`). `title` is nil while `rewriteStatus` is
/// `.pending` or `.failed` -- the background rewrite hasn't produced one
/// yet.
public struct SavedStorySummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let createdAt: Date
    public let pageCount: Int
    public let rewriteStatus: RewriteStatus

    public init(id: String, title: String?, createdAt: Date, pageCount: Int, rewriteStatus: RewriteStatus) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.rewriteStatus = rewriteStatus
    }
}

/// Full contents of one saved story for the Reading/The End screens -- the
/// shape of the server's future `story_detail` wire message (`{title,
/// pages, epilogue, rewrite_status}`). `epilogue` is nil whenever no real
/// animal fact was shared during that story -- never a fabricated one.
public struct SavedStoryDetail: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let pages: [StoryPage]
    public let epilogue: String?
    public let rewriteStatus: RewriteStatus

    public init(id: String, title: String?, pages: [StoryPage], epilogue: String?, rewriteStatus: RewriteStatus) {
        self.id = id
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
        self.rewriteStatus = rewriteStatus
    }
}

/// Library card caption text ("today" / "yesterday" / "N days ago" / "N
/// weeks ago"), based on calendar-day difference (not raw elapsed hours) so
/// "11pm yesterday" reads as "yesterday" rather than "0 days ago". A
/// simplification of the design canvas's exact wording (which used a
/// weekday name, e.g. "last Tuesday", for one example) -- easy to revisit
/// if the household wants exact weekday names later.
public func relativeDateLabel(from date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let startOfDate = calendar.startOfDay(for: date)
    let startOfNow = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

    switch days {
    case ..<1:
        return "today"
    case 1:
        return "yesterday"
    case 2...6:
        return "\(days) days ago"
    default:
        let weeks = max(1, days / 7)
        return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter SavedStoryTests`
Expected: PASS (all six tests)

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/SavedStoryTests.swift
git commit -m "feat(ios): add SavedStory models + relativeDateLabel to TinyTalkCore"
```

---

### Task 2: App target — `MockStories` fixture data

**Files:**
- Create: `ios/TinyTalkApp/TinyTalkApp/MockStories.swift`

**Interfaces:**
- Consumes: `SavedStorySummary`, `SavedStoryDetail`, `StoryPage`,
  `RewriteStatus` (Task 1).
- Produces: `MockStories.pip/.cookies/.dolphinSleepover/.stillWriting/.couldNotFinish: SavedStoryDetail`,
  `MockStories.librarySummaries: [SavedStorySummary]`,
  `MockStories.detail(forId:) -> SavedStoryDetail?`. Used by Task 3, 4, 5, 6.

- [ ] **Step 1: Create Local.xcconfig for this fresh worktree**

Per this repo's CLAUDE.md "Fresh-worktree gotcha" — `Local.xcconfig` is
gitignored and does not exist in a newly created worktree:

```bash
cp ios/TinyTalkApp/Local.xcconfig.example ios/TinyTalkApp/Local.xcconfig
```

(Use the same Apple Developer Team ID already used in other worktrees —
it's the household's own account, not a secret. If unknown, leave the
example's placeholder value; simulator builds below don't require a real
team.)

- [ ] **Step 2: Write the fixture data**

Create `ios/TinyTalkApp/TinyTalkApp/MockStories.swift`:

```swift
import Foundation
import TinyTalkCore

/// Fixture data for the Library/Reading/The End screens until the real
/// server API (`list_stories`/`get_story`, storybook-persistence
/// sub-project) is wired up -- reached only via Settings' "COMING SOON"
/// preview buttons, never shown in the real onboarding->story flow (see
/// this project's own "no fabricated toggles that don't do anything"
/// convention in SettingsView.swift: these are a developer preview of
/// real, working screens, not a fake feature claimed to a child user).
/// Pip's title/pages/epilogue are transcribed verbatim from the Claude
/// Design canvas's own "1a" interactive prototype (project
/// d19c0d00-d971-4dc6-ac5b-1a06aaf11025); the other two "done" stories and
/// the pending/failed examples are original filler so every Library card
/// state (done/pending/failed) is exercised on-device.
enum MockStories {
    static let pip = SavedStoryDetail(
        id: "pip",
        title: "Pip the Noisy Fox",
        pages: [
            StoryPage(text: "Pip the fox knew forty sounds. He had a bark, a squeak, and a wow-wow-wow for Tuesdays."),
            StoryPage(text: "But one snowy morning Pip opened his mouth and — nothing. Not one of his forty sounds came out."),
            StoryPage(text: "Maya gave him her stripy blanket. Pip wound it round his throat — and something under the stripes went squeak."),
            StoryPage(text: "A mouse had borrowed his voice to sing to her babies. She only needed one sound. Pip had thirty-nine left."),
            StoryPage(text: "So they shared it. Now the hill has forty-one sounds, and one of them is a lullaby. The end."),
        ],
        epilogue: "And one true thing we learned: foxes really do have over forty sounds.",
        rewriteStatus: .done
    )

    static let cookies = SavedStoryDetail(
        id: "cookies",
        title: "The Cookies That Ran Away",
        pages: [
            StoryPage(text: "Three gingerbread cookies jumped off the tray the moment it left the oven."),
            StoryPage(text: "They rolled past the cat, past the dog, and straight out the garden gate, giggling crumbs the whole way."),
            StoryPage(text: "Down by the pond, a family of ducks was having a very plain breakfast — until three cookies came skidding in."),
            StoryPage(text: "Everyone shared, everyone was full, and the cookies agreed running away was much better with friends at the end of it."),
        ],
        epilogue: nil,
        rewriteStatus: .done
    )

    static let dolphinSleepover = SavedStoryDetail(
        id: "dolphin-sleepover",
        title: "Dolphin Sleepover",
        pages: [
            StoryPage(text: "Every dolphin in the bay had somewhere to be that night — except one, who had nowhere at all."),
            StoryPage(text: "A little seal noticed and towed a raft of kelp over: instant sleepover, population two."),
            StoryPage(text: "They stayed up far too late trading the best splash tricks either of them knew."),
            StoryPage(text: "By sunrise the whole bay had heard, and the kelp raft needed six more spots."),
        ],
        epilogue: "And one true thing we learned: dolphins sleep with only half their brain at a time.",
        rewriteStatus: .done
    )

    static let stillWriting = SavedStoryDetail(id: "brave-turtle", title: nil, pages: [], epilogue: nil, rewriteStatus: .pending)

    static let couldNotFinish = SavedStoryDetail(id: "missing-star", title: nil, pages: [], epilogue: nil, rewriteStatus: .failed)

    /// The Library screen's grid, newest first -- matches story_store.py's
    /// own `list_stories()` ordering.
    static var librarySummaries: [SavedStorySummary] {
        let now = Date()
        let calendar = Calendar.current
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: now) ?? now }

        return [
            summary(for: stillWriting, createdAt: now, pageCount: 0),
            summary(for: pip, createdAt: now, pageCount: pip.pages.count),
            summary(for: couldNotFinish, createdAt: daysAgo(1), pageCount: 0),
            summary(for: cookies, createdAt: daysAgo(6), pageCount: cookies.pages.count),
            summary(for: dolphinSleepover, createdAt: daysAgo(15), pageCount: dolphinSleepover.pages.count),
        ]
    }

    /// Looks up the full detail behind one Library card's summary --
    /// stands in for the real `GetStory(story_id)` round trip until that's
    /// wired up.
    static func detail(forId id: String) -> SavedStoryDetail? {
        [pip, cookies, dolphinSleepover, stillWriting, couldNotFinish].first { $0.id == id }
    }

    private static func summary(for detail: SavedStoryDetail, createdAt: Date, pageCount: Int) -> SavedStorySummary {
        SavedStorySummary(id: detail.id, title: detail.title, createdAt: createdAt, pageCount: pageCount, rewriteStatus: detail.rewriteStatus)
    }
}
```

- [ ] **Step 3: Regenerate the Xcode project and build**

Run:
```bash
cd ios/TinyTalkApp && xcodegen generate
xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`. (This only checks compilation — `MockStories`
isn't referenced by any view yet, so there is nothing to see on-screen
until Task 6.) If `xcodebuild` fails for signing/simulator-availability
reasons specific to this machine, open `TinyTalkApp.xcodeproj` in Xcode and
build with Cmd+B instead — this project has no CI for the iOS app per its
own CLAUDE.md, so a local Xcode build is the fallback of record, not a
workaround.

- [ ] **Step 4: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/MockStories.swift
git commit -m "feat(ios): add MockStories fixture data for the storybook screens"
```

---

### Task 3: `TheEndView` — the post-story book-cover screen

**Files:**
- Create: `ios/TinyTalkApp/TinyTalkApp/TheEndView.swift`

**Interfaces:**
- Consumes: `AppModel.selectedStory` (Task 6 adds this property — until
  then this file compiles but AppModel doesn't yet expose it; see the note
  at the end of this task), `SavedStoryDetail`, `MockStories.librarySummaries`.
- Produces: `TheEndView(model:childName:)`. Used by Task 6 (`ContentView`).

- [ ] **Step 1: Write the view**

Create `ios/TinyTalkApp/TinyTalkApp/TheEndView.swift`:

```swift
import SwiftUI
import TinyTalkCore

/// Shown right after a story naturally concludes (design 1a's "The End").
/// For now, reached only via Settings' preview buttons -- wiring this into
/// the real conclude flow needs the storybook-persistence branch's
/// ConcludeStory/story_detail wire messages, not yet merged (see
/// docs/superpowers/plans/2026-09-08-storybook-persistence.md).
struct TheEndView: View {
    @ObservedObject var model: AppModel
    var childName: String = "you"

    @State private var sparkle = false

    var body: some View {
        if let detail = model.selectedStory {
            content(for: detail)
        } else {
            TTA.Palette.ink.ignoresSafeArea()
        }
    }

    private func content(for detail: SavedStoryDetail) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RadialGradient(
                    colors: [Color(hex: 0x5a4a7a), Color(hex: 0x2c2340)],
                    center: UnitPoint(x: 0.5, y: 0.2),
                    startRadius: 10,
                    endRadius: 420
                )
                .ignoresSafeArea()

                sparkleDot().offset(x: 44, y: 90)
                sparkleDot(delay: 0.6).offset(x: geo.size.width - 58, y: 150)
                sparkleDot(delay: 1.1).offset(x: 66, y: max(0, geo.size.height - 210))

                VStack(spacing: 0) {
                    Text("You wrote a whole story!")
                        .font(TTA.Typography.story(17, italic: true))
                        .foregroundColor(Color(hex: 0xd9c9f0))

                    bookCover(for: detail)
                        .padding(.top, 20)

                    Text("The End.")
                        .font(TTA.Typography.display(38))
                        .foregroundColor(Color(hex: 0xffe9b8))
                        .padding(.top, 26)

                    if let epilogue = detail.epilogue {
                        Text(epilogue)
                            .font(TTA.Typography.body(16))
                            .foregroundColor(Color(hex: 0xe6dcf5))
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }

                    Button {
                        model.libraryStories = MockStories.librarySummaries
                        model.screen = .library
                    } label: {
                        Text("Read it now")
                    }
                    .buttonStyle(.ttaPrimary)
                    .padding(.top, 24)

                    Button {
                        model.goHome()
                    } label: {
                        Text("Back home")
                            .font(TTA.Typography.display(15))
                            .foregroundColor(Color(hex: 0xc9b8e4))
                            .underline()
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 32)
                .frame(width: geo.size.width, alignment: .top)
            }
        }
        .onAppear { sparkle = true }
    }

    private func bookCover(for detail: SavedStoryDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(detail.title ?? "Untitled")
                .font(TTA.Typography.display(26))
                .foregroundColor(TTA.Palette.cream)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TTA.Palette.cream.opacity(0.16))
                .frame(height: 86)
                .overlay(
                    Text("cover art")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(hex: 0xffeacf))
                )

            Spacer(minLength: 12)

            Text("by \(childName) & Elsie · \(detail.pages.count) pages")
                .font(TTA.Typography.story(12.5))
                .foregroundColor(Color(hex: 0xffe9b8))
        }
        .padding(18)
        .frame(width: 206, height: 272)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 16, topTrailingRadius: 16)
                .fill(LinearGradient(colors: [TTA.Palette.scarf, TTA.Palette.scarfShadow], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(TTA.Palette.scarfShadow)
                .frame(width: 9)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    private func sparkleDot(delay: Double = 0) -> some View {
        Circle()
            .fill(Color(hex: 0xffe9b8))
            .frame(width: 7, height: 7)
            .opacity(sparkle ? 0.9 : 0.3)
            .scaleEffect(sparkle ? 1.3 : 0.8)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(delay), value: sparkle)
    }
}
```

Note: this file references `model.selectedStory`, which does not exist on
`AppModel` until Task 6. That's fine — Step 2 below builds `TinyTalkCore`
and does a syntax-only check of this file in isolation; the full app
target won't compile again until Task 6 adds the missing `AppModel`
property. Do not add a placeholder property to `AppModel` here — Task 6 is
where all three screens get wired atomically (see its own note on why).

- [ ] **Step 2: Sanity-check the new file's syntax**

Run: `cd ios/TinyTalkCore && swift build` (confirms Task 1's types this
file imports still build cleanly; the App target itself is intentionally
left non-building until Task 6 — see the note above).
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/TheEndView.swift
git commit -m "feat(ios): add TheEndView (design 1a's post-story book-cover screen)"
```

---

### Task 4: `LibraryView` — the saved-stories grid

**Files:**
- Create: `ios/TinyTalkApp/TinyTalkApp/LibraryView.swift`

**Interfaces:**
- Consumes: `AppModel.libraryStories`/`selectedStory` (Task 6),
  `SavedStorySummary`, `MockStories.detail(forId:)`, `relativeDateLabel`.
- Produces: `LibraryView(model:)`. Used by Task 6 (`ContentView`).

- [ ] **Step 1: Write the view**

Create `ios/TinyTalkApp/TinyTalkApp/LibraryView.swift`:

```swift
import SwiftUI
import TinyTalkCore

/// Grid of saved stories (design 1a's "Library"). Reached today via
/// Settings' preview buttons and via TheEndView's "Read it now" -- real
/// data (story_store.list_stories()) isn't wired up yet, see
/// TheEndView.swift's doc comment.
struct LibraryView: View {
    @ObservedObject var model: AppModel

    private let cardGradients: [[Color]] = [
        [TTA.Palette.scarf, TTA.Palette.scarfShadow],
        [TTA.Palette.teal, TTA.Palette.tealShadow],
        [Color(hex: 0x8a7bb8), Color(hex: 0x4a3f75)],
    ]

    var body: some View {
        ZStack {
            TTA.Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 22) {
                        ForEach(Array(model.libraryStories.enumerated()), id: \.element.id) { index, summary in
                            card(for: summary, colorIndex: index)
                        }
                        newStoryTile
                    }
                    .padding(20)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.screen = .landing
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.ttaIcon)

            Text("Your Stories")
                .font(TTA.Typography.display(24))
                .foregroundColor(TTA.Palette.ink)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(TTA.Palette.paper)
    }

    private func card(for summary: SavedStorySummary, colorIndex: Int) -> some View {
        let colors = cardGradients[colorIndex % cardGradients.count]
        let isTappable = summary.rewriteStatus == .done

        return Button {
            guard isTappable, let detail = MockStories.detail(forId: summary.id) else { return }
            model.selectedStory = detail
            model.screen = .reading
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 190)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(colors[1]).frame(width: 8)
                        }
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5, bottomTrailingRadius: 13, topTrailingRadius: 13))

                    if summary.rewriteStatus == .done {
                        Text(summary.title ?? "Untitled")
                            .font(TTA.Typography.display(19))
                            .foregroundColor(TTA.Palette.cream)
                            .padding(14)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)

                statusCaption(for: summary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }

    @ViewBuilder
    private func statusCaption(for summary: SavedStorySummary) -> some View {
        switch summary.rewriteStatus {
        case .done:
            Text("\(relativeDateLabel(from: summary.createdAt)) · \(summary.pageCount) pages")
                .font(TTA.Typography.story(13))
                .foregroundColor(TTA.Palette.inkSoft)
        case .pending:
            Text("Elsie is still writing this one…")
                .font(TTA.Typography.story(13, italic: true))
                .foregroundColor(TTA.Palette.inkSoft)
        case .failed:
            Text("Couldn't finish this storybook")
                .font(TTA.Typography.story(13, italic: true))
                .foregroundColor(TTA.Palette.alert)
        }
    }

    private var newStoryTile: some View {
        Button {
            Task { await model.startStory() }
        } label: {
            VStack(spacing: 8) {
                Text("+")
                    .font(TTA.Typography.display(26))
                    .foregroundColor(TTA.Palette.cream)
                    .frame(width: 52, height: 52)
                    .background(TTA.Palette.scarf)
                    .clipShape(Circle())
                Text("New story")
                    .font(TTA.Typography.display(14))
                    .foregroundColor(TTA.Palette.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(TTA.Palette.wood.opacity(0.42), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Sanity-check the new file's syntax**

Run: `cd ios/TinyTalkCore && swift build`
Expected: `Build complete!` (same reasoning as Task 3, Step 2 — the App
target itself is wired together in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/LibraryView.swift
git commit -m "feat(ios): add LibraryView (design 1a's saved-stories grid)"
```

---

### Task 5: `ReadingView` — the paginated storybook reader

**Files:**
- Create: `ios/TinyTalkApp/TinyTalkApp/ReadingView.swift`

**Interfaces:**
- Consumes: `AppModel.selectedStory` (Task 6), `SavedStoryDetail`, `StoryPage`.
- Produces: `ReadingView(model:)`. Used by Task 6 (`ContentView`).

- [ ] **Step 1: Write the view**

Create `ios/TinyTalkApp/TinyTalkApp/ReadingView.swift`:

```swift
import AVFoundation
import SwiftUI
import TinyTalkCore

/// Paginated storybook reader (design 1a's "Reading"). Reached via a
/// Library card tap or Settings' preview buttons.
///
/// The 🔊 replay button uses the system's built-in AVSpeechSynthesizer
/// voice, not the real Kokoro TTS pipeline (server/tinytalk/tts_kokoro.py)
/// -- SynthesizePage's live wire round trip needs the storybook-
/// persistence branch merged first. Using the device's own voice keeps
/// this a real, working feature today rather than a fake button that does
/// nothing, matching this project's "no fabricated toggles" convention --
/// swap the body of replayCurrentPage() for a SynthesizePage round trip
/// once that lands.
struct ReadingView: View {
    @ObservedObject var model: AppModel

    @State private var pageIndex = 0
    private let synthesizer = AVSpeechSynthesizer()

    var body: some View {
        if let detail = model.selectedStory, !detail.pages.isEmpty {
            content(for: detail)
        } else {
            Color(hex: 0x2c2118).ignoresSafeArea()
        }
    }

    private func content(for detail: SavedStoryDetail) -> some View {
        ZStack {
            Color(hex: 0x2c2118).ignoresSafeArea()

            TabView(selection: $pageIndex) {
                ForEach(Array(detail.pages.enumerated()), id: \.offset) { index, page in
                    pageView(page, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                topBar(title: detail.title ?? "Untitled", pages: detail.pages)
                Spacer()
                bottomBar(pageCount: detail.pages.count)
            }
        }
        .onDisappear { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func pageView(_ page: StoryPage, index: Int) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(TTA.Palette.paper)
                .overlay(
                    Text("page art")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TTA.Palette.inkSoft)
                        .padding(8)
                        .background(TTA.Palette.cream.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                )
                .frame(height: 260)

            VStack(alignment: .leading, spacing: 10) {
                Text("PAGE \(index + 1)")
                    .font(TTA.Typography.display(14))
                    .tracking(2)
                    .foregroundColor(TTA.Palette.scarf)
                Text(page.text)
                    .font(TTA.Typography.story(22))
                    .foregroundColor(TTA.Palette.ink)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTA.Palette.paper)
        }
        .background(TTA.Palette.paper)
    }

    private func topBar(title: String, pages: [StoryPage]) -> some View {
        HStack {
            Button {
                model.screen = .library
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(TTA.Palette.paper)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            Spacer()

            Text(title)
                .font(TTA.Typography.display(14))
                .foregroundColor(TTA.Palette.paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer()

            Button {
                guard pages.indices.contains(pageIndex) else { return }
                replayCurrentPage(text: pages[pageIndex].text)
            } label: {
                Text("🔊")
                    .font(.system(size: 15))
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 44)
    }

    private func bottomBar(pageCount: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? TTA.Palette.gold : TTA.Palette.paper.opacity(0.4))
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("swipe to turn the page")
                .font(TTA.Typography.story(12.5, italic: true))
                .foregroundColor(TTA.Palette.paper.opacity(0.7))
        }
        .padding(.bottom, 26)
    }

    private func replayCurrentPage(text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        synthesizer.speak(utterance)
    }
}
```

- [ ] **Step 2: Sanity-check the new file's syntax**

Run: `cd ios/TinyTalkCore && swift build`
Expected: `Build complete!` (same reasoning as Tasks 3-4.)

- [ ] **Step 3: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/ReadingView.swift
git commit -m "feat(ios): add ReadingView (design 1a's paginated storybook reader)"
```

---

### Task 6: Wire it all together — `AppModel`, `ContentView`, `SettingsView`

This is the task where the app actually compiles and runs with all three
new screens reachable — it must land as one unit (the switch in
`ContentView` has to be exhaustive the moment the three new `AppScreen`
cases exist, and the preview buttons need `AppModel`'s new properties to
already exist).

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`
- Modify: `ios/TinyTalkApp/TinyTalkApp/ContentView.swift`
- Modify: `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`

**Interfaces:**
- Consumes: `TheEndView`, `LibraryView`, `ReadingView` (Tasks 3-5),
  `MockStories` (Task 2), `SavedStorySummary`/`SavedStoryDetail` (Task 1).
- Produces: `AppModel.libraryStories: [SavedStorySummary]`,
  `AppModel.selectedStory: SavedStoryDetail?`, three new `AppScreen` cases.

- [ ] **Step 1: Extend `AppScreen` and add published state**

In `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`, change:

```swift
enum AppScreen: Equatable {
    case onboarding
    case landing
    case creating
    case settings
}
```

to:

```swift
enum AppScreen: Equatable {
    case onboarding
    case landing
    case creating
    case settings
    case library
    case reading
    case theEnd
}
```

And add, next to the existing `@Published var turns: [StoryTurn] = []`:

```swift
    /// Saved-story fixtures for the Library screen -- populated by
    /// Settings' preview buttons or TheEndView's "Read it now" until the
    /// real list_stories() wire call is wired up (see MockStories.swift).
    @Published var libraryStories: [SavedStorySummary] = []
    /// The story currently shown by TheEndView/ReadingView -- populated by
    /// whichever screen navigates to them (a Library card tap, or a
    /// Settings preview button).
    @Published var selectedStory: SavedStoryDetail?
```

- [ ] **Step 2: Wire the new screens into `ContentView`**

In `ios/TinyTalkApp/TinyTalkApp/ContentView.swift`, change the `switch`:

```swift
            switch model.screen {
            case .onboarding:
                OnboardingView(model: model)
            case .landing:
                LandingView(model: model)
            case .creating:
                StoryView(model: model)
            case .settings:
                SettingsView(model: model)
            }
```

to:

```swift
            switch model.screen {
            case .onboarding:
                OnboardingView(model: model)
            case .landing:
                LandingView(model: model)
            case .creating:
                StoryView(model: model)
            case .settings:
                SettingsView(model: model)
            case .library:
                LibraryView(model: model)
            case .reading:
                ReadingView(model: model)
            case .theEnd:
                TheEndView(model: model)
            }
```

- [ ] **Step 3: Add the three preview buttons to Settings**

In `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`, add a new card after
`underTheHoodCard` and before `replayButton` in `body`'s `VStack`:

```swift
                    VStack(spacing: 18) {
                        serverCard
                        underTheHoodCard
                        storybookPreviewCard
                        replayButton
                    }
```

Then add the new card and its helper as new private computed
properties/methods on `SettingsView` (near `underTheHoodCard`):

```swift
    /// Developer preview of the Library/Reading/The End screens against
    /// mock data -- see MockStories.swift and TheEndView.swift's doc
    /// comments for why these aren't wired into the real Landing/Story
    /// "Read Stories" buttons yet.
    private var storybookPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMING SOON: STORYBOOKS")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)

            Text("Preview only — these screens use example stories, not real ones yet.")
                .font(TTA.Typography.body(12.5))
                .foregroundColor(TTA.Palette.inkSoft)

            previewButton("Preview: The End") {
                model.selectedStory = MockStories.pip
                model.screen = .theEnd
            }
            previewButton("Preview: Library") {
                model.libraryStories = MockStories.librarySummaries
                model.screen = .library
            }
            previewButton("Preview: Reading") {
                model.selectedStory = MockStories.pip
                model.screen = .reading
            }
        }
        .padding(16)
        .background(TTA.Palette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func previewButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TTA.Typography.display(14))
                .foregroundColor(TTA.Palette.wood)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(TTA.Palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
```

- [ ] **Step 4: Regenerate and build**

Run:
```bash
cd ios/TinyTalkApp && xcodegen generate
xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`. If it fails, read the error against the exact
code above before changing anything else — the most likely mistake at this
step is a missed case in `ContentView`'s `switch` or a typo in a
`TTA.Palette`/`TTA.Typography` call (cross-check spellings against
`DesignSystem.swift`).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift ios/TinyTalkApp/TinyTalkApp/ContentView.swift ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
git commit -m "feat(ios): wire Library/Reading/The End screens behind a Settings preview"
```

- [ ] **Step 6: On-device (or simulator) verification**

This is the real functional test — Steps 4's build only proves it
compiles. On the phone or a simulator, after installing this branch's
build:

1. Launch the app, get to Landing, tap the gear icon → Settings.
2. Scroll to "COMING SOON: STORYBOOKS". Tap **Preview: The End** — expect
   a purple night-sky screen with three faintly pulsing sparkle dots, an
   orange book-cover card reading "Pip the Noisy Fox" / "cover art" /
   "by you & Elsie · 5 pages", a "The End." heading, the fox-facts
   epilogue line, a "Read it now" button, and a smaller underlined
   "Back home" link.
3. Tap **Read it now** — expect it to land on the Library grid ("Your
   Stories" header, back chevron) showing 5 cards: "Pip the Noisy Fox"
   (today · 5 pages), one captioned "Elsie is still writing this one…"
   (non-tappable), one captioned "Couldn't finish this storybook" in a
   reddish tone (non-tappable), "The Cookies That Ran Away" (6 days ago ·
   4 pages), "Dolphin Sleepover" (2 weeks ago · 4 pages), plus a dashed
   "+ New story" tile.
4. Tap the "Pip the Noisy Fox" card — expect the Reading screen: a dark
   full-bleed page with a "page art" placeholder box on top, "PAGE 1" and
   the first page's prose below, a back chevron and title pill and 🔊
   button along the top, and 5 dot indicators + "swipe to turn the page"
   along the bottom.
5. Swipe left/right — the page and its dot indicator should advance/go
   back; the last page's text should end with "The end." (page 5's own
   text, not a separate UI element).
6. Tap the 🔊 button — the device should speak the current page's text
   out loud in the system voice (confirms `AVSpeechSynthesizer` is wired,
   not the real Kokoro pipeline — that's expected at this stage).
7. Tap the back chevron (top-left) — returns to Library. Tap Library's
   own back chevron — returns to Landing.
8. Back in Settings, tap **Preview: Library** directly, and **Preview:
   Reading** directly — both should work standalone without having gone
   through The End first.
9. Confirm nothing on Landing or the live Story screen's hamburger menu
   changed — "Read Stories" on Landing should still show its existing
   disabled empty-state exactly as before this branch (this plan
   deliberately does not touch that button).
