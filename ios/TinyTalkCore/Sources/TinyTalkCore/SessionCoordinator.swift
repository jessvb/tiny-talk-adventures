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
/// cancellation of whatever runTurn() is currently awaiting. Real-turn
/// audio calls `await audio.enqueue(_:)`, which schedules a buffer and
/// returns without waiting for it to actually play -- it's that
/// `enqueue(_:)` call, not per-chunk playback, that's the in-flight await
/// cancelled here -- confirmed with a test asserting the in-flight
/// `enqueue(_:)` call observes cancellation and does not complete after
/// the interrupt. (Genuinely waiting for real playback completion happens
/// only once per turn, at turnEnd -- see readyToShowTheEnd's doc comment --
/// and the machine stays .speaking through that wait, so a barge-in during
/// the reply's audible tail still reaches interrupt().)
/// `stopPlaybackImmediately()` is still called synchronously first, before
/// any of that cancellation machinery runs, so the child stops hearing the
/// agent instantly regardless of how long structured cancellation takes to
/// propagate.
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
    /// How long the ditty is allowed to loop before this gives up and
    /// treats the turn as failed -- see startWaitingDitty()/
    /// handleDittyTimeout(). Without this, a server that goes quiet mid-turn
    /// (for any reason other than the ones stopWaitingDitty() already
    /// covers) loops the jingle forever with no feedback -- a real failure
    /// was observed looping ~5 minutes before this existed. 45s default:
    /// generous headroom over any real multi-second STT/LLM/TTS reply.
    private let dittyTimeoutSeconds: TimeInterval
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
    /// Which turn_id lastTranscript/lastReply actually belong to -- NOT the
    /// same thing as activeTurnId (currentTurnId, whichever turn is now in
    /// progress). A poll-loop UI building a running history (e.g. AppModel's
    /// turns array) needs this: activeTurnId can already have advanced to a
    /// NEW turn (handleSpeechStart() bumps it the instant the child starts
    /// talking again) while lastTranscript/lastReply still hold the
    /// PREVIOUS turn's text, since that new turn's own transcriptFinal/
    /// responseText haven't arrived yet. Keying a dedup check off
    /// activeTurnId instead of these was confirmed on real hardware to
    /// duplicate the previous turn's bubble the moment the child spoke
    /// again, and then silently swallow the real new turn's text once it
    /// did arrive (already "seen" under the wrong turn_id) -- the UI
    /// appeared backed up by exactly one turn.
    public private(set) var lastTranscriptTurnId: Int?
    public private(set) var lastReplyTurnId: Int?
    /// The latest error worth showing, for the same poll-loop UI. Sticky
    /// until it goes stale: cleared when a new turn begins (beginNewTurn())
    /// or a new story starts (newStory()) -- so a UI can tell a repeat of
    /// the same text apart from the old value still sitting there.
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

    /// True from rewritingStarted until rewritingDone -- see those
    /// ServerEvent cases' doc comments. A UI (e.g. TheEndView) polls this
    /// to show/hide a "still being created" state.
    public private(set) var isRewriting = false
    public private(set) var latestStoryList: [SavedStorySummary]?
    public private(set) var latestStoryDetail: SavedStoryDetail?
    /// Every page-image request's result received so far, keyed
    /// "storyId#pageIndex" (matching AppModel.pageImages' own key format
    /// exactly, so its poll loop can merge this wholesale -- see
    /// AppModel.swift's startPollingState()). Accumulating, not a
    /// single-slot "latest" value: SwiftUI's TabView(.page) style fires
    /// .onAppear for more than one page during a swipe transition, so
    /// ReadingView routinely has two+ getPageImage() calls in flight for
    /// DIFFERENT pages at once. An earlier single-slot design
    /// (latestPageImage: PageImageResult?) silently lost whichever
    /// request's response arrived first once a second one overwrote it
    /// before AppModel's poll loop got a chance to read it -- that page's
    /// art then never showed, and never retried, since ReadingView's own
    /// dedupe had already marked it "requested". Never pruned entries for
    /// a story the child has moved on from -- harmless (AppModel/
    /// ReadingView only ever read keys for the currently-open story), and
    /// simpler than reasoning about when it would be safe to evict one.
    public private(set) var pageImages: [String: Data] = [:]
    /// Every getPageImage() request sent that hasn't yet been resolved by
    /// a matching page_image_done marker, in the order sent -- see
    /// getPageImage() and consumeServerEvents()'s .message(.pageImageDone)
    /// handling below. A FIFO queue (not a single optional) for the same
    /// reason pageImages is a dictionary: more than one request can be
    /// genuinely in flight at once. FIFO ordering is safe here because
    /// the server's connection-handling loop awaits each incoming
    /// message's handler to completion before reading the next one (see
    /// session.py's handle_text/handle_connection), so responses to
    /// get_page_image requests arrive in the exact order the requests
    /// were sent -- not merely usually, but guaranteed by the server's own
    /// single-threaded-per-connection handling.
    private var pendingPageImageRequests: [(storyId: String, pageIndex: Int)] = []
    /// The most recently arrived .audio frame while ANY page-image
    /// request is pending -- see the .audio handling in
    /// consumeServerEvents() below. A single slot (not one per pending
    /// request) is safe given the FIFO guarantee above: the server sends
    /// at most one binary frame per get_page_image request, immediately
    /// followed by that request's own page_image_done marker, before ever
    /// starting the next one -- so at most one such frame is ever
    /// "unclaimed" at a time. Cleared the instant its matching marker
    /// consumes it (whether or not that marker actually carried an
    /// image), so a later marker can never reuse stale bytes that
    /// belonged to an earlier request.
    private var pendingPageImageBytes: Data?
    /// The single in-flight synthesizePage() request, if any -- see
    /// getPageImage()'s pendingPageImageRequests for why THAT one is a
    /// queue. This one is a single optional, not a queue: ReadingView's
    /// manual tap-per-page 🔊 model (no prefetch-all-pages, unlike images)
    /// means at most one page-audio request is ever genuinely in flight at
    /// once. Checked before the turn-scoped isCurrentTurnAudio gate in
    /// consumeServerEvents(), same placement as pendingPageImageRequests,
    /// so incoming page audio isn't silently dropped or misrouted as
    /// live-turn audio. Cleared by stopPageAudio(), by an unrelated error
    /// (mirrors the image case), by handleConnectionLost(), and by
    /// matching page_audio_done marker.
    private var pendingPageAudioRequest: (storyId: String, pageIndex: Int)?
    /// Count of still-outstanding page_audio_done markers from requests
    /// this coordinator has already abandoned via stopPageAudio() (with a
    /// request genuinely still in flight at the time) but whose remaining
    /// audio the server is still draining -- see stopPageAudio()'s doc
    /// comment. The server processes one client message to completion
    /// before starting the next (see pendingPageImageRequests' doc
    /// comment for the identical guarantee, relied on there for the image
    /// case), so while this is > 0, EVERY arriving .audio frame is
    /// guaranteed to be a leftover chunk from an abandoned generation,
    /// never real audio for whatever NEW request pendingPageAudioRequest
    /// now names -- discarding unconditionally here is what stops a rapid
    /// re-tap from playing the tail of the previous page over the start
    /// of the new one. A counter, not a boolean, because a second rapid
    /// re-tap before the first abandoned request's marker arrives must
    /// not lose track of needing to discard for BOTH.
    private var pendingPageAudioDoneMarkersToDiscard = 0
    /// True once BOTH signals for "the story just concluded, AND the
    /// concluding turn's audio has genuinely finished playing" have been
    /// observed. A UI must wait for this (not just isRewriting) before
    /// navigating to The End screen -- see the two private flags below
    /// for why isRewriting alone is not sufficient.
    ///
    /// The server sends rewriting_started immediately after the
    /// concluding turn's turn_end (see session.py's _run_turn: the
    /// REWRITE_STARTED transition and turn_end send happen before
    /// save_story()/encode_rewriting_started()). But "turn_end sent by
    /// the server" is not the same as "this client has finished PLAYING
    /// that turn's audio": each `.audio` event inside runTurn() only
    /// calls `await audio.enqueue(_:)`, which schedules a buffer and
    /// returns immediately without waiting for it to actually play. The
    /// one genuine wait for real playback completion happens once per
    /// turn, in the `.message(.turnEnd(_))` case, via `await
    /// audio.waitForPlaybackToFinish()` immediately before
    /// noteTurnPlaybackFinished() -- a suspension consumeServerEvents()
    /// does not go through. consumeServerEvents() reads rewriting_started
    /// off the wire (and would set isRewriting) essentially immediately
    /// after yielding that turn's turnEnd into turnContinuation, with no
    /// suspension point forcing it to wait for runTurn()'s own
    /// waitForPlaybackToFinish() to resolve. In practice this means
    /// rewritingStarted routinely arrives WHILE the last sentence is
    /// still audibly playing, not after -- navigating to The End screen
    /// on isRewriting alone would cut the story off mid-sentence.
    public private(set) var readyToShowTheEnd = false
    /// Set the instant rewritingStarted is observed (see
    /// consumeServerEvents()). Distinct from isRewriting only in that it
    /// never resets back to false on rewritingDone -- readyToShowTheEnd
    /// must not un-latch once both signals have combined, but isRewriting
    /// itself does need to go back to false (a UI polls it to know when
    /// the rewrite has actually finished).
    private var sawRewritingStarted = false
    /// True once the CURRENT turn's turnEnd has been processed inside
    /// runTurn() -- i.e. every audio chunk that turn received has
    /// genuinely finished playing. Reset to false at the start of every
    /// new turn (handleSpeechEnd, resume, concludeStory) so a stale true
    /// left over from an earlier, ordinary turn can never combine with a
    /// later, unrelated rewritingStarted. Also set by
    /// abandonTurnForConcludedStory(): a concluding reply the child talked
    /// over never reaches its own turnEnd handling (that turn's task was
    /// cancelled, or its turn_end discarded as stale), but its audio is
    /// just as over.
    private var currentTurnPlaybackFinished = false

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
        let line = "[\(DebugTimestamp.now())] \(message)"
        print(line)
        debugLog.append(line)
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
        waitingDittyAudio: Data? = nil,
        dittyTimeoutSeconds: TimeInterval = 45
    ) {
        self.connection = connection
        self.audio = audio
        self.vad = vad
        self.waitingDittyAudio = waitingDittyAudio
        self.dittyTimeoutSeconds = dittyTimeoutSeconds
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

    /// Hands completed away-from-home stories to whatever connection is
    /// current -- a no-op (best effort, like sendObjectSeen) if the send
    /// fails; AppModel only clears PendingDemoStore after this returns
    /// without throwing.
    public func syncDemoStories(_ stories: [PendingDemoStoryPayload]) async throws {
        try await connection.send(.syncDemoStories(stories: stories))
    }

    /// Sends the parent's current story-length preference to the server --
    /// see protocol.py's UpdateSettings and this project's
    /// story-length-settings design spec. Fire-and-forget, same pattern
    /// as listStories()/getStory(storyId:): applies to the next story
    /// only, no response expected, no local state to update here (the
    /// values themselves live in AppModel/UserDefaults, not this actor).
    public func updateSettings(targetTurns: Int, pageCount: Int) async {
        try? await connection.send(.updateSettings(targetTurns: targetTurns, pageCount: pageCount))
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
    /// no separate timer/sleep needed. Bounded by dittyTimeoutSeconds: past
    /// that, `onTimeout` runs instead of looping again.
    ///
    /// Shared by the live-turn wait (startWaitingDitty()) and the
    /// page-audio wait (startPageAudioDitty()) -- both play the same clip
    /// through the same single player node. Sharing ONE dittyTask field
    /// (rather than a separate one per purpose) is what makes the no-op-if-
    /// already-running guard below also guarantee the two can never run at
    /// once, with no extra bookkeeping.
    private func startDittyLoop(onTimeout: @escaping @Sendable () async -> Void) {
        guard let waitingDittyAudio, dittyTask == nil else {
            // logDebug, not print: this is the single highest-signal line
            // for diagnosing "the ditty didn't resume after backgrounding"
            // on a real device with no cable attached (see debugLog's own
            // doc comment for why most ditty-loop prints stay excluded from
            // it -- this one is a rare, one-shot event, not per-iteration
            // noise).
            logDebug("SessionCoordinator: startDittyLoop() no-op (audio configured=\(waitingDittyAudio != nil), already running=\(dittyTask != nil))")
            return
        }
        logDebug("SessionCoordinator: starting ditty loop")
        let dittyStartedAt = Date()
        let dittyTimeoutSeconds = dittyTimeoutSeconds
        dittyTask = Task { [weak self] in
            guard let self else { return }
            var iteration = 0
            while !Task.isCancelled {
                if Date().timeIntervalSince(dittyStartedAt) >= dittyTimeoutSeconds {
                    print("SessionCoordinator: ditty loop timed out after \(iteration) iteration(s)")
                    await onTimeout()
                    return
                }
                iteration += 1
                print("SessionCoordinator: ditty loop iteration \(iteration) calling play()")
                await self.audio.play(waitingDittyAudio)
            }
            print("SessionCoordinator: ditty loop ended after \(iteration) iteration(s), cancelled=\(Task.isCancelled)")
        }
    }

    private func startWaitingDitty() {
        startDittyLoop { [weak self] in await self?.handleDittyTimeout() }
    }

    /// Page-audio counterpart to startWaitingDitty() -- covers the gap
    /// between a 🔊 tap and the first real audio chunk actually starting
    /// playback (network round trip + the server's own TTS synthesis time
    /// for that page's text), which previously had no audio feedback at
    /// all -- reported on-device as "I didn't get any voices initially."
    /// Stopped wherever pendingPageAudioRequest itself gets resolved or
    /// abandoned: the first real chunk (consumeServerEvents()'s .audio
    /// branch), stopPageAudio(), a send failure in synthesizePage(), and
    /// the unrelated-error cleanup branch in consumeServerEvents() -- all
    /// of those call the shared stopWaitingDitty() directly rather than a
    /// separate stop function, since stopping is identical regardless of
    /// which purpose started it.
    private func startPageAudioDitty() {
        startDittyLoop { [weak self] in await self?.handlePageAudioDittyTimeout() }
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

    /// Fires when the ditty has been looping for dittyTimeoutSeconds with no
    /// reply -- treats the wait as failed rather than continuing silently
    /// forever. Mirrors runTurn()'s own .message(.error) handling (the same
    /// situation: the wait is over, and not because a reply arrived),
    /// reusing the .turnEnd transition rather than adding a new state, and
    /// relying on the same turnContinuation-is-nil discard every other
    /// abandoned-turn path already uses to make a late reply harmless if the
    /// server responds after this gave up. Guards on still being
    /// .waitingForReply since the ditty loop's timeout check and this call
    /// aren't atomic -- a real reply can start playing (stopWaitingDitty()
    /// already cancelling this very task) in the narrow window between the
    /// loop's check and this method actually running.
    private func handleDittyTimeout() async {
        guard machine.state == .waitingForReply else { return }
        stopWaitingDitty()
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        await setMuted(false)
        lastErrorMessage = "The agent took too long thinking. Can you say something to wake them up?"
        _ = try? machine.handle(.turnEnd)
    }

    /// Page-audio counterpart to handleDittyTimeout() -- deliberately does
    /// NOT touch machine.state/turnContinuation/isMuted the way that one
    /// does: a page-audio wait has no turn of its own to abandon, and a
    /// live turn could genuinely be in progress at the same time (e.g. the
    /// child navigated to Library mid-reply-wait via Elsie's desk's
    /// "Library" menu item) -- this must only ever affect the page-audio
    /// request that's timing out, never an unrelated live turn. Guards on
    /// pendingPageAudioRequest still being set for the same reason
    /// handleDittyTimeout() re-checks machine.state: the loop's timeout
    /// check and this call aren't atomic, so real audio (or an error) may
    /// already have resolved this request in the narrow window between them.
    private func handlePageAudioDittyTimeout() async {
        guard pendingPageAudioRequest != nil else { return }
        stopWaitingDitty()
        pendingPageAudioRequest = nil
        lastErrorMessage = "That page's reading took too long to load."
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
        // A lost connection means no page_image_done marker for ANY
        // currently-pending request will ever arrive -- see
        // pendingPageImageRequests' doc comment. This matters even though
        // .closed itself ends consumeServerEvents() for good, because this
        // method is also reached from the SEND side (a control-frame send
        // failing in handleSpeechStart()/handleSpeechEnd()/interrupt()),
        // which leaves consumeServerEvents() running -- without this, a
        // stuck pendingPageImageRequests queue would permanently divert
        // every later .audio frame away from playback instead of to a live
        // turn. A disconnect invalidates EVERYTHING in flight, not just the
        // oldest request, so the whole queue is cleared, not just one entry.
        pendingPageImageRequests.removeAll()
        pendingPageImageBytes = nil
        // A lost connection means no page_audio_done marker (or further
        // chunks) for any pending synthesizePage() request will ever
        // arrive either -- same reasoning as the image case just above.
        // That applies equally to the markers still owed by already-
        // abandoned requests, so the discard counter resets too:
        // otherwise it would survive into the next connection and eat
        // that connection's first real page-audio chunks.
        pendingPageAudioRequest = nil
        pendingPageAudioDoneMarkersToDiscard = 0
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

    /// Called from runTurn() when ANY turn's turnEnd is processed (not
    /// just a concluding one) -- see currentTurnPlaybackFinished's doc
    /// comment for why that's safe: it's freshly reset to false at the
    /// start of every turn, so this only ever combines with a
    /// rewritingStarted that genuinely belongs to THIS turn.
    private func noteTurnPlaybackFinished() {
        currentTurnPlaybackFinished = true
        maybeSignalReadyToShowTheEnd()
    }

    private func maybeSignalReadyToShowTheEnd() {
        guard sawRewritingStarted, currentTurnPlaybackFinished else { return }
        readyToShowTheEnd = true
    }

    /// Ends whatever turn is in flight because the story it belonged to has
    /// concluded (rewriting_started seen) -- issue #47. From that moment the
    /// server is in its REWRITING gate and silently drops everything the
    /// child says (session.py: "interrupt ignored -- a storybook rewrite is
    /// still in progress"), so a turn started around the conclusion never
    /// gets a reply: its waiting ditty would loop over The End until the
    /// timeout. Used both when the child talks over the concluding reply
    /// after the fact (handleSpeechAfterConclusion()) and when
    /// rewriting_started reveals that a barge-in already replaced the
    /// concluding turn (consumeServerEvents()).
    ///
    /// Counts the concluding turn's playback as finished: the child talked
    /// over its audio (already stopped by that barge-in, or stopped by the
    /// caller here), and with that turn's task cancelled -- or its turn_end
    /// discarded as stale -- nothing else would ever set the flag, so The
    /// End would never become reachable.
    private func abandonTurnForConcludedStory() async {
        stopWaitingDitty()
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        // Same unconditional "abandon whatever this was" transition
        // newStory() uses: legal from every state, always lands in .idle.
        _ = try? machine.handle(.disconnected)
        // Auto-muted for a .waitingForReply that will now never finish (see
        // isMuted's doc comment); the UI re-mutes by screen as needed.
        await setMuted(false)
        currentTurnPlaybackFinished = true
        maybeSignalReadyToShowTheEnd()
    }

    /// The child started talking while the story is over (isRewriting) --
    /// see abandonTurnForConcludedStory() for why the server would drop
    /// everything they said. Deliberately NOT a new utterance: no
    /// speech_start, no interrupt, no turn, no ditty -- the client never
    /// sends speech the server is going to discard. If the concluding reply
    /// is still playing, talking over it stops it and lets The End appear;
    /// otherwise there is nothing to do (a fresh reconnect during a rewrite
    /// lands here too, with nothing in flight -- and must not fabricate a
    /// concluding turn's "playback finished").
    private func handleSpeechAfterConclusion() async {
        guard machine.state != .idle else { return }
        logDebug("SessionCoordinator: speech while the story is concluded -- stopping the concluding reply instead of starting an utterance (state=\(machine.state))")
        let id = latencyLogger.recordVADFire()
        audio.stopPlaybackImmediately()
        latencyLogger.recordPlaybackStopped(for: id)
        await abandonTurnForConcludedStory()
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
        // The turn_id of the most recent turn_end seen, matching or not.
        // rewriting_started always immediately follows the CONCLUDING turn's
        // turn_end on the wire, so this names the turn that concluded the
        // story -- see the .rewritingStarted case below.
        var lastTurnEndTurnId: Int?
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

            if case .audio(let data) = event {
                if !pendingPageImageRequests.isEmpty {
                    // Assumes the server sends a requested page image as
                    // exactly one binary frame -- if that ever changes to
                    // multiple chunks, this would need to accumulate them
                    // instead of overwriting. Safe to stash in this single
                    // slot even with multiple requests in flight: see
                    // pendingPageImageBytes' own doc comment for the FIFO
                    // guarantee that makes this correct.
                    pendingPageImageBytes = data
                    continue
                }
                if pendingPageAudioDoneMarkersToDiscard > 0 {
                    // A frame that's guaranteed to be a leftover chunk
                    // from an already-abandoned synthesizePage() request
                    // -- see pendingPageAudioDoneMarkersToDiscard's doc
                    // comment. Must be checked before the
                    // pendingPageAudioRequest branch below: once a NEW
                    // request has been sent, pendingPageAudioRequest is
                    // already non-nil again for that new request, but
                    // these bytes still belong to the old one.
                    continue
                }
                if pendingPageAudioRequest != nil {
                    // Unlike images, streamed straight to playback rather
                    // than stashed -- see pendingPageAudioRequest's doc
                    // comment. Safe to check after the image-queue branch
                    // above: the server processes one message at a time to
                    // completion (see pendingPageImageRequests' doc
                    // comment), so any earlier-sent getPageImage requests
                    // fully resolve before a later-sent synthesizePage's
                    // bytes ever start arriving -- these two branches never
                    // actually race for the same frame.
                    // Stops the page-audio ditty before this (or any later)
                    // chunk reaches the shared player node -- a no-op past
                    // the first chunk, since stopWaitingDitty() is already
                    // a no-op once dittyTask is nil. Mirrors runTurn()'s own
                    // .audio case stopping the live-turn ditty before its
                    // first real chunk, for the same "never in flight on
                    // the same player node at once" reason.
                    stopWaitingDitty()
                    await audio.enqueue(data)
                    continue
                }
                guard isCurrentTurnAudio else { continue }
                turnContinuation?.yield(event)
                continue
            }

            if case .message(.error) = event,
               !pendingPageImageRequests.isEmpty || pendingPageAudioRequest != nil
                || pendingPageAudioDoneMarkersToDiscard > 0 {
                // A get_page_image or synthesize_page failure is reported
                // as a generic error frame with no way to correlate it back
                // to a specific pending request -- see
                // pendingPageImageRequests' doc comment. ANY error while
                // either kind of request is pending is treated as a
                // safe-to-clear signal for both: worst case a page's image
                // or audio just never shows up/plays, which is far better
                // than leaving either stuck forever, permanently diverting
                // every later .audio frame away from live-turn playback.
                // The same applies, and matters even more, to markers owed
                // by ALREADY-ABANDONED requests: server-side,
                // handle_synthesize_page() answers a bad story_id/
                // page_index with an error frame and NO page_audio_done
                // (see session.py's _page_or_error), so an abandoned
                // request that fails that way never sends the marker its
                // discard count is waiting for. Without this clause that
                // count would stay above zero forever and the .audio
                // branch above would silently swallow EVERY later frame,
                // live-turn story audio included -- the app would simply
                // go deaf for the rest of the connection.
                // Deliberately does NOT `continue`: the error frame itself
                // still needs to fall through to normal turn-scoped error
                // handling below, unchanged.
                // Captured before clearing below, since stopping the
                // page-audio ditty (if any) needs to know whether THIS
                // error is what it was waiting on -- an unconditional
                // stopWaitingDitty() here would be wrong, since it could
                // just as easily be a live-turn ditty currently running
                // for an entirely unrelated turn (see startPageAudioDitty()'s
                // doc comment on the two sharing one dittyTask), which this
                // page-scoped error must never silence.
                let wasAwaitingPageAudio = pendingPageAudioRequest != nil
                pendingPageImageRequests.removeAll()
                pendingPageImageBytes = nil
                pendingPageAudioRequest = nil
                pendingPageAudioDoneMarkersToDiscard = 0
                if wasAwaitingPageAudio {
                    stopWaitingDitty()
                }
            }

            // Story-lifecycle events carry no turn_id -- they're not
            // scoped to a turn at all (browsing/rewrite status is
            // orthogonal to live turn-taking, see protocol.py's
            // ListStories/GetStory doc comments), so they're handled
            // here directly as actor-level state rather than routed
            // through turnContinuation/runTurn() like turn-scoped
            // events. Must be checked before the turn_id-extraction
            // switch below, which would otherwise have no case for them.
            if case .message(.turnEnd(let turnId)) = event {
                // Recorded before the stale-turn discard below on purpose:
                // a concluding turn_end that lost the race with a barge-in
                // is still the fact rewriting_started needs.
                lastTurnEndTurnId = turnId
            }
            switch event {
            case .message(.rewritingStarted):
                isRewriting = true
                sawRewritingStarted = true
                // The concluding turn is no longer the current one: the
                // child talked over it before this arrived, so what is in
                // flight now is their barge-in utterance -- and the server
                // (already REWRITING when it got that interrupt) ignored it.
                // Without this The End never appeared (issue #47): the
                // concluding turn's task was cancelled, its turn_end was
                // discarded as stale or its flag reset by the new utterance,
                // and nothing ever set currentTurnPlaybackFinished again.
                // Only fires when a turn_end WAS seen: a rewriting_started
                // on a fresh reconnect (nothing concluded on this
                // coordinator) leaves whatever is in flight alone.
                if let concludingTurnId = lastTurnEndTurnId, concludingTurnId != currentTurnId {
                    logDebug("SessionCoordinator: story concluded in turn \(concludingTurnId) but turn \(currentTurnId) is current -- abandoning it (state=\(machine.state))")
                    await abandonTurnForConcludedStory()
                }
                maybeSignalReadyToShowTheEnd()
                continue
            case .message(.rewritingDone):
                isRewriting = false
                continue
            case .message(.storyList(let stories)):
                latestStoryList = stories
                continue
            case .message(.storyDetail(let detail)):
                latestStoryDetail = detail
                continue
            case .message(.pageImageDone(let storyId, let pageIndex, let hasImage)):
                // No turn_id, same as the other story-lifecycle events
                // above -- see pendingPageImageRequests' doc comment for
                // why the .audio case above stashes the preceding binary
                // frame in pendingPageImageBytes rather than yielding it
                // into turnContinuation. Searches for the matching entry
                // (by storyId AND pageIndex) rather than blindly popping
                // the front -- it should typically BE at the front given
                // FIFO ordering, but searching stays robust rather than
                // assuming it, and leaves the queue untouched if nothing
                // matches (mirroring the old single-slot code's behavior
                // for a mismatched marker -- see
                // testPageImageDoneWithMismatchedIdsLeavesPendingRequestIntact).
                if let index = pendingPageImageRequests.firstIndex(where: {
                    $0.storyId == storyId && $0.pageIndex == pageIndex
                }) {
                    pendingPageImageRequests.remove(at: index)
                    if hasImage, let bytes = pendingPageImageBytes {
                        pageImages["\(storyId)#\(pageIndex)"] = bytes
                    }
                    // Cleared unconditionally once consumed by ITS matching
                    // marker, whether or not this marker carried an image --
                    // these bytes must never be reused for a later,
                    // different request's marker.
                    pendingPageImageBytes = nil
                }
                continue
            case .message(.pageAudioDone(let storyId, let pageIndex)):
                // If any abandoned generation's marker is still owed, this
                // MUST be one of those (never the current
                // pendingPageAudioRequest's own marker) -- the server's
                // strict per-connection ordering guarantees an older
                // request's marker always arrives before a newer one's,
                // see pendingPageAudioDoneMarkersToDiscard's doc comment.
                // Consume it as a discard, don't try to match it against
                // pendingPageAudioRequest (which names the NEW request,
                // not the one this marker belongs to).
                if pendingPageAudioDoneMarkersToDiscard > 0 {
                    pendingPageAudioDoneMarkersToDiscard -= 1
                    continue
                }
                // No turn_id, same as the other story-lifecycle events
                // above. Unlike pageImageDone, there is no bytes buffer to
                // consume here -- every chunk already reached playback
                // directly in the .audio branch above. This just clears
                // the pending marker once the matching request's audio is
                // fully sent, so a later unrelated error (see above) no
                // longer needs to guard against clearing a request that's
                // already finished.
                if pendingPageAudioRequest?.storyId == storyId, pendingPageAudioRequest?.pageIndex == pageIndex {
                    pendingPageAudioRequest = nil
                }
                continue
            default:
                break
            }

            let eventTurnId: Int
            switch event {
            case .message(.transcriptPartial(_, let turnId)),
                 .message(.transcriptFinal(_, let turnId)),
                 .message(.responseText(_, let turnId)),
                 .message(.turnEnd(let turnId)),
                 .message(.error(_, let turnId)):
                eventTurnId = turnId
            case .audio, .closed,
                 .message(.rewritingStarted), .message(.rewritingDone),
                 .message(.storyList), .message(.storyDetail),
                 .message(.pageImageDone), .message(.pageAudioDone):
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

    /// Every path that starts a new turn -- a fresh utterance, a barge-in,
    /// "Finish this story" -- takes its id here. Also drops lastErrorMessage
    /// (issue #48): an error from an earlier turn is stale the moment the
    /// child moves on (the "say something to wake them up" message has just
    /// been answered), and AppModel's poll loop shows a coordinator error
    /// only when its value CHANGES -- so a repeat of the very same text
    /// (timing out twice in a row) is only visible if it went back to nil in
    /// between.
    private func beginNewTurn() {
        currentTurnId += 1
        lastErrorMessage = nil
    }

    private func handleSpeechStart() async {
        if isRewriting {
            await handleSpeechAfterConclusion()
            return
        }
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
        beginNewTurn()
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
        // Reset before this new turn starts -- see its own doc comment
        // for why a stale true from an earlier turn must never survive
        // into this one.
        currentTurnPlaybackFinished = false
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
        currentTurnPlaybackFinished = false
        let (turnStream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
        turnContinuation = continuation
        turnTask = Task { [weak self] in
            await self?.runTurn(turnStream)
        }
    }

    /// The "Finish this story" menu action -- see server's
    /// handle_conclude_story(). Cancels whatever's in flight (same
    /// teardown as interrupt()), then -- unlike interrupt(), which lands
    /// in .listening and waits for a NEW speechStart -- immediately sets
    /// up to receive the server's forced final reply, since sending
    /// conclude_story itself triggers that reply with no further speech
    /// needed first (mirrors handleSpeechEnd()'s ordering: send the
    /// control frame, then create turnContinuation/turnTask afterward --
    /// safe because, same as handleSpeechEnd(), the server cannot
    /// possibly start replying before it has received and processed this
    /// send, given the real STT/LLM/TTS latency in between).
    public func concludeStory() async {
        stopWaitingDitty()
        audio.stopPlaybackImmediately()
        turnContinuation?.finish()
        turnContinuation = nil
        turnTask?.cancel()
        turnTask = nil
        _ = try? machine.handle(.conclude)
        // Same reasoning as handleSpeechStart()/interrupt(): must be
        // assigned before the control frame's own await below.
        beginNewTurn()
        await setMuted(true)
        do {
            try await connection.send(.concludeStory(turnId: currentTurnId))
        } catch {
            await handleConnectionLost(reason: "conclude_story send failed while \(machine.state)")
            return
        }
        currentTurnPlaybackFinished = false
        let (turnStream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
        turnContinuation = continuation
        turnTask = Task { [weak self] in
            await self?.runTurn(turnStream)
        }
        startWaitingDitty()
    }

    /// Requests the saved-story list for the Library screen -- see
    /// protocol.py's ListStories. Fire-and-forget, same as
    /// sendObjectSeen(): the response arrives asynchronously and updates
    /// latestStoryList for a UI to poll.
    public func listStories() async {
        try? await connection.send(.listStories)
    }

    /// Requests one saved story's full detail -- see protocol.py's
    /// GetStory. Fire-and-forget; the response updates latestStoryDetail.
    public func getStory(storyId: String) async {
        try? await connection.send(.getStory(storyId: storyId))
    }

    /// See protocol.py's GetPageImage. Fire-and-forget; the response
    /// updates pageImages. Safe to call again for a different page while
    /// an earlier request is still in flight -- see
    /// pendingPageImageRequests' doc comment for why this queues rather
    /// than overwrites.
    public func getPageImage(storyId: String, pageIndex: Int) async {
        let request = (storyId: storyId, pageIndex: pageIndex)
        pendingPageImageRequests.append(request)
        do {
            try await connection.send(.getPageImage(storyId: storyId, pageIndex: pageIndex))
        } catch {
            // This specific request never reached the server, so nothing
            // will ever arrive to resolve it -- remove exactly this entry
            // (not the whole queue; other requests already in flight are
            // unaffected) rather than leaving it stuck with a `try?`,
            // which would permanently divert a later .audio frame away
            // from playback (see pendingPageImageRequests' doc comment and
            // the .audio branch in consumeServerEvents()).
            if let index = pendingPageImageRequests.firstIndex(where: {
                $0.storyId == request.storyId && $0.pageIndex == request.pageIndex
            }) {
                pendingPageImageRequests.remove(at: index)
            }
        }
    }

    /// See protocol.py's SynthesizePage. Fire-and-forget; each chunk is
    /// enqueued to playback as it arrives (see consumeServerEvents()'s
    /// .audio handling) -- unlike getPageImage, there is no result to poll,
    /// since this plays audio rather than producing data a UI reads back.
    /// Starts the page-audio ditty immediately, covering the network +
    /// TTS-synthesis gap before the first real chunk arrives (see
    /// startPageAudioDitty()'s doc comment) -- stopped below on a send
    /// failure, since nothing will ever arrive to stop it the normal way.
    public func synthesizePage(storyId: String, pageIndex: Int) async {
        pendingPageAudioRequest = (storyId: storyId, pageIndex: pageIndex)
        startPageAudioDitty()
        do {
            try await connection.send(.synthesizePage(storyId: storyId, pageIndex: pageIndex))
        } catch {
            // Mirrors getPageImage()'s send-failure cleanup: this request
            // never reached the server, so nothing will ever arrive to
            // resolve it -- clear it now rather than leaving it stuck,
            // which would permanently divert later live-turn audio into
            // playback-as-page-audio (see the .audio branch below).
            if pendingPageAudioRequest?.storyId == storyId, pendingPageAudioRequest?.pageIndex == pageIndex {
                pendingPageAudioRequest = nil
            }
            stopWaitingDitty()
        }
    }

    /// What ReadingView calls when the child swipes to a new page or
    /// leaves Reading while a page's audio is still playing/pending --
    /// mirrors AVSpeechSynthesizer.stopSpeaking(at: .immediate)'s old
    /// role. Must clear pendingPageAudioRequest, not just stop playback:
    /// otherwise a chunk still in flight from the just-abandoned request
    /// would reach consumeServerEvents()'s .audio branch, see the (now
    /// stale) pending request, and start playing again moments after the
    /// child already left the page. There is no wire-level cancellation
    /// for synthesize_page, so the server keeps streaming the abandoned
    /// request's remaining chunks regardless -- which is what
    /// pendingPageAudioDoneMarkersToDiscard exists to swallow, see its
    /// doc comment.
    public func stopPageAudio() async {
        if pendingPageAudioRequest != nil {
            // This request's own page_audio_done marker (and any
            // remaining chunks before it) will still arrive -- see
            // pendingPageAudioDoneMarkersToDiscard's doc comment.
            pendingPageAudioDoneMarkersToDiscard += 1
        }
        pendingPageAudioRequest = nil
        // A no-op if the ditty already stopped itself (real audio already
        // arrived) -- still needed here for the case where the child
        // swipes away/re-taps before any real chunk ever showed up, since
        // nothing else would ever stop it otherwise.
        stopWaitingDitty()
        audio.stopPlaybackImmediately()
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
            // logDebug, not print -- see startWaitingDitty()'s matching
            // comment. This is the line that tells us whether the resumed
            // reply had already fully arrived (expected no-op, see
            // testStartResumedWaitingDittyIsANoOpIfTheTurnAlreadyFinished)
            // versus something else preventing the ditty from starting.
            logDebug("SessionCoordinator: startResumedWaitingDitty() no-op -- state is \(machine.state), not .waitingForReply")
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
                // Enqueues without waiting for real playback completion --
                // multiple .audio events now queue back-to-back on the
                // player node instead of each one fully blocking the next.
                // The old per-play()-call timing diagnostic (measuring
                // overshoot against a single buffer's own duration) no
                // longer means the same thing once calls don't block each
                // other -- see the turnEnd case below for its replacement,
                // which measures the one point that still genuinely waits.
                // See PlaybackQueueTracker's doc comment (AudioEngine.swift)
                // and docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md.
                await audio.enqueue(pcm)
            case .message(.turnEnd(_)):
                // Covers the empty-reply case: no .audio event ever
                // arrives, so this is the only place left to stop a
                // still-looping ditty for this turn -- and, for the same
                // reason, the only place left to auto-unmute if .speaking
                // was never reached (the "waiting" is over either way).
                stopWaitingDitty()
                await setMuted(false)
                turnContinuation = nil
                // .audio events this turn only enqueue()'d their buffers
                // (see the .audio case above) -- this is now the one
                // place that actually waits for genuine playback
                // completion, preserving readyToShowTheEnd's existing
                // "audio has truly finished, not just been scheduled"
                // guarantee (see that property's own doc comment for the
                // past real bug -- The End appearing mid-sentence -- this
                // prevents). Resolves immediately for an empty-reply turn,
                // since no .audio event means nothing was ever enqueued.
                let waitStarted = DispatchTime.now()
                await audio.waitForPlaybackToFinish()
                let waitElapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - waitStarted.uptimeNanoseconds) / 1_000_000_000
                logDebug("waitForPlaybackToFinish() took \(String(format: "%.2f", waitElapsedSeconds))s at turnEnd")
                // The machine only leaves .speaking NOW, once playback has
                // genuinely finished -- not when the server's turn_end
                // arrived (issue #28). The server synthesizes far faster
                // than real time, so with pipelined playback turn_end lands
                // while most of the reply is still audibly playing; going
                // .idle that early meant a child talking over that tail hit
                // handleSpeechStart()'s ordinary new-utterance path, which
                // never calls audio.stopPlaybackImmediately() (only
                // interrupt(), reached from .waitingForReply/.speaking,
                // does) -- Elsie just kept talking, and StoryView's status
                // line already read "Ready when you are". Before pipelining
                // this held automatically, since each play() call awaited
                // its own buffer. Skipped if this turn was cancelled during
                // the wait (a barge-in, newStory() or concludeStory()
                // already moved the machine on): applying this turnEnd to
                // whatever state that left behind -- e.g. a NEW turn's
                // .waitingForReply -- would corrupt it.
                if !Task.isCancelled {
                    _ = try? machine.handle(.turnEnd)
                }
                noteTurnPlaybackFinished()
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
            case .message(.transcriptFinal(let text, let turnId)):
                lastTranscript = text
                lastTranscriptTurnId = turnId
                continue
            case .message(.responseText(let text, let turnId)):
                lastReply = text
                lastReplyTurnId = turnId
                continue
            case .message(.transcriptPartial(_, _)):
                continue
            case .closed:
                stopWaitingDitty()
                await setMuted(false)
                return
            case .message(.rewritingStarted), .message(.rewritingDone),
                 .message(.storyList), .message(.storyDetail),
                 .message(.pageImageDone), .message(.pageAudioDone):
                fatalError("unreachable: consumeServerEvents() never forwards story-lifecycle events into turnContinuation")
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
        // issue #32: a rewrite still genuinely in progress means the
        // server's own REWRITING gate will silently ignore the
        // new_story message below (session.py's handle_new_story()) --
        // resetting isRewriting/readyToShowTheEnd here anyway would lie
        // to the rest of this coordinator (in particular
        // handleSpeechStart()'s isRewriting guard, added for #47) about
        // that, letting a turn through that the server will just as
        // silently drop, reintroducing the original hang. Leaving
        // everything untouched means the caller's UI keeps showing
        // whatever it already shows for isRewriting == true (StoryView's
        // "Elsie is finishing your storybook..." busy state) instead of
        // pretending a new story started.
        guard !isRewriting else {
            logDebug("SessionCoordinator: newStory ignored -- a storybook rewrite is still in progress")
            return
        }
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
        lastTranscriptTurnId = nil
        lastReplyTurnId = nil
        lastErrorMessage = nil
        // A fresh story means a fresh conclusion-tracking cycle -- these
        // are already all at their defaults here (the guard above
        // returns early whenever isRewriting is true, which is the only
        // way any of them could be non-default), but reset explicitly
        // rather than trust that invariant silently. latestStoryList/
        // latestStoryDetail are NOT reset here -- they're about browsing
        // past stories, unrelated to the live one just abandoned.
        isRewriting = false
        sawRewritingStarted = false
        currentTurnPlaybackFinished = false
        readyToShowTheEnd = false
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
        // Same reasoning as handleSpeechStart()'s beginNewTurn(): must be
        // assigned before the control frame's own await below, so
        // consumeServerEvents() can't observe a stale value while this is
        // suspended sending it.
        beginNewTurn()
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
