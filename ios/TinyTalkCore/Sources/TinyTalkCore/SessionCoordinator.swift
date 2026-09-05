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
    /// Read-only mirror of currentTurnId -- AppModel polls this (alongside
    /// state) so that if the app is backgrounded, it already knows which
    /// turn to resume without needing an extra actor round-trip during the
    /// narrow window iOS gives an app to react to being backgrounded. See
    /// resume().
    public var activeTurnId: Int { currentTurnId }
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
    /// Set the instant a disconnect is OBSERVED here (see
    /// consumeServerEvents()'s .closed case below) to whichever turn_id
    /// should be resumed on the next connect() -- or nil if there was
    /// nothing in flight to resume (state was .idle or .listening at the
    /// moment of disconnect). This is the counterpart to
    /// handleAppBackgrounded()'s existing PROACTIVE capture of activeTurnId
    /// before an intentional disconnect: that path works because the app
    /// itself chooses to disconnect and can read live state first. A
    /// disconnect this coordinator discovers on its own -- a network drop,
    /// a server hiccup, exactly what "the app is open and waiting, then it
    /// randomly disconnects" looks like -- has no such proactive caller, so
    /// it must be captured HERE, at the exact moment .closed is observed.
    /// Confirmed as the root cause of a real bug: by the time any caller
    /// notices isClosed via polling, machine.state has ALREADY been walked
    /// back to .idle by this same .closed handling, so the information
    /// would otherwise already be lost -- leaving a plain manual
    /// reconnect with no way to resume, silently discarding whatever the
    /// server replays because currentTurnId resets to 0 on a fresh
    /// coordinator and never matches.
    public private(set) var resumableTurnIdAtDisconnect: Int?

    /// A bounded, most-recent-last log of this coordinator's highest-value
    /// diagnostic messages -- specifically the turn_id-mismatch discards
    /// (consumeServerEvents()) and resume-path events (resume()) that,
    /// prior to this being surfaced in the UI (see ContentView.swift), were
    /// only ever visible in Xcode's console. Deliberately NOT every
    /// print() in this file (the waiting-ditty loop alone would print
    /// every few seconds for as long as a turn takes) -- just the events
    /// that actually help diagnose whether a reconnect resumed correctly.
    public private(set) var debugLog: [String] = []
    private static let debugLogCap = 50

    private func logDebug(_ message: String) {
        print(message)
        debugLog.append(message)
        if debugLog.count > Self.debugLogCap {
            debugLog.removeFirst(debugLog.count - Self.debugLogCap)
        }
    }

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

    /// True while the mic is muted -- checked first thing in captureAudio(),
    /// before audio ever reaches the VAD. A deliberate "mute" (matching the
    /// mental model of a video-call mute button), not merely a barge-in
    /// suppressor: while muted, no new speechStart can be detected either,
    /// not just interrupts of an in-flight reply. That's the whole point of
    /// exposing it as a plain mute toggle rather than a narrower "block
    /// interrupts" flag -- it's simpler to explain to a parent and
    /// impossible to misread from the UI.
    ///
    /// This is the ONE flag both the UI's mute button AND this actor's own
    /// automatic mute/unmute (see handleSpeechEnd()/runTurn() -- muted for
    /// the whole .waitingForReply window, unmuted the instant real reply
    /// audio starts) write to, deliberately -- not two separate flags OR'd
    /// together. A parent/child pressing the button DURING an
    /// automatically-muted .waitingForReply window must genuinely unmute
    /// (e.g. to speak up and redirect the story while it's still thinking),
    /// not be silently overridden by the automatic behavior; sharing one
    /// flag is what makes that possible, at the cost of the automatic
    /// unmute-on-.speaking/-on-turn-end paths overriding a *manual* mute
    /// the child pressed moments earlier -- accepted since automatic
    /// unmuting only ever happens at points where nothing is being
    /// captured yet anyway (the child would need to speak AGAIN, at which
    /// point they could re-press the button if they still want it muted).
    ///
    /// Exposed read-only (not just private) so the UI can mirror the
    /// actual current state rather than only knowing what IT last set --
    /// necessary now that this can also change from inside this actor.
    public private(set) var isMuted = false

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

    /// Sends a recognized object's label to the server, to be woven into
    /// whichever turn happens next -- see object_recognition.py's
    /// ObjectTracker for how the server queues it. Deliberately not
    /// gated on `machine.state`: taking a photo is not tied to a turn
    /// boundary (per the design spec), so this is safe to call from
    /// .idle, .listening, .waitingForReply, or .speaking alike. Best
    /// effort, same as every other outgoing send in this file -- a
    /// failure here must not surface as a user-facing error; the child
    /// can just try the camera again.
    public func sendObjectSeen(label: String) async {
        try? await connection.send(.objectSeen(label: label))
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
        guard let waitingDittyAudio, dittyTask == nil else {
            print("SessionCoordinator: startWaitingDitty() no-op (audio configured=\(waitingDittyAudio != nil), already running=\(dittyTask != nil))")
            return
        }
        print("SessionCoordinator: starting ditty loop")
        dittyTask = Task { [weak self] in
            guard let self else { return }
            var iteration = 0
            while !Task.isCancelled {
                iteration += 1
                print("SessionCoordinator: ditty loop iteration \(iteration) calling play()")
                await self.audio.play(waitingDittyAudio)
            }
            print("SessionCoordinator: ditty loop ended after \(iteration) iteration(s), cancelled=\(Task.isCancelled)")
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

    /// Shared connection-lost recovery -- runs whether the loss was
    /// discovered on the receive side (consumeServerEvents()'s `.closed`
    /// case, the WebSocket's own receiveLoop() eventually failing a
    /// task.receive()) or the send side (an outbound control-frame send
    /// throwing in handleSpeechStart()/handleSpeechEnd()/interrupt()).
    ///
    /// The send side matters because machine.state is updated
    /// SYNCHRONOUSLY, before the control frame's own send -- e.g.
    /// handleSpeechEnd() flips to .waitingForReply, then sends speech_end.
    /// If that send throws, the old code (`try? await connection.send(...)`)
    /// silently discarded the error and carried on as if it had succeeded:
    /// the server was never actually told the utterance ended (confirmed
    /// against a real server log: session state stayed LISTENING), so no
    /// reply could ever arrive, and nothing here would notice until
    /// receiveLoop()'s own task.receive() eventually failed on its own --
    /// confirmed on real hardware to take tens of seconds, during which the
    /// app just sat showing .waitingForReply with no way to recover. Being
    /// told a send failed is a strictly earlier, equally trustworthy signal
    /// that the connection is gone, so this reacts to it immediately
    /// instead of waiting for the receive side to eventually agree.
    ///
    /// Idempotent -- safe to call a second time if the receive side later
    /// also independently observes `.closed` for the same underlying
    /// failure, since every mutation here is already a no-op by then.
    private func handleConnectionLost(reason: String) async {
        stopWaitingDitty()
        // Auto-unmute so this coordinator's own state stays consistent for
        // whatever brief window remains before the UI observes isClosed and
        // discards it (see isClosed's doc comment).
        await setMuted(false)
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        // Captured BEFORE machine.handle(.disconnected) below overwrites
        // machine.state -- see resumableTurnIdAtDisconnect's doc comment for
        // why this has to happen exactly here. Same criteria
        // handleAppBackgrounded() already uses: only a reply actually in
        // flight (or already spoken, waiting to be heard) is resumable --
        // .idle/.listening have nothing to pick back up.
        let wasResumable = machine.state == .waitingForReply || machine.state == .speaking
        resumableTurnIdAtDisconnect = wasResumable ? currentTurnId : nil
        logDebug("SessionCoordinator: \(reason) -- resumableTurnIdAtDisconnect=\(String(describing: resumableTurnIdAtDisconnect))")
        // A disconnect mid-turn must not leave the coordinator stuck outside
        // .idle forever -- mirrors the server's own _fail_turn state
        // walk-back on failure. .disconnected is legal from every state (see
        // SessionState.swift), so this is always safe to call regardless of
        // current state.
        _ = try? machine.handle(.disconnected)
        isClosed = true
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
                // This is the real receive-side disconnect path -- runTurn()'s
                // own .closed case is unreachable in practice, since this
                // handler intercepts .closed before it could ever be
                // forwarded into turnContinuation.
                await handleConnectionLost(reason: "connection closed while \(machine.state)")
                // Nothing else (state walking back to .idle looks just like
                // a normal idle state) tells a UI the connection actually
                // died -- see isClosed's doc comment. This loop -- and
                // therefore this actor's only observer of connection.events()
                // -- is about to stop running for good.
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
                logDebug("SessionCoordinator: discarding \(event) -- turn_id \(eventTurnId) does not match current turn \(currentTurnId)")
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
        do {
            try await connection.send(.speechStart(turnId: currentTurnId))
        } catch {
            // See handleConnectionLost's doc comment: a failed send here
            // means the server never learned this turn started, so there is
            // nothing to flush a pre-roll buffer toward -- react the same
            // way a receive-side disconnect would.
            await handleConnectionLost(reason: "speech_start send failed while \(machine.state)")
            return
        }
        await flushPreRoll()
    }

    private func handleSpeechEnd() async {
        guard machine.state == .listening else { return }
        guard (try? machine.handle(.speechEnd)) != nil else { return }
        // machine.state is .waitingForReply from this point on -- "press
        // the mute button" for the child, same as isMuted's doc comment
        // describes, so a manual unmute during this window genuinely
        // works (one shared flag, not a separate auto-mute OR'd on top).
        // setMuted(true) itself calls back into handleSpeechEnd() -- safe,
        // not infinite: machine.state is already .waitingForReply by the
        // time that nested call runs, so its own top guard immediately
        // no-ops it.
        await setMuted(true)
        do {
            try await connection.send(.speechEnd)
        } catch {
            // The exact bug this guards against: machine.state is already
            // .waitingForReply at this point (set synchronously above). If
            // this send fails and is silently ignored, the server is never
            // told the utterance ended -- confirmed against a real server
            // log staying in LISTENING -- so no reply can ever arrive and
            // the app is stuck showing .waitingForReply with nothing to
            // recover it. React the same way a receive-side disconnect
            // would, immediately, instead of relying on receiveLoop() to
            // eventually notice on its own.
            await handleConnectionLost(reason: "speech_end send failed while \(machine.state)")
            return
        }
        let (turnStream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
        turnContinuation = continuation
        turnTask = Task { [weak self] in
            await self?.runTurn(turnStream)
        }
        startWaitingDitty()
    }

    /// Re-enters .waitingForReply for a turn that was already in flight (or
    /// already complete) on the server when this app was backgrounded --
    /// call right after creating a fresh coordinator for a reconnect that
    /// followed a backgrounding-triggered disconnect, and BEFORE calling
    /// start(): this sets currentTurnId and starts turnTask listening on
    /// turnContinuation before consumeServerEvents() (started by start())
    /// exists to forward anything into it, so nothing the server replays
    /// can be discarded as stale for arriving "too early". A no-op if this
    /// coordinator is not freshly-.idle (only ever called on a fresh one in
    /// practice).
    ///
    /// turnId must be whatever turn_id was active when the disconnect
    /// happened (AppModel polls activeTurnId for exactly this) -- the
    /// server stamps every replayed event with that same id, and
    /// consumeServerEvents() discards anything whose turn_id doesn't match
    /// currentTurnId.
    ///
    /// Deliberately identical whether the disconnect happened while
    /// .waitingForReply or already .speaking: the server always replays a
    /// held reply from its start (see replay_last_turn() on the server), so
    /// there is nothing state-specific left to resume into -- both cases
    /// are "wait for the reply to (re)arrive from the top."
    ///
    /// Deliberately does NOT start the waiting ditty itself -- see
    /// startResumedWaitingDitty(), which the caller (AppModel.connect(
    /// resumingTurnId:)) invokes separately, only after mic capture has
    /// been started. Confirmed on real hardware: calling play() (and so
    /// engine.start()) before the mic capture pipeline has ever configured
    /// RealAudioEngine's input side reliably fails with an input/output
    /// sample-rate mismatch inside CoreAudio's voice-processing unit --
    /// every retry attempt failed identically, unlike the transient
    /// "route still settling" case RealAudioEngine's own retries already
    /// handle. This method still sets currentTurnId and starts turnTask
    /// listening on turnContinuation synchronously, before start() is
    /// called, for the reason described above -- only the ditty's first
    /// play() call needed to move later.
    public func resume(turnId: Int) async {
        guard (try? machine.handle(.resumed)) != nil else {
            logDebug("SessionCoordinator: resume(turnId: \(turnId)) ignored -- not fresh/.idle (state=\(machine.state))")
            return
        }
        currentTurnId = turnId
        logDebug("SessionCoordinator: resumed into .waitingForReply for turn_id=\(turnId)")
        // "Press the mute button" for the wait, same as handleSpeechEnd() --
        // there is nothing new to say until this replayed/resumed turn
        // finishes.
        await setMuted(true)
        let (turnStream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
        turnContinuation = continuation
        turnTask = Task { [weak self] in
            await self?.runTurn(turnStream)
        }
    }

    /// Starts the waiting-ditty loop for a turn resume() already set up --
    /// split out for ordering reasons only, see resume()'s doc comment.
    /// Guards on still being .waitingForReply since, by the time the
    /// caller gets around to calling this (after mic capture has started,
    /// which can itself take a couple of seconds under real hardware's own
    /// retry logic), the resumed reply may have already arrived and moved
    /// playback past the point where a ditty makes sense.
    public func startResumedWaitingDitty() {
        guard machine.state == .waitingForReply else {
            print("SessionCoordinator: startResumedWaitingDitty() no-op -- state is \(machine.state), not .waitingForReply")
            return
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
                logDebug("SessionCoordinator: discarding \(event) -- this turn was cancelled")
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
                    // machine.state is .speaking from this point on --
                    // "press the mute button" again to auto-unmute the
                    // instant real reply audio starts, so barge-in works
                    // normally once there's something to barge in on. If
                    // the child already manually unmuted themselves during
                    // the wait, this is a harmless no-op (already false).
                    await setMuted(false)
                }
                await audio.play(pcm)
            case .message(.turnEnd(_)):
                // Covers the empty-reply case: no .audio event ever
                // arrives, so this is the only place left to stop a
                // still-looping ditty for this turn -- and, for the same
                // reason, the only place left to auto-unmute if .speaking
                // was never reached (the "waiting" is over either way).
                stopWaitingDitty()
                await setMuted(false)
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                return
            case .message(.error(let text, _)):
                stopWaitingDitty()
                await setMuted(false)
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
                await setMuted(false)
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

    /// Debug/testing affordance: abandon whatever's happening and start a
    /// fresh story, without a full disconnect/reconnect. Mirrors
    /// interrupt()'s teardown of any in-flight turn (nothing to salvage --
    /// the story it belonged to is being discarded server-side too, see
    /// SessionRunner.handle_new_story()), but lands in .idle rather than
    /// .listening, since nothing new is starting yet. currentTurnId is
    /// deliberately left alone -- it just keeps incrementing across
    /// stories within the same connection, the same way it already does
    /// across ordinary turns, matching the server's own choice not to
    /// reset turn_id numbering either.
    public func newStory() async {
        stopWaitingDitty()
        audio.stopPlaybackImmediately()
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        // .disconnected is legal from every state and always lands in
        // .idle (see SessionState.swift) -- exactly the unconditional
        // "abandon whatever this was, reset" transition needed here too.
        _ = try? machine.handle(.disconnected)
        await setMuted(false)
        lastTranscript = ""
        lastReply = ""
        lastErrorMessage = nil
        try? await connection.send(.newStory)
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
        do {
            try await connection.send(.interrupt(turnId: currentTurnId))
        } catch {
            // Same reasoning as handleSpeechEnd()'s catch block: a failed
            // send here must not be silently ignored.
            await handleConnectionLost(reason: "interrupt send failed while \(machine.state)")
            return
        }
        await flushPreRoll()
    }
}
