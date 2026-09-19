/// Errors thrown by RealAudioEngine (AudioEngine.swift). Lives in its own
/// file, outside that file's `#if os(iOS)` gate, because nothing here
/// touches AVFoundation -- the payloads are plain `Error`s -- and keeping
/// it compilable on macOS is what lets `swift test` cover it (same reason
/// PlaybackQueueTracker.swift is separate).
public enum AudioEngineError: Error {
    case sessionConfigurationFailed(any Error)
    case captureStartFailed(any Error)
}
