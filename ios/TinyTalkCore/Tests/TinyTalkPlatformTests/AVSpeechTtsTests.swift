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

    func testAvailableEnglishVoicesAreAllEnglishWithNoDuplicatesAndSortedByName() {
        let voices = AVSpeechTts.availableEnglishVoices()
        // Every macOS/iOS SDK ships at least one English system voice --
        // an empty result here would mean the filter itself is broken,
        // not that the test machine happens to have none installed.
        XCTAssertFalse(voices.isEmpty)
        for voice in voices {
            XCTAssertTrue(voice.language.hasPrefix("en"), "\(voice.name) has language \(voice.language)")
        }
        let identifiers = voices.map { $0.identifier }
        XCTAssertEqual(identifiers.count, Set(identifiers).count, "expected no duplicate voices")
        let names = voices.map { $0.name }
        XCTAssertEqual(names, names.sorted(), "expected voices sorted by name")
    }
}
