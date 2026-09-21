import Foundation

public final class DemoConnection: ServerConnecting, @unchecked Sendable {
    /// Verbatim copy of config.py's SYSTEM_PROMPT, so demo mode's Elsie
    /// sounds the same as the real server's.
    public static let defaultSystemPrompt =
        "You are a warm, interesting storyteller telling a story out loud with a young, " +
        "intelligent child, aged about three to six. You and the child are making the " +
        "story up together. You like to subtly add educational facts to the story to make it " +
        "more interesting. Like any good arts major, you love to develop a good story arc.\n" +
        "\n" +
        "Rules you always follow:\n" +
        "- Reply with one to three short sentences. Never more. The child is " +
        "listening, not reading.\n" +
        "- Keep everything gentle and wholesome. No violence, no weapons, no death, " +
        "no frightening peril.\n" +
        "- End most replies by asking the child what should happen next.\n" +
        "- If the child interrupts you, follow their idea happily. Never scold them " +
        "for interrupting and never insist on finishing your previous sentence.\n" +
        "- Keep the story grounded in the real world: no magic, no talking " +
        "plants or objects, no impossible physics. Animal characters can " +
        "talk and think like people, but everything else about the world " +
        "should be realistic.\n" +
        "- Write plain spoken words only: no emoji, no asterisks, no stage " +
        "directions, no narration about yourself."

    /// Mirrors config.CONCLUDE_SAFETY_RETRY_ATTEMPTS.
    static let concludeSafetyRetryAttempts = 3

    /// Fed back when a forced conclusion trips the kid-safety check --
    /// mirrors session.py's _CONCLUDE_SAFETY_RETRY_TEMPLATE.
    static func concludeSafetyRetryPrompt(terms: String) -> String {
        "That reply isn't appropriate for a young child -- it mentioned: " +
        "\(terms). Give the same warm, complete ending again, same story, but " +
        "leave out any mention of that. Remember: this must be the last " +
        "reply, and it should end with the words \"The end.\""
    }

    /// Fed back when a forced-conclude attempt comes back empty --
    /// mirrors session.py's _CONCLUDE_EMPTY_RETRY_NUDGE.
    static let concludeEmptyRetryNudge =
        "You didn't write anything. Please write your ending now -- a few " +
        "warm sentences that finish the story, ending with the words " +
        "\"The end.\""

    private static let sttFailureGuidance =
        "You didn't hear anything new from the child just now -- it might " +
        "have been background noise. Don't mention this or ask them to " +
        "repeat themselves. Instead, gently continue the story yourself " +
        "using what's already happened, and end with an easy, inviting " +
        "question so they have a natural opening to jump back in."

    private let chatClient: any ChatCompleting
    private let sttClient: any SpeechTranscribing
    private let ttsClient: any SpeechSynthesizing
    private let animalFactTracker: AnimalFactTracker
    private let systemPrompt: String
    private let library: DemoStoryLibrary?
    private let onStoryCompleted: ((PendingDemoStoryPayload) -> Void)?

    /// Optional hook for surfacing DemoConnection's diagnostic lines into
    /// the same on-screen debug log RealAudioEngine.onDebugEvent and
    /// SessionCoordinator.debugLog already feed -- see AudioEngine.swift's
    /// onDebugEvent doc comment for the shared pattern this mirrors, and
    /// DebugTimestamp's doc comment for why a shared, thread-safe formatter
    /// matters here specifically (runTurn runs on a background Task, not a
    /// fixed thread). Pre-timestamped here (not left to the caller) so it
    /// sorts correctly against those other sources' own timestamped lines
    /// after merging.
    public var onDebugEvent: (@Sendable (String) -> Void)?

    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>

    private let lock = NSLock()
    private var currentTurnId = 0
    private var audioBuffer = Data()
    private var conversation = DemoConversation()
    private var storyArc: StoryArc
    private var objectTracker = ObjectTracker()
    private var turnTask: Task<Void, Never>?
    /// The chain of page-browsing media requests (page audio, page images)
    /// -- see startMediaTask().
    private var mediaTask: Task<Void, Never>?
    /// The parent's story-length settings (see the .updateSettings case).
    /// Lock-protected like everything above since a settings change can
    /// arrive on any task. They apply to the NEXT story only.
    private var targetTurns: Int
    private var pageCount: Int
    /// The page count in force when the CURRENT story began -- what its
    /// storybook rewrite will ask for. Captured at story start (not read at
    /// conclusion) so a mid-story settings change never applies
    /// retroactively.
    private var storyPageCount: Int

