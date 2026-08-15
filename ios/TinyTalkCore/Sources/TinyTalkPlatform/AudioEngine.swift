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

        // .playAndRecord + .voiceChat mode alone is necessary but NOT
        // sufficient for AEC: per AVAudioSessionTypes.h's documentation of
        // AVAudioSessionModeVoiceChat, echo cancellation is only loaded once
        // the Voice-Processing I/O unit is enabled. Must be set while the
        // engine is stopped (also per that header); enabling it on the
        // input node auto-enables it on the output node too, so this is the
        // only call needed for both directions. This is the actual
        // mechanism behind the file-level doc comment's AEC claim.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw AudioEngineError.sessionConfigurationFailed(error)
        }

        engine.attach(playerNode)
        // wireFormat (24kHz mono Int16), not nil: nil leaves the connection
        // at the mixer's default format (typically 44.1/48kHz float32,
        // often stereo), which pcmDataToBuffer's 24kHz mono Int16 buffers
        // don't match -- AVAudioPlayerNode.h documents that scheduling can
        // throw on a channel-count mismatch, and sample-rate mismatch isn't
        // validated at all, so mismatched-but-not-crashing means TTS plays
        // back at roughly double speed. The mixer input bus is the
        // documented place a non-standard interleaved Int16 format is
        // accepted. If a real device rejects this (only Task 8's on-device
        // testing can confirm either way), the documented fallback is a
        // 24kHz float32 connection format with PCM16->Float32 conversion
        // added to pcmDataToBuffer.
        engine.connect(playerNode, to: engine.mainMixerNode, format: wireFormat)
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
        // outputFormat(forBus:), not inputFormat(forBus:): AVAudioNode.h's
        // tap documentation says the tap/connection format should match the
        // node's OUTPUT format on that bus -- inputFormat and outputFormat
        // are different properties that happen to coincide before
        // setVoiceProcessingEnabled(true) is called (which changes what
        // this returns), which is exactly why using the wrong one was
        // invisible until voice processing was enabled above.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
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

            // AVAudioConverter.h documents that this block can be invoked
            // more than once per outer convert() call (e.g. the first call,
            // or calls after a reset, request additional input frames).
            // Serving the same `buffer` on every invocation -- rather than
            // signaling .noDataNow once it's been consumed -- would
            // duplicate the captured audio and inject standing latency
            // directly into the mic path that feeds the VAD/barge-in
            // detector. `served` makes this the canonical one-shot idiom:
            // hand the buffer over once, then tell the converter there's
            // nothing more this call. `nonisolated(unsafe)`: the block is
            // @Sendable per AVAudioConverter's imported signature, but
            // convert(to:error:withInputFrom:) documents that it invokes
            // this block synchronously and reentrantly on the calling
            // thread while producing a single output buffer -- never truly
            // concurrently -- so the mutation is safe despite the
            // compiler's conservative Sendable-closure check.
            nonisolated(unsafe) var served = false
            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if served {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                served = true
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
