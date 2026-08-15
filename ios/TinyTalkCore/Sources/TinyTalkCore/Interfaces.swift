/// Protocol seams SessionCoordinator depends on, so it can be tested with
/// fakes -- no real audio hardware, no real network, no real VAD model.
/// Mirrors the shape of the server's engines.py (SttEngine/LlmEngine/
/// TtsEngine as Protocols consumed by SessionRunner).
import Foundation

public protocol AudioPlaying: Sendable {
    /// Must return immediately with no async work and no network
    /// dependency -- this is on the critical path for barge-in latency.
    func stopPlaybackImmediately()
    func play(_ pcm: Data) async
}

public enum ServerConnectionEvent: Sendable {
    case message(ServerEvent)
    case audio(Data)
    case closed
}

public protocol ServerConnecting: Sendable {
    func send(_ message: ClientMessage) async throws
    func send(audio pcm: Data) async throws
    func events() -> AsyncStream<ServerConnectionEvent>
    /// Tears down the underlying connection and finishes the events()
    /// stream, so a consumer's `for await` over it actually returns instead
    /// of hanging forever -- cancelling the Task that's consuming it is not
    /// enough on its own, since cancellation doesn't make an in-progress
    /// `for await` exit unless the stream itself yields or finishes.
    func close()
}

public enum VADEvent: Sendable {
    case speechStart
    case speechEnd
}

public protocol VoiceActivityDetecting: Sendable {
    func events() -> AsyncStream<VADEvent>
    func feed(_ pcm: Data)
    /// Finishes the events() stream for the same reason ServerConnecting.close()
    /// does -- so SessionCoordinator's consumeVADEvents() loop actually
    /// returns during teardown instead of blocking forever on an event that
    /// will never come.
    func close()
}
