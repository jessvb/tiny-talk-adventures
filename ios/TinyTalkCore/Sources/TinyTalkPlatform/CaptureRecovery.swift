import Foundation

// Self-healing for RealAudioEngine's mic capture (issues #39/#49). Both
// issues are a mic that went silently dead mid-session -- #39 with the
// orange dot lit and zero tap buffers, #49 with no dot at all -- and in
// both a fresh reconnect was the only cure. The exact trigger was never
// caught on-device, but every candidate mechanism found in the code (a
// config change that stopped the engine with no follow-up notification, a
// rebuildCaptureTap() that failed and left no tap, an engine that
// start()ed then immediately stopped) ends in the same observable state:
// the tap stops delivering buffers. So instead of guessing which one, this
// watches for exactly that state and recovers from it, whatever caused it.
// Kept out of AudioEngine.swift's `#if os(iOS)` gate, with no AVFoundation
// dependency, so `swift test` covers the decisions; AudioEngine.swift holds
// only the glue that acts on them.

/// Decides, check by check, what to do about the tap's buffer count. A
/// healthy tap delivers ~10 buffers a second whatever the room sounds like
/// (silence is still buffers -- and the coordinator's mute doesn't stop the
/// engine either), so a whole check interval with none is never normal
/// while capturing.
///
/// Bounded on purpose: at most `maxAttempts` recoveries in a row, then ONE
/// `.giveUp` (RealAudioEngine escalates that to AppModel, whose cure is the
/// full reconnect that fixed #39 by hand), then silence -- no retry loop
/// that could grind forever against, say, a phone call holding the mic.
/// Buffers flowing again resets everything, so a later, unrelated death
/// gets a full budget.
struct CaptureRecoveryBudget {
    static let defaultMaxAttempts = 3

    enum Decision: Equatable {
        /// Buffers are flowing and nothing was wrong.
        case healthy
        /// Buffers are flowing again after one or more recovery attempts.
        case recovered(afterAttempts: Int)
        /// No buffers since the last check: try recovery number `attempt`.
        case attemptRecovery(attempt: Int)
        /// The attempts are used up. Returned exactly once per dead spell.
        case giveUp(attempts: Int)
        /// Still dead after giving up -- nothing more to do or log.
        case stillDead
    }

    let maxAttempts: Int
    private var attemptsSoFar = 0
    private var hasGivenUp = false

    init(maxAttempts: Int = defaultMaxAttempts) {
        self.maxAttempts = maxAttempts
    }

    mutating func evaluate(buffersSinceLastCheck: Int) -> Decision {
        if buffersSinceLastCheck > 0 {
            let attempts = attemptsSoFar
            attemptsSoFar = 0
            hasGivenUp = false
            return attempts == 0 ? .healthy : .recovered(afterAttempts: attempts)
        }
        if hasGivenUp { return .stillDead }
        if attemptsSoFar < maxAttempts {
            attemptsSoFar += 1
            return .attemptRecovery(attempt: attemptsSoFar)
        }
        hasGivenUp = true
        return .giveUp(attempts: attemptsSoFar)
    }
}

/// The periodic check itself: every `intervalNanos`, compares the tap's
/// cumulative buffer count against the previous check's and hands the
/// budget's decision to `onDecision` (which, for `.attemptRecovery`, does
/// the actual recovery before returning). Runs until its Task is cancelled
/// -- RealAudioEngine starts one per startCapturing() and stopCapturing()
/// cancels it.
enum CaptureHealthMonitor {
    static let defaultIntervalNanos: UInt64 = 2_000_000_000

    static func run(
        intervalNanos: UInt64 = defaultIntervalNanos,
        maxAttempts: Int = CaptureRecoveryBudget.defaultMaxAttempts,
        currentBuffers: () -> Int,
        onDecision: (CaptureRecoveryBudget.Decision) -> Void
    ) async {
        var budget = CaptureRecoveryBudget(maxAttempts: maxAttempts)
        var lastSeen = currentBuffers()
        while true {
            do {
                try await Task.sleep(nanoseconds: intervalNanos)
            } catch {
                return
            }
            let now = currentBuffers()
            let decision = budget.evaluate(buffersSinceLastCheck: now - lastSeen)
            lastSeen = now
            onDecision(decision)
        }
    }
}
