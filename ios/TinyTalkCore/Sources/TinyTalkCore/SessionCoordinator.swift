/// Per-app-lifetime orchestration -- the client's counterpart to the
/// server's SessionRunner.
///
/// Two independent event sources feed this actor: VAD events (their own
/// AsyncStream, consumed by its own permanent loop -- fine, since nothing
/// else ever reads that same stream) and server events. Server events are
/// handled differently on purpose: `start()`'s loop is the ONLY consumer
/// of `connection.events()`, ever. It deals with `.closed` directly
/// (a disconnect must be observable even while idle, before any turn
/// exists) and forwards turn-relevant events into a fresh per-turn
/// AsyncStream that `runTurn()` -- the real body of the cancellable
/// `turnTask` -- exclusively consumes. Two Swift AsyncStreams were
/// confirmed, by a real test during planning, to have competing-consumer
/// semantics (each element goes to whichever consumer happens to read
/// next, not to all consumers) -- so `connection.events()` must never be
/// read from two places at once, and this design guarantees that.
///
/// Because `runTurn()` is `turnTask`'s actual body, cancelling `turnTask`
/// on interrupt triggers real Swift structured-concurrency cooperative
/// cancellation of an in-flight `await audio.play()` call -- confirmed
/// with a test asserting the in-flight call observes cancellation and does
/// not complete after the interrupt. `stopPlaybackImmediately()` is still
/// called synchronously first, before any of that cancellation machinery
/// runs, so the child stops hearing the agent instantly regardless of how
/// long structured cancellation takes to propagate.
import Foundation

