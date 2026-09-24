import Foundation
import TinyTalkCore

/// Wraps an away-from-home picture pass so leaving the app mid-drawing
/// doesn't quietly cost the story its pictures (issue #68). Two jobs:
///
/// 1. Feeds UIApplication's background/foreground notifications to the
///    ForegroundClock the wrapped IllustrationPass measures its drawing
///    budget on, so time spent suspended no longer counts against it.
/// 2. Holds a UIKit background task for the length of the pass, so a short
///    absence (the phone handed to a parent, a quick peek at another app)
///    lets the in-flight Groq/Cloudflare requests finish instead of dying
///    on suspension and becoming picture-less pages. iOS grants only ~30 s
///    of this, so it covers short absences, not long ones -- a pass that
///    still gets suspended ends however its requests end, and resume
///    doesn't retry a finished `partial`/`failed` pass (see #68's third,
///    not-yet-designed option).
///
/// iOS-only (UIApplication), hence TinyTalkPlatform and the `#if os(iOS)`
/// gate -- see AudioEngine.swift for why SwiftPM needs the gate.
#if os(iOS)
import UIKit

public final class BackgroundSafeIllustrator: StoryIllustrating, @unchecked Sendable {
    private let inner: any StoryIllustrating
    private let onDebugEvent: (@Sendable (String) -> Void)?
    /// NotificationCenter observer tokens; removed in deinit. Written only
    /// in init, so no lock is needed.
    private var observers: [NSObjectProtocol] = []

    /// `clock` must be the same ForegroundClock `inner`'s budget reads.
    /// Built while the app is in the foreground (connectAwayFromHome), so
    /// the clock's initial "foreground" state is correct.
    public init(
        wrapping inner: any StoryIllustrating,
        clock: ForegroundClock,
        onDebugEvent: (@Sendable (String) -> Void)? = nil
    ) {
        self.inner = inner
        self.onDebugEvent = onDebugEvent
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                clock.enterBackground()
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                clock.enterForeground()
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public func illustrate(pages: [String]) async -> IllustrationResult {
        let task = await IllustrationBackgroundTask.begin(onDebugEvent: onDebugEvent)
        // illustrate(pages:) never throws, so this is the only exit path.
        let result = await inner.illustrate(pages: pages)
        await task.end()
        return result
    }
}

/// One beginBackgroundTask/endBackgroundTask pair, ended exactly once:
/// either when the pass finishes or when iOS's expiration handler fires
/// first (ending it there is mandatory -- an app that overruns its
/// background time is killed). After an expiry the pass itself keeps going
/// until iOS suspends the app; whatever it then ends with is saved as usual.
@MainActor
private final class IllustrationBackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let onDebugEvent: (@Sendable (String) -> Void)?

    private init(onDebugEvent: (@Sendable (String) -> Void)?) {
        self.onDebugEvent = onDebugEvent
    }

    static func begin(onDebugEvent: (@Sendable (String) -> Void)?) -> IllustrationBackgroundTask {
        let task = IllustrationBackgroundTask(onDebugEvent: onDebugEvent)
        task.id = UIApplication.shared.beginBackgroundTask(withName: "illustration") { [weak task] in
            MainActor.assumeIsolated {
                task?.onDebugEvent?("[\(DebugTimestamp.now())] illustration: background time ran out mid-pass -- pages still drawing may come back without a picture")
                task?.end()
            }
        }
        return task
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
