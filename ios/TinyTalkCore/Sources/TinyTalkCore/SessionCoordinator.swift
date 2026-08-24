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
    /// Audio to loop while .waitingForReply, covering the STT/LLM/TTS
    /// pipeline's real multi-second latency with something more engaging
    /// than dead silence -- see WaitingDitty.swift. nil by default (not
    /// WaitingDitty.audio) specifically so every existing test that
    /// doesn't pass this explicitly stays completely unaffected; the real
    /// app wiring (ContentView.swift) passes WaitingDitty.audio, and
    /// dedicated tests pass their own fake audio to exercise this feature.
    private let waitingDittyAudio: Data?
    private var dittyTask: Task<Void, Never>?
    /// The turn_id sent on the most recent speechStart/interrupt -- see
    /// Protocol.swift's module doc comment for the full rationale.
    /// Confirmed necessary on real hardware: the server's read loop is
    /// strictly serial and STT can take several real seconds per
    /// utterance, so if the child interrupts and starts a new utterance
    /// while the server is still finishing the previous one, that reply
    /// arrives late -- after this client has already moved on to a newer
    /// turn. consumeServerEvents() uses this to tell a late reply for an
    /// abandoned utterance apart from a reply for the current one, instead
    /// of accepting whatever arrives next as if it must belong to the
    /// active turn (which was observed, on-device, to either misattribute
    /// a reply to the wrong turn or silently drop it entirely).
    private var currentTurnId = 0

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
    /// preRollBuffer's doc comment. Confirmed on-device that 200ms wasn't
    /// generous enough: VoiceActivityDetector's onset debounce (attackChunks,
    /// ~96ms) plus a child's natural breath/lead-in before their first word
    /// routinely exceeded it, so the earliest part of that word had already
    /// been evicted from the ring buffer by the time speechStart actually
    /// fired -- reported on-device as the first word being cut off. 500ms
    /// gives comfortable headroom above the debounce with no real downside
    /// (a little extra leading silence in what's sent is harmless -- the
    /// server's own STT already expects to pad with silence regardless, see
    /// stt_kyutai.py's module doc comment).
    private static let preRollDurationSeconds: Double = 0.5
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

    /// True while the child/parent has muted the mic via the UI. Checked
    /// first thing in captureAudio(), before audio ever reaches the VAD --
    /// this is a deliberate "mute" (matching the mental model of a video-
    /// call mute button), not merely a barge-in suppressor: while muted, no
    /// new speechStart can be detected either, not just interrupts of an
    /// in-flight reply. That's the whole point of exposing it as a plain
    /// mute toggle rather than a narrower "block interrupts" flag -- it's
    /// simpler to explain to a parent and impossible to misread from the
    /// UI. Muting mid-.listening utterance is handled explicitly by
    /// setMuted(_:) below: since captureAudio() stops feeding the VAD the
    /// instant this flips true, the VAD would otherwise never observe the
    /// silence hangover needed to fire speechEnd on its own, leaving the
    /// state machine stuck in .listening forever.
    private var isMuted = false

    public init(
        connection: any ServerConnecting,
        audio: any AudioPlaying,
        vad: any VoiceActivityDetecting,
        waitingDittyAudio: Data? = nil
    ) {
        self.connection = connection
        self.audio = audio
        self.vad = vad
        self.waitingDittyAudio = waitingDittyAudio
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
        guard !isMuted else { return }
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

    /// Toggles mic muting -- see isMuted's doc comment for exactly what
    /// this does and doesn't affect. Safe to call from any state; has no
    /// effect on audio the server has already been sent or is already
    /// playing back, only on mic audio captured from this point forward.
    ///
    /// isMuted is set BEFORE the handleSpeechEnd() call below (not after),
    /// so that even though handleSpeechEnd() suspends (its own
    /// `connection.send(.speechEnd)` await), any captureAudio() call
    /// scheduled concurrently during that suspension already observes
    /// isMuted == true and skips feeding the VAD -- same reasoning as
    /// isFlushing being set before its own control-frame send elsewhere in
    /// this file.
    ///
    /// Muting while .listening finalizes the in-progress utterance exactly
    /// as if the VAD itself had observed silence: this reuses
    /// handleSpeechEnd() as-is (its own `guard machine.state == .listening`
    /// makes this a no-op in every other state), so whatever was captured
    /// up to the moment of muting is sent to the server as a normal turn --
    /// "stop listening" really does stop listening, rather than leaving the
    /// state machine stuck in .listening with no more audio ever arriving
    /// to end it.
    public func setMuted(_ muted: Bool) async {
        isMuted = muted
        if muted {
            await handleSpeechEnd()
        }
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

    /// Starts looping waitingDittyAudio (if configured) through the same
    /// AudioPlaying path real replies use. A no-op if already running or if
    /// no ditty audio was configured (see waitingDittyAudio's doc comment).
    /// Each loop iteration awaits a full play() call, so the ditty's own
    /// baked-in trailing silence (see WaitingDitty.audio) paces the loop --
    /// no separate timer/sleep needed.
    private func startWaitingDitty() {
        guard let waitingDittyAudio, dittyTask == nil else { return }
        dittyTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.audio.play(waitingDittyAudio)
            }
        }
    }

    /// Stops the ditty loop, if one is running. Calls stopPlaybackImmediately()
    /// unconditionally (safe even if nothing is playing) rather than relying
    /// on cancellation alone to silence a note already in flight -- the same
    /// reasoning as interrupt()'s own use of it: cancelling dittyTask only
    /// stops the NEXT loop iteration from starting, it doesn't by itself cut
    /// off audio the player node is already partway through. Called before
    /// any real reply audio starts playing, so the two can never be
    /// in-flight on the same player node at once.
    private func stopWaitingDitty() {
        guard dittyTask != nil else { return }
        dittyTask?.cancel()
        dittyTask = nil
        audio.stopPlaybackImmediately()
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
        // Audio frames carry no turn_id of their own (see Protocol.swift --
        // only the JSON control events do), but the server only ever sends
        // audio strictly between a matching response_text and that same
        // turn's turn_end, so this tracks "was the most recent turn_id-
        // bearing event for the turn we're currently accepting" and gates
        // audio on it. Starts false: audio can't legitimately arrive before
        // any text event has established which turn it belongs to.
        var isCurrentTurnAudio = false
        for await event in connection.events() {
            if case .closed = event {
                stopWaitingDitty()
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

            if case .audio = event {
                guard isCurrentTurnAudio else { continue }
                turnContinuation?.yield(event)
                continue
            }

            let eventTurnId: Int
            switch event {
            case .message(.transcriptPartial(_, let turnId)),
                 .message(.transcriptFinal(_, let turnId)),
                 .message(.responseText(_, let turnId)),
                 .message(.turnEnd(let turnId)),
                 .message(.error(_, let turnId)):
                eventTurnId = turnId
            case .audio, .closed:
                fatalError("unreachable: handled above")
            }

            isCurrentTurnAudio = eventTurnId == currentTurnId
            guard isCurrentTurnAudio else {
                print("SessionCoordinator: discarding \(event) -- turn_id \(eventTurnId) does not match current turn \(currentTurnId)")
                continue
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
            // been preempted -- that in-turn behavior is unchanged. Only
            // reached for turn_id-matching errors -- see the guard above --
            // so a stale, already-abandoned turn's error can no longer
            // overwrite a legitimate current one.
            if case .message(.error(let text, _)) = event {
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
        // Assigned before the control frame's own await below, same
        // reasoning as isFlushing just above it: machine.state is already
        // .listening at this point, so the id must be settled before
        // anything else can suspend and let a stale/concurrent read of it
        // through.
        currentTurnId += 1
        // Must be set before the control frame's own await below -- see
        // isFlushing's and flushPreRoll()'s doc comments. machine.state is
        // already .listening at this point (machine.handle() above flipped
        // it synchronously), so without this, a captureAudio() call
        // delivered during the send's suspension would race it.
        isFlushing = true
        try? await connection.send(.speechStart(turnId: currentTurnId))
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
        startWaitingDitty()
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
            if Task.isCancelled {
                print("SessionCoordinator: discarding \(event) -- this turn was cancelled")
                return
            }
            switch event {
            case .audio(let pcm):
                if machine.state == .waitingForReply {
                    // Real reply audio is about to start -- stop the
                    // ditty (if any) BEFORE playing it, so the two can
                    // never be in flight on the same player node at once.
                    stopWaitingDitty()
                    guard (try? machine.handle(.audioChunkReceived)) != nil else { return }
                }
                await audio.play(pcm)
            case .message(.turnEnd(_)):
                // Covers the empty-reply case: no .audio event ever
                // arrives, so this is the only place left to stop a
                // still-looping ditty for this turn.
                stopWaitingDitty()
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                return
            case .message(.error(let text, _)):
                stopWaitingDitty()
                lastErrorMessage = text
                // Mirrors the server's own behavior: end the turn
                // immediately rather than waiting for a turn_end the
                // error may have preempted.
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                return
            case .message(.transcriptFinal(let text, _)):
                lastTranscript = text
                continue
            case .message(.responseText(let text, _)):
                lastReply = text
                continue
            case .message(.transcriptPartial(_, _)):
                continue
            case .closed:
                stopWaitingDitty()
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
        stopWaitingDitty()
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        connection.close()
        vad.close()
    }

    private func interrupt() async {
        stopWaitingDitty()
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
        // Same reasoning as handleSpeechStart()'s currentTurnId += 1: must
        // be assigned before the control frame's own await below, so
        // consumeServerEvents() can't observe a stale value while this is
        // suspended sending it.
        currentTurnId += 1
        // See the matching comment in handleSpeechStart(): must be set
        // before the control frame's own await below, for the same reason.
        isFlushing = true
        try? await connection.send(.interrupt(turnId: currentTurnId))
        await flushPreRoll()
    }
}
