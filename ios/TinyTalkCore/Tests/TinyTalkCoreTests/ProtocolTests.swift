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

    func testSyncDemoStoriesCarriesTheFinishedStorybookWhenThereIsOne() throws {
        let story = PendingDemoStoryPayload(
            id: "story-1",
            createdAt: "2026-09-19T12:00:00Z",
            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
            sharedFacts: [["fox", "Foxes are clever."]],
            storybook: DemoSyncStorybook(
                title: #"The "Brave" Fox"#,
                pages: [
                    DemoSyncPage(text: "Page one.", imageJPEG: Data([0xFF, 0xD8, 0xFF])),
                    DemoSyncPage(text: "Page two.", imageJPEG: nil),
                ],
                illustrationsStatus: .partial
            )
        )

        let encoded = ClientMessage.syncDemoStories(stories: [story]).encode()

        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let storyJSON = try XCTUnwrap((json["stories"] as? [[String: Any]])?.first)
        let storybook = try XCTUnwrap(storyJSON["storybook"] as? [String: Any])
        XCTAssertEqual(storybook["title"] as? String, #"The "Brave" Fox"#)
        XCTAssertEqual(storybook["illustrations_status"] as? String, "partial")
        let pages = try XCTUnwrap(storybook["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0]["text"] as? String, "Page one.")
        XCTAssertEqual(pages[0]["image"] as? String, Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        XCTAssertEqual(pages[1]["text"] as? String, "Page two.")
        XCTAssertNil(pages[1]["image"], "a page with no picture must omit the key, not send null")
        XCTAssertNil(storybook["epilogue"], "the server derives the epilogue from shared_facts")
    }

    func testSyncDemoStoriesOmitsTheStorybookKeyForATranscriptOnlyStory() throws {
        let story = PendingDemoStoryPayload(
            id: "story-1", createdAt: "2026-09-19T12:00:00Z",
            turns: [PendingDemoStoryTurn(speaker: "child", text: "hi", interrupted: false)],
            sharedFacts: []
        )
        let encoded = ClientMessage.syncDemoStories(stories: [story]).encode()
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let storyJSON = try XCTUnwrap((json["stories"] as? [[String: Any]])?.first)
        XCTAssertNil(storyJSON["storybook"], "an older server must see exactly today's payload shape")
        XCTAssertEqual(Set(storyJSON.keys), Set(["id", "created_at", "turns", "shared_facts"]))
    }

    func testSyncDemoStoriesEncodesEmptyStoriesArray() throws {
        let encoded = ClientMessage.syncDemoStories(stories: []).encode()
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "sync_demo_stories")
        XCTAssertEqual(try XCTUnwrap(json["stories"] as? [[String: Any]]).count, 0)
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

    func testUpdateSettingsEncodesLlmBackendWhenPresent() {
        XCTAssertEqual(
            ClientMessage.updateSettings(targetTurns: 7, pageCount: 5, llmBackend: "groq").encode(),
            #"{"type":"update_settings","target_turns":7,"page_count":5,"llm_backend":"groq"}"#
        )
    }

    func testUpdateSettingsEncodesTtsVoiceWhenPresent() {
        XCTAssertEqual(
            ClientMessage.updateSettings(targetTurns: 7, pageCount: 5, ttsVoice: "bf_emma").encode(),
            #"{"type":"update_settings","target_turns":7,"page_count":5,"tts_voice":"bf_emma"}"#
        )
        XCTAssertEqual(
            ClientMessage.updateSettings(targetTurns: 7, pageCount: 5, llmBackend: "groq", ttsVoice: "af_heart").encode(),
            #"{"type":"update_settings","target_turns":7,"page_count":5,"llm_backend":"groq","tts_voice":"af_heart"}"#
        )
    }

    func testKokoroVoiceCatalogHasTheServerDefaultAndLooksUpNames() {
        XCTAssertEqual(KokoroVoices.defaultID, "af_heart")
        XCTAssertTrue(KokoroVoices.all.contains { $0.id == KokoroVoices.defaultID })
        XCTAssertEqual(Set(KokoroVoices.all.map(\.id)).count, KokoroVoices.all.count)
        XCTAssertEqual(KokoroVoices.displayName(for: "bf_emma"), "Emma (British, female)")
        // An ID this build doesn't know (e.g. a stale persisted value)
        // still shows something rather than a blank row.
        XCTAssertEqual(KokoroVoices.displayName(for: "zz_gone"), "zz_gone")
    }

    func testDecodesLlmBackendStatus() throws {
        let event = try decodeServerEvent(
            #"{"type": "llm_backend", "requested": "groq", "active": "ollama", "groq_available": false}"#
        )
        XCTAssertEqual(
            event,
            .llmBackend(LlmBackendStatus(requested: "groq", active: "ollama", groqAvailable: false))
        )
    }

    func testGetPageImageEncodesStoryIdAndPageIndex() {
        XCTAssertEqual(
            ClientMessage.getPageImage(storyId: "abcd1234", pageIndex: 2).encode(),
            #"{"type":"get_page_image","story_id":"abcd1234","page_index":2}"#
        )
    }

    func testSynthesizePageEncodesStoryIdAndPageIndex() {
        XCTAssertEqual(
            ClientMessage.synthesizePage(storyId: "abcd1234", pageIndex: 2).encode(),
            #"{"type":"synthesize_page","story_id":"abcd1234","page_index":2}"#
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

    func testDecodesPageImageDoneWithImage() throws {
        let event = try decodeServerEvent(
            #"{"type": "page_image_done", "story_id": "abcd1234", "page_index": 1, "has_image": true}"#
        )
        XCTAssertEqual(event, .pageImageDone(storyId: "abcd1234", pageIndex: 1, hasImage: true))
    }

    func testDecodesPageImageDoneWithoutImage() throws {
        let event = try decodeServerEvent(
            #"{"type": "page_image_done", "story_id": "abcd1234", "page_index": 1, "has_image": false}"#
        )
        XCTAssertEqual(event, .pageImageDone(storyId: "abcd1234", pageIndex: 1, hasImage: false))
    }

    func testDecodesPageAudioDone() throws {
        let event = try decodeServerEvent(
            #"{"type": "page_audio_done", "story_id": "abcd1234", "page_index": 1}"#
        )
        XCTAssertEqual(event, .pageAudioDone(storyId: "abcd1234", pageIndex: 1))
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

    func testDecodesStoryDetailIncludesHasImageAndIllustrationsStatus() throws {
        let event = try decodeServerEvent(
            #"""
            {"type": "story_detail", "id": "pip", "title": "Pip the Fox",
             "pages": [{"text": "Once upon a time.", "has_image": true}, {"text": "The end.", "has_image": false}],
             "epilogue": null, "rewrite_status": "done", "illustrations_status": "partial"}
            """#
        )
        guard case .storyDetail(let detail) = event else {
            return XCTFail("expected storyDetail, got \(event)")
        }
        XCTAssertEqual(detail.pages[0].hasImage, true)
        XCTAssertEqual(detail.pages[1].hasImage, false)
        XCTAssertEqual(detail.illustrationsStatus, .partial)
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

    func testDecodesStoryDetailWithNoIllustrationsStatusDefaultsToNil() throws {
        let event = try decodeServerEvent(
            #"{"type": "story_detail", "id": "brave-turtle", "title": null, "pages": [{"text": "Once upon a time."}], "epilogue": null, "rewrite_status": "pending"}"#
        )
        guard case .storyDetail(let detail) = event else {
            return XCTFail("expected storyDetail, got \(event)")
        }
        XCTAssertNil(detail.illustrationsStatus)
        XCTAssertEqual(detail.pages[0].hasImage, false)
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
