import Foundation

/// Errors thrown by RealAudioEngine (AudioEngine.swift). Lives in its own
/// file, outside that file's `#if os(iOS)` gate, because nothing here
/// touches AVFoundation -- the payloads are plain `Error`s -- and keeping
/// it compilable on macOS is what lets `swift test` cover it (same reason
/// PlaybackQueueTracker.swift is separate).
///
/// Describes itself, including the wrapped error: without that, AppModel's
/// "could not start audio capture: \(error.localizedDescription)" bridged
/// this enum to NSError's generic "The operation couldn't be completed.
/// (TinyTalkPlatform.AudioEngineError error 1.)" -- observed on-device
/// (issue #39, 2026-09-17), with the case index (1 == captureStartFailed)
/// the only clue and the real reason (an invalid 0 Hz input format, a
/// converter failure, or an AVAudioEngine.start() error) discarded.
public enum AudioEngineError: Error, LocalizedError, CustomStringConvertible {
    case sessionConfigurationFailed(any Error)
    case captureStartFailed(any Error)

    /// Read by AppModel via `localizedDescription`.
    public var errorDescription: String? { description }

    /// Also what `"\(error)"` prints -- startCapturing()'s retry loop logs
    /// each failed attempt that way.
    public var description: String {
        switch self {
        case .sessionConfigurationFailed(let underlying):
            "audio session setup failed: \(Self.describe(underlying))"
        case .captureStartFailed(let underlying):
            "capture setup failed: \(Self.describe(underlying))"
        }
    }

    /// The wrapped error's own text, plus its NSError domain and code when
    /// that text doesn't already include them. The two hand-built throw
    /// sites in RealAudioEngine carry a precise NSLocalizedDescriptionKey
    /// but no domain/code in it; AVFoundation's own errors are the opposite
    /// (an unhelpful "operation couldn't be completed" whose only real
    /// signal is the domain/code it already embeds).
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        return text.contains(nsError.domain) ? text : "\(text) [\(nsError.domain) \(nsError.code)]"
    }
}