    public init(
        chatClient: any ChatCompleting,
        sttClient: any SpeechTranscribing,
        ttsClient: any SpeechSynthesizing,
        animalFactTracker: AnimalFactTracker,
        systemPrompt: String = DemoConnection.defaultSystemPrompt,
        targetTurns: Int = 7,
        pageCount: Int = 5,
        library: DemoStoryLibrary? = nil,
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) {
        self.chatClient = chatClient
        self.sttClient = sttClient
        self.ttsClient = ttsClient
        self.animalFactTracker = animalFactTracker
        self.systemPrompt = systemPrompt
        self.targetTurns = targetTurns
        self.pageCount = pageCount
        self.storyPageCount = pageCount
        self.library = library
        self.onStoryCompleted = onStoryCompleted
        self.storyArc = StoryArc(targetTurns: targetTurns)
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
    }

    /// Starts a fresh story with the CURRENT settings: a new arc, and the
    /// page count its storybook will be asked for. Caller must hold `lock`.
    /// Mirrors SessionRunner._begin_story() server-side.
    private func beginStoryLocked() {
        storyArc = StoryArc(targetTurns: targetTurns)
        storyPageCount = pageCount
    }

    /// Cancels and clears both the in-flight live turn and the page-browsing
    /// media chain. Caller must hold `lock`.
    private func cancelInFlightLocked() {
        mediaTask?.cancel()
        mediaTask = nil
        turnTask?.cancel()
        turnTask = nil
    }

    /// The barge-in reset: abandons whatever was in flight, then makes
    /// `turnId` current with an empty audio buffer. Caller must hold `lock`.
    private func beginTurnLocked(turnId: Int) {
        cancelInFlightLocked()
        currentTurnId = turnId
        audioBuffer = Data()
    }

    private func currentTurn() -> Int {
        lock.withLockReturning { currentTurnId }
    }

