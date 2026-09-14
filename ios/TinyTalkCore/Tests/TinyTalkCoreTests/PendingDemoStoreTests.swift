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
}
