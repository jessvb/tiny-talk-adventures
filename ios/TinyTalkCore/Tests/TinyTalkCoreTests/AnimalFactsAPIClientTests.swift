import XCTest
@testable import TinyTalkCore

final class AnimalFactsAPIClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testReturnsNilImmediatelyWithNoKeyConfigured() async {
        let client = AnimalFactsAPIClient(apiKey: nil, session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertNil(facts)
    }

    func testReturnsNilForAnEmptyKey() async {
        let client = AnimalFactsAPIClient(apiKey: "", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertNil(facts)
    }

    func testFetchesAndExtractsFactsFromTheFirstRecord() async {
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("name=fox"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "ninja-key")
            let body = """
            [{"name":"Fox","characteristics":{"most_distinctive_feature":"its bushy tail","diet":"omnivore"}}]
            """
            return (200, body.data(using: .utf8)!)
        }
        let client = AnimalFactsAPIClient(apiKey: "ninja-key", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertEqual(facts, ["its most distinctive feature is its bushy tail", "its diet is omnivore"])
    }

    func testReturnsEmptyArrayWhenNoRecordsMatch() async {
        StubURLProtocol.handler = { _ in (200, "[]".data(using: .utf8)!) }
        let client = AnimalFactsAPIClient(apiKey: "ninja-key", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertEqual(facts, [])
    }

    func testReturnsNilOnANetworkError() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let client = AnimalFactsAPIClient(apiKey: "ninja-key", session: makeSession())
        let facts = await client.fetchFacts(for: "fox")
        XCTAssertNil(facts)
    }
}
