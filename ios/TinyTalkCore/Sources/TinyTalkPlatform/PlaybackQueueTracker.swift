import Foundation

/// Tracks how many playback buffers are "outstanding" -- scheduled but
/// not yet confirmed finished -- so a caller can enqueue several buffers
/// back-to-back without waiting for each one individually, then await
/// genuine completion of all of them at once. See
/// docs/superpowers/specs/2026-09-12-pipelined-tts-playback-design.md for
/// why this exists: RealAudioEngine.play() previously fully awaited each
/// buffer's real playback completion before the next could even be
/// scheduled, and on-device timing evidence traced a real, audible
/// per-buffer stutter to that serialization.
///
/// Lock-protected, `@unchecked Sendable` -- same idiom PlaybackCompletionGate
/// already establishes in AudioEngine.swift for state shared between a
/// completion closure (fires on an arbitrary AVFoundation thread) and
/// Swift concurrency.
///
/// Also owns the per-buffer hang-guard arithmetic (see bufferEnqueued()),
/// because it has to know what is queued ahead of a buffer to say when that
/// buffer will really finish -- and it lives here, not in AudioEngine.swift,
/// so it can be unit-tested with a fake clock (that file is iOS-only).
final class PlaybackQueueTracker: @unchecked Sendable {
    /// The hang-guard never fires sooner than this after scheduling, however
    /// short the buffer -- and never sooner than this much after the moment
    /// the buffer is EXPECTED to finish. See hangGuardSeconds(playbackFinishesIn:).
    static let hangGuardFloorSeconds: TimeInterval = 3
    static let hangGuardGraceSeconds: TimeInterval = 2

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var outstanding = 0
    private var generation = 0
    /// When (on `clock`) the last buffer scheduled since the queue was last
    /// idle is expected to finish playing; nil while nothing is queued.
    private var expectedQueueEnd: TimeInterval?
    private var waiter: CheckedContinuation<Void, Never>?

    /// `clock` is monotonic seconds; injectable so tests can move time by
    /// hand instead of sleeping.
    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// How long a buffer that is expected to finish playing `remaining`
    /// seconds from now gets before its hang-guard gives up on it: the
    /// expected finish plus a fixed grace, with a floor so a very short (or
    /// empty) buffer is still covered for a moment. Also what play() uses,
    /// for its own single buffer.
    static func hangGuardSeconds(playbackFinishesIn remaining: TimeInterval) -> TimeInterval {
        max(hangGuardFloorSeconds, remaining + hangGuardGraceSeconds)
    }

    /// Call once per buffer, right before scheduling it. Returns the
    /// generation token this buffer was enqueued in -- pass it back to
    /// bufferFinished(generation:) so a completion (or timeout fallback)
    /// that arrives after a reset() can't decrement a LATER turn's
    /// count. See reset()'s doc comment for the real bug this closes: a
    /// barge-in followed immediately by a new turn could otherwise let
    /// an orphaned 3-second timeout from the discarded turn's buffer
    /// silently steal a decrement from the new turn's outstanding
    /// count, letting waitForPlaybackToFinish() resolve one buffer
    /// early -- the same class of bug (readyToShowTheEnd firing before
    /// audio has truly finished) this whole mechanism exists to
    /// prevent. Found in the final whole-plan review; not caught by any
    /// single task's own review, since it only manifests when Task 1's
    /// tracker and Task 2's un-cancelled timeout Task are seen together.
    ///
    /// Also returns how many seconds from now the buffer's hang-guard timer
    /// should fire (issue #29). The player node plays scheduled buffers
    /// back to back, so a buffer starts when the queue ahead of it ends --
    /// not when it is scheduled -- and its guard is measured from THERE:
    /// with a whole reply scheduled within ~2s, a guard measured from
    /// scheduling gave up on every buffer behind the first while it was
    /// still waiting its turn, and waitForPlaybackToFinish() returned
    /// seconds before Elsie stopped talking. `durationSeconds` is the
    /// buffer's own playing time.
    func bufferEnqueued(durationSeconds: TimeInterval) -> (generation: Int, hangGuardSeconds: TimeInterval) {
        lock.withLock {
            outstanding += 1
            let now = clock()
            let end = max(now, expectedQueueEnd ?? now) + durationSeconds
            expectedQueueEnd = end
            return (generation, Self.hangGuardSeconds(playbackFinishesIn: end - now))
        }
    }

    /// Call exactly once per enqueued buffer, whichever of (real
    /// completion, timeout fallback) resolves it first -- mirrors how
    /// PlaybackCompletionGate already guarantees "exactly once" per
    /// buffer today. No-ops if `generation` is stale (a reset() happened
    /// since this buffer was enqueued) rather than decrementing whatever
    /// turn happens to be current now.
    func bufferFinished(generation callerGeneration: Int) {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            guard callerGeneration == generation else { return nil }
            outstanding = max(0, outstanding - 1)
            if outstanding == 0 {
                // Idle: the next buffer starts a fresh queue from "now".
                expectedQueueEnd = nil
                if let waiter {
                    self.waiter = nil
                    return waiter
                }
            }
            return nil
        }
        toResume?.resume()
    }

    /// Suspends until every buffer enqueued so far has been confirmed
    /// finished (via bufferFinished()) -- resolves immediately if
    /// nothing is outstanding.
    func waitForIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeNow: Bool = lock.withLock {
                if outstanding <= 0 {
                    return true
                }
                waiter = continuation
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    /// Forces outstanding back to zero, resumes any waiter immediately,
    /// and advances generation -- so a completion or timeout for a
    /// buffer enqueued before this reset() can never affect a LATER
    /// turn's outstanding count (see bufferFinished(generation:)'s doc
    /// comment for the real, previously-latent bug this prevents).
    /// Called when playback is forcibly stopped (barge-in), since a
    /// stopped buffer's own completion callback is not guaranteed to
    /// fire (AudioEngine.swift already documents that distrust for the
    /// pre-existing single-buffer case). Also forgets where the discarded
    /// queue was expected to end, so the next reply's buffers aren't
    /// measured against time that reply never had to wait through.
    func reset() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            generation += 1
            outstanding = 0
            expectedQueueEnd = nil
            let w = waiter
            waiter = nil
            return w
        }
        toResume?.resume()
    }
}
