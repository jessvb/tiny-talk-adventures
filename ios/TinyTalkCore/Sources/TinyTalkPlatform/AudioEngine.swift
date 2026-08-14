/// Real AudioPlaying backed by AVAudioEngine, with AVAudioSession
/// configured for voice-processing mode -- this is what provides hardware
/// acoustic echo cancellation (AEC), so the phone doesn't hear its own TTS
/// output through the mic and falsely trigger the VAD mid-reply. Without
/// this, barge-in is unusable. iOS-only: AVAudioSession's API surface
/// (setCategory/setActive/the .voiceChat mode/.defaultToSpeaker option) is
/// marked `@available(macOS, unavailable)` -- the type exists in the shared
/// AVFAudio framework header but is unusable from macOS Swift code, which
/// is why this file lives in TinyTalkPlatform, not TinyTalkCore, and why
/// its body below is gated on `#if os(iOS)`. SwiftPM has no per-target
/// platform restriction (only a package-wide `platforms:` list, which must
/// include macOS so `swift test` can run on this Mac at all -- verified
/// against the local toolchain's PackageDescription API), so without this
/// guard `swift test`/`swift build` would try to compile this file for
/// macOS and fail on every AVAudioSession call. See the plan's Global
/// Constraints.
#if os(iOS)
import AVFoundation
import TinyTalkCore

public enum AudioEngineError: Error {
    case sessionConfigurationFailed(any Error)
    case captureStartFailed(any Error)
}

public final class RealAudioEngine: AudioPlaying, @unchecked Sendable {
    /// Matches server/tinytalk/audio.py's MIC_SAMPLE_RATE/TTS_SAMPLE_RATE
    /// (both 24000) -- see Global Constraints.
    private static let wireSampleRate: Double = 24000

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var wireFormat: AVAudioFormat!
    private var onAudioCaptured: (@Sendable (Data) -> Void)?

    public init() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw AudioEngineError.sessionConfigurationFailed(error)
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.wireSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("24kHz mono Int16 is a valid AVAudioFormat configuration")
        }
        wireFormat = format

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    /// Starts mic capture. `onAudioCaptured` is invoked with 24kHz mono
    /// PCM16 LE chunks (matching the wire format) as they're captured --
    /// converted from whatever format the hardware's input node natively
    /// uses. Exact tap buffer size and the real-time-thread -> caller
    /// hand-off mechanism are tuned during on-device testing in Task 8;
    /// AVAudioConverter is the right tool for the format conversion itself.
    public func startCapturing(onAudioCaptured: @escaping @Sendable (Data) -> Void) throws {
        self.onAudioCaptured = onAudioCaptured
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hardwareFormat, to: wireFormat) else {
            throw AudioEngineError.captureStartFailed(
                NSError(domain: "RealAudioEngine", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "could not create converter from \(hardwareFormat) to \(wireFormat!)"
                ])
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 2400, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: self.wireFormat,
                frameCapacity: AVAudioFrameCount(self.wireFormat.sampleRate * Double(buffer.frameLength) / hardwareFormat.sampleRate) + 1
            ) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let channelData = outputBuffer.int16ChannelData else { return }
            let frameLength = Int(outputBuffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
            self.onAudioCaptured?(data)
        }

        do {
            try engine.start()
        } catch {
            throw AudioEngineError.captureStartFailed(error)
        }
    }

    public func stopCapturing() {
        engine.inputNode.removeTap(onBus: 0)
    }

    public func stopPlaybackImmediately() {
        playerNode.stop()
    }

    public func play(_ pcm: Data) async {
        guard let buffer = pcmDataToBuffer(pcm) else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        await withCheckedContinuation { continuation in
            playerNode.scheduleBuffer(buffer) {
                continuation.resume()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
        }
    }

    private func pcmDataToBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(pcm.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { rawBuffer in
            guard let channelData = buffer.int16ChannelData else { return }
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channelData[0][i] = samples[i]
            }
        }
        return buffer
    }
}
#endif
