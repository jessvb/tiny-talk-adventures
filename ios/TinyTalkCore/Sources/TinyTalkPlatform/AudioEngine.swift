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
    /// Format used ONLY for the playerNode -> mainMixerNode engine
    /// connection -- AVAudioPlayerNode's output bus rejects Int16 as a
    /// sample format outright (confirmed by directly compiling and running
    /// standalone AVAudioEngine probes on this Mac: connecting at Int16,
    /// interleaved or not, raises an uncaught NSException from
    /// AVAudioPlayerNodeImpl::SetOutputFormat,
    /// NSOSStatusErrorDomain -10868 / kAudioUnitErr_FormatNotSupported;
    /// Float32 succeeds). This is a hard restriction on engine bus
    /// connection formats specifically, not on PCM buffers/AVAudioFormat in
    /// general -- wireFormat (Int16) stays correct for the wire protocol
    /// and for AVAudioConverter's output on the capture side. Since
    /// connect(_:to:format:) is non-throwing, this exception cannot be
    /// caught from Swift -- getting this format wrong crashes the process
    /// on every launch, before the app can do anything.
    private var playbackConnectionFormat: AVAudioFormat!
    private var onAudioCaptured: (@Sendable (Data) -> Void)?
    /// See installCaptureTapAndStart()/rebuildCaptureTap()'s doc comments --
    /// confirmed on-device necessary to recover from voice processing's
    /// graph rebuild silently invalidating the input tap.
    private var configChangeObserver: NSObjectProtocol?
    /// See the outputVolume observer set up in init() -- kept alive for
    /// this instance's whole lifetime (NSKeyValueObservation stops
    /// observing the moment it deallocates).
    private var outputVolumeObserver: NSKeyValueObservation?

    public init() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // .allowBluetoothA2DP: without this, iOS never routes playback
            // to a Bluetooth device at all -- confirmed the reported
            // "audio doesn't go through Bluetooth headphones" wasn't
            // phone-specific, it's this. A2DP (not the plain .allowBluetooth
            // HFP option) specifically routes OUTPUT to the headphones while
            // leaving mic INPUT on the phone's own built-in mic -- keeps the
            // capture path this whole app's VAD/AEC tuning was done against
            // unchanged, and sidesteps HFP's much lower audio quality
            // (narrowband, mono) that a lot of kids' Bluetooth headphones
            // would otherwise impose on the TTS voice. Also makes AEC less
            // load-bearing when active, not more: echo cancellation exists
            // here to stop the phone's OWN speaker output from leaking into
            // the phone's OWN mic -- with headphones, that leakage path
            // doesn't exist in the first place.
            try session.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
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

        guard let connectionFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.wireSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("24kHz mono Float32 is a valid AVAudioFormat configuration")
        }
        playbackConnectionFormat = connectionFormat

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
        // playbackConnectionFormat (24kHz mono Float32), not wireFormat and
        // not nil. `nil` leaves the connection at the mixer's default
        // format (typically 44.1/48kHz float32, often stereo) -- mismatched
        // vs. the buffers actually scheduled. Int16 was tried and directly
        // disproven (see playbackConnectionFormat's doc comment above):
        // AVAudioPlayerNode's output bus rejects Int16 as a sample format
        // outright, an uncaught NSException `connect` can't propagate as a
        // Swift error, so that crashes the process on every launch. Float32
        // is the confirmed-working connection format; pcmDataToBuffer
        // converts the Int16 wire bytes to Float32 before scheduling.
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackConnectionFormat)

        // .voiceChat mode (needed above for AEC) routes playback through a
        // separate "call audio" volume domain that does NOT automatically
        // follow the hardware volume buttons for a plain, non-CallKit app --
        // confirmed on real hardware as both the waiting ditty being too
        // loud regardless of the media volume slider (worked around
        // separately by lowering its own baked-in amplitude -- see
        // WaitingDitty.swift) and, more generally, playback over headphones
        // not responding to the volume buttons at all. AVAudioSession's
        // outputVolume property itself DOES still update live as the
        // buttons are pressed even though .voiceChat mode doesn't apply it
        // automatically -- observing it and applying it to playerNode's own
        // volume directly is the standard workaround for a voice-processing
        // session that still needs to respect the user's volume control.
        playerNode.volume = session.outputVolume
        outputVolumeObserver = session.observe(\.outputVolume, options: [.new]) { [weak playerNode] _, change in
            guard let playerNode, let newValue = change.newValue else { return }
            playerNode.volume = newValue
        }
    }

    /// Explicitly requests microphone permission and awaits the user's
    /// answer, rather than relying on AVAudioEngine/AVAudioSession to
    /// trigger an implicit system prompt on first use. That implicit path
    /// is not reliable on modern iOS: `setActive(true)`/`engine.start()`
    /// can both succeed even when record permission is undetermined or
    /// denied, leaving the input node silently deliver zero buffers to any
    /// tap -- no thrown error, no crash, just permanent silence, which is
    /// indistinguishable from "no speech yet" from the rest of this app's
    /// perspective. Returns `true` only if permission is actually granted.
    public static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Starts mic capture. `onAudioCaptured` is invoked with 24kHz mono
    /// PCM16 LE chunks (matching the wire format) as they're captured --
    /// converted from whatever format the hardware's input node natively
    /// uses. Exact tap buffer size and the real-time-thread -> caller
    /// hand-off mechanism are tuned during on-device testing in Task 8;
    /// AVAudioConverter is the right tool for the format conversion itself.
    public func startCapturing(onAudioCaptured: @escaping @Sendable (Data) -> Void) throws {
        self.onAudioCaptured = onAudioCaptured

        // Confirmed on-device (real iPhone 13 Pro): enabling voice
        // processing makes the input tap deliver zero buffers forever, no
        // thrown error, even though engine.isRunning and every session
        // property (route/availability/category) report healthy. This is a
        // documented AVAudioEngine behavior, not a bug in this file's own
        // configuration: enabling voice processing rebuilds the underlying
        // audio unit graph, and the engine can silently invalidate the
        // already-installed tap's render path without engine.start()
        // itself failing -- Apple's own guidance is to observe
        // AVAudioEngineConfigurationChangeNotification and rebuild.
        // Registering unconditionally (not just after voice processing) is
        // deliberate: this notification is also the same, real, recommended
        // recovery mechanism for a completely different case Task 8's own
        // review already anticipated -- a route change from a phone call,
        // AirPods connecting, etc. -- so this one observer covers both.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            print("RealAudioEngine: AVAudioEngineConfigurationChange received -- rebuilding capture tap")
            self?.rebuildCaptureTap()
        }

        try installCaptureTapAndStart()
    }

    /// (Re)installs the mic tap against the input node's CURRENT format and
    /// (re)starts the engine. Called both from startCapturing() and from
    /// the AVAudioEngineConfigurationChange handler, since a configuration
    /// change can also mean the hardware format itself changed (e.g. a
    /// route change), not just that voice processing's graph rebuild
    /// invalidated the previous tap.
    private func installCaptureTapAndStart() throws {
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

        print("RealAudioEngine: installing tap, hardwareFormat=\(hardwareFormat)")
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

    private func rebuildCaptureTap() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installCaptureTapAndStart()
        } catch {
            print("RealAudioEngine: failed to rebuild capture tap after configuration change: \(error)")
        }
    }

    public func stopCapturing() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        // Removing the tap alone leaves the engine (and its
        // voice-processing I/O unit, which owns the physical mic) running.
        // A fast disconnect/reconnect cycle then briefly has two
        // AVAudioEngine instances both holding the shared input hardware --
        // observed on-device as the newer engine's tap silently receiving
        // zero buffers, no error either side. engine.stop() releases the
        // hardware; play()'s existing `if !engine.isRunning { try?
        // engine.start() }` already handles a caller needing to use this
        // same instance for playback afterward.
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    /// Converts wire-format (24kHz mono Int16 LE) bytes into an
    /// AVAudioPCMBuffer in playbackConnectionFormat (24kHz mono Float32),
    /// since that's what's actually scheduled against playerNode --
    /// AVAudioPlayerNode's output bus rejects Int16 buffers outright (see
    /// playbackConnectionFormat's doc comment). Standard Int16 -> Float32
    /// PCM sample conversion: divide by Int16.max to land in [-1, 1].
    private func pcmDataToBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(pcm.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackConnectionFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { rawBuffer in
            guard let channelData = buffer.floatChannelData else { return }
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channelData[0][i] = Float(samples[i]) / Float(Int16.max)
            }
        }
        return buffer
    }
}
#endif
