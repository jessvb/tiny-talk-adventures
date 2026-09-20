import XCTest
@testable import TinyTalkCore

/// Mirrors server/tests/test_storybook.py's cases for storybook.py -- the
/// Swift port is verified against the same behavior, not assumed to match.
final class StorybookWriterTests: XCTestCase {
    private let turns = [
        PendingDemoStoryTurn(speaker: "child", text: "tell me about a fox", interrupted: false),
        PendingDemoStoryTurn(speaker: "agent", text: "Once there was a clever fox.", interrupted: false),
    ]

    private func json(title: String = "A Story", pages: [String] = ["Once upon a time."], epilogue: String? = nil) -> String {
        var object: [String: Any] = ["title": title, "pages": pages.map { ["text": $0] }]
        if let epilogue { object["epilogue"] = epilogue }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func write(
        _ chat: ScriptedChatClient,
        facts: [[String]] = [],
        pageCount: Int = 5,
        maxAttempts: Int = StorybookWriter.defaultMaxAttempts
    ) async -> WrittenStorybook? {
        await StorybookWriter(chat: chat, maxAttempts: maxAttempts)
            .write(turns: turns, sharedFacts: facts, pageCount: pageCount)
    }

    // MARK: - happy path

    func testParsesAValidRewriteAndGroundsTheEpilogueInTheRealFact() async {
        let chat = ScriptedChatClient(
            json(title: "Pip the Noisy Fox", pages: ["Once there was a fox.", "The end."],
                 epilogue: "Foxes have excellent hearing.")
        )
        let result = await write(chat, facts: [["fox", "foxes have excellent hearing"]])
        XCTAssertEqual(result?.title, "Pip the Noisy Fox")
        XCTAssertEqual(result?.pages, ["Once there was a fox.", "The end."])
        // Formatted from shared facts, NOT the model's own epilogue text.
        XCTAssertEqual(result?.epilogue, "And one true thing we learned about the fox: foxes have excellent hearing")
    }

    func testToleratesProseWrappedAroundTheJSON() async {
        let chat = ScriptedChatClient(
            "Sure, here you go:\n" + json(title: "Pip") + "\nHope that helps!"
        )
        let result = await write(chat)
        XCTAssertEqual(result?.title, "Pip")
    }

    func testOmitsTheEpilogueWhenNoFactsWereShared() async {
        let chat = ScriptedChatClient(json())
        let result = await write(chat)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.epilogue)
    }

