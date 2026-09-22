import XCTest
@testable import TinyTalkCore

final class LibraryPeekTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_758_000_000)

    private func summary(id: String) -> SavedStorySummary {
        SavedStorySummary(id: id, title: "A Story", createdAt: fixedDate, pageCount: 3, rewriteStatus: .done)
    }

    func testReturnsStoriesFromAStoryListEvent() async {
        let connection = FakeConnection()
        connection.emit(.message(.storyList([summary(id: "abc")])))

        let result = await peekStoryList(via: connection)

        XCTAssertEqual(result, [summary(id: "abc")])
        XCTAssertEqual(connection.sentMessages, [.listStories])
    }

    func testReturnsNilWhenTheConnectionClosesFirst() async {
        let connection = FakeConnection()
        connection.emit(.closed)

        let result = await peekStoryList(via: connection, timeout: .seconds(2))

        XCTAssertNil(result)
    }

    func testReturnsNilOnTimeoutWhenNothingArrives() async {
        let connection = FakeConnection()

        let result = await peekStoryList(via: connection, timeout: .milliseconds(50))

        XCTAssertNil(result)
    }

    func testIgnoresUnrelatedEventsAndWaitsForStoryList() async {
        let connection = FakeConnection()
        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.message(.turnEnd(turnId: 1)))
        connection.emit(.message(.storyList([summary(id: "xyz")])))

        let result = await peekStoryList(via: connection)

        XCTAssertEqual(result, [summary(id: "xyz")])
    }

    func testAlwaysClosesTheConnectionBeforeReturning() async {
        let connection = FakeConnection()
        connection.emit(.message(.storyList([])))
        _ = await peekStoryList(via: connection)
        XCTAssertEqual(connection.closeCallCount, 1)

        let timedOutConnection = FakeConnection()
        _ = await peekStoryList(via: timedOutConnection, timeout: .milliseconds(50))
        XCTAssertEqual(timedOutConnection.closeCallCount, 1)
    }
}
