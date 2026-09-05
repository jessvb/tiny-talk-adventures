import XCTest
@testable import TinyTalkCore

final class ObjectRecognitionTests: XCTestCase {
    func testPicksTheHighestConfidenceCandidateAboveThreshold() {
        let candidates = [
            ClassificationCandidate(label: "teddy bear", confidence: 0.62),
            ClassificationCandidate(label: "toy", confidence: 0.41),
        ]

        let result = selectTopClassification(candidates, threshold: 0.3)

        XCTAssertEqual(result, RecognizedObject(label: "teddy bear", confidence: 0.62))
    }

    func testReturnsNilWhenTheTopCandidateIsBelowThreshold() {
        let candidates = [ClassificationCandidate(label: "blur", confidence: 0.2)]

        XCTAssertNil(selectTopClassification(candidates, threshold: 0.3))
    }

    func testIncludesACandidateExactlyAtTheThreshold() {
        let candidates = [ClassificationCandidate(label: "couch", confidence: 0.3)]

        XCTAssertEqual(
            selectTopClassification(candidates, threshold: 0.3),
            RecognizedObject(label: "couch", confidence: 0.3)
        )
    }

    func testReturnsNilForEmptyCandidates() {
        XCTAssertNil(selectTopClassification([], threshold: 0.3))
    }

    func testTiesKeepWhicheverCandidateVisionRankedFirst() {
        // Vision's own results already come sorted by confidence
        // descending, so "first-seen wins a tie" naturally matches
        // Vision's own ranking rather than introducing a second,
        // independent tiebreak.
        let candidates = [
            ClassificationCandidate(label: "teddy bear", confidence: 0.5),
            ClassificationCandidate(label: "stuffed animal", confidence: 0.5),
        ]

        XCTAssertEqual(selectTopClassification(candidates, threshold: 0.3)?.label, "teddy bear")
    }
}
