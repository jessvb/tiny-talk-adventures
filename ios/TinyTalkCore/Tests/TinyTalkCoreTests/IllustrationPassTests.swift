import XCTest
@testable import TinyTalkCore

/// Mirrors server/tests/test_illustrations.py's cases for illustrations.py.
final class IllustrationPassTests: XCTestCase {
    private let pages = ["Page one.", "Page two.", "Page three."]
    private let fullSize = TestImages.png(width: 1024, height: 768)

    private func sceneChat() -> ScriptedChatClient {
        ScriptedChatClient("a small orange fox in a meadow", "the small orange fox meets an owl", "the small orange fox goes home")
    }

    private func pass(
        chat: any ChatCompleting,
        backend: FakeImageBackend,
        timeBudget: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        log: DebugLog? = nil
    ) -> IllustrationPass {
        IllustrationPass(
            chat: chat, backend: backend, timeBudget: timeBudget, now: now,
            onDebugEvent: log.map { log in { @Sendable line in log.append(line) } }
        )
    }

    // MARK: - happy path

    func testEveryPageGetsAPictureAndTheStatusIsDone() async {
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.images.count, 3)
        for image in result.images {
            let data = try! XCTUnwrap(image)
            XCTAssertTrue(TestImages.isJPEG(data), "pictures are stored as JPEG")
            let size = try! XCTUnwrap(TestImages.pixelSize(of: data))
            XCTAssertLessThanOrEqual(max(size.width, size.height), 512, "and downscaled to at most 512 px")
        }
    }

    func testEachPromptIsTheStyleDirectiveFollowedByThatPagesScene() async {
        let backend = FakeImageBackend(results: [.success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertEqual(backend.calls.map(\.prompt), [
            IllustrationPass.styleDirective + "a small orange fox in a meadow",
            IllustrationPass.styleDirective + "the small orange fox meets an owl",
            IllustrationPass.styleDirective + "the small orange fox goes home",
        ])
    }

    func testTheSceneRequestCarriesThePageTextAndTheTwentyFiveWordLimit() async {
        let chat = sceneChat()
        let backend = FakeImageBackend(results: [.success(fullSize)])
        _ = await pass(chat: chat, backend: backend).illustrate(pages: pages)

        XCTAssertEqual(chat.callCount, 3, "one scene prompt per page")
        let request = chat.receivedMessages[1][0]["content"] ?? ""
        XCTAssertTrue(request.contains("Page text: Page two."))
        XCTAssertTrue(request.contains("no more than 25 words"))
        XCTAssertTrue(request.contains("same short description on every page"))
    }

    // MARK: - reference images (character consistency)

    func testALaterPageGetsPageZerosImageAsItsReferenceWhenTheBackendSupportsOne() async {
        let backend = FakeImageBackend(supportsReference: true, results: [.success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertNil(backend.calls[0].reference, "page 0 is drawn reference-free")
        XCTAssertEqual(backend.calls[1].reference, fullSize)
        XCTAssertEqual(backend.calls[2].reference, fullSize)
    }

    func testNoReferenceIsSentWhenTheBackendCannotUseOne() async {
        let backend = FakeImageBackend(supportsReference: false, results: [.success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertTrue(backend.calls.allSatisfy { $0.reference == nil })
    }

    // MARK: - partial and total failure

    func testOnePagesFailureLeavesItPictureLessAndTheRestContinue() async {
        let backend = FakeImageBackend(results: [
            .success(fullSize), .failure(ImageGenerationError.http(status: 500, detail: "boom")), .success(fullSize),
        ])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertEqual(result.status, .partial)
        XCTAssertNotNil(result.images[0])
        XCTAssertNil(result.images[1])
        XCTAssertNotNil(result.images[2])
        XCTAssertEqual(backend.calls.count, 3, "a failure must not stop the later pages")
    }

    func testEveryPageFailingMarksTheWholePassFailed() async {
        let backend = FakeImageBackend(results: [.failure(ImageGenerationError.http(status: 401, detail: "bad token"))])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.images.compactMap { $0 }.count, 0)
    }

    func testABackendThatDeclinesLeavesThatPagePictureLess() async {
        let backend = FakeImageBackend(results: [.success(fullSize), .success(nil), .success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.images[1])
    }

    func testBytesThatAreNotAnImageLeaveThatPagePictureLessInsteadOfCrashing() async {
        let backend = FakeImageBackend(results: [.success(Data("not an image".utf8)), .success(fullSize), .success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.images[0])
    }

    func testAPageWhoseScenePromptFailsIsSkippedWithoutCallingTheBackend() async {
        // A scripted client can't fail on just one call, so use two: the
        // first call throws, later ones succeed.
        final class FlakyChat: ChatCompleting, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func complete(messages: [[String: String]]) async throws -> String {
                let call = lock.withLock { () -> Int in calls += 1; return calls }
                if call == 1 { throw DemoConnectionError.groqError("rate limited") }
                return "a small orange fox"
            }
        }
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: FlakyChat(), backend: backend).illustrate(pages: pages)

        XCTAssertNil(result.images[0])
        XCTAssertNotNil(result.images[1])
        XCTAssertNotNil(result.images[2])
        XCTAssertEqual(backend.calls.count, 2, "no scene prompt, so nothing to draw for page 0")
        XCTAssertEqual(result.status, .partial)
    }

    func testAStoryWithNoPagesIsFailedNotDone() async {
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: [])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.images.count, 0)
    }

    // MARK: - time budget

    func testPagesNotReachedBeforeTheTimeBudgetRunsOutGetNoPicture() async {
        let clock = FakeClock()
        let backend = FakeImageBackend(results: [.success(fullSize)])
        backend.onGenerate = { clock.advance(40) } // each picture "takes" 40 s
        let result = await pass(chat: sceneChat(), backend: backend, timeBudget: 60, now: { clock.now() })
            .illustrate(pages: pages)

        // Page 0 starts at 0 s, page 1 at 40 s (both < 60); page 2 would
        // start at 80 s -- past the budget, so it is skipped.
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertNotNil(result.images[0])
        XCTAssertNotNil(result.images[1])
        XCTAssertNil(result.images[2])
        XCTAssertEqual(result.status, .partial)
    }

    func testASceneStageSlowerThanTheWholeBudgetDoesNotCostAnyPageItsPicture() async {
        // The scene sentences come from the chat service, and the budget
        // exists for the image service -- it must not start counting until
        // drawing starts.
        final class ClockAdvancingChatClient: ChatCompleting, @unchecked Sendable {
            private let clock: FakeClock
            init(clock: FakeClock) { self.clock = clock }
            func complete(messages: [[String: String]]) async throws -> String {
                clock.advance(100) // each scene prompt "takes" 100 s -- longer than the whole 60 s budget
                return "a small orange fox in a meadow"
            }
        }
        let clock = FakeClock()
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: ClockAdvancingChatClient(clock: clock), backend: backend, now: { clock.now() })
            .illustrate(pages: pages)

        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.images.compactMap { $0 }.count, 3)
        XCTAssertEqual(backend.calls.count, 3, "one picture attempt per page")
    }

    // MARK: - diagnostics

    func testFailuresAndTheFinalStatusReachTheDebugLog() async {
        let log = DebugLog()
        let backend = FakeImageBackend(results: [.success(fullSize), .failure(ImageGenerationError.emptyImage), .success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend, log: log).illustrate(pages: pages)

        XCTAssertTrue(log.lines.contains { $0.contains("page 1 failed") })
        XCTAssertTrue(log.lines.last?.hasSuffix("illustration: partial (2/3 pages)") == true)
        XCTAssertTrue(log.lines.allSatisfy { $0.hasPrefix("[") }, "every line must carry the timestamp prefix so the merged log sorts chronologically")
    }

    func testAURLErrorIsLoggedWithoutItsFailingURLSoTheAccountIdNeverReachesTheLog() async {
        let log = DebugLog()
        let timedOut = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "https://api.cloudflare.com/client/v4/accounts/SECRETACCT/ai/run/@cf/black-forest-labs/flux-1-schnell",
        ])
        let backend = FakeImageBackend(results: [.success(fullSize), .failure(timedOut), .success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend, log: log).illustrate(pages: pages)

        XCTAssertTrue(log.lines.contains { $0.contains("page 1 failed") && $0.contains("URLError -1001") })
        XCTAssertFalse(log.lines.contains { $0.contains("SECRETACCT") }, "a URLError's description embeds the Cloudflare URL, which contains the account id")
    }
}
