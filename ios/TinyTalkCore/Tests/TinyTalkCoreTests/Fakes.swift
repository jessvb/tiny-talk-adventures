import Foundation
@testable import TinyTalkCore

final class FakeAudio: AudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false
    private var _played: [Data] = []
    private var _playWasCancelled = false
    var playDelayNanos: UInt64 = 0

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

final class FakeConnection: ServerConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [ClientMessage] = []
    private var _sentAudio: [Data] = []
    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>

    var sentMessages: [ClientMessage] { lock.withLock { _sentMessages } }
    var sentAudio: [Data] { lock.withLock { _sentAudio } }

    init() {
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
    }

    func send(_ message: ClientMessage) async throws {
        lock.withLock { _sentMessages.append(message) }
    }

    func send(audio pcm: Data) async throws {
        lock.withLock { _sentAudio.append(pcm) }
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
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
