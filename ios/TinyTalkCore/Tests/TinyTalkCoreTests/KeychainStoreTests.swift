import XCTest
@testable import TinyTalkCore

final class KeychainStoreTests: XCTestCase {
    private let testKey = "com.tinytalk.test.keychainStoreTests"

    override func tearDown() {
        KeychainStore.delete(testKey)
        super.tearDown()
    }

    func testGetReturnsNilWhenNothingIsStored() {
        XCTAssertNil(KeychainStore.get(testKey))
    }

    func testSetThenGetRoundTrips() {
        KeychainStore.set("gsk_abc123", forKey: testKey)
        XCTAssertEqual(KeychainStore.get(testKey), "gsk_abc123")
    }

    func testSetOverwritesAnExistingValue() {
        KeychainStore.set("first", forKey: testKey)
        KeychainStore.set("second", forKey: testKey)
        XCTAssertEqual(KeychainStore.get(testKey), "second")
    }

    func testDeleteRemovesTheValue() {
        KeychainStore.set("gsk_abc123", forKey: testKey)
        KeychainStore.delete(testKey)
        XCTAssertNil(KeychainStore.get(testKey))
    }
}
