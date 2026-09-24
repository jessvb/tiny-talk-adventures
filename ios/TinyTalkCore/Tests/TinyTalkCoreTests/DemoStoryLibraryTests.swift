import XCTest
@testable import TinyTalkCore

final class DemoStoryLibraryTests: XCTestCase {
    private func makeStore() -> LocalStoryStore {
        LocalStoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func payload(id: String, createdAt: String = "2026-09-19T12:00:00Z", facts: [[String]] = []) -> PendingDemoStoryPayload {
        PendingDemoStoryPayload(
            id: id,
            createdAt: createdAt,
            turns: [
                PendingDemoStoryTurn(speaker: "child", text: "tell me about a fox", interrupted: false),
                PendingDemoStoryTurn(speaker: "agent", text: "Once there was a clever fox. The end.", interrupted: false),
            ],
            sharedFacts: facts
        )
    }

    private func storybookJSON(title: String = "Pip the Fox", pages: [String] = ["Page one.", "Page two.", "Page three."]) -> String {
        let object: [String: Any] = ["title": title, "pages": pages.map { ["text": $0] }]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func makeLibrary(
        store: LocalStoryStore,
        chat: any ChatCompleting,
        illustrator: (any StoryIllustrating)? = nil
    ) -> DemoStoryLibrary {
        DemoStoryLibrary(store: store, writer: StorybookWriter(chat: chat), illustrator: illustrator)
    }

    // MARK: - begin / list / detail

    func testABegunStoryIsListedAsPendingWithNoTitleOrPages() {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()))
        library.begin(payload(id: "abc"), pageCount: 3)
        let list = library.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "abc")
        XCTAssertNil(list[0].title)
        XCTAssertEqual(list[0].pageCount, 0)
        XCTAssertEqual(list[0].rewriteStatus, .pending)
    }

    func testListIsNewestFirstAndParsesTheCreationDate() {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()))
        library.begin(payload(id: "older", createdAt: "2026-09-17T09:00:00Z"), pageCount: 3)
        library.begin(payload(id: "newer", createdAt: "2026-09-19T09:00:00Z"), pageCount: 3)
        let list = library.list()
        XCTAssertEqual(list.map(\.id), ["newer", "older"])
        XCTAssertEqual(list[0].createdAt, ISO8601DateFormatter().date(from: "2026-09-19T09:00:00Z"))
    }

    func testDetailOfAnUnknownIdIsNil() {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()))
        XCTAssertNil(library.detail(id: "nope"))
    }

    // MARK: - buildStorybook

    func testBuildingProducesADoneStorybookAskingForTheStoryOwnPageCount() async {
        let chat = ScriptedChatClient(storybookJSON())
        let library = makeLibrary(store: makeStore(), chat: chat)
        library.begin(payload(id: "abc", facts: [["fox", "foxes have excellent hearing"]]), pageCount: 3)

        await library.buildStorybook(id: "abc")

        let detail = library.detail(id: "abc")
        XCTAssertEqual(detail?.title, "Pip the Fox")
        XCTAssertEqual(detail?.pages.map(\.text), ["Page one.", "Page two.", "Page three."])
        XCTAssertEqual(detail?.pages.map(\.hasImage), [false, false, false])
        XCTAssertEqual(detail?.epilogue, "And one true thing we learned about the fox: foxes have excellent hearing")
        XCTAssertEqual(detail?.rewriteStatus, .done)
        XCTAssertNil(detail?.illustrationsStatus, "no illustrator configured -> text-only")
        let prompt = chat.receivedMessages[0][1]["content"] ?? ""
        XCTAssertTrue(prompt.contains("exactly 3 pages"))
    }

    func testAFailedRewriteMarksTheStoryFailedAndKeepsItsTranscript() async {
        let store = makeStore()
        let library = makeLibrary(store: store, chat: ScriptedChatClient("this is not json at all"))
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")

        XCTAssertEqual(library.detail(id: "abc")?.rewriteStatus, .failed)
        XCTAssertNil(library.detail(id: "abc")?.title)
        XCTAssertEqual(store.load(id: "abc")?.turns.count, 2, "the transcript must survive a failed rewrite")
    }

    func testBuildingTwiceOnlyRewritesOnce() async {
        let chat = ScriptedChatClient(storybookJSON())
        let library = makeLibrary(store: makeStore(), chat: chat)
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")
        await library.buildStorybook(id: "abc")

        XCTAssertEqual(chat.callCount, 1)
    }

    func testAStoryRemovedWhileItsBuildIsInFlightIsNotResurrected() async {
        // E.g. the phone reconnected to the Mac and synced the story home
        // (deleting its local copy) while the storybook was still being
        // written. The finishing build must not re-save it.
        let gate = GatedChatClient(reply: storybookJSON())
        let store = makeStore()
        let library = makeLibrary(store: store, chat: gate)
        library.begin(payload(id: "abc"), pageCount: 3)

        let build = Task { await library.buildStorybook(id: "abc") }
        try? await Task.sleep(nanoseconds: 50_000_000) // the build is now parked inside the chat call
        store.remove(ids: ["abc"])
        gate.release()
        await build.value

        XCTAssertNil(store.load(id: "abc"))
        XCTAssertEqual(store.loadAll(), [])
    }

    func testBuildingAnUnknownStoryDoesNothing() async {
        let chat = ScriptedChatClient(storybookJSON())
        let library = makeLibrary(store: makeStore(), chat: chat)
        await library.buildStorybook(id: "ghost")
        XCTAssertEqual(chat.callCount, 0)
    }

    func testTwoBuildsNeverOverlapEvenWhenStartedTogether() async {
        let chat = ConcurrencyProbeChatClient(reply: storybookJSON())
        let store = makeStore()
        let library = makeLibrary(store: store, chat: chat)
        library.begin(payload(id: "one"), pageCount: 3)
        library.begin(payload(id: "two"), pageCount: 3)

        async let first: Void = library.buildStorybook(id: "one")
        async let second: Void = library.buildStorybook(id: "two")
        _ = await (first, second)

        XCTAssertEqual(chat.maxInFlight, 1, "builds must be serialized, not interleaved")
        XCTAssertEqual(library.detail(id: "one")?.rewriteStatus, .done)
        XCTAssertEqual(library.detail(id: "two")?.rewriteStatus, .done)
    }

    // MARK: - illustrations

    func testAnIllustratorsPicturesAreStoredAndReportedPerPage() async {
        let illustrator = FakeIllustrator(result: IllustrationResult(
            images: [Data([1]), nil, Data([3])], status: .partial
        ))
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON()), illustrator: illustrator)
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")

        let detail = library.detail(id: "abc")
        XCTAssertEqual(detail?.pages.map(\.hasImage), [true, false, true])
        XCTAssertEqual(detail?.illustrationsStatus, .partial)
        XCTAssertEqual(library.pageImage(id: "abc", index: 0), Data([1]))
        XCTAssertNil(library.pageImage(id: "abc", index: 1))
        XCTAssertEqual(library.pageImage(id: "abc", index: 2), Data([3]))
        XCTAssertEqual(illustrator.receivedPages, [["Page one.", "Page two.", "Page three."]])
    }

    func testNoIllustrationsAreAttemptedWhenTheRewriteFailed() async {
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [], status: .failed))
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient("nope"), illustrator: illustrator)
        library.begin(payload(id: "abc"), pageCount: 3)

        await library.buildStorybook(id: "abc")

        XCTAssertEqual(illustrator.receivedPages, [])
    }

    // MARK: - page lookups

    func testPageTextAndImageLookupsAreBoundsChecked() async {
        let library = makeLibrary(store: makeStore(), chat: ScriptedChatClient(storybookJSON(pages: ["Only page."])))
        library.begin(payload(id: "abc"), pageCount: 1)
        await library.buildStorybook(id: "abc")

        XCTAssertEqual(library.pageText(id: "abc", index: 0), "Only page.")
        XCTAssertNil(library.pageText(id: "abc", index: 1))
        XCTAssertNil(library.pageText(id: "abc", index: -1))
        XCTAssertNil(library.pageText(id: "ghost", index: 0))
        XCTAssertNil(library.pageImage(id: "abc", index: 0), "a page with no picture has no image")
    }

    // MARK: - interrupted builds

    func testResumeRebuildsOnlyStoriesLeftPending() async {
        let chat = ScriptedChatClient(storybookJSON())
        let store = makeStore()
        let library = makeLibrary(store: store, chat: chat)
        library.begin(payload(id: "finished"), pageCount: 3)
        await library.buildStorybook(id: "finished")
        XCTAssertEqual(chat.callCount, 1)
        library.begin(payload(id: "interrupted", createdAt: "2026-09-19T13:00:00Z"), pageCount: 3)

        await library.resumeInterruptedBuilds()

        XCTAssertEqual(chat.callCount, 2, "only the interrupted story should be rebuilt")
        XCTAssertEqual(library.detail(id: "interrupted")?.rewriteStatus, .done)
    }

    /// What a kill mid-drawing leaves on disk: the rewrite finished, the
    /// pictures were marked pending, and none of them were saved yet.
    private func storyKilledMidIllustration(id: String, illustrationsStatus: IllustrationsStatus? = .pending) -> LocalStory {
        LocalStory(
            id: id,
            createdAt: "2026-09-19T12:00:00Z",
            turns: payload(id: id).turns,
            sharedFacts: [],
            pageCount: 3,
            title: "Pip the Fox",
            pages: ["Page one.", "Page two.", "Page three."].map { LocalStoryPage(text: $0) },
            rewriteStatus: .done,
            illustrationsStatus: illustrationsStatus
        )
    }

    func testResumeRedrawsPicturesForAStoryKilledMidIllustrationWithoutRewritingIt() async {
        let chat = ScriptedChatClient(storybookJSON(title: "A Different Title"))
        let store = makeStore()
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [Data([1]), Data([2]), nil], status: .partial))
        let library = makeLibrary(store: store, chat: chat, illustrator: illustrator)
        store.save(storyKilledMidIllustration(id: "abc"))

        await library.resumeInterruptedBuilds()

        XCTAssertEqual(chat.callCount, 0, "the finished rewrite must not be redone")
        XCTAssertEqual(illustrator.receivedPages, [["Page one.", "Page two.", "Page three."]])
        let detail = library.detail(id: "abc")
        XCTAssertEqual(detail?.title, "Pip the Fox")
        XCTAssertEqual(detail?.illustrationsStatus, .partial)
        XCTAssertEqual(detail?.pages.map(\.hasImage), [true, true, false])
        XCTAssertEqual(library.pageImage(id: "abc", index: 1), Data([2]))
    }

    func testResumeLeavesStoriesWhosePicturesFinishedOrWereNeverStartedAlone() async {
        let store = makeStore()
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [nil, nil, nil], status: .failed))
        let library = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()), illustrator: illustrator)
        store.save(storyKilledMidIllustration(id: "done", illustrationsStatus: .done))
        store.save(storyKilledMidIllustration(id: "partial", illustrationsStatus: .partial))
        store.save(storyKilledMidIllustration(id: "failed", illustrationsStatus: .failed))
        store.save(storyKilledMidIllustration(id: "textonly", illustrationsStatus: nil))

        await library.resumeInterruptedBuilds()

        XCTAssertEqual(illustrator.receivedPages, [])
    }

    func testResumeWithNoIllustratorLeavesAnInterruptedPassPendingForLater() async {
        let store = makeStore()
        let library = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()))
        store.save(storyKilledMidIllustration(id: "abc"))

        await library.resumeInterruptedBuilds()

        XCTAssertEqual(library.detail(id: "abc")?.illustrationsStatus, .pending)
        XCTAssertEqual(library.detail(id: "abc")?.rewriteStatus, .done)
    }

    func testResumingTwiceDrawsAnInterruptedStoryOnlyOnce() async {
        let store = makeStore()
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [nil, nil, nil], status: .failed))
        let library = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()), illustrator: illustrator)
        store.save(storyKilledMidIllustration(id: "abc"))

        async let first: Void = library.resumeInterruptedBuilds()
        async let second: Void = library.resumeInterruptedBuilds()
        _ = await (first, second)

        XCTAssertEqual(illustrator.receivedPages.count, 1)
    }

    // MARK: - sync payloads

    func testSyncPayloadCarriesTheFinishedStorybookAndItsPictures() async {
        let store = makeStore()
        let illustrator = FakeIllustrator(result: IllustrationResult(images: [Data([7, 7]), nil, nil], status: .partial))
        let library = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()), illustrator: illustrator)
        let original = payload(id: "abc", facts: [["fox", "foxes are clever"]])
        library.begin(original, pageCount: 3)
        await library.buildStorybook(id: "abc")

        let synced = DemoStoryLibrary.syncPayloads(store: store, pending: [original])

        XCTAssertEqual(synced.count, 1)
        XCTAssertEqual(synced[0].id, "abc")
        XCTAssertEqual(synced[0].turns, original.turns)
        XCTAssertEqual(synced[0].sharedFacts, [["fox", "foxes are clever"]])
        XCTAssertEqual(synced[0].storybook?.title, "Pip the Fox")
        XCTAssertEqual(synced[0].storybook?.pages.map(\.text), ["Page one.", "Page two.", "Page three."])
        XCTAssertEqual(synced[0].storybook?.pages.map(\.imageJPEG), [Data([7, 7]), nil, nil])
        XCTAssertEqual(synced[0].storybook?.illustrationsStatus, .partial)
    }

    func testSyncPayloadIsTranscriptOnlyForAStoryThatIsPendingFailedOrUnknown() async {
        let store = makeStore()
        let pendingLibrary = makeLibrary(store: store, chat: ScriptedChatClient(storybookJSON()))
        let failedLibrary = makeLibrary(store: store, chat: ScriptedChatClient("nope"))
        let stillPending = payload(id: "pending")
        let failed = payload(id: "failed")
        let unknown = payload(id: "unknown")
        pendingLibrary.begin(stillPending, pageCount: 3)
        failedLibrary.begin(failed, pageCount: 3)
        await failedLibrary.buildStorybook(id: "failed")

        let synced = DemoStoryLibrary.syncPayloads(store: store, pending: [stillPending, failed, unknown])

        XCTAssertEqual(synced, [stillPending, failed, unknown], "no storybook may be attached to any of them")
        XCTAssertTrue(synced.allSatisfy { $0.storybook == nil })
    }
}
