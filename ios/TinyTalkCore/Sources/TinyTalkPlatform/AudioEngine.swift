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
    /// Optional hook for surfacing this file's highest-value diagnostic
    /// lines -- config-change-driven engine restarts and playback timeouts,
    /// the exact mechanism suspected (see rebuildCaptureTap() and play()'s
    /// own doc comments) of silencing the waiting ditty after a
    /// backgrounding-triggered resume -- into the same on-screen debug log
    /// SessionCoordinator.debugLog already feeds (see AppModel's wiring).
    /// Not every print() in this file goes through this, just these few:
    /// RealAudioEngine has no reference back to the coordinator to append
    /// into its debugLog directly (different module, and the coordinator is
    /// the one holding a reference to this, not the other way around), so
    /// the caller that DOES hold both (AppModel) is what merges them.
    /// Pre-timestamped here (not left to the caller) so it sorts correctly
    /// against SessionCoordinator's own timestamped lines after merging --
    /// see DebugTimestamp's doc comment for why a shared, thread-safe
    /// formatter matters here specifically (this fires from a notification
    /// callback and a scheduleBuffer completion, not from a fixed thread).
    public var onDebugEvent: (@Sendable (String) -> Void)?
    private let playbackQueueTracker = PlaybackQueueTracker()

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
    public func startCapturing(onAudioCaptured: @escaping @Sendable (Data) -> Void) async throws {
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
            let message = "RealAudioEngine: AVAudioEngineConfigurationChange received -- rebuilding capture tap"
            print(message)
            self?.onDebugEvent?("[\(DebugTimestamp.now())] \(message)")
            self?.rebuildCaptureTap()
        }

        // A plain single `try installCaptureTapAndStart()` here used to be
        // fatal on the very first attempt: right after a backgrounding-
        // triggered reconnect, the input format can genuinely still be
        // invalid (see installCaptureTapAndStart()'s own format-validity
        // guard) for a brief window while the route settles -- confirmed
        // on real hardware as a "could not start audio capture" error that
        // gave up and disconnected immediately, even though the SAME
        // condition resolves itself moments later for the
        // AVAudioEngineConfigurationChange-driven retries in
        // rebuildCaptureTap() below. This is that same retry, just for the
        // very first attempt, which has no notification to fall back on.
        var lastError: Error?
        for attempt in 1...8 {
            do {
                try installCaptureTapAndStart()
                return
            } catch {
                lastError = error
                print("RealAudioEngine: startCapturing attempt \(attempt)/8 failed: \(error)")
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    throw lastError!  // cancelled -- stop retrying immediately, see ensureEngineRunning()
                }
            }
        }
        throw lastError!
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
        // Confirmed reachable on real hardware (observed under Xcode's
        // debugger, where a slower-attached process widens the window, but
        // nothing about the mechanism is Xcode-specific): a rapid run of
        // AVAudioEngineConfigurationChange notifications -- e.g. voice
        // processing's graph rebuild landing back-to-back with a genuine
        // route change -- can report a transiently invalid 0Hz/0-channel
        // format for the input node BETWEEN two valid ones, while the route
        // is still being renegotiated. AVAudioConverter's initializer does
        // NOT reject this format (confirmed: it succeeded here), but
        // installTap(format:) does -- via an uncaught Objective-C
        // NSException, not a Swift error, so `try` cannot catch it and the
        // process crashes outright ('required condition is false:
        // IsFormatSampleRateAndChannelCountValid'). Checking explicitly and
        // bailing out via a normal Swift error is what turns that crash
        // into a safe no-op: another AVAudioEngineConfigurationChange
        // notification reliably follows once the route actually settles,
        // and rebuildCaptureTap() retries then.
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioEngineError.captureStartFailed(
                NSError(domain: "RealAudioEngine", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "input hardware format not yet valid (\(hardwareFormat)) -- route still settling",
                ])
            )
        }
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
        // engine.stop() stops the WHOLE engine graph, not just the input
        // side being rebuilt here -- if playerNode is mid-buffer when this
        // fires, that playback is interrupted too. Logged so a real-device
        // capture can confirm whether this is the actual mechanism behind
        // "the real reply audio was audibly delayed after a resume" (see
        // play()'s own 3s completion-handler timeout, added for the same
        // reason).
        if playerNode.isPlaying {
            let message = "RealAudioEngine: rebuildCaptureTap() is stopping the engine WHILE playerNode is playing"
            print(message)
            onDebugEvent?("[\(DebugTimestamp.now())] \(message)")
        }
        // Root-cause fix, confirmed on real hardware (backgrounding-
        // triggered resume, 2026-09-08): engine.stop() alone does NOT leave
        // playerNode able to render again once installCaptureTapAndStart()
        // restarts the engine below -- it stays wedged, silently failing to
        // fire scheduleBuffer's completion handler on every subsequent
        // play() call, not just the one in flight right now. Observed:
        // five consecutive "did not fire within 3s" timeouts (play()'s own
        // doc comment), ~19 seconds of total silence from the waiting
        // ditty, self-healing only once stopWaitingDitty()'s
        // stopPlaybackImmediately() call -- which is this exact same
        // playerNode.stop() -- finally ran because the real reply arrived.
        // Calling it here, in lockstep with engine.stop(), resets the
        // node's render state immediately instead of leaving every
        // waiting-ditty iteration in between silently die. Unconditional,
        // not gated on the isPlaying check above -- that flag is already
        // known unreliable here (engine.stop() does not reset it, per this
        // method's other doc comment above), and stop() on an
        // already-stopped node is a documented no-op.
        playerNode.stop()
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
        // A stopped/cancelled buffer's own scheduleBuffer completion
        // callback is not guaranteed to fire -- see play()'s own doc
        // comments on why this file already distrusts that assumption
        // elsewhere. Without this, a future turn's
        // waitForPlaybackToFinish() could hang forever waiting for a
        // buffer this stop just discarded.
        playbackQueueTracker.reset()
    }

    public func play(_ pcm: Data) async {
        guard let buffer = pcmDataToBuffer(pcm) else { return }
        guard await ensureEngineRunning() else {
            // Giving up and returning here (rather than scheduling the
            // buffer anyway) is deliberate: playerNode.play() with the
            // engine not actually running never fires scheduleBuffer's
            // completion handler (confirmed on real hardware: "Engine is
            // not running... Cannot play yet!", with the awaiting
            // continuation left hanging forever) -- which wedges whichever
            // caller is awaiting this play() call permanently. The
            // waiting-ditty's own retry loop (`while !Task.isCancelled {
            // await audio.play(...) }`) will simply call play() again.
            print("RealAudioEngine: engine never started -- dropping this play() call rather than hanging forever")
            return
        }
        // Guards scheduleBuffer's completion handler and the timeout task
        // below from both trying to resume the same continuation --
        // resuming twice is a fatal error. Real race, confirmed on real
        // hardware: rebuildCaptureTap() (fired by AVAudioEngineConfiguration
        // Change, which reliably happens more than once in quick succession
        // right after a reconnect -- see that method's own doc comment)
        // calls engine.stop(), which stops the WHOLE engine, including
        // whatever playerNode is currently rendering -- not just the input
        // side it's ostensibly rebuilding. When that lands mid-buffer,
        // scheduleBuffer's completion handler does not reliably fire
        // (confirmed as a real, user-visible symptom: state correctly
        // advances to .speaking, since that transition happens before this
        // await, but no audio is actually heard for several seconds until
        // -- if ever -- the handler eventually fires). Without this timeout,
        // that hangs whichever caller is awaiting this play() call
        // (runTurn()'s TTS loop, or the waiting ditty) indefinitely.
        let gate = PlaybackCompletionGate()
        await withCheckedContinuation { continuation in
            // completionCallbackType: .dataPlayedBack -- the plain
            // scheduleBuffer(_:completionHandler:) overload used here
            // before defaults to .dataConsumed, which fires as soon as
            // AVAudioPlayerNode has handed the buffer off to the render
            // engine, NOT once it has actually been heard through the
            // speaker (any downstream output latency, e.g. a route
            // change or just normal hardware buffering, still happens
            // afterward). Confirmed on real hardware as the root cause of
            // The End screen appearing while Elsie's last sentence was
            // still audibly playing: every doc comment on
            // readyToShowTheEnd (SessionCoordinator.swift) explicitly
            // assumes this await already means "genuinely finished
            // playing," which .dataConsumed does not actually guarantee.
            // .dataPlayedBack is the one AVAudioPlayerNodeCompletionCallbackType
            // case that accounts for that remaining output latency.
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                if gate.tryResume() {
                    continuation.resume()
                }
            }
            // Deliberately unconditional -- AVAudioPlayerNode.play() on an
            // already-playing node is a documented no-op, so the previous
            // `if !playerNode.isPlaying` guard was only ever an
            // optimization, not a correctness requirement. Confirmed on
            // real hardware that it was actively harmful: engine.stop()
            // (from rebuildCaptureTap(), see this method's own doc comment)
            // does NOT reset playerNode.isPlaying back to false, even
            // though the engine restarting means nothing is actually
            // rendering for this node anymore. With the guard, every
            // subsequent play() call after that first collision skipped
            // re-invoking playerNode.play() (since isPlaying still read
            // true), so scheduled buffers just sat there timing out one
            // after another -- observed as many consecutive "did not fire
            // within 3s" logs with genuinely no sound at all, self-healing
            // only once something else (stopWaitingDitty()) called
            // stopPlaybackImmediately() and reset the flag.
            playerNode.play()
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if gate.tryResume() {
                    let message = "RealAudioEngine: play() scheduleBuffer completion did not fire within 3s (likely the engine was stopped mid-render by a concurrent reconfiguration) -- giving up on this buffer rather than hanging forever"
                    print(message)
                    self.onDebugEvent?("[\(DebugTimestamp.now())] \(message)")
                    continuation.resume()
                }
            }
        }
    }

    /// Schedules a buffer without waiting for it to actually finish
    /// playing -- see AudioPlaying.enqueue(_:)'s doc comment and
    /// PlaybackQueueTracker's doc comment for why. Mirrors play(_:)'s
    /// structure almost exactly (same ensureEngineRunning() guard, same
    /// per-buffer PlaybackCompletionGate + 3-second-timeout race, same
    /// .dataPlayedBack completion type) -- the only difference is that
    /// this does not wrap scheduling in a continuation that waits for
    /// that race to resolve; it fires the schedule and the buffer's own
    /// timeout fallback, then returns.
    public func enqueue(_ pcm: Data) async {
        guard let buffer = pcmDataToBuffer(pcm) else { return }
        guard await ensureEngineRunning() else {
            print("RealAudioEngine: engine never started -- dropping this enqueue() call rather than hanging forever")
            return
        }
        let generation = playbackQueueTracker.bufferEnqueued()
        let gate = PlaybackCompletionGate()
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            if gate.tryResume() {
                self?.playbackQueueTracker.bufferFinished(generation: generation)
            }
        }
        // Deliberately unconditional -- see play()'s own doc comment on
        // why guarding this with `if !playerNode.isPlaying` was actively
        // harmful on real hardware.
        playerNode.play()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if gate.tryResume() {
                let message = "RealAudioEngine: enqueue() scheduleBuffer completion did not fire within 3s (likely the engine was stopped mid-render by a concurrent reconfiguration) -- giving up on this buffer rather than hanging forever"
                print(message)
                self?.onDebugEvent?("[\(DebugTimestamp.now())] \(message)")
                self?.playbackQueueTracker.bufferFinished(generation: generation)
            }
        }
    }

    /// Suspends until every buffer enqueued via enqueue(_:) so far has
    /// genuinely finished playing.
    public func waitForPlaybackToFinish() async {
        await playbackQueueTracker.waitForIdle()
    }

    /// Retries engine.start() a handful of times with a short delay between
    /// attempts, rather than one attempt with its error silently discarded
    /// (the previous behavior). Confirmed on real hardware: right after a
    /// backgrounding-triggered reconnect, engine.start() can genuinely fail
    /// -- not just throw and succeed moments later on its own -- while the
    /// audio route is still settling (the same class of issue as
    /// installCaptureTapAndStart()'s transiently-invalid-format guard, here
    /// on the playback side). A handful of short retries gives the route a
    /// real chance to settle before play() gives up on this buffer.
    private func ensureEngineRunning() async -> Bool {
        if engine.isRunning { return true }
        for attempt in 1...8 {
            do {
                try engine.start()
                return true
            } catch {
                print("RealAudioEngine: engine.start() attempt \(attempt)/8 failed: \(error)")
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    // Cancelled -- e.g. stopWaitingDitty() cancelling the
                    // ditty loop's task because the app is backgrounding.
                    // Confirmed on real hardware that the earlier `try?`
                    // here silently discarded exactly this cancellation,
                    // so this retry loop kept grinding through all 8
                    // attempts (~2s) regardless of being told to stop --
                    // real time during which this now-abandoned engine
                    // instance was still fighting the shared, singleton
                    // AVAudioSession for the route right as a NEW
                    // RealAudioEngine (for the reconnect) was trying to
                    // configure the exact same session. Stopping the
                    // instant cancellation is observed, instead of
                    // swallowing it, is what actually lets that
                    // contention window close promptly.
                    return false
                }
            }
        }
        return false
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

/// Lock-protected "resume exactly once" gate for play()'s continuation --
/// scheduleBuffer's completion handler and play()'s own timeout task race
/// to resume the same continuation (see play()'s doc comment for why the
/// timeout exists), and resuming a continuation twice is a fatal error. A
/// tiny `@unchecked Sendable` class, rather than a captured local var, is
/// what Swift 6's strict concurrency checking accepts for state shared
/// between a closure and a detached Task like this.
private final class PlaybackCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Returns true for exactly one caller (whichever gets there first,
    /// completion handler or timeout) -- that caller is the one that
    /// should actually resume the continuation.
    func tryResume() -> Bool {
        lock.withLock {
            defer { resumed = true }
            return !resumed
        }
    }
}
#endif
