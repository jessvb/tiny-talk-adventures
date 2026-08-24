/// A short, gentle chime, generated in code (no bundled audio asset), meant
/// to be looped by SessionCoordinator while the child waits for a reply --
/// the STT/LLM/TTS pipeline can take several real seconds, and dead silence
/// for that whole window is a worse experience for a young child than a
/// small, obviously-not-final "still thinking" sound. Played through the
/// same AudioPlaying/RealAudioEngine path as a real reply, so it gets the
/// same AEC treatment (the mic won't mistake it for something to transcribe)
/// and the same instant barge-in cancellation for free -- no separate
/// interrupt handling needed for it.
import Foundation

public enum WaitingDitty {
    /// 24kHz mono PCM16 LE -- matches the wire format used everywhere else
    /// (see RealAudioEngine.wireSampleRate / server MIC_SAMPLE_RATE).
    private static let sampleRate = 24_000.0

    /// One loop iteration: a gentle four-note major arpeggio (C5, E5, G5,
    /// C6) -- consonant and cheerful rather than jarring on repeat. Each
    /// note gets a quick-attack, exponential-decay envelope for a soft
    /// bell/chime character instead of an abrupt on/off tone. A short
    /// silence tail is baked in so SessionCoordinator can loop this buffer
    /// with nothing more than `while !Task.isCancelled { await audio.play(
    /// WaitingDitty.audio) }` -- no separate pacing/sleep logic needed.
    public static let audio: Data = {
        let notes: [Double] = [523.25, 659.25, 783.99, 1046.50]
        let noteDuration = 0.18
        let gapDuration = 0.35
        let amplitude = 0.25

        var samples: [Int16] = []
        for frequency in notes {
            let sampleCount = Int(noteDuration * sampleRate)
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let envelope = exp(-6.0 * t / noteDuration)
                let value = sin(2.0 * Double.pi * frequency * t) * envelope * amplitude
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        samples.append(contentsOf: Array(repeating: Int16(0), count: Int(gapDuration * sampleRate)))

        // Explicit little-endian byte construction (not relying on the
        // platform's native Int16 layout happening to match) -- matches
        // the wire format's own LE requirement and the care taken
        // elsewhere in this codebase (e.g. protocol.py's "<i2" dtype).
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }()
}
