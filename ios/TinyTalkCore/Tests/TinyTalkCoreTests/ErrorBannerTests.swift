import XCTest
@testable import TinyTalkCore

final class ErrorBannerTests: XCTestCase {
    func testStartsEmpty() {
        XCTAssertNil(ErrorBanner().message)
    }

    // MARK: - Coordinator errors (the poll loop's copy)

    func testANewCoordinatorErrorShowsAndIsReportedAsNew() {
        var banner = ErrorBanner()
        XCTAssertTrue(banner.observe(coordinatorError: "boom"))
        XCTAssertEqual(banner.message, "boom")
    }

    /// The coordinator's value is sticky, so the poll loop sees the same
    /// "boom" on every ~100ms tick -- only the first is an event.
    func testTheSameStickyErrorIsNotANewEventOnLaterTicks() {
        var banner = ErrorBanner()
        XCTAssertTrue(banner.observe(coordinatorError: "boom"))
        XCTAssertFalse(banner.observe(coordinatorError: "boom"))
        XCTAssertFalse(banner.observe(coordinatorError: "boom"))
        XCTAssertEqual(banner.message, "boom")
    }

    /// Issue #48's mechanism: tap-to-dismiss (and every other clear) used to
    /// be undone on the next tick, because the poll loop copied the still-
    /// set coordinator value over it again.
    func testADismissedBannerStaysGoneWhileTheCoordinatorStillHoldsThatError() {
        var banner = ErrorBanner()
        banner.observe(coordinatorError: "boom")
        banner.dismiss()
        XCTAssertNil(banner.message)

        XCTAssertFalse(banner.observe(coordinatorError: "boom"))
        XCTAssertNil(banner.message, "the ~100ms poll tick must not resurrect a dismissed banner")
    }

    func testACoordinatorErrorThatChangesReplacesTheBanner() {
        var banner = ErrorBanner()
        banner.observe(coordinatorError: "first")
        XCTAssertTrue(banner.observe(coordinatorError: "second"))
        XCTAssertEqual(banner.message, "second")
    }

    /// The coordinator drops its error when a new turn begins or a new story
    /// starts (see SessionCoordinator.beginNewTurn()/newStory()) -- the
    /// banner for it goes with it.
    func testTheCoordinatorClearingItsErrorClearsTheBanner() {
        var banner = ErrorBanner()
        banner.observe(coordinatorError: "boom")

        XCTAssertFalse(banner.observe(coordinatorError: nil), "an error going away is not a new error")
        XCTAssertNil(banner.message)
    }

    /// Timing out twice in a row produces the same text twice; only the nil
    /// in between (a new turn began) lets the second one register.
    func testARepeatOfTheSameErrorAfterTheCoordinatorClearedItShowsAgain() {
        var banner = ErrorBanner()
        banner.observe(coordinatorError: "took too long")
        banner.observe(coordinatorError: nil)

        XCTAssertTrue(banner.observe(coordinatorError: "took too long"))
        XCTAssertEqual(banner.message, "took too long")
    }

    // MARK: - Client-side errors

    func testAClientSideErrorShows() {
        var banner = ErrorBanner()
        banner.show("could not start audio capture")
        XCTAssertEqual(banner.message, "could not start audio capture")
    }

    /// A coordinator that simply has no error yet (nil, nothing ever
    /// observed) must not wipe out a client-side one -- connect() surfaces
    /// its failures without any coordinator error existing.
    func testAQuietCoordinatorDoesNotEraseAClientSideError() {
        var banner = ErrorBanner()
        banner.show("disconnected from server")

        XCTAssertFalse(banner.observe(coordinatorError: nil))
        XCTAssertFalse(banner.observe(coordinatorError: nil))
        XCTAssertEqual(banner.message, "disconnected from server")
    }

    /// Only the coordinator's OWN banner goes with its error.
    func testTheCoordinatorClearingItsErrorLeavesADifferentClientSideMessageAlone() {
        var banner = ErrorBanner()
        banner.observe(coordinatorError: "took too long")
        banner.show("disconnected from server")

        banner.observe(coordinatorError: nil)
        XCTAssertEqual(banner.message, "disconnected from server")
    }

    func testANewCoordinatorErrorReplacesAClientSideError() {
        var banner = ErrorBanner()
        banner.show("disconnected from server")
        XCTAssertTrue(banner.observe(coordinatorError: "took too long"))
        XCTAssertEqual(banner.message, "took too long")
    }

    func testDismissClearsAClientSideError() {
        var banner = ErrorBanner()
        banner.show("disconnected from server")
        banner.dismiss()
        XCTAssertNil(banner.message)
    }

    // MARK: - A fresh connect attempt

    func testAConnectAttemptStartingClearsTheBanner() {
        var banner = ErrorBanner()
        banner.show("disconnected from server")
        banner.connectAttemptStarted()
        XCTAssertNil(banner.message)
    }

    /// The replaced coordinator's last error is not this attempt's to keep
    /// suppressing: a brand-new coordinator that hits the very same error
    /// must show it.
    func testAConnectAttemptForgetsTheOldCoordinatorsError() {
        var banner = ErrorBanner()
        banner.observe(coordinatorError: "took too long")
        banner.connectAttemptStarted()

        XCTAssertFalse(banner.observe(coordinatorError: nil), "the fresh coordinator starts with no error")
        XCTAssertTrue(banner.observe(coordinatorError: "took too long"))
        XCTAssertEqual(banner.message, "took too long")
    }
}
