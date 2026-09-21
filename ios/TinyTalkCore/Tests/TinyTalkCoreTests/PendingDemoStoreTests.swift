import XCTest
@testable import TinyTalkCore

final class PendingDemoStoreTests: XCTestCase {
    private func makeStore() -> PendingDemoStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return PendingDemoStore(directory: dir)
    }

    private func makePayload(id: String) -> PendingDemoStoryPayload {
        PendingDemoStoryPayload(
            id: id,
            createdAt: "2026-09-09T12:00:00+00:00",
            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
            sharedFacts: [["fox", "foxes are clever"]]
        )
    }

    func testLoadAllReturnsEmptyWhenNothingSaved() {
        XCTAssertEqual(makeStore().loadAll(), [])
    }

    func testSaveThenLoadAllRoundTrips() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "abc")
        XCTAssertEqual(loaded[0].sharedFacts, [["fox", "foxes are clever"]])
    }

    func testMultipleSavesAreAllReturned() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        store.save(makePayload(id: "def"))
        XCTAssertEqual(Set(store.loadAll().map(\.id)), Set(["abc", "def"]))
    }

    func testClearRemovesEverything() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        store.clear()
        XCTAssertEqual(store.loadAll(), [])
    }

    func testAPayloadFileWrittenBeforeStorybookExistedStillDecodes() throws {
        // Payload files saved by earlier builds have no "storybook" key at
        // all -- they must keep loading (as transcript-only stories).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"{"id":"old","createdAt":"2026-09-09T12:00:00Z","turns":[{"speaker":"child","text":"hi","interrupted":false}],"sharedFacts":[["fox","foxes are clever"]]}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("old.json"))

        let loaded = PendingDemoStore(directory: dir).loadAll()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "old")
        XCTAssertNil(loaded[0].storybook)
    }

    func testAPayloadWithoutAStorybookRoundTripsWithoutOne() {
        let store = makeStore()
        store.save(makePayload(id: "abc"))
        XCTAssertNil(store.loadAll()[0].storybook)
    }
}
