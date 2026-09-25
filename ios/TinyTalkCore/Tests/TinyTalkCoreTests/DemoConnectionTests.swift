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

    // MARK: - shared helpers for the local-server behavior below

    private func makeStore() -> LocalStoryStore {
        LocalStoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func payload(id: String) -> PendingDemoStoryPayload {
        PendingDemoStoryPayload(
            id: id,
            createdAt: "2026-09-19T12:00:00Z",
            turns: [
                PendingDemoStoryTurn(speaker: "child", text: "tell me about a fox", interrupted: false),
                PendingDemoStoryTurn(speaker: "agent", text: "Once there was a clever fox. The end.", interrupted: false),
            ],
            sharedFacts: []
        )
    }

    private func storybookJSON(pages: [String] = ["Page one.", "Page two."]) -> String {
        let object: [String: Any] = ["title": "Pip the Fox", "pages": pages.map { ["text": $0] }]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func makeLibraryConnection(
        chat: any ChatCompleting,
        library: DemoStoryLibrary?,
        tts: any SpeechSynthesizing = FakeTtsClient(),
        targetTurns: Int = 7,
        pageCount: Int = 5,
        onStoryCompleted: ((PendingDemoStoryPayload) -> Void)? = nil
    ) -> DemoConnection {
        DemoConnection(
            chatClient: chat,
            sttClient: FakeSttClient(),
            ttsClient: tts,
            animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher()),
            targetTurns: targetTurns,
            pageCount: pageCount,
            library: library,
            onStoryCompleted: onStoryCompleted
        )
    }

    /// One complete ordinary turn (transcript, reply, audio, turn end),
    /// waiting until the recorder has seen `total` events in all.
    private func speak(_ connection: DemoConnection, recorder: EventRecorder, turnId: Int, total: Int) async throws {
        try await connection.send(.speechStart(turnId: turnId))
        try await connection.send(audio: Data(repeating: 0, count: 100))
        try await connection.send(.speechEnd)
        await recorder.waitForCount(total)
    }

    private func systemPrompt(of call: [[String: String]]) -> String { call[0]["content"] ?? "" }

    // MARK: - update_settings

    func testUpdateSettingsBeforeTheFirstTurnAppliesToThatStory() async throws {
        let chat = FakeChatClient()
        let connection = makeConnection(chat: chat)
        let recorder = EventRecorder(connection)

        try await connection.send(.updateSettings(targetTurns: 4, pageCount: 3))
        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
        try await speak(connection, recorder: recorder, turnId: 2, total: 8)

        // Turn 2 of a 4-turn story is "rising action"; under the default 7
        // it would still be "setup" -- so this proves the new value was used.
        XCTAssertTrue(systemPrompt(of: chat.receivedMessages[1]).contains("The story is building."))
    }

    func testUpdateSettingsMidStoryDoesNotChangeTheStoryInProgress() async throws {
        let chat = FakeChatClient()
        let connection = makeConnection(chat: chat)
        let recorder = EventRecorder(connection)

        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
        try await connection.send(.updateSettings(targetTurns: 4, pageCount: 3))
        try await speak(connection, recorder: recorder, turnId: 2, total: 8)

        // Never retroactive: turn 2 is still "setup" under the story's
        // original 7-turn arc, even though the setting changed in between.
        let prompt = systemPrompt(of: chat.receivedMessages[1])
        XCTAssertTrue(prompt.contains("Continue introducing the setting"))
        XCTAssertFalse(prompt.contains("The story is building."))
    }

    func testUpdateSettingsClampsTurnsToTheServersLowerBound() async throws {
        let chat = FakeChatClient()
        let connection = makeConnection(chat: chat)
        let recorder = EventRecorder(connection)

        try await connection.send(.updateSettings(targetTurns: 1, pageCount: 5))
        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
        try await speak(connection, recorder: recorder, turnId: 2, total: 8)

        // Unclamped, a 1-turn story would jump straight to "resolution" on
        // turn 2. Clamped to the server's minimum of 4 it is "rising action".
        let prompt = systemPrompt(of: chat.receivedMessages[1])
        XCTAssertTrue(prompt.contains("The story is building."))
        XCTAssertFalse(prompt.contains("It's time to resolve"))
    }

    func testUpdateSettingsIsSilent() async throws {
        let connection = makeConnection()
        let recorder = EventRecorder(connection)
        try await connection.send(.updateSettings(targetTurns: 6, pageCount: 4))
        let events = await recorder.settle()
        XCTAssertTrue(events.isEmpty)
    }

    func testUpdateSettingsIgnoresTheHomeServersTtsVoice() async throws {
        // Issue #78: the phone sends its "Home voice" (a Kokoro ID) to
        // whichever connection is live; demo mode speaks with AVSpeech,
        // so the field must be a harmless no-op here.
        let connection = makeConnection()
        let recorder = EventRecorder(connection)
        try await connection.send(.updateSettings(targetTurns: 6, pageCount: 4, llmBackend: "groq", ttsVoice: "bf_emma"))
        let events = await recorder.settle()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - list_stories / get_story

    func testListStoriesAnswersWithTheLibrarysStories() async throws {
        let chat = ScriptedChatClient(storybookJSON())
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        library.begin(payload(id: "abc"), pageCount: 2)
        let connection = makeLibraryConnection(chat: chat, library: library)
        let recorder = EventRecorder(connection)

        try await connection.send(.listStories)

        let events = await recorder.waitForCount(1)
        guard case .message(.storyList(let stories)) = events[0] else {
            return XCTFail("expected storyList, got \(events[0])")
        }
        XCTAssertEqual(stories.map(\.id), ["abc"])
        XCTAssertEqual(stories[0].rewriteStatus, .pending)
    }

    func testListStoriesWithoutALibraryAnswersWithAnEmptyListRatherThanSilence() async throws {
        let connection = makeConnection()
        let recorder = EventRecorder(connection)
        try await connection.send(.listStories)
        let events = await recorder.waitForCount(1)
        guard case .message(.storyList(let stories)) = events[0] else {
            return XCTFail("expected storyList, got \(events[0])")
        }
        XCTAssertEqual(stories, [])
    }

    func testGetStoryAnswersWithTheStoryDetail() async throws {
        let chat = ScriptedChatClient(storybookJSON())
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        library.begin(payload(id: "abc"), pageCount: 2)
        await library.buildStorybook(id: "abc")
        let connection = makeLibraryConnection(chat: chat, library: library)
        let recorder = EventRecorder(connection)

        try await connection.send(.getStory(storyId: "abc"))

        let events = await recorder.waitForCount(1)
        guard case .message(.storyDetail(let detail)) = events[0] else {
            return XCTFail("expected storyDetail, got \(events[0])")
        }
        XCTAssertEqual(detail.id, "abc")
        XCTAssertEqual(detail.title, "Pip the Fox")
        XCTAssertEqual(detail.pages.map(\.text), ["Page one.", "Page two."])
    }

    // MARK: - story conclusion -> storybook

    private static let closingReply = "And they all lived happily ever after. The end."

    func testConclusionEmitsRewritingStartedThenRewritingDoneAfterTurnEnd() async throws {
        let chat = ScriptedChatClient(Self.closingReply, storybookJSON())
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        var completed: PendingDemoStoryPayload?
        let connection = makeLibraryConnection(chat: chat, library: library, onStoryCompleted: { completed = $0 })
        let recorder = EventRecorder(connection)

        try await speak(connection, recorder: recorder, turnId: 1, total: 6)

        let events = recorder.events
        XCTAssertEqual(events.count, 6, "transcriptFinal, responseText, audio, turnEnd, rewritingStarted, rewritingDone")
        guard case .message(.transcriptFinal) = events[0],
              case .message(.responseText) = events[1],
              case .audio = events[2],
              case .message(.turnEnd(let turnId)) = events[3],
              case .message(.rewritingStarted) = events[4],
              case .message(.rewritingDone) = events[5]
        else { return XCTFail("unexpected event order: \(events)") }
        XCTAssertEqual(turnId, 1)
        XCTAssertNotNil(completed, "the transcript must be queued for sync before rewriting_started")

        let saved = try XCTUnwrap(library.detail(id: try XCTUnwrap(completed?.id)))
        XCTAssertEqual(saved.rewriteStatus, .done)
        XCTAssertEqual(saved.title, "Pip the Fox")
    }

    func testAFailedRewriteStillReleasesRewritingDone() async throws {
        let chat = ScriptedChatClient(Self.closingReply, "this is not json at all")
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        var completed: PendingDemoStoryPayload?
        let connection = makeLibraryConnection(chat: chat, library: library, onStoryCompleted: { completed = $0 })
        let recorder = EventRecorder(connection)

        try await speak(connection, recorder: recorder, turnId: 1, total: 6)

        guard case .message(.rewritingDone) = recorder.events.last else {
            return XCTFail("rewriting_done must always follow rewriting_started, even when the rewrite fails")
        }
        XCTAssertEqual(library.detail(id: try XCTUnwrap(completed?.id))?.rewriteStatus, .failed)
    }

    func testWithoutALibraryAConclusionEmitsNoRewritingEvents() async throws {
        let chat = FakeChatClient()
        chat.replyText = Self.closingReply
        let connection = makeConnection(chat: chat)
        let recorder = EventRecorder(connection)

        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
        let events = await recorder.settle()

        XCTAssertEqual(events.count, 4)
        XCTAssertFalse(recorder.messages.contains(.rewritingStarted))
    }

    func testAStorybookAsksForThePageCountInForceWhenItsStoryBegan() async throws {
        // A story only counts as underway once its first turn has been
        // recorded (StoryArc.hasStarted, as on the server) -- so story 1
        // completes one ordinary turn under 5 pages, THEN the parent lowers
        // it to 3. Story 1 must still ask for 5 (never retroactive); story
        // 2, which begins after the change, asks for 3.
        let ordinaryReply = "Once upon a time, a fox went for a walk. What happens next?"
        let chat = ScriptedChatClient(
            ordinaryReply, Self.closingReply, storybookJSON(), // story 1: turn, concluding turn, rewrite
            Self.closingReply, storybookJSON() // story 2: concluding turn, rewrite
        )
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        let connection = makeLibraryConnection(chat: chat, library: library, pageCount: 5)
        let recorder = EventRecorder(connection)

        try await speak(connection, recorder: recorder, turnId: 1, total: 4)
        try await connection.send(.updateSettings(targetTurns: 7, pageCount: 3))
        try await speak(connection, recorder: recorder, turnId: 2, total: 10)
        try await speak(connection, recorder: recorder, turnId: 3, total: 16)

        let firstRewritePrompt = chat.receivedMessages[2][1]["content"] ?? ""
        let secondRewritePrompt = chat.receivedMessages[4][1]["content"] ?? ""
        XCTAssertTrue(firstRewritePrompt.contains("exactly 5 pages"), "story 1 began under 5 pages")
        XCTAssertTrue(secondRewritePrompt.contains("exactly 3 pages"), "story 2 began after the change")
    }

    // MARK: - "Finish this story" (conclude_story)

    func testConcludeStoryRunsOneTurnWithNoTranscriptThenTheConclusionFlow() async throws {
        let chat = ScriptedChatClient("The fox went home and slept. The end.", storybookJSON())
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        let connection = makeLibraryConnection(chat: chat, library: library)
        let recorder = EventRecorder(connection)

        try await connection.send(.concludeStory(turnId: 3))
        let events = await recorder.waitForCount(5)

        XCTAssertEqual(events.count, 5, "responseText, audio, turnEnd, rewritingStarted, rewritingDone")
        guard case .message(.responseText(_, let responseTurn)) = events[0],
              case .audio = events[1],
              case .message(.turnEnd(let endTurn)) = events[2],
              case .message(.rewritingStarted) = events[3],
              case .message(.rewritingDone) = events[4]
        else { return XCTFail("unexpected event order: \(events)") }
        XCTAssertEqual(responseTurn, 3)
        XCTAssertEqual(endTurn, 3)
        // Like the server, a forced conclusion skips STT entirely.
        XCTAssertFalse(recorder.messages.contains { if case .transcriptFinal = $0 { return true } else { return false } })
        XCTAssertTrue(systemPrompt(of: chat.receivedMessages[0]).contains("This must be the last reply"))
    }

    func testConcludeStoryEndsTheStoryEvenWhenTheReplyLacksAClosingPhrase() async throws {
        let chat = ScriptedChatClient("The fox went home and slept.", storybookJSON())
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat))
        let connection = makeLibraryConnection(chat: chat, library: library)
        let recorder = EventRecorder(connection)

        try await connection.send(.concludeStory(turnId: 3))
        await recorder.waitForCount(5)

        XCTAssertTrue(recorder.messages.contains(.rewritingStarted),
                      "an explicit request to finish must end the story regardless of the reply's wording")
    }

    func testConcludeStoryRetriesAFlaggedEndingWithTheFlaggedWordFedBack() async throws {
        let chat = ScriptedChatClient("He picked up the knife. The end.", "The fox went home. The end.")
        let connection = makeLibraryConnection(chat: chat, library: nil)
        let recorder = EventRecorder(connection)

        try await connection.send(.concludeStory(turnId: 3))
        await recorder.waitForCount(3)

        XCTAssertEqual(chat.callCount, 2)
        XCTAssertTrue((chat.receivedMessages[1].last?["content"] ?? "").contains("knife"))
        guard case .message(.responseText(let reply, _)) = recorder.events[0] else {
            return XCTFail("expected responseText first")
        }
        XCTAssertEqual(reply, "The fox went home. The end.")
    }

    func testConcludeStoryFallsBackOnlyAfterEveryRetryIsFlagged() async throws {
        let chat = ScriptedChatClient("He picked up the knife. The end.")
        let connection = makeLibraryConnection(chat: chat, library: nil)
        let recorder = EventRecorder(connection)

        try await connection.send(.concludeStory(turnId: 3))
        await recorder.waitForCount(3)

        XCTAssertEqual(chat.callCount, DemoConnection.concludeSafetyRetryAttempts)
        guard case .message(.responseText(let reply, _)) = recorder.events[0] else {
            return XCTFail("expected responseText first")
        }
        XCTAssertEqual(reply, Safety.safeFallback, "the generic fallback is a last resort, not the first answer")
    }

    func testConcludeStoryNudgesAnEmptyReplyInsteadOfResubmittingItUnchanged() async throws {
        let chat = ScriptedChatClient("", "All done now. The end.")
        let connection = makeLibraryConnection(chat: chat, library: nil)
        let recorder = EventRecorder(connection)

        try await connection.send(.concludeStory(turnId: 3))
        await recorder.waitForCount(3)

        XCTAssertEqual(chat.callCount, 2)
        XCTAssertEqual(chat.receivedMessages[1].last?["content"], DemoConnection.concludeEmptyRetryNudge)
    }

    // MARK: - synthesize_page / get_page_image

    /// A library holding one finished two-page story "abc": page 0 has a
    /// picture, page 1 doesn't.
    private func makeIllustratedLibrary() async -> DemoStoryLibrary {
        let chat = ScriptedChatClient(storybookJSON(pages: ["First page.", "Second page."]))
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [Data([1, 2, 3]), nil], status: .partial))
        let library = DemoStoryLibrary(store: makeStore(), writer: StorybookWriter(chat: chat), illustrator: illustrator)
        library.begin(payload(id: "abc"), pageCount: 2)
        await library.buildStorybook(id: "abc")
        return library
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func kind(_ event: ServerConnectionEvent) -> String {
        switch event {
        case .audio: return "audio"
        case .closed: return "closed"
        case .message(let message):
            switch message {
            case .transcriptFinal: return "transcript"
            case .responseText: return "response"
            case .turnEnd: return "turnEnd"
            case .pageAudioDone: return "pageAudioDone"
            case .pageImageDone: return "pageImageDone"
            case .error: return "error"
            default: return "other"
            }
        }
    }

    func testSynthesizePageStreamsTheChunksThenTheDoneMarker() async throws {
        let library = await makeIllustratedLibrary()
        let tts = ChunkedTtsClient(chunks: [Data([1]), Data([2]), Data([3])])
        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library, tts: tts)
        let recorder = EventRecorder(connection)

        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 1))
        await recorder.waitForCount(4)

        XCTAssertEqual(recorder.audioFrames, [Data([1]), Data([2]), Data([3])])
        XCTAssertEqual(recorder.messages, [.pageAudioDone(storyId: "abc", pageIndex: 1)])
        XCTAssertEqual(tts.synthesizedTexts, ["Second page."])
    }

    func testSynthesizePageOfABadStoryOrPageAnswersWithAnErrorAndNoDoneMarker() async throws {
        let library = await makeIllustratedLibrary()
        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library)
        let recorder = EventRecorder(connection)

        try await connection.send(.synthesizePage(storyId: "ghost", pageIndex: 0))
        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 5))
        let events = await recorder.waitForCount(2)

        XCTAssertEqual(events.count, 2)
        guard case .message(.error(let first, _)) = events[0], case .message(.error(let second, _)) = events[1] else {
            return XCTFail("expected two error frames, got \(events)")
        }
        XCTAssertEqual(first, "no page 0 for story 'ghost'")
        XCTAssertEqual(second, "no page 5 for story 'abc'")
        XCTAssertTrue(recorder.audioFrames.isEmpty)
    }

    func testACancelledPageAudioRequestStillEndsWithItsDoneMarker() async throws {
        // A request that just went quiet would leave SessionCoordinator's
        // page request pending forever, diverting all later live audio into
        // page playback -- so a barge-in must still terminate it.
        let library = await makeIllustratedLibrary()
        let tts = ChunkedTtsClient(chunks: Array(repeating: Data([9]), count: 20), delayNanos: 30_000_000)
        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library, tts: tts)
        let recorder = EventRecorder(connection)

        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 0))
        await recorder.waitForCount(1) // the first chunk is out
        try await connection.send(.speechStart(turnId: 9)) // the child starts talking
        await waitUntil { recorder.messages.contains(.pageAudioDone(storyId: "abc", pageIndex: 0)) }

        XCTAssertTrue(recorder.messages.contains(.pageAudioDone(storyId: "abc", pageIndex: 0)))
        XCTAssertLessThan(recorder.audioFrames.count, 20, "cancelling must stop the stream early")
    }

    func testPageAudioWaitsForAnInFlightLiveTurnInsteadOfInterleavingWithIt() async throws {
        let library = await makeIllustratedLibrary()
        let gate = GatedChatClient(reply: "Once upon a time. What happens next?")
        let tts = ChunkedTtsClient(chunks: [Data([7])])
        let connection = makeLibraryConnection(chat: gate, library: library, tts: tts)
        let recorder = EventRecorder(connection)

        try await connection.send(.speechStart(turnId: 1))
        try await connection.send(audio: Data(repeating: 0, count: 100))
        try await connection.send(.speechEnd) // the turn now blocks inside the chat call
        await recorder.waitForCount(1) // its transcript
        try await connection.send(.synthesizePage(storyId: "abc", pageIndex: 0))

        let whileTheTurnIsInFlight = await recorder.settle()
        XCTAssertEqual(whileTheTurnIsInFlight.count, 1, "page audio must wait for the live turn, not interleave with it")

        gate.release()
        await waitUntil { recorder.messages.contains(.pageAudioDone(storyId: "abc", pageIndex: 0)) }

        XCTAssertEqual(
            recorder.events.map(kind),
            ["transcript", "response", "audio", "turnEnd", "audio", "pageAudioDone"],
            "the live turn's frames must all precede the page's"
        )
    }

    func testGetPageImageSendsTheBytesThenTheDoneMarkerOrJustTheMarker() async throws {
        let library = await makeIllustratedLibrary()
        let connection = makeLibraryConnection(chat: FakeChatClient(), library: library)
        let recorder = EventRecorder(connection)

        try await connection.send(.getPageImage(storyId: "abc", pageIndex: 0)) // has a picture
        try await connection.send(.getPageImage(storyId: "abc", pageIndex: 1)) // has none
        try await connection.send(.getPageImage(storyId: "abc", pageIndex: 9)) // no such page
        await recorder.waitForCount(4)

        let events = recorder.events
        XCTAssertEqual(events.count, 4)
        guard case .audio(let bytes) = events[0],
              case .message(.pageImageDone(_, let firstIndex, let firstHasImage)) = events[1],
              case .message(.pageImageDone(_, let secondIndex, let secondHasImage)) = events[2],
              case .message(.error(let message, _)) = events[3]
        else { return XCTFail("unexpected events: \(events)") }
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        XCTAssertEqual(firstIndex, 0)
        XCTAssertTrue(firstHasImage)
        XCTAssertEqual(secondIndex, 1)
        XCTAssertFalse(secondHasImage)
        XCTAssertEqual(message, "no page 9 for story 'abc'")
    }

    func testGetStoryOfAnUnknownIdAnswersWithAnErrorFrameCarryingTheCurrentTurnId() async throws {
        let connection = makeLibraryConnection(chat: FakeChatClient(), library: nil)
        let recorder = EventRecorder(connection)
        try await connection.send(.speechStart(turnId: 7)) // sets the current turn id, emits nothing

        try await connection.send(.getStory(storyId: "ghost"))

        let events = await recorder.waitForCount(1)
        guard case .message(.error(let message, let turnId)) = events[0] else {
            return XCTFail("expected an error frame, got \(events[0])")
        }
        XCTAssertEqual(message, "no saved story with id 'ghost'")
        XCTAssertEqual(turnId, 7)
    }
}