    public func send(_ message: ClientMessage) async throws {
        switch message {
        case .speechStart(let turnId):
            lock.withLock {
                beginTurnLocked(turnId: turnId)
            }
        case .speechEnd:
            let (turnId, pcm) = lock.withLockReturning { (currentTurnId, audioBuffer) }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runTurn(turnId: turnId, pcm: pcm)
            }
            lock.withLock { turnTask = task }
        case .interrupt(let turnId):
            lock.withLock {
                beginTurnLocked(turnId: turnId)
            }
        case .objectSeen(let label):
            let tracker = lock.withLockReturning { objectTracker }
            tracker.recordSeen(label: label)
        case .newStory:
            lock.withLock {
                cancelInFlightLocked()
                conversation = DemoConversation()
                beginStoryLocked()
                objectTracker = ObjectTracker()
            }
            await animalFactTracker.reset()
        case .updateSettings(let turns, let pages):
            // Same bounds SessionRunner.handle_update_settings enforces
            // server-side (turns 4-12, pages 3-10). Applies to the NEXT
            // story only: an arc that hasn't started is rebuilt now (so the
            // very next story uses it); one already in progress is left
            // alone -- never retroactive.
            lock.withLock {
                targetTurns = max(4, min(12, turns))
                pageCount = max(3, min(10, pages))
                if !storyArc.hasStarted { beginStoryLocked() }
            }
        case .listStories:
            continuation.yield(.message(.storyList(library?.list() ?? [])))
        case .getStory(let storyId):
            if let detail = library?.detail(id: storyId) {
                continuation.yield(.message(.storyDetail(detail)))
            } else {
                continuation.yield(.message(.error("no saved story with id '\(storyId)'", turnId: currentTurn())))
            }
        case .concludeStory(let turnId):
            // Same as a barge-in first: whatever was in flight is abandoned.
            lock.withLock {
                beginTurnLocked(turnId: turnId)
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runTurn(turnId: turnId, pcm: Data(), forceConclude: true)
            }
            lock.withLock { turnTask = task }
        case .getPageImage(let storyId, let pageIndex):
            startMediaTask { [weak self] in
                await self?.runPageImage(storyId: storyId, pageIndex: pageIndex)
            }
        case .synthesizePage(let storyId, let pageIndex):
            startMediaTask { [weak self] in
                await self?.runPageAudio(storyId: storyId, pageIndex: pageIndex)
            }
        case .syncDemoStories:
            // Genuinely never sent here: it is only issued by
            // AppModel.connect()'s real (LAN) path, once already reconnected
            // to the actual server (see SessionCoordinator.syncDemoStories).
            // An explicit no-op -- deliberately not folded into a shared
            // catch-all, so a NEW ClientMessage case can never silently
            // inherit "do nothing" (see DemoProtocolParityTests).
            break
        }
    }

    /// Runs page-browsing media work (page audio, page images) strictly in
    /// arrival order, and never while a live turn is still producing its own
    /// audio. Two reasons, both about the real server's behavior that
    /// DemoConnection must reproduce: SessionCoordinator routes an .audio
    /// frame to page playback whenever a page request is pending and to the
    /// live turn otherwise, which is only correct if frames from the two
    /// never interleave (the server guarantees that by handling one message
    /// at a time to completion); and AVSpeechTts shares one
    /// AVSpeechSynthesizer across every synthesize() call, so two
    /// overlapping ones would cut each other off. Every cancel site sets
    /// `mediaTask` to nil, so a media request issued immediately after a
    /// barge-in does not chain behind the still-terminating cancelled one;
    /// that one's late `pageAudioDone` is discarded or ignored by
    /// SessionCoordinator (its page-audio marker handling), which is why
    /// that is safe.
    private func startMediaTask(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = mediaTask
            let inFlightTurn = turnTask
            mediaTask = Task {
                await previous?.value
                await inFlightTurn?.value
                await work()
            }
        }
    }

    /// Every synthesize_page request ends with EXACTLY ONE terminating
    /// frame -- page_audio_done, or an error for a bad story/page -- even
    /// when cancelled part-way (a barge-in, a new story, close()).
    /// SessionCoordinator keeps a request "pending" until one of those
    /// arrives, and a pending request diverts every later audio frame into
    /// page playback; a request that simply went quiet would wedge live
    /// story audio.
    private func runPageAudio(storyId: String, pageIndex: Int) async {
        guard let text = library?.pageText(id: storyId, index: pageIndex) else {
            continuation.yield(.message(.error(
                "no page \(pageIndex) for story '\(storyId)'", turnId: currentTurn()
            )))
            return
        }
        if !Task.isCancelled {
            for await chunk in ttsClient.synthesize(text) {
                if Task.isCancelled { break }
                continuation.yield(.audio(chunk))
            }
        }
        continuation.yield(.message(.pageAudioDone(storyId: storyId, pageIndex: pageIndex)))
    }

    /// One binary frame then page_image_done(hasImage: true) when the page
    /// has a picture; page_image_done(hasImage: false) alone when it
    /// doesn't; an error frame for a bad story/page -- matching the real
    /// server's handle_get_page_image.
    private func runPageImage(storyId: String, pageIndex: Int) async {
        guard library?.pageText(id: storyId, index: pageIndex) != nil else {
            continuation.yield(.message(.error(
                "no page \(pageIndex) for story '\(storyId)'", turnId: currentTurn()
            )))
            return
        }
        if let image = library?.pageImage(id: storyId, index: pageIndex) {
            continuation.yield(.audio(image))
            continuation.yield(.message(.pageImageDone(storyId: storyId, pageIndex: pageIndex, hasImage: true)))
        } else {
            continuation.yield(.message(.pageImageDone(storyId: storyId, pageIndex: pageIndex, hasImage: false)))
        }
    }

    public func send(audio pcm: Data) async throws {
        lock.withLock { audioBuffer.append(pcm) }
    }

    public func events() -> AsyncStream<ServerConnectionEvent> { stream }

    public func close() {
        lock.lock()
        cancelInFlightLocked()
        lock.unlock()
        continuation.finish()
    }

    /// Captures conversation/storyArc/objectTracker once, under lock, at
    /// the top of the turn -- and operates only on those captured locals
    /// for the rest of the turn. This is deliberate: those three
    /// properties can be reassigned to fresh instances mid-turn by a
    /// concurrent .newStory (or by another turn's completeStory()), and
    /// reading `self.x` fresh at each use site -- as this used to do --
    /// let a still-running turn silently read/write whichever instance
    /// happened to be current at that exact statement, which is how a
    /// just-concluded story could be lost or a reply could leak into the
    /// wrong story's transcript. See task-13-report.md's fix-up entry.
    private func runTurn(turnId: Int, pcm: Data, forceConclude: Bool = false) async {
        let (localConversation, localStoryArc, localObjectTracker, localPageCount) = lock.withLockReturning {
            (conversation, storyArc, objectTracker, storyPageCount)
        }
        do {
            try Task.checkCancellation()
            // "Finish this story" has no child audio: like the server (whose
            // forced conclusion skips STT), no transcript is produced or emitted.
            let transcript: String
            if forceConclude {
                transcript = ""
            } else {
                transcript = try await sttClient.transcribe(pcm)
                try Task.checkCancellation()
                continuation.yield(.message(.transcriptFinal(transcript, turnId: turnId)))
            }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                localConversation.addChild(trimmed)
            }

            // forceConcludeGuidance() deliberately does NOT advance the arc's
            // turn count (an out-of-band final turn, not the next turn of the
            // normal budget), same as story_arc.py.
            var guidance = forceConclude
                ? localStoryArc.forceConcludeGuidance()
                : localStoryArc.recordTurn(childText: transcript)
            let factGuidance = await animalFactTracker.recordTurn(transcript: transcript, stage: localStoryArc.stage)
            if !factGuidance.isEmpty {
                guidance += "\n\n" + factGuidance
                // On-device testing had no way to confirm whether a fact
                // was actually found and woven in, or whether the
                // mechanism never fired -- same visibility gap the TTS
                // debug logging above already closed.
                onDebugEvent?("[\(DebugTimestamp.now())] animal fact guidance added for turn \(turnId)")
            }
            let objectGuidance = localObjectTracker.consumeGuidance()
            if !objectGuidance.isEmpty {
                guidance += "\n\n" + objectGuidance
                onDebugEvent?("[\(DebugTimestamp.now())] object recognition guidance added for turn \(turnId)")
            }
            if trimmed.isEmpty && !forceConclude { guidance += "\n\n" + Self.sttFailureGuidance }

            var messages = localConversation.toMessages(systemPrompt: systemPrompt + "\n\n" + guidance)
            try Task.checkCancellation()
            var raw = try await chatClient.complete(messages: messages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            var reply = Safety.filterReply(raw)
            if forceConclude {
                // An explicit "finish this story" request must not end on the
                // generic safety-fallback line ("...What should happen next?")
                // -- unlike an ordinary turn, where the conversation simply
                // continues, this reply becomes the story's permanent ending.
                // Retry with the flagged word(s) fed back (mirrors
                // session.py's forced-conclude retry) before finally
                // accepting the fallback as a last resort.
                var attempt = 1
                while reply == Safety.safeFallback && attempt < Self.concludeSafetyRetryAttempts {
                    attempt += 1
                    let blocked = Safety.findBlocked(raw)
                    if blocked.isEmpty {
                        // filterReply() also falls back on a genuinely empty
                        // completion -- nothing to name, so nudge the model
                        // to actually write something.
                        messages.append(["role": "user", "content": Self.concludeEmptyRetryNudge])
                    } else {
                        messages.append(["role": "assistant", "content": raw])
                        messages.append([
                            "role": "user",
                            "content": Self.concludeSafetyRetryPrompt(terms: blocked.joined(separator: ", ")),
                        ])
                    }
                    try Task.checkCancellation()
                    raw = try await chatClient.complete(messages: messages)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    reply = Safety.filterReply(raw)
                }
                // Unconditional: an explicit request to finish must not be
                // able to silently fail to end because the reply's wording
                // happens not to match a natural-conclusion phrase.
                localStoryArc.markDone()
            } else {
                localStoryArc.recordReply(replyText: reply)
            }

            continuation.yield(.message(.responseText(reply, turnId: turnId)))

            var ttsChunkCount = 0
            var ttsTotalBytes = 0
            var ttsMinChunkBytes = Int.max
            var ttsMaxChunkBytes = 0
            let synthesisStarted = DispatchTime.now()
            for await pcmChunk in ttsClient.synthesize(reply) {
                try Task.checkCancellation()
                ttsChunkCount += 1
                ttsTotalBytes += pcmChunk.count
                ttsMinChunkBytes = min(ttsMinChunkBytes, pcmChunk.count)
                ttsMaxChunkBytes = max(ttsMaxChunkBytes, pcmChunk.count)
                continuation.yield(.audio(pcmChunk))
            }
            let synthesisElapsedSeconds =
                Double(DispatchTime.now().uptimeNanoseconds - synthesisStarted.uptimeNanoseconds) / 1_000_000_000
            if ttsChunkCount == 0 {
                onDebugEvent?("[\(DebugTimestamp.now())] TTS produced 0 bytes for turn \(turnId)")
            } else {
                // Diagnostic for the on-device-reported garbled/stuttering
                // audio. Chunk count/size distribution and implied audio
                // duration (24kHz mono PCM16 = 48000 bytes/sec) already
                // confirmed the "tch tch tch" cause (AVSpeechSynthesizer.
                // write()'s ~11ms native buffers vs RealAudioEngine.play()'s
                // fully-sequential per-buffer playback wait -- fixed by
                // coalescing in AVSpeechTts). Comparing synthesisElapsedSeconds
                // (this loop's own wall-clock time) against the audio's
                // implied duration tests a different, still-open hypothesis
                // for the residual stutter: production (this loop, yielding
                // into continuation) and playback (SessionCoordinator's
                // separate consuming task, downstream of the same
                // AsyncStream) run concurrently, not sequentially -- if
                // on-device synthesis can't keep up with realtime under
                // concurrent VAD/mic-capture/TTS load, the playback consumer
                // would starve waiting for the next chunk with each
                // individual play() call still measuring perfectly normal,
                // which a play()-side timing check alone could never catch.
                let impliedSeconds = Double(ttsTotalBytes) / 48_000.0
                onDebugEvent?(
                    "[\(DebugTimestamp.now())] TTS for turn \(turnId): \(ttsChunkCount) chunks, " +
                    "\(ttsTotalBytes) bytes (~\(String(format: "%.2f", impliedSeconds))s audio), " +
                    "chunk size \(ttsMinChunkBytes)-\(ttsMaxChunkBytes) bytes, " +
                    "synthesis took \(String(format: "%.2f", synthesisElapsedSeconds))s wall-clock"
                )
            }
            try Task.checkCancellation() // closes the window between the last audio chunk and recording the reply

            localConversation.addAgent(reply)
            continuation.yield(.message(.turnEnd(turnId: turnId)))

            if localStoryArc.isDone {
                await completeStory(
                    conversation: localConversation,
                    storyArc: localStoryArc,
                    objectTracker: localObjectTracker,
                    pageCount: localPageCount
                )
            }
        } catch is CancellationError {
            return
        } catch {
            onDebugEvent?("[\(DebugTimestamp.now())] turn \(turnId) failed: \(error)")
            continuation.yield(.message(.error(
                "Elsie's cloud brain is having trouble -- let's try again in a moment.",
                turnId: turnId
            )))
        }
    }

    /// Takes the turn's own conversation/storyArc/objectTracker as
    /// parameters (the same instances runTurn captured at its start,
    /// never `self`'s live properties) and only resets `self`'s
    /// properties back to fresh instances if they still point at these
    /// same objects (===) -- so a concurrent .newStory that already
    /// replaced them isn't clobbered back to empty by a
    /// now-superseded turn's own cleanup.
    ///
    /// Disclosed, accepted residual risk: if .newStory lands in the
    /// narrow window while this function's own two awaits
    /// (sharedFacts()/reset()) are in flight, a stale
    /// animalFactTracker.reset() can still wipe a new story's
    /// already-accumulated animal-facts progress. Not fixed here --
    /// closing it needs a generation-counter mechanism disproportionate
    /// to this demo feature.
    private func completeStory(
        conversation: DemoConversation, storyArc: StoryArc, objectTracker: ObjectTracker, pageCount: Int
    ) async {
        let turns = conversation.fullHistory
        let sharedFacts = await animalFactTracker.sharedFacts()
        let payload = PendingDemoStoryPayload(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            turns: turns.map {
                PendingDemoStoryTurn(speaker: $0.speaker.rawValue, text: $0.text, interrupted: $0.interrupted)
            },
            sharedFacts: sharedFacts.map { [$0.animal, $0.fact] }
        )
        onStoryCompleted?(payload)

        lock.withLock {
            if self.conversation === conversation { self.conversation = DemoConversation() }
            if self.storyArc === storyArc { beginStoryLocked() }
            if self.objectTracker === objectTracker { self.objectTracker = ObjectTracker() }
        }
        await animalFactTracker.reset()

        // Mirrors SessionRunner._run_turn's concluding branch: turn_end has
        // already gone out (runTurn sent it) and the transcript is saved;
        // only now does rewriting_started follow. With the concluding turn's
        // playback finishing, that event is what makes SessionCoordinator's
        // readyToShowTheEnd true. The build then runs in the background --
        // deliberately NOT tied to this connection's lifetime: it is
        // app-level work, and cancelling it on close() (e.g. the app being
        // backgrounded) would wrongly mark the story failed.
        guard let library else { return }
        library.begin(payload, pageCount: pageCount)
        continuation.yield(.message(.rewritingStarted))
        let continuation = self.continuation
        let storyId = payload.id
        Task {
            await library.buildStorybook(id: storyId)
            continuation.yield(.message(.rewritingDone))
        }
    }
}

private extension NSLock {
    func withLockReturning<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }

    /// Void-returning counterpart to withLockReturning. Both exist because
    /// this toolchain's NSLock.lock()/unlock() are marked unavailable from
    /// asynchronous contexts (a Swift concurrency lint against blocking an
    /// async context directly) -- routing every lock/unlock pair through a
    /// synchronous, non-async wrapper like this one is the standard
    /// workaround, and keeps the actual locking semantics (same lock, same
    /// critical sections) identical to a bare lock()/unlock() pair.
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
