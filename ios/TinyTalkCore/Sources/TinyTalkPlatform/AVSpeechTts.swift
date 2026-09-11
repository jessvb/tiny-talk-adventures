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
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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