    func testDiscardsAFabricatedEpilogueWhenNoFactsWereShared() async {
        let chat = ScriptedChatClient(json(epilogue: "Foxes can fly to the moon."))
        let result = await write(chat)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.epilogue, "a model-invented epilogue must never be used")
    }

    func testIgnoresTheModelsOwnEpilogueEvenWhenFactsWereShared() async {
        let chat = ScriptedChatClient(json(epilogue: "Foxes can fly to the moon."))
        let result = await write(chat, facts: [["owl", "owls can turn their heads far around"]])
        XCTAssertEqual(result?.epilogue, "And one true thing we learned about the owl: owls can turn their heads far around")
    }

    // MARK: - prompt shape

    func testPromptCarriesTheTranscriptPageCountAndKidSafetyFraming() async {
        let chat = ScriptedChatClient(json())
        _ = await write(chat, pageCount: 3)
        let messages = chat.receivedMessages[0]
        XCTAssertEqual(messages[0]["role"], "system")
        let system = messages[0]["content"] ?? ""
        XCTAssertTrue(system.contains("Keep everything gentle and wholesome"))
        // The live-dialogue rules must NOT leak into a one-shot rewrite:
        // they made the model end pages with "what should we do next".
        XCTAssertFalse(system.contains("asking the child what should happen next"))
        let user = messages[1]["content"] ?? ""
        XCTAssertTrue(user.contains("Child: tell me about a fox"))
        XCTAssertTrue(user.contains("Storyteller: Once there was a clever fox."))
        XCTAssertTrue(user.contains("exactly 3 pages"))
    }

    func testFactsAppearInThePromptAndAddTheEpilogueKeyOnlyWhenPresent() async {
        let withFacts = ScriptedChatClient(json())
        _ = await write(withFacts, facts: [["fox", "foxes have excellent hearing"]])
        let promptWithFacts = withFacts.receivedMessages[0][1]["content"] ?? ""
        XCTAssertTrue(promptWithFacts.contains("Real facts this story actually used: fox: foxes have excellent hearing."))
        XCTAssertTrue(promptWithFacts.contains(#""epilogue": "one true, real fact from the story, in one sentence""#))

        let withoutFacts = ScriptedChatClient(json())
        _ = await write(withoutFacts)
        let promptWithoutFacts = withoutFacts.receivedMessages[0][1]["content"] ?? ""
        XCTAssertFalse(promptWithoutFacts.contains("Real facts this story actually used"))
        XCTAssertFalse(promptWithoutFacts.contains(#""epilogue""#))
    }

    // MARK: - failure handling

    func testReturnsNilOnUnparseableOutputAfterEveryAttempt() async {
        let chat = ScriptedChatClient("this is not json at all")
        let result = await write(chat)
        XCTAssertNil(result)
        XCTAssertEqual(chat.callCount, StorybookWriter.defaultMaxAttempts)
    }

    func testReturnsNilWhenTheChatClientThrows() async {
        let chat = ScriptedChatClient(json())
        chat.error = DemoConnectionError.groqError("boom")
        let result = await write(chat)
        XCTAssertNil(result)
    }

    func testRetriesAndSucceedsOnceALaterAttemptParses() async {
        let chat = ScriptedChatClient("this is not json at all", json(title: "A Story"))
        let result = await write(chat)
        XCTAssertEqual(result?.title, "A Story")
        XCTAssertEqual(chat.callCount, 2)
    }

    func testParseRetryAsksForValidJSONAgain() async {
        let chat = ScriptedChatClient("this is not json at all", json())
        _ = await write(chat)
        let retry = chat.receivedMessages[1].last?["content"] ?? ""
        XCTAssertTrue(retry.lowercased().contains("valid json"))
    }

    // MARK: - kid-safety retry

    func testRetriesAndSavesOnceALaterAttemptIsSafe() async {
        let chat = ScriptedChatClient(json(title: "The Knife Fight"), json(title: "The Big Adventure"))
        let result = await write(chat)
        XCTAssertEqual(result?.title, "The Big Adventure")
        XCTAssertEqual(chat.callCount, 2)
    }

    func testSafetyRetryTellsTheModelWhatToAvoid() async {
        let chat = ScriptedChatClient(json(title: "The Knife Fight"), json(title: "A Story"))
        _ = await write(chat)
        let retry = chat.receivedMessages[1].last?["content"] ?? ""
        XCTAssertTrue(retry.lowercased().contains("knife"))
    }

    func testGivesUpAfterTheConfiguredNumberOfSafetyAttempts() async {
        let chat = ScriptedChatClient(json(title: "The Knife Fight"))
        let result = await write(chat)
        XCTAssertNil(result)
        XCTAssertEqual(chat.callCount, StorybookWriter.defaultMaxAttempts)
    }

    func testAnUnsafePageFailsTheStorybook() async {
        let chat = ScriptedChatClient(json(pages: ["The knight had to kill the dragon."]))
        let result = await write(chat)
        XCTAssertNil(result)
    }

    func testAnUnsafeGroundedEpilogueFailsTheStorybook() async {
        // The epilogue comes from the real shared fact, so an unsafe FACT
        // must be caught even though the model's own text is spotless.
        let chat = ScriptedChatClient(json())
        let result = await write(chat, facts: [["shark", "sharks can kill"]])
        XCTAssertNil(result)
    }

    func testMaxAttemptsIsHonoured() async {
        let chat = ScriptedChatClient("not json")
        _ = await write(chat, maxAttempts: 1)
        XCTAssertEqual(chat.callCount, 1)
    }
}
