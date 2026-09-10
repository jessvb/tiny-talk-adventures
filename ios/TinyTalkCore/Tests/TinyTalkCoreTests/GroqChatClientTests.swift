import XCTest
@testable import TinyTalkCore

final class GroqChatClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testCompleteReturnsTheAssistantMessageContent() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = #"{"choices":[{"message":{"role":"assistant","content":"Once upon a time."}}]}"#
            return (200, body.data(using: .utf8)!)
        }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        let reply = try await client.complete(messages: [["role": "user", "content": "hi"]])
        XCTAssertEqual(reply, "Once upon a time.")
    }

    func testCompleteThrowsOnNon200() async {
        StubURLProtocol.handler = { _ in (429, "rate limited".data(using: .utf8)!) }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.complete(messages: [])
            XCTFail("expected an error")
        } catch DemoConnectionError.groqError {
            // expected
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testCompleteThrowsWhenThereAreNoChoices() async {
        StubURLProtocol.handler = { _ in (200, #"{"choices":[]}"#.data(using: .utf8)!) }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.complete(messages: [])
            XCTFail("expected an error")
        } catch DemoConnectionError.groqError {
            // expected
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
