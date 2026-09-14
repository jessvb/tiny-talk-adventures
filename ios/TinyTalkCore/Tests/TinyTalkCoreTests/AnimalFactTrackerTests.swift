import XCTest
@testable import TinyTalkCore

final class FakeAnimalFactFetcher: AnimalFactFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedNames: [String] = []
    var factsToReturn: [String: [String]?] = [:]

    var requestedNames: [String] { lock.withLockUnchecked { _requestedNames } }

    func fetchFacts(for canonicalName: String) async -> [String]? {
        lock.withLockUnchecked { _requestedNames.append(canonicalName) }
        return factsToReturn[canonicalName] ?? nil
    }
}

private extension NSLock {
    func withLockUnchecked<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

final class AnimalFactTrackerTests: XCTestCase {
    func testRecordTurnReturnsWeaveInGuidanceOnAFreshMention() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = ["foxes are clever"]
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        let guidance = await tracker.recordTurn(transcript: "tell me about a fox", stage: .setup)

        XCTAssertTrue(guidance.contains("fox"))
        XCTAssertTrue(guidance.contains("foxes are clever"))
        let shared = await tracker.sharedFacts()
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared[0].animal, "fox")
    }

    func testSameAnimalIsNotFetchedTwice() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = ["foxes are clever"]
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)
        _ = await tracker.recordTurn(transcript: "the fox again", stage: .risingAction)

        XCTAssertEqual(fetcher.requestedNames, ["fox"])
    }

    func testAFailedFetchIsNotRetriedWithinTheSameStory() async {
        let fetcher = FakeAnimalFactFetcher() // factsToReturn defaults to nil == failure
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)
        _ = await tracker.recordTurn(transcript: "the fox again", stage: .risingAction)

        XCTAssertEqual(fetcher.requestedNames, ["fox"])
    }

    func testNudgesForAnAnimalDuringIntroSetupIfNoneMentionedYet() async {
        let fetcher = FakeAnimalFactFetcher()
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        let guidance = await tracker.recordTurn(transcript: "let's start a story", stage: .intro)

        XCTAssertTrue(guidance.contains("what animal should be in the story"))
    }

    func testNoNudgeOnceAnAnimalHasBeenMentioned() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = nil // fetch fails, but the animal WAS mentioned
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .intro)
        let guidance = await tracker.recordTurn(transcript: "what happens next", stage: .setup)

        XCTAssertEqual(guidance, "")
    }

    func testResetClearsSharedFactsAndAllowsRefetching() async {
        let fetcher = FakeAnimalFactFetcher()
        fetcher.factsToReturn["fox"] = ["foxes are clever"]
        let tracker = AnimalFactTracker(fetcher: fetcher, cache: AnimalFactsCache(path: tempCachePath()))

        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)
        await tracker.reset()
        _ = await tracker.recordTurn(transcript: "a fox", stage: .setup)

        XCTAssertEqual(fetcher.requestedNames, ["fox"])
        let shared = await tracker.sharedFacts()
        XCTAssertEqual(shared.count, 1) // only this story's fact, not both
    }

    private func tempCachePath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    }
}
