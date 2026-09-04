import XCTest
@testable import TinyTalkCore

final class ProtocolTests: XCTestCase {
    func testSpeechStartEncodesExactType() {
        XCTAssertEqual(ClientMessage.speechStart(turnId: 3).encode(), #"{"type":"speech_start","turn_id":3}"#)
    }

    func testSpeechEndEncodesExactType() {
        XCTAssertEqual(ClientMessage.speechEnd.encode(), #"{"type":"speech_end"}"#)
    }

    func testInterruptEncodesExactType() {
        XCTAssertEqual(ClientMessage.interrupt(turnId: 7).encode(), #"{"type":"interrupt","turn_id":7}"#)
    }

    func testNewStoryEncodesExactType() {
        XCTAssertEqual(ClientMessage.newStory.encode(), #"{"type":"new_story"}"#)
    }

    func testDecodesTranscriptPartial() throws {
        let event = try decodeServerEvent(#"{"type": "transcript_partial", "text": "a fox", "turn_id": 5}"#)
        guard case .transcriptPartial(let text, let turnId) = event else {
            return XCTFail("expected transcriptPartial, got \(event)")
        }
        XCTAssertEqual(text, "a fox")
        XCTAssertEqual(turnId, 5)
    }

    func testDecodesTranscriptFinal() throws {
        let event = try decodeServerEvent(#"{"type": "transcript_final", "text": "a fox ran", "turn_id": 5}"#)
        guard case .transcriptFinal(let text, let turnId) = event else {
            return XCTFail("expected transcriptFinal, got \(event)")
        }
        XCTAssertEqual(text, "a fox ran")
        XCTAssertEqual(turnId, 5)
    }

    func testDecodesResponseText() throws {
        let event = try decodeServerEvent(#"{"type": "response_text", "text": "Once upon a time", "turn_id": 5}"#)
        guard case .responseText(let text, let turnId) = event else {
            return XCTFail("expected responseText, got \(event)")
        }
        XCTAssertEqual(text, "Once upon a time")
        XCTAssertEqual(turnId, 5)
    }

    func testDecodesTurnEnd() throws {
        let event = try decodeServerEvent(#"{"type": "turn_end", "turn_id": 5}"#)
        guard case .turnEnd(let turnId) = event else {
            return XCTFail("expected turnEnd, got \(event)")
        }
        XCTAssertEqual(turnId, 5)
    }

    func testDecodesError() throws {
        let event = try decodeServerEvent(#"{"type": "error", "message": "Ollama is not running", "turn_id": 5}"#)
        guard case .error(let message, let turnId) = event else {
            return XCTFail("expected error, got \(event)")
        }
        XCTAssertEqual(message, "Ollama is not running")
        XCTAssertEqual(turnId, 5)
    }

    func testDecodeDefaultsMissingTurnIdToZero() throws {
        // Server events sent before any speech_start has ever set a turn_id
        // (e.g. a malformed-frame error right after connecting) carry
        // turn_id 0 server-side -- decoding one with no turn_id field at all
        // should match that same default, not fail or silently misdecode.
        let event = try decodeServerEvent(#"{"type": "turn_end"}"#)
        guard case .turnEnd(let turnId) = event else {
            return XCTFail("expected turnEnd, got \(event)")
        }
        XCTAssertEqual(turnId, 0)
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
