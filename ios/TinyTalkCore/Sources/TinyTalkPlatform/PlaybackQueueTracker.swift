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
final class PlaybackQueueTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var generation = 0
    private var waiter: CheckedContinuation<Void, Never>?

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
    func bufferEnqueued() -> Int {
        lock.withLock {
            outstanding += 1
            return generation
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
            if outstanding == 0, let waiter {
                self.waiter = nil
                return waiter
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
    /// pre-existing single-buffer case).
    func reset() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            generation += 1
            outstanding = 0
            let w = waiter
            waiter = nil
            return w
        }
        toResume?.resume()
    }
}
