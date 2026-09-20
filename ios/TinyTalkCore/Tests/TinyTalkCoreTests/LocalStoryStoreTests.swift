import XCTest
@testable import TinyTalkCore

final class LocalStoryStoreTests: XCTestCase {
    private func makeStore() -> LocalStoryStore {
        LocalStoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func makeStory(id: String, createdAt: String = "2026-09-19T12:00:00Z") -> LocalStory {
        LocalStory(
            id: id,
            createdAt: createdAt,
            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
            sharedFacts: [["fox", "foxes are clever"]],
            pageCount: 5
        )
    }

    func testLoadAllIsEmptyWhenNothingIsSaved() {
        XCTAssertEqual(makeStore().loadAll(), [])
    }

    func testSaveThenLoadRoundTripsEveryField() {
        let store = makeStore()
        var story = makeStory(id: "abc12345")
        story.title = "Pip the Fox"
        story.pages = [LocalStoryPage(text: "Page one."), LocalStoryPage(text: "Page two.", hasImage: true)]
        story.epilogue = "And one true thing we learned about the fox: foxes are clever"
        story.rewriteStatus = .done
        story.illustrationsStatus = .partial
        store.save(story)
        XCTAssertEqual(store.load(id: "abc12345"), story)
    }

    func testLoadOfAnUnknownIdIsNil() {
        XCTAssertNil(makeStore().load(id: "nope"))
    }

    func testLoadAllReturnsNewestFirst() {
        let store = makeStore()
        store.save(makeStory(id: "old", createdAt: "2026-09-17T09:00:00Z"))
        store.save(makeStory(id: "new", createdAt: "2026-09-19T09:00:00Z"))
        store.save(makeStory(id: "mid", createdAt: "2026-09-18T09:00:00Z"))
        XCTAssertEqual(store.loadAll().map(\.id), ["new", "mid", "old"])
    }

    func testASavedStoryOverwritesItsPreviousVersion() {
        let store = makeStore()
        var story = makeStory(id: "abc")
        store.save(story)
        story.rewriteStatus = .failed
        store.save(story)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(store.load(id: "abc")?.rewriteStatus, .failed)
    }

    func testImagesRoundTripPerPage() {
        let store = makeStore()
        store.saveImage(Data([1, 2, 3]), id: "abc", pageIndex: 0)
        store.saveImage(Data([9, 9]), id: "abc", pageIndex: 2)
        XCTAssertEqual(store.imageData(id: "abc", pageIndex: 0), Data([1, 2, 3]))
        XCTAssertEqual(store.imageData(id: "abc", pageIndex: 2), Data([9, 9]))
        XCTAssertNil(store.imageData(id: "abc", pageIndex: 1))
    }

    func testRemoveDeletesTheStoryAndItsImages() {
        let store = makeStore()
        store.save(makeStory(id: "abc"))
        store.save(makeStory(id: "keep"))
        store.saveImage(Data([1]), id: "abc", pageIndex: 0)
        store.remove(ids: ["abc"])
        XCTAssertNil(store.load(id: "abc"))
        XCTAssertNil(store.imageData(id: "abc", pageIndex: 0))
        XCTAssertNotNil(store.load(id: "keep"))
    }

    func testAnIdThatCouldEscapeTheStoreDirectoryIsRejected() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStoryStore(directory: directory)
        store.save(makeStory(id: "../escape"))
        store.saveImage(Data([1]), id: "../escape", pageIndex: 0)
        XCTAssertNil(store.load(id: "../escape"))
        XCTAssertNil(store.imageData(id: "../escape", pageIndex: 0))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.json").path
        ))
    }

    func testACorruptFileIsSkippedNotFatal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStoryStore(directory: directory)
        store.save(makeStory(id: "good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        XCTAssertEqual(store.loadAll().map(\.id), ["good"])
    }
}
