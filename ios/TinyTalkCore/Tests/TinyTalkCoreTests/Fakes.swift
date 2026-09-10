import Foundation
import XCTest
@testable import TinyTalkCore

final class FakeAudio: AudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false
    private var _played: [Data] = []
    private var _playWasCancelled = false
    private var _playDelayNanos: UInt64 = 0
    /// Lock-protected (not a bare var) so a test can safely flip this
    /// mid-run -- e.g. to let one chunk be genuinely slow while later
    /// chunks resolve instantly, isolating "did a buffered event reach
    /// play() at all" from "Task.sleep's own cancellation-awareness
    /// happened to save us."
    var playDelayNanos: UInt64 {
        get { lock.withLock { _playDelayNanos } }
        set { lock.withLock { _playDelayNanos = newValue } }
    }

    var stopped: Bool { lock.withLock { _stopped } }
    var played: [Data] { lock.withLock { _played } }
    /// True if a play() call observed real Task cancellation (via
    /// Task.sleep throwing) rather than completing normally. This is what
    /// distinguishes "the caller was told to stop" from "the in-flight
    /// work was actually cancelled" -- see SessionCoordinator's doc comment.
    var playWasCancelled: Bool { lock.withLock { _playWasCancelled } }

    func stopPlaybackImmediately() {
        lock.withLock { _stopped = true }
    }

    func play(_ pcm: Data) async {
        let playDelayNanos = playDelayNanos
        if playDelayNanos > 0 {
            do {
                try await Task.sleep(nanoseconds: playDelayNanos)
            } catch {
                lock.withLock { _playWasCancelled = true }
                return // real cooperative cancellation: stop here, don't record as played
            }
        }
        lock.withLock { _played.append(pcm) }
    }
}

/// Thrown by FakeConnection.send(_:) when sendMessageError is set --
/// stands in for a real URLSessionWebSocketTask write failure (e.g. a
/// half-dead socket that hasn't yet failed a receive() call).
struct FakeSendError: Error, Equatable {}

final class FakeConnection: ServerConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [ClientMessage] = []
    private var _sentAudio: [Data] = []
    private var _sendMessageError: Error?
    /// Interleaved record of everything sent, in the order the fake
    /// actually observed it -- unlike sentMessages/sentAudio (which split
    /// control frames and audio into separate arrays and so can't reveal
    /// their relative ordering), this is what a reentrancy-ordering test
    /// needs to assert against.
    private var _sentLog: [SentItem] = []
    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>
    /// Lock-protected delays applied inside send(_:)/send(audio:) before
    /// they record the send, so a test can force either call to genuinely
    /// suspend (a real `await`, not one that resolves instantly) -- see
    /// sendMessageDelayNanos/sendAudioDelayNanos.
    private var _sendMessageDelayNanos: UInt64 = 0
    private var _sendAudioDelayNanos: UInt64 = 0

    enum SentItem: Equatable {
        case message(ClientMessage)
        case audio(Data)
    }

    var sentMessages: [ClientMessage] { lock.withLock { _sentMessages } }
    var sentAudio: [Data] { lock.withLock { _sentAudio } }
    var sentLog: [SentItem] { lock.withLock { _sentLog } }
    /// How long send(_:) (control frames) suspends (via Task.sleep) before
    /// recording its send. See sendAudioDelayNanos's doc comment for why
    /// this matters -- same reasoning, for control frames instead of audio.
    /// Lock-protected so a test can flip it mid-run.
    var sendMessageDelayNanos: UInt64 {
        get { lock.withLock { _sendMessageDelayNanos } }
        set { lock.withLock { _sendMessageDelayNanos = newValue } }
    }
    /// How long send(audio:) suspends (via Task.sleep) before recording its
    /// send. Every other fake in this file (FakeAudio.playDelayNanos)
    /// completes instantly by default too -- real reentrancy bugs need a
    /// real suspension point to manifest, since an instantly-resolving
    /// `await` never actually hands control back to the actor's scheduler.
    /// Lock-protected so a test can flip it mid-run.
    var sendAudioDelayNanos: UInt64 {
        get { lock.withLock { _sendAudioDelayNanos } }
        set { lock.withLock { _sendAudioDelayNanos = newValue } }
    }
    /// When set, send(_:) throws this instead of recording the message --
    /// simulates a control-frame write failing (e.g. a socket that's
    /// already degraded but hasn't yet failed a receive() call). Lock-
    /// protected so a test can flip it mid-run.
    var sendMessageError: Error? {
        get { lock.withLock { _sendMessageError } }
        set { lock.withLock { _sendMessageError = newValue } }
    }

    init() {
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
    }

    func send(_ message: ClientMessage) async throws {
        let delay = sendMessageDelayNanos
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        if let error = sendMessageError {
            throw error
        }
        lock.withLock {
            _sentMessages.append(message)
            _sentLog.append(.message(message))
        }
    }

    func send(audio pcm: Data) async throws {
        let delay = sendAudioDelayNanos
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        lock.withLock {
            _sentAudio.append(pcm)
            _sentLog.append(.audio(pcm))
        }
    }

    // `SessionCoordinator.start()` is the ONLY caller of this, exactly
    // once, for the coordinator's whole lifetime -- see the AsyncStream
    // competing-consumer note above Step 1. Never call this a second time
    // from a test; it would silently split events with the coordinator's
    // own consumption.
    func events() -> AsyncStream<ServerConnectionEvent> { stream }

    /// Test-only: push a fake event as if it arrived from the server.
    func emit(_ event: ServerConnectionEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    /// Real ServerConnecting.close() requirement -- same effect as the
    /// test-only finish() helper above, but this is what production
    /// teardown code (SessionCoordinator.close()) actually calls.
    func close() {
        continuation.finish()
    }
}

final class FakeVAD: VoiceActivityDetecting, @unchecked Sendable {
    private let continuation: AsyncStream<VADEvent>.Continuation
    private let stream: AsyncStream<VADEvent>
    private let lock = NSLock()
    private var _fed: [Data] = []

    var fed: [Data] { lock.withLock { _fed } }

    init() {
        (stream, continuation) = AsyncStream<VADEvent>.makeStream()
    }

    func events() -> AsyncStream<VADEvent> { stream }

    func feed(_ pcm: Data) {
        lock.withLock { _fed.append(pcm) }
    }

    /// Test-only: simulate the VAD firing, as if real audio triggered it.
    func fire(_ event: VADEvent) {
        continuation.yield(event)
    }

    /// Real VoiceActivityDetecting.close() requirement.
    func close() {
        continuation.finish()
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
