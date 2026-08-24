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
        }
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
