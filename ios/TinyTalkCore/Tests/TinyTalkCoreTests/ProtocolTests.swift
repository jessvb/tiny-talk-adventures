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

    func testObjectSeenEncodesTheLabel() {
        XCTAssertEqual(
            ClientMessage.objectSeen(label: "teddy bear").encode(),
            #"{"type":"object_seen","label":"teddy bear"}"#
        )
    }

    func testObjectSeenEscapesQuotesAndBackslashesInTheLabel() {
        // Vision's ~1300-category taxonomy is plain English words in
        // practice, but the encoder must still produce valid JSON for
        // any string -- this is the one field on the wire (unlike
        // turn_id, always an Int) that isn't safe to interpolate
        // unescaped.
        XCTAssertEqual(
            ClientMessage.objectSeen(label: #"a "cool" robot\thing"#).encode(),
            #"{"type":"object_seen","label":"a \"cool\" robot\\thing"}"#
        )
    }

    func testNewStoryEncodesExactType() {
        XCTAssertEqual(ClientMessage.newStory.encode(), #"{"type":"new_story"}"#)
    }

    func testSyncDemoStoriesRoundTripsThroughValidJSON() throws {
        // This case carries arbitrary user-generated text (unlike every
        // other case above, which encodes a fixed identifier or no data
        // at all), so it's encoded via JSONSerialization instead of this
        // file's usual hand-built string interpolation -- confirm the
        // result actually is valid, well-shaped JSON rather than just
        // eyeballing a fixed literal like the tests above do.
        let story = PendingDemoStoryPayload(
            id: "story-1",
            createdAt: "2026-09-09T12:00:00Z",
            turns: [
                PendingDemoStoryTurn(speaker: "child", text: #"a "brave" fox\adventure"#, interrupted: false),
                PendingDemoStoryTurn(speaker: "elsie", text: "Once upon a time...", interrupted: true),
            ],
            sharedFacts: [["fox", "Foxes have whiskers on their legs too."]]
        )
        let encoded = ClientMessage.syncDemoStories(stories: [story]).encode()

        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "sync_demo_stories")
        let storiesJSON = try XCTUnwrap(json["stories"] as? [[String: Any]])
        XCTAssertEqual(storiesJSON.count, 1)
        XCTAssertEqual(storiesJSON[0]["id"] as? String, "story-1")
        XCTAssertEqual(storiesJSON[0]["created_at"] as? String, "2026-09-09T12:00:00Z")
        let turnsJSON = try XCTUnwrap(storiesJSON[0]["turns"] as? [[String: Any]])
        XCTAssertEqual(turnsJSON.count, 2)
        XCTAssertEqual(turnsJSON[0]["speaker"] as? String, "child")
        XCTAssertEqual(turnsJSON[0]["text"] as? String, #"a "brave" fox\adventure"#)
        XCTAssertEqual(turnsJSON[0]["interrupted"] as? Bool, false)
        let sharedFactsJSON = try XCTUnwrap(storiesJSON[0]["shared_facts"] as? [[String]])
        XCTAssertEqual(sharedFactsJSON, [["fox", "Foxes have whiskers on their legs too."]])
    }

    func testSyncDemoStoriesEncodesEmptyStoriesArray() throws {
        let encoded = ClientMessage.syncDemoStories(stories: []).encode()
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "sync_demo_stories")
        XCTAssertEqual(try XCTUnwrap(json["stories"] as? [[String: Any]]).count, 0)
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
