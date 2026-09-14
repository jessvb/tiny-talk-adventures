import Foundation

public enum StoryStage: Sendable, Equatable {
    case intro, setup, risingAction, climax, resolution, done
}

/// Swift port of server/tinytalk/story_arc.py. Deliberately
/// deterministic (regex + turn counting), same reasoning as that file's
/// module docstring.
public final class StoryArc: @unchecked Sendable {
    private static let forcedGuidance =
        "This must be the last reply. Resolve the problem from earlier in " +
        "the story and bring it to a warm, complete ending right now. Do not " +
        "ask what should happen next. The story is over. End your reply " +
        "with the words \"The end.\""

    private static let guidance: [StoryStage: String] = [
        .intro: "You're at the very start of the story. Introduce the setting and characters.",
        .setup: "You're at the start of the story. Continue introducing the setting " +
            "and characters, and introduce a problem, challenge, or conflict for " +
            "them to face. Every good story needs something for the " +
            "characters to overcome -- don't wait to introduce it.",
        .risingAction: "The story is building. Keep developing the problem or " +
            "challenge from the start of the story, raise the stakes a " +
            "little, and let the child's ideas shape what happens next.",
        .climax: "The story is nearing its big moment. Build toward an exciting " +
            "(but still gentle) turning point where the problem or challenge " +
            "comes to a head.",
        .resolution: "It's time to resolve the problem from earlier in the story and " +
            "wrap up the story warmly and happily in this reply or the next " +
            "one. If you conclude it now, do not ask what should happen " +
            "next. Instead, end your reply with the words \"The end.\"",
    ]

    private static let childStopPhrases = [
        "the end", "i'm done", "im done", "stop the story",
        "that's enough", "thats enough", "no more story", "i want to stop",
    ]

    private static let conclusionPhrases = [
        "the end", "happily ever after", "lived happily", "the story is over",
    ]

    private let lock = NSLock()
    private let targetTurns: Int
    private let graceCeiling: Int
    private var turnCount = 0
    private var _isDone = false

    public init(targetTurns: Int = 7) {
        self.targetTurns = targetTurns
        self.graceCeiling = targetTurns + 3
    }

    public var stage: StoryStage {
        lock.lock(); defer { lock.unlock() }
        return _isDone ? .done : stageForTurn(turnCount)
    }

    public var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isDone
    }

    private func stageForTurn(_ turn: Int) -> StoryStage {
        if turn <= 1 { return .intro }
        let setupEnd = Int((Double(targetTurns) / 4).rounded())
        let risingEnd = Int((Double(targetTurns) * 2 / 3).rounded())
        if turn <= setupEnd { return .setup }
        if turn <= risingEnd { return .risingAction }
        if turn <= targetTurns { return .climax }
        return .resolution
    }

    public func recordTurn(childText: String) -> String {
        lock.lock(); defer { lock.unlock() }
        turnCount += 1
        if turnCount > graceCeiling { return Self.forcedGuidance }
        if Self.matches(childText, any: Self.childStopPhrases) { return Self.guidance[.resolution]! }
        return Self.guidance[stageForTurn(turnCount)]!
    }

    public func recordReply(replyText: String) {
        lock.lock(); defer { lock.unlock() }
        if turnCount > graceCeiling { _isDone = true; return }
        if Self.matches(replyText, any: Self.conclusionPhrases) { _isDone = true }
    }

    /// Guidance for an explicitly-requested conclusion -- deliberately
    /// does NOT touch turnCount, same reasoning as story_arc.py's
    /// force_conclude_guidance().
    public func forceConcludeGuidance() -> String { Self.forcedGuidance }

    public func markDone() {
        lock.lock(); defer { lock.unlock() }
        _isDone = true
    }

    private static func matches(_ text: String, any phrases: [String]) -> Bool {
        let lower = text.lowercased()
        return phrases.contains { wordBoundaryContains(lower, phrase: $0) }
    }

    private static func wordBoundaryContains(_ text: String, phrase: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
        ) else { return text.contains(phrase) }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
