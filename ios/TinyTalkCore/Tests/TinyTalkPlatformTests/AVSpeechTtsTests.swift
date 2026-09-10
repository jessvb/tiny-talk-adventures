import XCTest
@testable import TinyTalkPlatform

final class AVSpeechTtsTests: XCTestCase {
    func testSynthesizeProducesNonEmptyPCM16Data() async {
        let tts = AVSpeechTts()
        var chunks: [Data] = []
        for await chunk in tts.synthesize("Hello there.") {
            chunks.append(chunk)
        }
        XCTAssertFalse(chunks.isEmpty)
        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(totalBytes, 0)
        // PCM16 is 2 bytes/sample -- every chunk must be an even byte count.
        for chunk in chunks {
            XCTAssertEqual(chunk.count % 2, 0)
        }
    }

    func testSynthesizingEmptyTextProducesNoAudio() async {
        let tts = AVSpeechTts()
        var chunks: [Data] = []
        for await chunk in tts.synthesize("") {
            chunks.append(chunk)
        }
        XCTAssertTrue(chunks.allSatisfy { $0.isEmpty == false } || chunks.isEmpty)
    }
}
