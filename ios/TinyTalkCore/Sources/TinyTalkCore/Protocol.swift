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
    default:
        throw ProtocolError.malformed("unknown server message type: \(type)")
    }
}
