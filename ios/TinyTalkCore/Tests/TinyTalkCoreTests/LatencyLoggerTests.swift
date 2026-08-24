import XCTest
@testable import TinyTalkCore

final class LatencyLoggerTests: XCTestCase {
    func testCompletedEventProducesNonNegativeLatenciesAndAppendsToHistory() {
        let logger = LatencyLogger()
        let id = logger.recordVADFire()
        logger.recordInterruptSent(for: id)
        let result = logger.recordPlaybackStopped(for: id)

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.vadFireToInterruptSentMillis, 0)
        XCTAssertGreaterThanOrEqual(result!.vadFireToPlaybackStoppedMillis, 0)
        XCTAssertEqual(logger.history, [result!])
    }

    func testPlaybackStoppedForUnknownIDReturnsNil() {
        let logger = LatencyLogger()
        XCTAssertNil(logger.recordPlaybackStopped(for: UUID()))
    }

    func testPlaybackStoppedWithoutInterruptSentStillCompletes() {
        // A barge-in during .waitingForReply, before any audio has arrived,
        // has no separate "interrupt sent" moment distinct from VAD-fire in
        // some call patterns -- recordInterruptSent is not required before
        // recordPlaybackStopped.
        let logger = LatencyLogger()
        let id = logger.recordVADFire()
        let result = logger.recordPlaybackStopped(for: id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.vadFireToInterruptSentMillis, 0)
    }

    func testEachVADFireGetsAUniqueID() {
        let logger = LatencyLogger()
        let first = logger.recordVADFire()
        let second = logger.recordVADFire()
        XCTAssertNotEqual(first, second)
    }

    func testCompletingAnEventTwiceReturnsNilTheSecondTime() {
        let logger = LatencyLogger()
        let id = logger.recordVADFire()
        _ = logger.recordPlaybackStopped(for: id)
        XCTAssertNil(logger.recordPlaybackStopped(for: id))
    }
}
