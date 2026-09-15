import Foundation
import TinyTalkCore

/// Fixture data reached only via Settings' "COMING SOON" preview button
/// for the Reading screen (`MockStories.pip`), never shown in the real
/// onboarding->story flow -- see this project's own "no fabricated
/// toggles that don't do anything" convention in SettingsView.swift:
/// this is a developer preview of a real, working screen, not a fake
/// feature claimed to a child user. The Library and The End screens now
/// run on the real server API (`list_stories`/`get_story`), so the
/// fixtures that stood in for it (`librarySummaries`, `detail(forId:)`)
/// were deleted once nothing called them.
/// Pip's title/pages/epilogue are transcribed verbatim from the Claude
/// Design canvas's own "1a" interactive prototype (project
/// d19c0d00-d971-4dc6-ac5b-1a06aaf11025); the other details below are
/// original filler, kept as ready-made preview material for the
/// remaining card states (done with no epilogue, pending, failed).
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
}
