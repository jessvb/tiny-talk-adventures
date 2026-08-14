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

    /// Called by the real AudioEngine (Task 6) as mic audio is captured
    /// while .listening. Exposed as a method (not folded into VAD's own
    /// event stream) because captured audio and VAD's speech/silence
    /// decisions are two independent streams from two different sources.
    public func captureAudio(_ pcm: Data) async {
        guard machine.state == .listening else { return }
        vad.feed(pcm)
        try? await connection.send(audio: pcm)
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
                return
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
        try? await connection.send(.speechStart)
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
            case .message(.error):
                // Mirrors the server's own behavior: end the turn
                // immediately rather than waiting for a turn_end the
                // error may have preempted.
                _ = try? machine.handle(.turnEnd)
                turnContinuation = nil
                return
            case .message(.transcriptPartial), .message(.transcriptFinal), .message(.responseText):
                continue
            case .closed:
                return
            }
        }
    }

    private func interrupt() async {
        let id = latencyLogger.recordVADFire()
        // The critical operation: stop sound RIGHT NOW, before anything
        // else in this method runs, so nothing async can delay it further.
        audio.stopPlaybackImmediately()
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        _ = try? machine.handle(.interrupt)
        try? await connection.send(.interrupt)
        latencyLogger.recordInterruptSent(for: id)
        latencyLogger.recordPlaybackStopped(for: id)
    }
}
