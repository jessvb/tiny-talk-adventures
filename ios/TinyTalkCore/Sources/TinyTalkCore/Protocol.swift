/// Wire protocol between this client and the Mac server. Mirrors
/// `server/tinytalk/protocol.py` exactly -- same type strings, same field
/// names. Control messages are JSON text frames; audio travels as binary
/// frames and is not represented here (see ServerConnecting in
/// Interfaces.swift for how binary frames are handled).
///
/// turn_id: see protocol.py's module docstring for the full rationale --
/// confirmed necessary on real hardware, not speculative. This client
/// assigns a new turn_id every time it starts a fresh listening turn
/// (speechStart or interrupt) and sends it to the server; the server
/// stamps every event it sends back with whichever turn_id it was most
/// recently told. SessionCoordinator uses this to discard a reply that
/// arrives for a turn the client has already abandoned, rather than
/// misattributing it to whatever turn happens to be active when it
/// arrives (or silently losing it) -- the mechanism that was missing when
/// the server's serialized, multi-second-per-utterance STT pipeline fell
/// behind a child talking faster than it could keep up.
import Foundation

public enum ClientMessage: Sendable, Equatable {
    case speechStart(turnId: Int)
    case speechEnd
    case interrupt(turnId: Int)
    /// See object_recognition.py / this file's `ClientMessage` mirror --
    /// deliberately no turn_id, matching protocol.py's ObjectSeen.
    case objectSeen(label: String)
    /// Abandon the current story and start fresh, without tearing down
    /// the connection -- see server/tinytalk/session.py's
    /// handle_new_story(). No turn_id: mirrors protocol.py's NewStory,
    /// which isn't itself the start of a turn.
    case newStory
    /// Hands one or more stories completed away from home (Groq-backed
    /// demo mode, no persistent server session) to the real server once
    /// reconnected -- see PendingDemoStore/AppModel.connect(). Uses
    /// JSONSerialization in encode() below, not hand-built interpolation
    /// like every other case here: this is the one payload carrying
    /// arbitrary user-generated transcript/reply text.
    case syncDemoStories(stories: [PendingDemoStoryPayload])
    /// Request the saved-story list for the Library screen -- see
    /// server/tinytalk/protocol.py's ListStories. No turn_id: browsing
    /// saved stories is unrelated to live turn-taking.
    case listStories
    /// Request one saved story's full detail (title/pages/epilogue/
    /// rewrite_status) for the Reading/The End screens -- see
    /// protocol.py's GetStory.
    case getStory(storyId: String)
    /// The "Finish this story" menu action -- see protocol.py's
    /// ConcludeStory. Carries a turn_id like speechStart/interrupt: it
    /// results in one more real response_text/turn_end pair the client
    /// must be able to attribute to a turn.
    case concludeStory(turnId: Int)
    /// Parent-adjustable story-length settings from the Settings screen --
    /// see protocol.py's UpdateSettings. Sent once after connecting and
    /// again whenever changed while connected.
    case updateSettings(targetTurns: Int, pageCount: Int)

