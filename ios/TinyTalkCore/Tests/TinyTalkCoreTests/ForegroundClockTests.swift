import XCTest
@testable import TinyTalkCore

/// Issue #68: the away-from-home drawing budget must not count time the app
/// spent in the background.
final class ForegroundClockTests: XCTestCase {
    func testAdvancesWithTheWallClockWhileInTheForeground() {
        let wall = FakeClock()
        let clock = ForegroundClock(wallClock: { wall.now() })
        let start = clock.now()
        wall.advance(30)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 30, accuracy: 0.001)
    }

    func testStandsStillWhileBackgroundedAndResumesFromWhereItStopped() {
        let wall = FakeClock()
        let clock = ForegroundClock(wallClock: { wall.now() })
        let start = clock.now()
        wall.advance(10)
        clock.enterBackground()
        wall.advance(300)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 10, accuracy: 0.001,
            "time in the background doesn't count")
        clock.enterForeground()
        wall.advance(5)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 15, accuracy: 0.001)
    }

    func testRepeatedOrUnbalancedTransitionsAreHarmless() {
        // didEnterBackground/willEnterForeground aren't guaranteed to arrive
        // strictly paired from the clock's point of view (e.g. observers
        // installed while already in the background), so a duplicate must
        // neither double-count nor go backwards.
        let wall = FakeClock()
        let clock = ForegroundClock(wallClock: { wall.now() })
        let start = clock.now()
        clock.enterForeground() // already in the foreground: no-op
        wall.advance(10)
        clock.enterBackground()
        wall.advance(20)
        clock.enterBackground() // duplicate: must not restart the pause
        wall.advance(20)
        clock.enterForeground()
        clock.enterForeground() // duplicate
        wall.advance(1)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 11, accuracy: 0.001)
    }

    func testAPassBackgroundedMidDrawingKeepsItsBudgetForTheRemainingPages() async {
        // The repro from #68: background mid-pass for well over the whole
        // budget, then come back. Before the fix the pass read the plain
        // wall clock, so every remaining page hit "time budget spent".
        let wall = FakeClock()
        let clock = ForegroundClock(wallClock: { wall.now() })
        let backend = FakeImageBackend(results: [.success(TestImages.png(width: 64, height: 64))])
        backend.onGenerate = { [unowned backend] in
            wall.advance(10)
            if backend.calls.count == 1 {
                clock.enterBackground()
                wall.advance(600) // ten minutes away from the app
                clock.enterForeground()
            }
        }
        let pass = IllustrationPass(
            chat: ScriptedChatClient("a fox", "the fox and an owl", "the fox goes home"),
            backend: backend, timeBudget: 60, now: { clock.now() }
        )
        let result = await pass.illustrate(pages: ["One.", "Two.", "Three."])

        XCTAssertEqual(backend.calls.count, 3)
        XCTAssertEqual(result.status, .done)
    }
}
