import XCTest
@testable import TinyTalkCore

final class GroqChatClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// URLProtocol hands the handler the request with its body moved into
    /// httpBodyStream, so read it from there.
    private func bodyObject(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
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

    // MARK: - reasoning_effort

    func testReasoningEffortIsOmittedByDefault() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.data(using: .utf8)!)
        }
        let client = GroqChatClient(apiKey: "test-key", session: makeSession())
        _ = try await client.complete(messages: [["role": "user", "content": "hi"]])

        let body = try XCTUnwrap(bodyObject(of: try XCTUnwrap(captured)))
        XCTAssertNil(body["reasoning_effort"], "the live conversation and storybook rewrite must see an unchanged request body")
    }

    func testReasoningEffortIsSentWhenRequested() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.data(using: .utf8)!)
        }
        let client = GroqChatClient(apiKey: "test-key", reasoningEffort: "low", session: makeSession())
        _ = try await client.complete(messages: [["role": "user", "content": "hi"]])

        let body = try XCTUnwrap(bodyObject(of: try XCTUnwrap(captured)))
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    }
}
