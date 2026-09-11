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
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
                    continuation.finish()
                    return
                }
                if converter == nil {
                    converter = AVAudioConverter(from: pcmBuffer.format, to: Self.targetFormat)
                }
                guard let converter else {
                    continuation.finish()
                    return
                }
                if let converted = Self.convert(pcmBuffer, with: converter, to: Self.targetFormat) {
                    continuation.yield(converted)
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
