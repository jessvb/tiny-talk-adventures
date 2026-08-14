import XCTest
@testable import TinyTalkCore

final class ProtocolTests: XCTestCase {
    func testSpeechStartEncodesExactType() {
        XCTAssertEqual(ClientMessage.speechStart.encode(), #"{"type":"speech_start"}"#)
    }

    func testSpeechEndEncodesExactType() {
        XCTAssertEqual(ClientMessage.speechEnd.encode(), #"{"type":"speech_end"}"#)
    }

    func testInterruptEncodesExactType() {
        XCTAssertEqual(ClientMessage.interrupt.encode(), #"{"type":"interrupt"}"#)
    }

    func testDecodesTranscriptPartial() throws {
        let event = try decodeServerEvent(#"{"type": "transcript_partial", "text": "a fox"}"#)
        guard case .transcriptPartial(let text) = event else {
            return XCTFail("expected transcriptPartial, got \(event)")
        }
        XCTAssertEqual(text, "a fox")
    }

    func testDecodesTranscriptFinal() throws {
        let event = try decodeServerEvent(#"{"type": "transcript_final", "text": "a fox ran"}"#)
        guard case .transcriptFinal(let text) = event else {
            return XCTFail("expected transcriptFinal, got \(event)")
        }
        XCTAssertEqual(text, "a fox ran")
    }

    func testDecodesResponseText() throws {
        let event = try decodeServerEvent(#"{"type": "response_text", "text": "Once upon a time"}"#)
        guard case .responseText(let text) = event else {
            return XCTFail("expected responseText, got \(event)")
        }
        XCTAssertEqual(text, "Once upon a time")
    }

    func testDecodesTurnEnd() throws {
        let event = try decodeServerEvent(#"{"type": "turn_end"}"#)
        guard case .turnEnd = event else {
            return XCTFail("expected turnEnd, got \(event)")
        }
    }

    func testDecodesError() throws {
        let event = try decodeServerEvent(#"{"type": "error", "message": "Ollama is not running"}"#)
        guard case .error(let message) = event else {
            return XCTFail("expected error, got \(event)")
        }
        XCTAssertEqual(message, "Ollama is not running")
    }

    func testDecodeRejectsInvalidJSON() {
        XCTAssertThrowsError(try decodeServerEvent("not json at all")) { error in
            guard case ProtocolError.malformed = error else {
                return XCTFail("expected ProtocolError.malformed, got \(error)")
            }
        }
    }

    func testDecodeRejectsUnknownType() {
        XCTAssertThrowsError(try decodeServerEvent(#"{"type": "launch_rocket"}"#)) { error in
            guard case ProtocolError.malformed = error else {
                return XCTFail("expected ProtocolError.malformed, got \(error)")
            }
        }
    }

    func testDecodeRejectsMissingType() {
        XCTAssertThrowsError(try decodeServerEvent("{}")) { error in
            guard case ProtocolError.malformed = error else {
                return XCTFail("expected ProtocolError.malformed, got \(error)")
            }
        }
    }
}
