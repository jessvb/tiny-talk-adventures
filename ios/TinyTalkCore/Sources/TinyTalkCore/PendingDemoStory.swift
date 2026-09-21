import Foundation

public struct PendingDemoStoryTurn: Codable, Sendable, Equatable {
    public let speaker: String
    public let text: String
    public let interrupted: Bool

    public init(speaker: String, text: String, interrupted: Bool) {
        self.speaker = speaker
        self.text = text
        self.interrupted = interrupted
    }
}

/// One page of a finished storybook being uploaded with a synced story.
public struct DemoSyncPage: Codable, Sendable, Equatable {
    public let text: String
    /// The page's illustration as JPEG bytes, or nil when it has none.
    public let imageJPEG: Data?

    public init(text: String, imageJPEG: Data?) {
        self.text = text
        self.imageJPEG = imageJPEG
    }
}

/// The finished storybook a demo-mode story carries to the home server at
/// sync time, so nothing generated away from home is discarded or redone.
/// The epilogue is deliberately NOT part of this: the server recomputes it
/// from the story's shared facts (its own rule -- never model-written).
public struct DemoSyncStorybook: Codable, Sendable, Equatable {
    public let title: String
    public let pages: [DemoSyncPage]
    public let illustrationsStatus: IllustrationsStatus?

    public init(title: String, pages: [DemoSyncPage], illustrationsStatus: IllustrationsStatus?) {
        self.title = title
        self.pages = pages
        self.illustrationsStatus = illustrationsStatus
    }
}

/// One story completed away from home, pending sync to the home server
/// -- see DemoConnection (Task 13, writes these) and PendingDemoStore
/// (Task 13, persists them) and AppModel (Task 15, sends them once
/// reconnected).
public struct PendingDemoStoryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let createdAt: String
    public let turns: [PendingDemoStoryTurn]
    /// [[animal, fact], ...] -- matches AnimalFactTracker.sharedFacts()'s
    /// (animal, fact) pairs, in the shape the wire message sends them.
    public let sharedFacts: [[String]]
    /// Only ever set at sync time (see DemoStoryLibrary.syncPayloads) --
    /// never persisted by PendingDemoStore, so payload files written before
    /// this field existed still decode (an absent key is simply nil).
    public let storybook: DemoSyncStorybook?

    public init(
        id: String,
        createdAt: String,
        turns: [PendingDemoStoryTurn],
        sharedFacts: [[String]],
        storybook: DemoSyncStorybook? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.turns = turns
        self.sharedFacts = sharedFacts
        self.storybook = storybook
    }
}
