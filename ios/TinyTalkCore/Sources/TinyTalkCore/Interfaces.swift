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
    /// Schedules a buffer for playback and returns as soon as scheduling
    /// succeeds -- NOT once the buffer has actually finished playing.
    /// Multiple enqueue(_:) calls queue back-to-back on the underlying
    /// player node; use waitForPlaybackToFinish() to know when
    /// everything enqueued so far has genuinely finished. See
    /// docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md.
    func enqueue(_ pcm: Data) async
    /// Suspends until every buffer enqueued via enqueue(_:) so far has
    /// genuinely finished playing (or resolves immediately if none are
    /// outstanding).
    func waitForPlaybackToFinish() async
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
    /// stream. Cancelling the Task that's consuming it is not enough on its
    /// own: cancellation alone would leave the underlying connection open
    /// -- close() ensures the connection/stream is actually torn down, not
    /// just that the consuming `for await` loop exits.
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
    /// does -- cancellation alone would leave whatever native resources the
    /// detector holds open, so close() ensures those (and the stream) are
    /// actually torn down during teardown, not just that
    /// SessionCoordinator's consumeVADEvents() loop exits.
    func close()
}
