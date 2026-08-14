/// Wire protocol between this client and the Mac server. Mirrors
/// `server/tinytalk/protocol.py` exactly -- same type strings, same field
/// names. Control messages are JSON text frames; audio travels as binary
/// frames and is not represented here (see ServerConnecting in
/// Interfaces.swift for how binary frames are handled).
import Foundation

public enum ClientMessage: Sendable {
    case speechStart
    case speechEnd
    case interrupt

    public func encode() -> String {
        let type: String
        switch self {
        case .speechStart: type = "speech_start"
        case .speechEnd: type = "speech_end"
        case .interrupt: type = "interrupt"
        }
        // Field order and separators are fixed here (no JSONEncoder) so the
        // wire bytes are exact and predictable for the single-field case.
        return #"{"type":"\#(type)"}"#
    }
}

public enum ServerEvent: Sendable, Equatable {
    case transcriptPartial(String)
    case transcriptFinal(String)
    case responseText(String)
    case turnEnd
    case error(String)
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
    switch type {
    case "transcript_partial":
        return .transcriptPartial(json["text"] as? String ?? "")
    case "transcript_final":
        return .transcriptFinal(json["text"] as? String ?? "")
    case "response_text":
        return .responseText(json["text"] as? String ?? "")
    case "turn_end":
        return .turnEnd
    case "error":
        return .error(json["message"] as? String ?? "")
    default:
        throw ProtocolError.malformed("unknown server message type: \(type)")
    }
}