public actor SessionCoordinator {
    private let connection: any ServerConnecting
    private let audio: any AudioPlaying
    private let vad: any VoiceActivityDetecting
    private let machine = SessionStateMachine()
    private let latencyLogger = LatencyLogger()

    private var turnTask: Task<Void, Never>?
    private var turnContinuation: AsyncStream<ServerConnectionEvent>.Continuation?

    public var state: SessionState { machine.state }
    public var latencyHistory: [InterruptLatency] { latencyLogger.history }
    /// Latest transcript_final/response_text/error text from the server,
    /// for a UI (e.g. the iOS client's poll loop) to surface -- see
    /// runTurn()'s .message cases below for where these are set. The design
    /// spec requires errors be surfaced clearly rather than silently
    /// dropped, and the "Heard/Reply" UI needs real values, not permanently
    /// empty strings.
    public private(set) var lastTranscript: String = ""
    public private(set) var lastReply: String = ""
    public private(set) var lastErrorMessage: String?
    /// Flips to true the moment consumeServerEvents() sees the connection
    /// close. A poll-loop UI (e.g. AppModel) has no other way to learn
    /// about a dropped/failed connection -- state alone walks back to
    /// .idle on disconnect, which is indistinguishable from a normal idle
    /// state, so this is the dedicated signal for "the connection died,
    /// tear yourself down and tell the user." Never reset to false by this
    /// actor; the UI's disconnect() is what retires it (by discarding this
    /// coordinator entirely and creating a fresh one on reconnect).
    public private(set) var isClosed = false

    /// Roughly how much recently-captured mic audio to retain so it can be
    /// flushed as pre-roll the instant a turn/barge-in starts -- see
    /// preRollBuffer's doc comment.
    private static let preRollDurationSeconds: Double = 0.2
    /// Matches RealAudioEngine.wireSampleRate / server MIC_SAMPLE_RATE
    /// (24kHz mono Int16 LE) -- see that file's doc comment. Only used here
    /// to size the pre-roll buffer's byte cap; not load-bearing for
    /// correctness if a fake/future audio source uses a different rate,
    /// since the cap just becomes a differently-sized window in that case.
    private static let wireBytesPerSecond: Int = 24_000 * 2
    private static let preRollByteCap = Int(Double(wireBytesPerSecond) * preRollDurationSeconds)
    /// Ring buffer of the most recent ~200ms of mic audio, populated on
    /// every captureAudio() call regardless of state (see that method's
    /// doc comment). Only network-sending audio is gated on .listening --
    /// but that means the very audio that caused the VAD to fire (which by
    /// definition arrives just BEFORE the state machine transitions into
    /// .listening) would otherwise never reach the server, clipping the
    /// start of every utterance. Flushed and cleared the instant the state
    /// machine transitions into .listening (both the happy-path speechStart
    /// and the barge-in interrupt path), immediately after the control
    /// frame that announces the new utterance.
    private var preRollBuffer: [Data] = []
    private var preRollBufferBytes = 0
    /// True from the moment a control-frame-send-then-flush sequence begins
    /// (set just before the `speechStart`/`interrupt` control frame's
    /// `await connection.send(...)`, in handleSpeechStart()/interrupt())
    /// until flushPreRoll() has genuinely drained everything and confirmed
    /// nothing new arrived while doing so. `machine.state` flips to
    /// `.listening` synchronously, BEFORE that first control-frame await --
    /// so without this flag, a captureAudio() call delivered by the mic
    /// pipeline's own task during that await (or during any await inside
    /// flushPreRoll()'s send loop) would see `.listening` already, take the
    /// direct-send branch, and race its own independently-awaited send
    /// against the control frame / pre-roll flush, reaching the wire out of
    /// order. While this is true, captureAudio() buffers instead (same as
    /// the not-yet-`.listening` case), even though `machine.state` already
    /// reports `.listening` -- closing that reentrancy window. See
    /// flushPreRoll()'s doc comment for how it's cleared safely.
    private var isFlushing = false

    public init(connection: any ServerConnecting, audio: any AudioPlaying, vad: any VoiceActivityDetecting) {
        self.connection = connection
        self.audio = audio
        self.vad = vad
    }

    /// Runs for the coordinator's whole lifetime. Call once. Cancel the
    /// enclosing Task to stop both this and VAD consumption.
    public func start() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.consumeVADEvents() }
            group.addTask { await self.consumeServerEvents() }
        }
    }

    /// Called by the real AudioEngine (Task 6) as mic audio is captured.
    /// VAD must be fed unconditionally, regardless of state -- it has to
    /// keep monitoring the mic while the agent is .speaking, since that is
    /// the only way a barge-in can ever be detected in the first place.
    /// Only the network send (uploading the child's own speech to the
    /// server) is gated on .listening. Exposed as a method (not folded
    /// into VAD's own event stream) because captured audio and VAD's
    /// speech/silence decisions are two independent streams from two
    /// different sources.
    public func captureAudio(_ pcm: Data) async {
        vad.feed(pcm)
        // isFlushing overrides an already-.listening state on purpose -- see
        // its doc comment: a control-frame-send-then-flush sequence is in
        // progress, so this chunk must queue behind it, not race it.
        guard machine.state == .listening, !isFlushing else {
            appendToPreRollBuffer(pcm)
            return
        }
        try? await connection.send(audio: pcm)
    }

    /// Appends to the pre-roll ring buffer, evicting the oldest chunks once
    /// the ~200ms byte cap is exceeded. Only called while NOT .listening, or
    /// while isFlushing is true -- once .listening AND not flushing,
    /// captured audio goes straight to the network instead (see
    /// captureAudio() above).
    private func appendToPreRollBuffer(_ pcm: Data) {
        preRollBuffer.append(pcm)
        preRollBufferBytes += pcm.count
        while preRollBufferBytes > Self.preRollByteCap, !preRollBuffer.isEmpty {
            preRollBufferBytes -= preRollBuffer.removeFirst().count
        }
    }

    /// Sends every buffered pre-roll chunk to the server, in capture order,
    /// then clears the buffer. Must be called immediately after the control
    /// frame (speech_start or interrupt) that announces a new utterance is
    /// starting, so the server receives this audio right after being told
    /// to expect it. Callers must set `isFlushing = true` before that
    /// control frame's own `await connection.send(...)` -- i.e. before
    /// calling this method at all -- so captureAudio() is already buffering
    /// (instead of racing a direct send) for the whole sequence, not just
    /// for this method's own body.
    ///
    /// Each `await connection.send(audio:)` below is itself a suspension
    /// point: a concurrently-running captureAudio() call can be scheduled
    /// in the gap, see isFlushing is still true, and append to
    /// `preRollBuffer` again before this loop finishes draining its
    /// snapshot. Looping -- re-snapshotting and re-draining -- until a pass
    /// leaves the buffer empty, checked with no `await` in between, closes
    /// that: only once a drain pass is immediately followed by an empty
    /// buffer (nothing could have snuck in between the check and the flag
    /// flip, since actor-isolated code between two awaits is atomic) is it
    /// safe to flip `isFlushing` back to false and let captureAudio()
    /// resume direct-sending.
    private func flushPreRoll() async {
        while !preRollBuffer.isEmpty {
            let buffered = preRollBuffer
            preRollBuffer = []
            preRollBufferBytes = 0
            for chunk in buffered {
                try? await connection.send(audio: chunk)
            }
        }
        isFlushing = false
    }

    private func consumeVADEvents() async {
        for await event in vad.events() {
            switch event {
            case .speechStart:
                await handleSpeechStart()
            case .speechEnd:
                await handleSpeechEnd()
            }
        }
    }

    /// The sole consumer of connection.events(), for the coordinator's
    /// whole lifetime. See the type-level doc comment above for why this
    /// must never be duplicated.
    private func consumeServerEvents() async {
        for await event in connection.events() {
            if case .closed = event {
                turnContinuation?.finish()
                turnContinuation = nil
                turnTask?.cancel()
                // A disconnect mid-turn must not leave the coordinator
                // stuck outside .idle forever -- mirrors the server's own
                // _fail_turn state walk-back on failure. .disconnected is
                // legal from every state (see SessionState.swift), so this
                // is always safe to call regardless of current state.
                _ = try? machine.handle(.disconnected)
                // Nothing else (state walking back to .idle looks just like
                // a normal idle state) tells a UI the connection actually
                // died -- see isClosed's doc comment. Must be set before
                // returning, since this loop -- and therefore this actor's
                // only observer of connection.events() -- is about to stop
                // running for good.
                isClosed = true
                return
            }
            // Handled here, unconditionally, rather than only inside
            // runTurn()'s loop: an error frame can arrive OUTSIDE an active
            // turn too (e.g. while .listening, before speech_end, if the
            // server's STT feed fails) -- runTurn() only exists between
            // handleSpeechEnd() and turn end, so turnContinuation is nil at
            // that point and yielding to it would silently drop the event.
            // Set unconditionally, before the forwarding below, so it's
            // captured either way; runTurn() still separately handles
            // `.message(.error)` for turns that ARE active, ending the turn
            // immediately instead of waiting for a turn_end that may have
            // been preempted -- that in-turn behavior is unchanged.
            if case .message(.error(let text)) = event {
                lastErrorMessage = text
            }
            turnContinuation?.yield(event)
        }
    }

    private func handleSpeechStart() async {
        if machine.state == .waitingForReply || machine.state == .speaking {
            await interrupt()
            return
        }
        guard (try? machine.handle(.speechStart)) != nil else { return }
        // Must be set before the control frame's own await below -- see
        // isFlushing's and flushPreRoll()'s doc comments. machine.state is
        // already .listening at this point (machine.handle() above flipped
        // it synchronously), so without this, a captureAudio() call
        // delivered during the send's suspension would race it.
        isFlushing = true
        try? await connection.send(.speechStart)
        await flushPreRoll()
    }

    private func handleSpeechEnd() async {
        guard machine.state == .listening else { return }
        guard (try? machine.handle(.speechEnd)) != nil else { return }
        try? await connection.send(.speechEnd)
        let (turnStream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
        turnContinuation = continuation
        turnTask = Task { [weak self] in
            await self?.runTurn(turnStream)
        }
    }

    /// turnTask's real body: processes exactly one turn's worth of server
    /// events, handed off from consumeServerEvents via turnContinuation.
    /// Cancelling turnTask genuinely cancels whatever this is awaiting.
    private func runTurn(_ turnStream: AsyncStream<ServerConnectionEvent>) async {
        for await event in turnStream {
            // `interrupt()`/the `.closed` handler finish() the stream and
            // cancel this task, but AsyncStream.finish() only stops NEW
            // items from being enqueued -- it does not discard items
            // already buffered (e.g. several TTS chunks plus a turnEnd
            // that arrived back-to-back, faster than play() drains them).
            // A stale, cancelled runTurn would otherwise keep delivering
            // those buffered events -- playing audio after the child was
            // told to stop, and worse, applying a stale turnEnd to
            // `machine`/`turnContinuation` even after a NEW turn has
            // already started, corrupting it. Checking cancellation before
            // touching any shared state on every iteration closes that
            // window: cancel() is synchronous, so this check reliably
            // catches a stale turn on its very next loop iteration.
            if Task.isCancelled { return }
            switch event {
            case .audio(let pcm):
                if machine.state == .waitingForReply {
                    guard (try? machine.handle(.audioChunkReceived)) != nil else { return }
                }
                await audio.play(pcm)
            case .message(.turnEnd):
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                return
            case .message(.error(let text)):
                lastErrorMessage = text
                // Mirrors the server's own behavior: end the turn
                // immediately rather than waiting for a turn_end the
                // error may have preempted.
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                return
            case .message(.transcriptFinal(let text)):
                lastTranscript = text
                continue
            case .message(.responseText(let text)):
                lastReply = text
                continue
            case .message(.transcriptPartial):
                continue
            case .closed:
                return
            }
        }
    }

    /// Tears the coordinator down: closes the connection and the VAD
    /// detector's event stream. Cancelling the Task that's running start()
    /// alone is NOT sufficient: cancellation alone would leave the
    /// underlying WebSocket connection (and, for the VAD, whatever native
    /// resources it holds) open -- close() ensures the connection/stream is
    /// actually torn down, not just that the consuming loops stop. Call
    /// once, right before discarding this coordinator (e.g. from the iOS
    /// client's disconnect()).
    public func close() async {
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        connection.close()
        vad.close()
    }

    private func interrupt() async {
        let id = latencyLogger.recordVADFire()
        // The critical operation: stop sound RIGHT NOW, before anything
        // else in this method runs, so nothing async can delay it further.
        audio.stopPlaybackImmediately()
        // Stamp the headline latency metric (vadFireToPlaybackStoppedMillis)
        // right here, immediately after the stop actually happened -- not
        // after the network send below. recordPlaybackStopped both records
        // "now" and finalizes/removes the pending entry, so calling it
        // this early means the metric reflects only VAD-fire-to-actual-stop,
        // not VAD-fire-to-actual-stop-plus-a-network-round-trip. Because the
        // entry is finalized here, recordInterruptSent(for:) below would be
        // a no-op if called -- intentionally not called.
        latencyLogger.recordPlaybackStopped(for: id)
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        _ = try? machine.handle(.interrupt)
        // See the matching comment in handleSpeechStart(): must be set
        // before the control frame's own await below, for the same reason.
        isFlushing = true
        try? await connection.send(.interrupt)
        await flushPreRoll()
    }
}
