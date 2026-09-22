import Foundation

/// What the story screen's red error banner says and when it goes away --
/// pulled out of AppModel's poll loop so those rules can be unit-tested
/// (issue #48: banners used to stay up forever, because the message was only
/// ever set, and the one clear that existed was undone by the poll loop
/// within ~100ms).
///
/// Two kinds of message flow in. CLIENT-SIDE failures AppModel reports itself
/// (connect() rejected, audio capture failed, "disconnected from server") via
/// show(). COORDINATOR errors (an error frame, a ditty timeout) arrive by
/// polling SessionCoordinator.lastErrorMessage through observe(). That value
/// is a sticky latest value, not an event, so only the tick on which it
/// CHANGES counts: re-copying it every tick is what made every clear
/// (tap-to-dismiss included) a no-op.
///
/// It goes away on dismiss() (a tap, a new story, going Home) and on
/// connectAttemptStarted() (any fresh connect: whatever it was about is
/// stale, and a failed attempt shows its own). The coordinator clears its own
/// error when a new turn begins, which observe() passes on. Errors that are
/// still true stay: a "disconnected from server" banner lives until someone
/// reconnects or dismisses it.
public struct ErrorBanner: Equatable, Sendable {
    public private(set) var message: String?
    /// The last SessionCoordinator.lastErrorMessage observe() saw, nil
    /// included -- what "changed" is measured against.
    private var observedCoordinatorError: String?

    public init() {}

    /// A failure AppModel itself detected. Replaces whatever is showing.
    public mutating func show(_ message: String) {
        self.message = message
    }

    /// Feed in the coordinator's current lastErrorMessage on every poll
    /// tick. Returns true only on the tick a NEW error appeared (so the
    /// caller can react once, not on every tick the sticky value is still
    /// there). The coordinator's value going back to nil -- a new turn or
    /// a new story began -- takes its own banner down, but never an unrelated
    /// client-side message; a nil that was already nil is nothing at all,
    /// so a client-side error survives a coordinator that has none.
    @discardableResult
    public mutating func observe(coordinatorError: String?) -> Bool {
        guard coordinatorError != observedCoordinatorError else { return false }
        let previous = observedCoordinatorError
        observedCoordinatorError = coordinatorError
        if let coordinatorError {
            message = coordinatorError
            return true
        }
        if message == previous {
            message = nil
        }
        return false
    }

    /// Takes the banner down without forgetting what the coordinator still
    /// holds: that same sticky error must not come straight back on the next
    /// poll tick.
    public mutating func dismiss() {
        message = nil
    }

    /// A fresh connect attempt is starting -- the one funnel every
    /// reconnect goes through. Also forgets the replaced coordinator's last
    /// error, so a new coordinator hitting the very same error shows it.
    public mutating func connectAttemptStarted() {
        message = nil
        observedCoordinatorError = nil
    }
}
