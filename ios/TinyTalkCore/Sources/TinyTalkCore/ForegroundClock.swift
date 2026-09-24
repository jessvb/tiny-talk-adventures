import Foundation

/// A clock that only moves while the app is in the foreground: the wall
/// clock minus every stretch the app spent backgrounded. IllustrationPass
/// measures its drawing budget on it (issue #68) -- that budget exists so a
/// slow image service can't hold The End hostage, not to limit time the app
/// wasn't even running, and with the plain wall clock a pass backgrounded
/// for more than ~2 minutes came back to "time budget spent" on every
/// remaining page.
///
/// Why explicit enter/leave calls instead of a system clock: none of them
/// means "time this app was running". Date() and the continuous clock keep
/// going through everything; ProcessInfo.systemUptime / mach_absolute_time /
/// CLOCK_UPTIME_RAW only stop while the whole DEVICE sleeps, so they still
/// advance while this app sits suspended behind another app with the screen
/// on; a CPU-time clock stops while a request is merely waiting on the
/// network, which would disable the budget exactly when it's needed. The
/// app is told when it backgrounds and foregrounds, so the clock is told too
/// (see TinyTalkPlatform's BackgroundSafeIllustrator).
///
/// Backgrounded time is excluded even while a background task keeps the
/// pass running for its ~30 s of grace: that grace is bounded by iOS itself,
/// so the budget has nothing to add there.
public final class ForegroundClock: @unchecked Sendable {
    private let wallClock: @Sendable () -> Date
    private let lock = NSLock()
    /// Total time spent in completed background stretches.
    private var pausedTotal: TimeInterval = 0
    /// When the current background stretch began; nil while foregrounded.
    private var backgroundedAt: Date?

    public init(wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.wallClock = wallClock
    }

    public func now() -> Date {
        lock.withLock {
            // While backgrounded the clock stands still at the moment the
            // app left.
            (backgroundedAt ?? wallClock()).addingTimeInterval(-pausedTotal)
        }
    }

    /// Idempotent: a duplicate doesn't restart the current pause.
    public func enterBackground() {
        lock.withLock {
            if backgroundedAt == nil { backgroundedAt = wallClock() }
        }
    }

    /// Idempotent: a no-op when already in the foreground.
    public func enterForeground() {
        lock.withLock {
            guard let since = backgroundedAt else { return }
            pausedTotal += max(0, wallClock().timeIntervalSince(since))
            backgroundedAt = nil
        }
    }
}
