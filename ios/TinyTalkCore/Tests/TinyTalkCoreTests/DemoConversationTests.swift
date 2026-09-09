import XCTest
@testable import TinyTalkCore

final class DemoConversationTests: XCTestCase {
    func testEmptyTextIsNotAdded() {
        let conversation = DemoConversation()
        conversation.addChild("  ")
        conversation.addAgent("")
        XCTAssertTrue(conversation.fullHistory.isEmpty)
    }

    func testAddedTextIsTrimmed() {
        let conversation = DemoConversation()
        conversation.addChild("  hello  ")
        XCTAssertEqual(conversation.fullHistory.first?.text, "hello")
    }

    func testToMessagesIncludesSystemPromptFirst() {
        let conversation = DemoConversation()
        conversation.addChild("hi")
        let messages = conversation.toMessages(systemPrompt: "be kind")
        XCTAssertEqual(messages.first, ["role": "system", "content": "be kind"])
        XCTAssertEqual(messages[1], ["role": "user", "content": "hi"])
    }

    func testInterruptedAgentTurnGetsMarkerAppended() {
        let conversation = DemoConversation()
        conversation.addAgent("once upon a", interrupted: true)
        let messages = conversation.toMessages(systemPrompt: "x")
        XCTAssertEqual(messages[1]["content"], "once upon a \(DemoConversation.interruptedMarker)")
        XCTAssertEqual(messages[1]["role"], "assistant")
    }

    func testFullHistoryKeepsEverythingBeyondTheWindow() {
        let conversation = DemoConversation(maxTurns: 20)
        for i in 0..<15 {
            conversation.addChild("turn \(i)")
            conversation.addAgent("reply \(i)")
        }
        XCTAssertEqual(conversation.fullHistory.count, 30)
        XCTAssertEqual(conversation.fullHistory.first?.text, "turn 0")
    }

    func testToMessagesOnlyUsesTheRecentWindow() {
        let conversation = DemoConversation(maxTurns: 2)
        conversation.addChild("first")
        conversation.addAgent("first reply")
        conversation.addChild("second")
        let messages = conversation.toMessages(systemPrompt: "x")
        // system + 2 windowed turns, not 3 -- and specifically the two
        // MOST RECENT turns, not an arbitrary subset of the same size.
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["content"], "first reply")
        XCTAssertEqual(messages[2]["content"], "second")
    }
}
