import Foundation

/// The home server's voices (Kokoro TTS) the parent can pick for Elsie in
/// Settings -- issue #78. Kokoro voice IDs are unrelated to the
/// AVSpeechSynthesisVoice identifiers away-from-home mode uses, which is
/// why this is its own list and its own Settings row.
///
/// Must match server/tinytalk/config.py's KOKORO_VOICES exactly, in the
/// same order (server/tests/test_config.py checks); an ID the server
/// doesn't list is ignored there and the current voice is kept.
public enum KokoroVoices {
    public struct Voice: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
    }

    /// The server's own default (config.KOKORO_VOICE, unless the Mac
    /// overrides it with TINYTALK_TTS_VOICE).
    public static let defaultID = "af_heart"

    public static let all: [Voice] = [
        Voice(id: "af_heart", displayName: "Heart (US, female)"),
        Voice(id: "af_bella", displayName: "Bella (US, female)"),
        Voice(id: "af_nicole", displayName: "Nicole (US, female)"),
        Voice(id: "af_aoede", displayName: "Aoede (US, female)"),
        Voice(id: "af_kore", displayName: "Kore (US, female)"),
        Voice(id: "af_sarah", displayName: "Sarah (US, female)"),
        Voice(id: "af_alloy", displayName: "Alloy (US, female)"),
        Voice(id: "af_nova", displayName: "Nova (US, female)"),
        Voice(id: "af_sky", displayName: "Sky (US, female)"),
        Voice(id: "am_fenrir", displayName: "Fenrir (US, male)"),
        Voice(id: "am_michael", displayName: "Michael (US, male)"),
        Voice(id: "am_puck", displayName: "Puck (US, male)"),
        Voice(id: "bf_emma", displayName: "Emma (British, female)"),
        Voice(id: "bf_isabella", displayName: "Isabella (British, female)"),
        Voice(id: "bm_fable", displayName: "Fable (British, male)"),
        Voice(id: "bm_george", displayName: "George (British, male)"),
    ]

    public static func displayName(for id: String) -> String {
        all.first { $0.id == id }?.displayName ?? id
    }
}
