import XCTest
@testable import TinyTalkCore

final class ObjectTrackingTests: XCTestCase {
    func testNoPendingLabelReturnsEmptyGuidance() {
        let tracker = ObjectTracker()
        XCTAssertEqual(tracker.consumeGuidance(), "")
    }

    func testSafeLabelProducesWeaveInGuidance() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "teddy bear")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.contains("teddy bear"))
    }

    func testUnsafeLabelIsDiscarded() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a gun")
        XCTAssertEqual(tracker.consumeGuidance(), "")
    }

    func testConsumingClearsThePendingLabel() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a couch")
        _ = tracker.consumeGuidance()
        XCTAssertEqual(tracker.consumeGuidance(), "")
    }

    func testANewerLabelOverwritesAnOlderUnconsumedOne() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "elephant")
        tracker.recordSeen(label: "backpack")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.contains("backpack"))
        XCTAssertFalse(guidance.contains("elephant"))
    }

    func testAnUnsafeLabelDoesNotClearAnEarlierPendingSafeOne() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "a couch")
        tracker.recordSeen(label: "a gun")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.contains("a couch"))
    }

    func testWeaveInGuidanceRequiresRecognizableTrait() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "golden retriever")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.lowercased().contains("recognizable"))
    }

    func testWeaveInGuidanceDiscouresUnrelatedSubstitute() {
        let tracker = ObjectTracker()
        tracker.recordSeen(label: "golden retriever")
        let guidance = tracker.consumeGuidance()
        XCTAssertTrue(guidance.lowercased().contains("unrelated"))
    }
}