    public func encode() -> String {
        // Field order and separators are fixed here (no JSONEncoder) so the
        // wire bytes are exact and predictable.
        switch self {
        case .speechStart(let turnId):
            return #"{"type":"speech_start","turn_id":\#(turnId)}"#
        case .speechEnd:
            return #"{"type":"speech_end"}"#
        case .interrupt(let turnId):
            return #"{"type":"interrupt","turn_id":\#(turnId)}"#
        case .objectSeen(let label):
            return #"{"type":"object_seen","label":"\#(Self.jsonEscaped(label))"}"#
        case .newStory:
            return #"{"type":"new_story"}"#
        case .syncDemoStories(let stories):
            let storiesJSON: [[String: Any]] = stories.map { story in
                [
                    "id": story.id,
                    "created_at": story.createdAt,
                    "turns": story.turns.map {
                        ["speaker": $0.speaker, "text": $0.text, "interrupted": $0.interrupted]
                    },
                    "shared_facts": story.sharedFacts,
                ]
            }
            let payload: [String: Any] = ["type": "sync_demo_stories", "stories": storiesJSON]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return #"{"type":"sync_demo_stories","stories":[]}"#
            }
            return json
        case .listStories:
            return #"{"type":"list_stories"}"#
        case .getStory(let storyId):
            return #"{"type":"get_story","story_id":"\#(Self.jsonEscaped(storyId))"}"#
        case .concludeStory(let turnId):
            return #"{"type":"conclude_story","turn_id":\#(turnId)}"#
        case .updateSettings(let targetTurns, let pageCount):
            return #"{"type":"update_settings","target_turns":\#(targetTurns),"page_count":\#(pageCount)}"#
        }
    }

    /// Escapes the characters that could appear in a Vision classification
    /// label and break JSON's string syntax. Not a general-purpose JSON
    /// escaper -- control characters (U+0000-U+001F) are not handled,
    /// because the only value reaching this function is an identifier
    /// from Vision's fixed taxonomy.
    private static func jsonEscaped(_ s: String) -> String {
        var result = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

public enum ServerEvent: Sendable, Equatable {
    case transcriptPartial(String, turnId: Int)
    case transcriptFinal(String, turnId: Int)
    case responseText(String, turnId: Int)
    case turnEnd(turnId: Int)
    case error(String, turnId: Int)
    /// A story just concluded and its background storybook rewrite has
    /// started -- see server/tinytalk/protocol.py's encode_rewriting_started().
    /// Carries no turn_id or story_id: see SessionCoordinator's
    /// readyToShowTheEnd doc comment for why arrival of this event alone
    /// is NOT sufficient to know the concluding turn's audio has finished
    /// playing.
    case rewritingStarted
    /// The background rewrite finished (successfully or not) -- see
    /// encode_rewriting_done(). Carries no story_id; the client already
    /// knows which story it's waiting on (the most recent one) from
    /// rewritingStarted.
    case rewritingDone
    case storyList([SavedStorySummary])
    case storyDetail(SavedStoryDetail)
}

public enum ProtocolError: Error, Equatable {
    case malformed(String)
}

public func decodeServerEvent(_ raw: String) throws -> ServerEvent {
    guard let data = raw.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProtocolError.malformed("control frame is not a valid JSON object: \(raw)")
    }
    guard let type = json["type"] as? String else {
        throw ProtocolError.malformed("control frame has no \"type\" field: \(raw)")
    }
    let turnId = json["turn_id"] as? Int ?? 0
    switch type {
    case "transcript_partial":
        return .transcriptPartial(json["text"] as? String ?? "", turnId: turnId)
    case "transcript_final":
        return .transcriptFinal(json["text"] as? String ?? "", turnId: turnId)
    case "response_text":
        return .responseText(json["text"] as? String ?? "", turnId: turnId)
    case "turn_end":
        return .turnEnd(turnId: turnId)
    case "error":
        return .error(json["message"] as? String ?? "", turnId: turnId)
    case "rewriting_started":
        return .rewritingStarted
    case "rewriting_done":
        return .rewritingDone
    case "story_list":
        let rawStories = json["stories"] as? [[String: Any]] ?? []
        return .storyList(rawStories.map(decodeStorySummary))
    case "story_detail":
        guard let id = json["id"] as? String else {
            throw ProtocolError.malformed("story_detail missing id: \(raw)")
        }
        return .storyDetail(decodeStoryDetail(json, id: id))
    default:
        throw ProtocolError.malformed("unknown server message type: \(type)")
    }
}

/// One entry of a story_list message -- see story_store.py's
/// list_stories(). Lenient about individual fields (matching this
/// file's existing style, e.g. turnId's default-to-0 above): a
/// malformed summary should degrade gracefully, not take down the
/// whole list.
private func decodeStorySummary(_ json: [String: Any]) -> SavedStorySummary {
    SavedStorySummary(
        id: json["id"] as? String ?? "",
        title: json["title"] as? String,
        createdAt: parseISODate(json["created_at"] as? String) ?? Date(),
        pageCount: json["page_count"] as? Int ?? 0,
        rewriteStatus: RewriteStatus(rawValue: json["rewrite_status"] as? String ?? "") ?? .pending
    )
}

/// story_detail's payload -- see session.py's handle_get_story(). `id`
/// is already validated present by the caller (decodeServerEvent);
/// everything else defaults leniently, same reasoning as
/// decodeStorySummary above.
private func decodeStoryDetail(_ json: [String: Any], id: String) -> SavedStoryDetail {
    let rawPages = json["pages"] as? [[String: Any]] ?? []
    let pages = rawPages.map { StoryPage(text: $0["text"] as? String ?? "") }
    return SavedStoryDetail(
        id: id,
        title: json["title"] as? String,
        pages: pages,
        epilogue: json["epilogue"] as? String,
        rewriteStatus: RewriteStatus(rawValue: json["rewrite_status"] as? String ?? "") ?? .pending
    )
}

/// Parses story_store.py's `datetime.now(timezone.utc).isoformat()`
/// output (e.g. "2026-09-09T12:00:00.123456+00:00") -- includes
/// microsecond fractional seconds, which ISO8601DateFormatter only
/// parses with .withFractionalSeconds explicitly set. Falls back to a
/// formatter without that option for a timestamp with no fractional part
/// at all (e.g. the exact strings used in this file's own tests).
private func parseISODate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: raw) { return date }
    let withoutFractional = ISO8601DateFormatter()
    withoutFractional.formatOptions = [.withInternetDateTime]
    return withoutFractional.date(from: raw)
}
