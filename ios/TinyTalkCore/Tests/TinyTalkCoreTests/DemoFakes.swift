import Foundation
@testable import TinyTalkCore

/// Replies with a scripted sequence, one reply per call. If more calls
/// happen than replies were given, the LAST reply repeats -- the same
/// convention as the server tests' FakeRewriteLlm, so a test that wants a
/// specific attempt count passes exactly that many replies and asserts on
/// `callCount`. Records every messages array it receives.
final class ScriptedChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String]
    private var _receivedMessages: [[[String: String]]] = []
    /// Set before use; when non-nil every call throws it.
    var error: Error?

    init(_ replies: String...) {
        self.replies = replies
    }

    var receivedMessages: [[[String: String]]] { lock.withLock { _receivedMessages } }
    var callCount: Int { lock.withLock { _receivedMessages.count } }

    func complete(messages: [[String: String]]) async throws -> String {
        if let error { throw error }
        return lock.withLock {
            _receivedMessages.append(messages)
            guard !replies.isEmpty else { return "" }
            return replies[min(_receivedMessages.count - 1, replies.count - 1)]
        }
    }
}
