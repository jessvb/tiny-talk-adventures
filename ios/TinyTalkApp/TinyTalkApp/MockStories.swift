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
