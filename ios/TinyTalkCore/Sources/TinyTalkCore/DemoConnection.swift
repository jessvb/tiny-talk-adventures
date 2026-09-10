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
    private let targetTurns: Int
    private let onStoryCompleted: ((PendingDemoStoryPayload) -> Void)?

    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>

    private let lock = NSLock()
    private var currentTurnId = 0
    private var audioBuffer = Data()
    private var conversation = DemoConversation()
    private var storyArc: StoryArc
    private var objectTracker = ObjectTracker()
    private var turnTask: Task<Void, Never>?

    public init(
        chatClient: any ChatCompleting,
        sttClient: any SpeechTranscribing,
        ttsClient: any SpeechSynthesizing,
        animalFactTracker: AnimalFactTracker,
        systemPrompt: String = DemoConnection.defaultSystemPrompt,
        targetTurns: Int = 7,
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) {
        self.chatClient = chatClient
        self.sttClient = sttClient
        self.ttsClient = ttsClient
        self.animalFactTracker = animalFactTracker
        self.systemPrompt = systemPrompt
        self.targetTurns = targetTurns
        self.onStoryCompleted = onStoryCompleted
        self.storyArc = StoryArc(targetTurns: targetTurns)
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
    }

    public func send(_ message: ClientMessage) async throws {
        switch message {
        case .speechStart(let turnId):
            lock.withLock {
                turnTask?.cancel()
                turnTask = nil
                currentTurnId = turnId
                audioBuffer = Data()
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
                turnTask?.cancel()
                turnTask = nil
                currentTurnId = turnId
                audioBuffer = Data()
            }
        case .objectSeen(let label):
            let tracker = lock.withLockReturning { objectTracker }
            tracker.recordSeen(label: label)
        case .newStory:
            lock.withLock {
                turnTask?.cancel()
                turnTask = nil
                conversation = DemoConversation()
                storyArc = StoryArc(targetTurns: targetTurns)
                objectTracker = ObjectTracker()
            }
            await animalFactTracker.reset()
        case .syncDemoStories:
            // Never legitimately sent to a DemoConnection: syncDemoStories
            // is only ever issued by AppModel.connect()'s real (LAN) path,
            // against a WebSocketServerConnection, once already reconnected
            // to the actual server -- see SessionCoordinator.syncDemoStories.
            // No-op here rather than unreachable/fatalError so a future
            // caller mistake fails silently (matching every other best-
            // effort send in this file) instead of crashing the app.
            break
        }
    }

    public func send(audio pcm: Data) async throws {
        lock.withLock { audioBuffer.append(pcm) }
    }

    public func events() -> AsyncStream<ServerConnectionEvent> { stream }

    public func close() {
        lock.lock(); turnTask?.cancel(); turnTask = nil; lock.unlock()
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
    private func runTurn(turnId: Int, pcm: Data) async {
        let (localConversation, localStoryArc, localObjectTracker) = lock.withLockReturning {
            (conversation, storyArc, objectTracker)
        }
        do {
            try Task.checkCancellation()
            let transcript = try await sttClient.transcribe(pcm)
            try Task.checkCancellation()
            continuation.yield(.message(.transcriptFinal(transcript, turnId: turnId)))

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                localConversation.addChild(trimmed)
            }

            var guidance = localStoryArc.recordTurn(childText: transcript)
            let factGuidance = await animalFactTracker.recordTurn(transcript: transcript, stage: localStoryArc.stage)
            if !factGuidance.isEmpty { guidance += "\n\n" + factGuidance }
            let objectGuidance = localObjectTracker.consumeGuidance()
            if !objectGuidance.isEmpty { guidance += "\n\n" + objectGuidance }
            if trimmed.isEmpty { guidance += "\n\n" + Self.sttFailureGuidance }

            let messages = localConversation.toMessages(systemPrompt: systemPrompt + "\n\n" + guidance)
            try Task.checkCancellation()
            let rawReply = try await chatClient.complete(messages: messages)
            try Task.checkCancellation()
            let reply = Safety.filterReply(rawReply.trimmingCharacters(in: .whitespacesAndNewlines))
            localStoryArc.recordReply(replyText: reply)

            continuation.yield(.message(.responseText(reply, turnId: turnId)))

            for await pcmChunk in ttsClient.synthesize(reply) {
                try Task.checkCancellation()
                continuation.yield(.audio(pcmChunk))
            }
            try Task.checkCancellation() // closes the window between the last audio chunk and recording the reply

            localConversation.addAgent(reply)
            continuation.yield(.message(.turnEnd(turnId: turnId)))

            if localStoryArc.isDone {
                await completeStory(conversation: localConversation, storyArc: localStoryArc, objectTracker: localObjectTracker)
            }
        } catch is CancellationError {
            return
        } catch {
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
    private func completeStory(conversation: DemoConversation, storyArc: StoryArc, objectTracker: ObjectTracker) async {
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
            if self.storyArc === storyArc { self.storyArc = StoryArc(targetTurns: targetTurns) }
            if self.objectTracker === objectTracker { self.objectTracker = ObjectTracker() }
        }
        await animalFactTracker.reset()
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
