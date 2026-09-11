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

    func testListStoriesEncodesExactType() {
        XCTAssertEqual(ClientMessage.listStories.encode(), #"{"type":"list_stories"}"#)
    }

    func testGetStoryEncodesTheStoryId() {
        XCTAssertEqual(
            ClientMessage.getStory(storyId: "abc123").encode(),
            #"{"type":"get_story","story_id":"abc123"}"#
        )
    }

    func testConcludeStoryEncodesTheTurnId() {
        XCTAssertEqual(
            ClientMessage.concludeStory(turnId: 4).encode(),
            #"{"type":"conclude_story","turn_id":4}"#
        )
    }

    func testUpdateSettingsEncodesBothValues() {
        XCTAssertEqual(
            ClientMessage.updateSettings(targetTurns: 8, pageCount: 6).encode(),
            #"{"type":"update_settings","target_turns":8,"page_count":6}"#
        )
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

    func testDecodesRewritingStarted() throws {
        let event = try decodeServerEvent(#"{"type": "rewriting_started"}"#)
        XCTAssertEqual(event, .rewritingStarted)
    }

    func testDecodesRewritingDone() throws {
        let event = try decodeServerEvent(#"{"type": "rewriting_done"}"#)
        XCTAssertEqual(event, .rewritingDone)
    }

    func testDecodesStoryList() throws {
        let event = try decodeServerEvent(
            #"""
            {"type": "story_list", "stories": [
                {"id": "pip", "title": "Pip the Fox", "created_at": "2026-09-09T12:00:00+00:00", "page_count": 5, "rewrite_status": "done"},
                {"id": "brave-turtle", "title": null, "created_at": "2026-09-09T13:00:00+00:00", "page_count": 0, "rewrite_status": "pending"}
            ]}
            """#
        )
        guard case .storyList(let stories) = event else {
            return XCTFail("expected storyList, got \(event)")
        }
        XCTAssertEqual(stories.count, 2)
        XCTAssertEqual(stories[0].id, "pip")
        XCTAssertEqual(stories[0].title, "Pip the Fox")
        XCTAssertEqual(stories[0].pageCount, 5)
        XCTAssertEqual(stories[0].rewriteStatus, .done)
        XCTAssertEqual(stories[1].id, "brave-turtle")
        XCTAssertNil(stories[1].title)
        XCTAssertEqual(stories[1].rewriteStatus, .pending)
    }

    func testDecodesStoryDetail() throws {
        let event = try decodeServerEvent(
            #"""
            {"type": "story_detail", "id": "pip", "title": "Pip the Fox",
             "pages": [{"text": "Once upon a time."}, {"text": "The end."}],
             "epilogue": "And one true thing we learned about the fox: foxes have excellent hearing",
             "rewrite_status": "done"}
            """#
        )
        guard case .storyDetail(let detail) = event else {
            return XCTFail("expected storyDetail, got \(event)")
        }
        XCTAssertEqual(detail.id, "pip")
        XCTAssertEqual(detail.title, "Pip the Fox")
        XCTAssertEqual(detail.pages, [StoryPage(text: "Once upon a time."), StoryPage(text: "The end.")])
        XCTAssertEqual(detail.epilogue, "And one true thing we learned about the fox: foxes have excellent hearing")
        XCTAssertEqual(detail.rewriteStatus, .done)
    }

    func testDecodesStoryDetailWithNilTitleAndEpilogue() throws {
        // The .pending/.failed shape (see MockStories.stillWriting/
        // .couldNotFinish) -- the background rewrite hasn't produced a
        // title or epilogue yet, or never will.
        let event = try decodeServerEvent(
            #"{"type": "story_detail", "id": "brave-turtle", "title": null, "pages": [], "epilogue": null, "rewrite_status": "pending"}"#
        )
        guard case .storyDetail(let detail) = event else {
            return XCTFail("expected storyDetail, got \(event)")
        }
        XCTAssertNil(detail.title)
        XCTAssertEqual(detail.pages, [])
        XCTAssertNil(detail.epilogue)
        XCTAssertEqual(detail.rewriteStatus, .pending)
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
