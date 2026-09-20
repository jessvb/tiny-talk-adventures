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

/// Holds every complete() call open until the test releases it -- lets a
/// test keep a live turn genuinely in flight.
final class GatedChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private let reply: String

    init(reply: String) {
        self.reply = reply
    }

    func complete(messages: [[String: String]]) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return reply
    }

    func release() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let current = waiter
            waiter = nil
            return current
        }
        toResume?.resume()
    }
}

/// Reports what it was asked to illustrate and returns a scripted result.
final class FakeIllustrator: StoryIllustrating, @unchecked Sendable {
    private let lock = NSLock()
    private var _receivedPages: [[String]] = []
    let result: IllustrationResult

    init(result: IllustrationResult) {
        self.result = result
    }

    var receivedPages: [[String]] { lock.withLock { _receivedPages } }

    func illustrate(pages: [String]) async -> IllustrationResult {
        lock.withLock { _receivedPages.append(pages) }
        return result
    }
}

/// Answers every call with the same reply after a short real delay, and
/// records the highest number of calls ever in flight at once -- the probe
/// a "builds never overlap" test needs.
final class ConcurrencyProbeChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var _maxInFlight = 0
    private let reply: String

    init(reply: String) {
        self.reply = reply
    }

    var maxInFlight: Int { lock.withLock { _maxInFlight } }

    func complete(messages: [[String: String]]) async throws -> String {
        lock.withLock {
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        lock.withLock { inFlight -= 1 }
        return reply
    }
}
