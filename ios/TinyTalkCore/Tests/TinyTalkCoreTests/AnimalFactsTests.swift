import XCTest
@testable import TinyTalkCore

final class AnimalFactsTests: XCTestCase {
    func testDetectsAKnownAnimal() {
        XCTAssertEqual(AnimalFacts.findNewAnimal(in: "tell me about a fox", excluding: []), "fox")
    }

    func testDetectsAnAliasAndReturnsTheCanonicalName() {
        XCTAssertEqual(AnimalFacts.findNewAnimal(in: "look at the bunny", excluding: []), "rabbit")
    }

    func testAlreadyFactedAnimalsAreExcluded() {
        XCTAssertNil(AnimalFacts.findNewAnimal(in: "the fox again", excluding: ["fox"]))
    }

    func testNoKnownAnimalReturnsNil() {
        XCTAssertNil(AnimalFacts.findNewAnimal(in: "a beautiful castle", excluding: []))
    }

    func testWordBoundaryDoesNotFalsePositive() {
        // "foxglove" contains "fox" as a substring but must not match.
        XCTAssertNil(AnimalFacts.findNewAnimal(in: "a field of foxglove", excluding: []))
    }

    func testMultiWordAliasWinsOverAGenericSingleWordEntry() {
        XCTAssertEqual(AnimalFacts.findNewAnimal(in: "a sea turtle swam by", excluding: []), "sea turtle")
    }

    func testExtractFactsUsesOnlyTheAllowlistedFields() {
        let characteristics = AnimalRecordCharacteristics(
            mostDistinctiveFeature: "its bushy tail",
            topSpeed: "30 mph",
            diet: "small mammals",
            habitat: "forests",
            slogan: nil,
            color: "reddish orange",
            groupBehavior: nil,
            lifespan: "3 to 4 years"
        )
        let facts = AnimalFacts.extractFacts(from: characteristics)
        XCTAssertEqual(facts.count, 6)
        XCTAssertTrue(facts.contains("its most distinctive feature is its bushy tail"))
        XCTAssertTrue(facts.contains("it can move as fast as 30 mph"))
        XCTAssertTrue(facts.contains("its lifespan is 3 to 4 years"))
    }

    func testExtractFactsDropsAnUnsafeField() {
        let characteristics = AnimalRecordCharacteristics(
            mostDistinctiveFeature: nil, topSpeed: nil, diet: nil, habitat: nil,
            slogan: "known for a killing spree", color: nil, groupBehavior: nil, lifespan: nil
        )
        XCTAssertEqual(AnimalFacts.extractFacts(from: characteristics), [])
    }

    func testExtractFactsSkipsEmptyOrMissingFields() {
        let characteristics = AnimalRecordCharacteristics(
            mostDistinctiveFeature: "  ", topSpeed: nil, diet: nil, habitat: nil,
            slogan: nil, color: nil, groupBehavior: nil, lifespan: nil
        )
        XCTAssertEqual(AnimalFacts.extractFacts(from: characteristics), [])
    }
}
