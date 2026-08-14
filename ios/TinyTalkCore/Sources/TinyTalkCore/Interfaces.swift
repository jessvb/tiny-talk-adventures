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
}

public enum VADEvent: Sendable {
    case speechStart
    case speechEnd
}

public protocol VoiceActivityDetecting: Sendable {
    func events() -> AsyncStream<VADEvent>
    func feed(_ pcm: Data)
}
