import XCTest
@testable import TinyTalkCore

/// The mechanical answer to issue #24's "this keeps recurring": a feature
/// built on a new ClientMessage that only the real server implements used
/// to silently no-op in demo mode, because DemoConnection lumped every such
/// case into one catch-all. Now every ClientMessage case must carry an
/// explicit demo-mode decision -- either "answers with an event" or "silent
/// by design, and here is why".
final class DemoProtocolParityTests: XCTestCase {
    private enum Expectation {
        case respondsWithAnEvent
        case silentByDesign(String)
    }

    /// EXHAUSTIVE ON PURPOSE (deliberately no `default:`): adding a case to
    /// ClientMessage fails to compile HERE until someone decides what a
    /// DemoConnection does with it. When that happens, also add a sample for
    /// it to `samples` below and bump the count assertion in
    /// testEverySampleIsCoveredOnceAndBehavesAsClassified.
    private static func expectation(for message: ClientMessage) -> Expectation {
        switch message {
        case .speechStart:
            return .silentByDesign("starts buffering mic audio; the reply follows speechEnd")
        case .speechEnd:
            return .respondsWithAnEvent
        case .interrupt:
            return .silentByDesign("cancels in-flight work; the server sends nothing back either")
        case .objectSeen:
            return .silentByDesign("feeds the next turn's guidance; the server sends nothing back either")
        case .newStory:
            return .silentByDesign("resets state locally; the server sends nothing back either")
        case .syncDemoStories:
            return .silentByDesign("never sent to a DemoConnection; only the real-server connect path issues it")
        case .listStories:
            return .respondsWithAnEvent
        case .getStory:
            return .respondsWithAnEvent
        case .concludeStory:
            return .respondsWithAnEvent
        case .updateSettings:
            return .silentByDesign("takes effect on the next story; demo mode ignores llmBackend (always Groq), so unlike the real server it sends no llm_backend reply")
        case .getPageImage:
            return .respondsWithAnEvent
        case .synthesizePage:
            return .respondsWithAnEvent
        }
    }

    /// One sample per ClientMessage case.
    private static let samples: [ClientMessage] = [
        .speechStart(turnId: 1),
        .speechEnd,
        .interrupt(turnId: 2),
        .objectSeen(label: "fox"),
        .newStory,
        .syncDemoStories(stories: []),
        .listStories,
        .getStory(storyId: "ghost"),
        .concludeStory(turnId: 3),
        .updateSettings(targetTurns: 5, pageCount: 4),
        .getPageImage(storyId: "ghost", pageIndex: 0),
        .synthesizePage(storyId: "ghost", pageIndex: 0),
    ]

    func testEverySampleIsCoveredOnceAndBehavesAsClassified() async throws {
        XCTAssertEqual(Self.samples.count, 12, "one sample per ClientMessage case -- update with the switch above")

        for message in Self.samples {
            let connection = DemoConnection(
                chatClient: FakeChatClient(),
                sttClient: FakeSttClient(),
                ttsClient: FakeTtsClient(),
                animalFactTracker: AnimalFactTracker(fetcher: FakeAnimalFactFetcher())
            )
            let recorder = EventRecorder(connection)

            try await connection.send(message)
            // The wait depends on the classification: a case that must answer
            // is awaited until its first event arrives (several emit from a
            // detached Task, so a fixed sleep could flake on a loaded
            // machine), while a silent-by-design case needs a fixed quiet
            // period to prove nothing was emitted.
            let expectation = Self.expectation(for: message)
            let events: [ServerConnectionEvent]
            switch expectation {
            case .respondsWithAnEvent:
                events = await recorder.waitForCount(1)
            case .silentByDesign:
                events = await recorder.settle()
            }
            recorder.stop()

            switch expectation {
            case .respondsWithAnEvent:
                XCTAssertFalse(events.isEmpty, "\(message) must answer with at least one event, never silence")
            case .silentByDesign(let reason):
                XCTAssertTrue(events.isEmpty, "\(message) is meant to be silent (\(reason)) but emitted \(events)")
            }
        }
    }
}
