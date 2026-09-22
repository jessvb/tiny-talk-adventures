import Foundation

/// Decides, once per concluded story, when AppModel should ask the server
/// for the saved-story list that The End's navigation waits on -- pulled out
/// of AppModel's poll loop so the rule can be unit-tested.
///
/// SessionCoordinator.readyToShowTheEnd latches true when a story concludes
/// and stays true, so asking on every ~100ms poll tick would flood the
/// server; this hands back exactly one "ask now" per conclusion. The catch
/// (found on-device testing PR #50, 2026-09-21): the coordinator's
/// newStory() takes readyToShowTheEnd back to false, so ONE coordinator can
/// see several conclusions -- finish a story, use New Story instead of Home,
/// finish another. The guard used to be a plain "already asked" flag cleared
/// only when the coordinator was torn down, so the second conclusion never
/// asked, The End never appeared, and only a background/foreground cycle
/// (which does tear the coordinator down) brought it back. Watching the
/// flag itself go back to false is what re-arms it.
public struct TheEndLookup: Equatable, Sendable {
    private var requested = false

    public init() {}

    /// Feed in the coordinator's current readyToShowTheEnd on EVERY poll
    /// tick, false included -- the false ticks are what re-arm the guard.
    /// Returns true on the one tick the caller should send list_stories.
    public mutating func shouldRequest(readyToShowTheEnd: Bool) -> Bool {
        guard readyToShowTheEnd else {
            requested = false
            return false
        }
        guard !requested else { return false }
        requested = true
        return true
    }

    /// The coordinator was torn down: a request it never answered can't be
    /// answered now, and its replacement may already report ready without
    /// ever having passed through false (a foreground reconnect after the
    /// story concluded while the app was away).
    public mutating func reset() {
        requested = false
    }
}
