import XCTest
@testable import TinyTalkCore

final class WaitingDittyTests: XCTestCase {
    func testAudioIsNonEmptyAndEvenByteAligned() {
        let audio = WaitingDitty.audio
        XCTAssertFalse(audio.isEmpty)
        XCTAssertEqual(audio.count % 2, 0, "PCM16 samples must be an even number of bytes")
    }

    func testAudioStaysWithinInt16BoundsAndHasRealSignal() {
        // Reinterpret as little-endian Int16 samples and confirm none of
        // them clip -- amplitude scaling in WaitingDitty.audio should keep
        // every sample comfortably inside Int16's range, while still
        // containing real (non-zero) signal, not just the baked-in silence
        // gap.
        let audio = WaitingDitty.audio
        var maxAbsValue: Int32 = 0
        audio.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                maxAbsValue = max(maxAbsValue, abs(Int32(sample)))
            }
        }
        XCTAssertLessThan(maxAbsValue, Int32(Int16.max), "samples should not be at/near full scale")
        XCTAssertGreaterThan(maxAbsValue, 0, "the ditty should contain actual audible signal, not just silence")
    }

    func testAudioIsShortEnoughToLoopFrequently() {
        // Roughly a couple of seconds at most -- long enough to sound like
        // a real little tune, short enough that looping it doesn't feel
        // like it's stuck repeating one long clip.
        let sampleCount = WaitingDitty.audio.count / 2
        let seconds = Double(sampleCount) / 24_000.0
        XCTAssertLessThan(seconds, 2.0)
        XCTAssertGreaterThan(seconds, 0.3)
    }

    func testAudioIsStableAcrossAccesses() {
        // A static let, but worth confirming it's genuinely deterministic
        // (no per-call randomness) since SessionCoordinator relies on
        // comparing/reusing the same buffer across loop iterations.
        XCTAssertEqual(WaitingDitty.audio, WaitingDitty.audio)
    }
}
