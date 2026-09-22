import XCTest
@testable import TinyTalkCore

final class GroqWhisperClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// URLProtocol hands the handler the request with its body moved into
    /// httpBodyStream, so read it from there.
    private func bodyData(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            collected.append(buffer, count: read)
        }
        return collected
    }

    func testTranscribeSendsLanguageLockedToEnglish() async throws {
        // The multipart body's audio part is raw PCM/WAV bytes, not valid
        // UTF-8, so this searches for the field as bytes rather than
        // decoding the whole body as a String.
        StubURLProtocol.handler = { request in
            let raw = self.bodyData(of: request)
            let expected = Data("Content-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n".utf8)
            XCTAssertNotNil(
                raw.range(of: expected),
                "expected a multipart 'language' field set to 'en'"
            )
            return (200, #"{"text":"tell me a story about a fox"}"#.data(using: .utf8)!)
        }
        let client = GroqWhisperClient(apiKey: "test-key", session: makeSession())
        _ = try await client.transcribe(Data(repeating: 0, count: 4_800))
    }

    func testTranscribeReturnsTheTextField() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data"))
            return (200, #"{"text":"tell me a story about a fox"}"#.data(using: .utf8)!)
        }
        let client = GroqWhisperClient(apiKey: "test-key", session: makeSession())
        let text = try await client.transcribe(Data(repeating: 0, count: 4_800)) // 100ms of silence
        XCTAssertEqual(text, "tell me a story about a fox")
    }

    func testTranscribeThrowsOnNon200() async {
        StubURLProtocol.handler = { _ in (500, "server error".data(using: .utf8)!) }
        let client = GroqWhisperClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.transcribe(Data(repeating: 0, count: 100))
            XCTFail("expected an error")
        } catch DemoConnectionError.groqError {
            // expected
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testWavDataProducesAValidRIFFHeader() {
        let pcm = Data(repeating: 0, count: 480) // 10ms of silence @24kHz/16-bit/mono
        let wav = wavData(fromPCM16: pcm, sampleRate: 24_000, channels: 1)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }
}
