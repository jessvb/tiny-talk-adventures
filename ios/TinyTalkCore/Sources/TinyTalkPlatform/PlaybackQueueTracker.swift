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
    private var waiter: CheckedContinuation<Void, Never>?

    /// Call once per buffer, right before scheduling it.
    func bufferEnqueued() {
        lock.withLock { outstanding += 1 }
    }

    /// Call exactly once per enqueued buffer, whichever of (real
    /// completion, timeout fallback) resolves it first -- mirrors how
    /// PlaybackCompletionGate already guarantees "exactly once" per
    /// buffer today. Safe to call more times than bufferEnqueued() was
    /// called (never goes negative) -- defensive only, should not
    /// happen in practice.
    func bufferFinished() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
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

    /// Forces outstanding back to zero and resumes any waiter
    /// immediately -- called when playback is forcibly stopped
    /// (barge-in), since a stopped buffer's own completion callback is
    /// not guaranteed to fire (AudioEngine.swift already documents that
    /// distrust for the pre-existing single-buffer case).
    func reset() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            outstanding = 0
            let w = waiter
            waiter = nil
            return w
        }
        toResume?.resume()
    }
}
