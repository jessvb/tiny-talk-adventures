import XCTest
@testable import TinyTalkCore

final class CloudflareImageClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(accountId: String = "acct123") -> CloudflareImageClient {
        CloudflareImageClient(accountId: accountId, apiToken: "test-token", session: makeSession())
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

    private func envelope(image: String) -> Data {
        Data(#"{"result":{"image":"\#(image)"},"success":true,"errors":[],"messages":[]}"#.utf8)
    }

    func testTheRequestIsAnAuthenticatedPostToTheFluxSchnellEndpoint() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, self.envelope(image: Data([1, 2, 3]).base64EncodedString()))
        }

        _ = try await makeClient().generate(prompt: "a small orange fox", reference: nil)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.cloudflare.com/client/v4/accounts/acct123/ai/run/@cf/black-forest-labs/flux-1-schnell"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)
        let body = try XCTUnwrap(bodyObject(of: request))
        XCTAssertEqual(body["prompt"] as? String, "a small orange fox")
        XCTAssertEqual(body["steps"] as? Int, 4)
    }

    func testTheImageIsDecodedFromTheV4Envelope() async throws {
        StubURLProtocol.handler = { _ in (200, self.envelope(image: Data([9, 8, 7]).base64EncodedString())) }
        let image = try await makeClient().generate(prompt: "x", reference: nil)
        XCTAssertEqual(image, Data([9, 8, 7]))
    }

    func testTheImageIsAlsoDecodedFromABareObject() async throws {
        // The Workers binding returns {"image": ...} with no envelope.
        StubURLProtocol.handler = { _ in (200, Data(#"{"image":"\#(Data([5, 5]).base64EncodedString())"}"#.utf8)) }
        let image = try await makeClient().generate(prompt: "x", reference: nil)
        XCTAssertEqual(image, Data([5, 5]))
    }

    func testAPromptOverTheLimitIsTruncatedToTwoThousandFortyEightCharacters() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, self.envelope(image: Data([1]).base64EncodedString()))
        }
        _ = try await makeClient().generate(prompt: String(repeating: "a", count: 5000), reference: nil)
        let prompt = try XCTUnwrap(bodyObject(of: try XCTUnwrap(captured))?["prompt"] as? String)
        XCTAssertEqual(prompt.count, CloudflareImageClient.maxPromptCharacters)
    }

    func testAReferenceImageIsIgnoredBecauseFluxSchnellTakesNone() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, self.envelope(image: Data([1]).base64EncodedString()))
        }
        let client = makeClient()
        XCTAssertFalse(client.supportsReference)
        _ = try await client.generate(prompt: "x", reference: Data([1, 2, 3]))
        let body = try XCTUnwrap(bodyObject(of: try XCTUnwrap(captured)))
        XCTAssertEqual(Set(body.keys), Set(["prompt", "steps"]))
    }

    // MARK: - failures

    func testANon2xxStatusThrowsAnHTTPErrorCarryingTheStatusAndBody() async {
        StubURLProtocol.handler = { _ in (401, Data("Authentication error".utf8)) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .http(status: 401, detail: "Authentication error"))
        }
    }

    func testAResponseWithNoImageIsMalformed() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"result":{},"success":false}"#.utf8)) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .malformedResponse)
        }
    }

    func testABodyThatIsNotJSONIsMalformed() async {
        StubURLProtocol.handler = { _ in (200, Data("<html>gateway</html>".utf8)) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .malformedResponse)
        }
    }

    func testInvalidBase64IsMalformed() async {
        StubURLProtocol.handler = { _ in (200, self.envelope(image: "!!! not base64 !!!")) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .malformedResponse)
        }
    }

    func testAnEmptyImageIsReportedAsSuch() async {
        StubURLProtocol.handler = { _ in (200, self.envelope(image: "")) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .emptyImage)
        }
    }

    func testAnAccountIdThatCouldChangeTheRequestPathIsRefusedBeforeAnyNetworkCall() async {
        StubURLProtocol.handler = { _ in
            XCTFail("no request may be sent for an invalid account id")
            return (200, Data())
        }
        for bad in ["", "../other", "acct/123", "acct 123", "acct?x=1"] {
            do {
                _ = try await makeClient(accountId: bad).generate(prompt: "x", reference: nil)
                XCTFail("expected \(bad.debugDescription) to be refused")
            } catch {
                XCTAssertEqual(error as? ImageGenerationError, .invalidAccountId, "for \(bad.debugDescription)")
            }
        }
    }
}
