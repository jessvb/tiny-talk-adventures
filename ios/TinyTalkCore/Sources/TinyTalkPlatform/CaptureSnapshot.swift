import Foundation

/// One line of RealAudioEngine's capture state, formatted for the on-screen
/// debug log -- see CaptureDiagnostics.swift's header for why this exists
/// (issue #39). Plain values only: RealAudioEngine reads AVAudioEngine/
/// AVAudioSession into this, so the formatting (what a reader of the log
/// depends on) is testable on the Mac.
struct CaptureSnapshot {
    /// The AVAudioSession facts that matter for "why is the mic silent".
    struct Session {
        /// Raw AVAudioSession values -- the "AVAudioSessionCategory"/
        /// "AVAudioSessionMode" prefixes are stripped in the output.
        var category: String
        var mode: String
        var otherAudioPlaying: Bool
        var silenceSecondaryAudioHint: Bool
        var inputAvailable: Bool
        /// AVAudioSessionPort raw values of the current route's inputs.
        var inputPorts: [String]
        var sampleRate: Double
    }

    /// Another RealAudioEngine that is still allocated -- see
    /// WeakInstanceRegistry.
    struct OtherEngine {
        var id: Int
        var stopCalled: Bool
        var engineRunning: Bool
    }

    /// e.g. "startCapturing: begin".
    var label: String
    var engineId: Int
    var engineRunning: Bool
    /// When set, rendered as "before->after" (start/stop record it on the way in).
    var engineRunningBefore: Bool?
    var tapInstalled: Bool
    /// The input node's CURRENT output format. 0 Hz / 0 channels is the
    /// same invalid state installCaptureTapAndStart() refuses to tap.
    var inputSampleRate: Double
    var inputChannelCount: Int
    var session: Session
    /// Every RealAudioEngine still alive, this one included.
    var liveEngines: Int
    var otherEngines: [OtherEngine]
    var counts: CaptureDiagnostics.Counts

    /// Single line; the on-screen log shows one entry per line. Same
    /// "[diag: ...]" bracketing as RealAudioEngine.enqueue()'s existing
    /// hang-guard diagnostic.
    var formatted: String {
        let running = engineRunningBefore.map { "\($0)->\(engineRunning)" } ?? "\(engineRunning)"
        let inputValid = inputSampleRate > 0 && inputChannelCount > 0
        let input = "\(Self.hertz(inputSampleRate))Hz/\(inputChannelCount)ch" + (inputValid ? "" : "(INVALID)")
        let others = otherEngines.isEmpty
            ? "none"
            : "[" + otherEngines.map { "#\($0.id) stopCalled=\($0.stopCalled) engine.isRunning=\($0.engineRunning)" }.joined(separator: ", ") + "]"
        let ports = session.inputPorts.isEmpty ? "NONE" : session.inputPorts.joined(separator: ",")
        let category = Self.stripping("AVAudioSessionCategory", from: session.category)
        let mode = Self.stripping("AVAudioSessionMode", from: session.mode)
        return "RealAudioEngine#\(engineId) \(label) [diag: "
            + "engine.isRunning=\(running) tap=\(tapInstalled) input=\(input) live=\(liveEngines) others=\(others) "
            + "session=\(category)/\(mode) otherAudio=\(session.otherAudioPlaying) silenceHint=\(session.silenceSecondaryAudioHint) "
            + "inputAvailable=\(session.inputAvailable) route.in=[\(ports)] sessionRate=\(Self.hertz(session.sampleRate))Hz "
            + "buffers=\(counts.buffersReceived) chunks=\(counts.chunksDelivered) peak=\(counts.peakAmplitude)]"
    }

    private static func hertz(_ rate: Double) -> String {
        String(format: "%.0f", rate)
    }

    private static func stripping(_ prefix: String, from raw: String) -> String {
        raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }
}
