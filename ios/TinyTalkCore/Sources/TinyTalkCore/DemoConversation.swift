import Foundation

public enum ConversationSpeaker: String, Sendable {
    case child
    case agent
}

public struct ConversationTurn: Sendable, Equatable {
    public let speaker: ConversationSpeaker
    public let text: String
    public let interrupted: Bool

    public init(speaker: ConversationSpeaker, text: String, interrupted: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.interrupted = interrupted
    }
}

/// Swift port of server/tinytalk/conversation.py's Conversation, for
/// DemoConnection's turn loop -- named DemoConversation (not
/// Conversation) to keep it unambiguous alongside AppModel's own
/// display-only StoryTurn.
public final class DemoConversation: @unchecked Sendable {
    public static let interruptedMarker = "[interrupted by the child]"
    private static let roles: [ConversationSpeaker: String] = [.child: "user", .agent: "assistant"]

    private let lock = NSLock()
    private let maxTurns: Int
    private var windowed: [ConversationTurn] = []
    private var _fullHistory: [ConversationTurn] = []

    public init(maxTurns: Int = 20) {
        self.maxTurns = maxTurns
    }

    public var fullHistory: [ConversationTurn] {
        lock.lock(); defer { lock.unlock() }
        return _fullHistory
    }

    public func addChild(_ text: String) {
        add(ConversationTurn(speaker: .child, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public func addAgent(_ text: String, interrupted: Bool = false) {
        add(ConversationTurn(
            speaker: .agent,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            interrupted: interrupted
        ))
    }

    private func add(_ turn: ConversationTurn) {
        guard !turn.text.isEmpty else { return }
        lock.lock()
        windowed.append(turn)
        if windowed.count > maxTurns {
            windowed.removeFirst(windowed.count - maxTurns)
        }
        _fullHistory.append(turn)
        lock.unlock()
    }

    public func toMessages(systemPrompt: String) -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for turn in windowed {
            var content = turn.text
            if turn.interrupted {
                content += " \(Self.interruptedMarker)"
            }
            messages.append(["role": Self.roles[turn.speaker]!, "content": content])
        }
        return messages
    }
}
