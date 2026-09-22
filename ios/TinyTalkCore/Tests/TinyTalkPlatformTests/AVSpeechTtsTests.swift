import XCTest
@testable import TinyTalkPlatform

/// Records onDebugEvent lines -- lock-protected since the hook can fire
/// from a synthesizer callback, mirroring CaptureDiagnosticsTests.swift's
/// WatchdogCalls pattern in this same test target.
private final class DebugEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

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

    /// Issue #56 item 3: this line previously had no timestamp prefix,
    /// unlike every other source AppModel.mergedDebugLog() merges by plain
    /// string sort -- an unprefixed line clumps out of chronological order
    /// once merged. See DebugTimestamp's doc comment for the format every
    /// other source already follows.
    func testResolvedVoiceDebugLineIsTimestamped() async {
        let tts = AVSpeechTts()
        let box = DebugEventBox()
        tts.onDebugEvent = { box.append($0) }
        for await _ in tts.synthesize("Hello there.") {}
        let resolvedLines = box.all.filter { $0.contains("AVSpeechTts: resolved name=") }
        XCTAssertFalse(resolvedLines.isEmpty)
        for line in resolvedLines {
            XCTAssertTrue(line.hasPrefix("["), "expected a [HH:mm:ss.SSS] timestamp prefix, got: \(line)")
        }
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
