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

    public init(id: String, createdAt: String, turns: [PendingDemoStoryTurn], sharedFacts: [[String]]) {
        self.id = id
        self.createdAt = createdAt
        self.turns = turns
        self.sharedFacts = sharedFacts
    }
}
