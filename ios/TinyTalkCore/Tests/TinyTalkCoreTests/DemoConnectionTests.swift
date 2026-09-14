import XCTest
@testable import TinyTalkCore

final class FakeChatClient: ChatCompleting, @unchecked Sendable {
    var replyText = "Once upon a time, a fox went for a walk. What happens next?"
    var error: Error?
    private(set) var receivedMessages: [[[String: String]]] = []

    func complete(messages: [[String: String]]) async throws -> String {
        receivedMessages.append(messages)
        if let error { throw error }
        return replyText
    }
}

final class FakeSttClient: SpeechTranscribing, @unchecked Sendable {
    var transcriptToReturn = "tell me a story"
    var error: Error?

    func transcribe(_ pcm: Data) async throws -> String {
        if let error { throw error }
        return transcriptToReturn
    }
}

final class FakeTtsClient: SpeechSynthesizing, @unchecked Sendable {
    func synthesize(_ text: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data([0x01, 0x02]))
            continuation.finish()
        }
    }
}

final class DemoConnectionTests: XCTestCase {
    private func makeConnection(
        chat: FakeChatClient = FakeChatClient(),
        stt: FakeSttClient = FakeSttClient(),
        tts: FakeTtsClient = FakeTtsClient(),
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) -> DemoConnection {
        DemoConnection(
            chatClient: chat,
            sttClient: stt,
            ttsClient: tts,
            animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher()),
            targetTurns: 7,
            onStoryCompleted: onStoryCompleted
        )
    }

    private static func collectEvents(_ connection: DemoConnection, count: Int) async -> [ServerConnectionEvent] {
        var collected: [ServerConnectionEvent] = []
        for await event in connection.events() {
            collected.append(event)
            if collected.count == count { break }
        }
        return collected
    }

    func testFullTurnEmitsTranscriptReplyAudioThenTurnEnd() async throws {
        let connection = makeConnection()
        async let events = Self.collectEvents(connection, count: 4) // transcriptFinal, responseText, audio, turnEnd

        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(audio: Data(repeating: 0, count: 100))
        try await connection.send(.speechEnd)

        let collected = await events
        guard case .message(.transcriptFinal(let text, let turnId1)) = collected[0] else {
            return XCTFail("expected transcriptFinal, got \(collected[0])")
        }
        XCTAssertEqual(text, "tell me a story")
        XCTAssertEqual(turnId1, 1)

        guard case .message(.responseText(_, let turnId2)) = collected[1] else {
            return XCTFail("expected responseText, got \(collected[1])")
        }
        XCTAssertEqual(turnId2, 1)

        guard case .audio = collected[2] else {
            return XCTFail("expected audio, got \(collected[2])")
        }

        guard case .message(.turnEnd(let turnId3)) = collected[3] else {
            return XCTFail("expected turnEnd, got \(collected[3])")
        }
        XCTAssertEqual(turnId3, 1)
    }

    func testAnEngineFailureEmitsAnErrorEventWithTheTurnId() async throws {
        let stt = FakeSttClient()
        stt.error = DemoConnectionError.groqError("boom")
        let connection = makeConnection(stt: stt)
        async let events = Self.collectEvents(connection, count: 1)

        try await connection.send(.speechStart(turnId: 5))
        try await connection.send(.speechEnd)

        guard case .message(.error(_, let turnId)) = await events.first else {
            return XCTFail("expected an error event")
        }
        XCTAssertEqual(turnId, 5)
    }

    func testInterruptCancelsTheInFlightTurn() async throws {
        // A chat client that never resolves until cancelled, so we can
        // confirm interrupt() actually stops it rather than letting it
        // complete after the fact. `wasCancelled` is set from inside the
        // hanging call's own catch block, so a true reading is direct
        // proof that the real in-flight async work was torn down --
        // not merely that DemoConnection's own bookkeeping (turnTask,
        // currentTurnId, audioBuffer) got reset.
        final class HangingChatClient: ChatCompleting, @unchecked Sendable {
            private let lock = NSLock()
            private var _wasCancelled = false
            var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _wasCancelled }
            private func markCancelled() { lock.lock(); _wasCancelled = true; lock.unlock() }

            func complete(messages: [[String: String]]) async throws -> String {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return "should never get here"
                } catch {
                    markCancelled()
                    throw error
                }
            }
        }
        final class EventCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [ServerConnectionEvent] = []
            func record(_ event: ServerConnectionEvent) { lock.lock(); events.append(event); lock.unlock() }
            var all: [ServerConnectionEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }

        let hangingChat = HangingChatClient()
        let connection = DemoConnection(
            chatClient: hangingChat,
            sttClient: FakeSttClient(),
            ttsClient: FakeTtsClient(),
            animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher())
        )
        let collected = EventCollector()
        let collector = Task<Void, Never> {
            for await event in connection.events() { collected.record(event) }
        }

        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(.speechEnd)
        try await Task.sleep(nanoseconds: 50_000_000) // let the turn actually start (reach the hanging call)
        try await connection.send(.interrupt(turnId: 2))
        try await Task.sleep(nanoseconds: 150_000_000) // let cancellation actually propagate

        XCTAssertTrue(
            hangingChat.wasCancelled,
            "interrupt() should cancel the in-flight chat call itself, not just reset state variables"
        )

        // The turn had already gotten as far as transcribing (turn 1's
        // transcriptFinal is expected and fine) but must never progress
        // past the hanging chat call -- no responseText, audio, or
        // turnEnd for turn 1 should ever arrive.
        collector.cancel()
        for event in collected.all {
            if case .message(.responseText(_, let turnId)) = event {
                XCTFail("responseText for the interrupted turn should never arrive, got turnId \(turnId)")
            }
            if case .message(.turnEnd(let turnId)) = event {
                XCTFail("turnEnd for the interrupted turn should never arrive, got turnId \(turnId)")
            }
        }
    }

    func testConclusionCallsOnStoryCompletedWithTheFullTranscript() async throws {
        var completed: PendingDemoStoryPayload?
        let chat = FakeChatClient()
        chat.replyText = "And they all lived happily ever after. The end."
        let connection = makeConnection(chat: chat, onStoryCompleted: { completed = $0 })
        async let events = Self.collectEvents(connection, count: 4)

        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(.speechEnd)
        _ = await events

        try await Task.sleep(nanoseconds: 50_000_000) // let completeStory()'s own await settle
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.turns.last?.speaker, "agent")
    }
}
