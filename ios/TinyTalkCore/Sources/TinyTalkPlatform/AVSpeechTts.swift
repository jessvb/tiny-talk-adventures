@preconcurrency import AVFoundation
import TinyTalkCore

/// SpeechSynthesizing backed by on-device AVSpeechSynthesizer -- see the
/// spec's rationale for choosing this over Groq's (paid, Preview-status)
/// TTS. Converts AVSpeechSynthesizer's native buffer format to the wire
/// protocol's 24kHz mono PCM16LE via AVAudioConverter, since the two
/// essentially never match natively.
public final class AVSpeechTts: NSObject, SpeechSynthesizing, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    /// Fires once per synthesize() call with which voice actually got
    /// resolved, plus every "Matilda"-or-en-AU candidate speechVoices()
    /// reported -- added because a household report ("downloaded Matilda
    /// Premium, changed the OS default, restarted the app, still heard the
    /// old voice") had no way to distinguish "resolveVoice()'s exact-match
    /// found nothing" from "it found something, but not what was expected"
    /// without this. See AppModel's wiring of this hook into the same
    /// on-screen debug log RealAudioEngine/DemoConnection already use.
    public var onDebugEvent: ((String) -> Void)?
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
    )!
    /// 1s of 24kHz mono PCM16 (24000 * 2 bytes/sample * 1.0s). See
    /// synthesize()'s doc comment on minChunkBytes for why this exists.
    /// Was 200ms (9_600) -- on-device timing evidence (2026-09-11) ruled
    /// out synthesis as the bottleneck (12-13s of audio synthesized in
    /// 0.2-1.0s wall-clock, 10-60x faster than needed) and showed only
    /// modest (~100-130ms) per-play()-call overhead, meaning the residual
    /// audible stutter at 200ms chunks (~60-64 calls/reply) is consistent
    /// with a small, roughly-fixed per-call cost compounding across many
    /// calls, not one big stall. Since synthesis has enormous headroom,
    /// there's no cost to buffering further -- this cuts calls per reply
    /// to roughly 12-13, a further ~5x reduction.
    private static let minChunkBytes = 24_000

    public init(voiceIdentifier: String? = nil) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
    }

    public func synthesize(_ text: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard !text.isEmpty else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [synthesizer] _ in
                synthesizer.stopSpeaking(at: .immediate)
            }
            let utterance = AVSpeechUtterance(string: text)
            let resolvedVoice = Self.resolveVoice(preferring: voiceIdentifier)
            utterance.voice = resolvedVoice
            if let onDebugEvent {
                let candidates = AVSpeechSynthesisVoice.speechVoices()
                    .filter { $0.name.localizedCaseInsensitiveContains("Matilda") || $0.language == "en-AU" }
                    .map { "name=\($0.name) quality=\($0.quality.rawValue) lang=\($0.language) id=\($0.identifier)" }
                    .joined(separator: " | ")
                onDebugEvent(
                    "AVSpeechTts: resolved name=\(resolvedVoice?.name ?? "nil") "
                    + "quality=\(resolvedVoice?.quality.rawValue ?? -1) id=\(resolvedVoice?.identifier ?? "nil") "
                    + "-- Matilda/en-AU candidates: \(candidates.isEmpty ? "NONE FOUND" : candidates)"
                )
            }
            // One AVAudioConverter reused across every buffer callback for
            // this utterance, not a fresh one per chunk. write(_:)'s
            // callback fires once per internal synthesis chunk (many times
            // per utterance); recreating the converter each time restarts
            // its resampling filter from a cold state at every chunk
            // boundary, producing exactly the garbled/quiet audio an
            // on-device test caught -- confirmed by comparison against
            // AudioEngine.swift's startCapturing(), which creates its
            // converter once per capture session and reuses it across
            // every tap callback the same way.
            var converter: AVAudioConverter?
            // write(_:)'s callback fires roughly every 10ms (confirmed
            // on-device: 358-558 byte chunks, ~11.6ms of 24kHz mono PCM16
            // each -- 1142 chunks for a 13.25s reply). RealAudioEngine.play()
            // fully awaits each chunk's REAL playback completion
            // (completionCallbackType: .dataPlayedBack, not just handoff to
            // the render engine -- see that method's own doc comments) before
            // the next chunk can even be scheduled, since SessionCoordinator's
            // consuming loop calls `await audio.play(pcm)` on each .audio
            // event in turn. Yielding at write(_:)'s native ~11ms granularity
            // means hundreds of full schedule-then-wait-for-real-playback
            // round trips per reply -- confirmed on-device as the actual
            // cause of "tch tch tch", slow/jumpy playback (not a conversion
            // artifact -- the earlier converter-reuse fix was necessary but
            // insufficient). Coalescing into ~200ms chunks here cuts that by
            // roughly 17x, fixed at the source rather than touching
            // RealAudioEngine/SessionCoordinator, which are shared with the
            // real server path and already tuned against its larger,
            // less-frequent Kokoro-produced chunks.
            var pending = Data()
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
                    if !pending.isEmpty {
                        continuation.yield(pending)
                    }
                    continuation.finish()
                    return
                }
                if converter == nil {
                    converter = AVAudioConverter(from: pcmBuffer.format, to: Self.targetFormat)
                }
                guard let converter else {
                    if !pending.isEmpty {
                        continuation.yield(pending)
                    }
                    continuation.finish()
                    return
                }
                if let converted = Self.convert(pcmBuffer, with: converter, to: Self.targetFormat) {
                    pending.append(converted)
                    if pending.count >= Self.minChunkBytes {
                        continuation.yield(pending)
                        pending = Data()
                    }
                }
            }
        }
    }

    /// Matilda (Premium, en-AU) is this app's chosen storyteller voice --
    /// picked by the household over the default compact/robotic system
    /// voice after an on-device listening comparison of several Enhanced/
    /// Premium options. Looked up by name+quality, not a hardcoded
    /// identifier string (Apple doesn't document those as stable across
    /// OS versions), so a device that hasn't downloaded Matilda yet (Settings
    /// > Accessibility > Spoken Content/Live Speech > Voices > English (AU))
    /// degrades gracefully to the plain system default instead of silently
    /// resolving nothing. An explicit voiceIdentifier (if the caller passes
    /// one) always wins over this default.
    ///
    /// Matches on a name SUBSTRING, not equality -- on-device evidence
    /// (2026-09-12, via onDebugEvent) showed AVSpeechSynthesisVoice.name
    /// for this voice is actually "Matilda (Premium)", not "Matilda", so
    /// an exact-equality check silently matched nothing and always fell
    /// through to the en-US default (Samantha) even with Matilda Premium
    /// correctly downloaded (quality reported correctly as .premium).
    private static func resolveVoice(preferring voiceIdentifier: String?) -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return voice
        }
        if let matilda = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.name.localizedCaseInsensitiveContains("Matilda") && $0.quality == .premium
        }) {
            return matilda
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// English-language system voices, sorted by name, for a Settings
    /// voice picker (a household wants to experiment with alternatives to
    /// the default Matilda pick). Filtered to English only --
    /// speechVoices() returns 100+ voices across every language iOS
    /// ships, and this is a storyteller voice for an English-speaking
    /// household. Returns whatever speechVoices() reports regardless of
    /// actual download state (there is no public API to check that --
    /// see resolveVoice()'s own doc comment on the same limitation); an
    /// undownloaded Enhanced/Premium voice still works, just synthesized
    /// at lower on-the-fly quality, so this degrades gracefully rather
    /// than needing to filter anything out.
    public static func availableEnglishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCapacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let int16Data = outBuffer.int16ChannelData else { return nil }
        let frameLength = Int(outBuffer.frameLength)
        return Data(bytes: int16Data[0], count: frameLength * MemoryLayout<Int16>.size)
    }
}
