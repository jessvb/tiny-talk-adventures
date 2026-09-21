import Foundation

/// Runs async work strictly one item at a time, in arrival order -- across
/// every caller sharing the same queue instance.
///
/// An `actor` would NOT do this: an actor only serializes the synchronous
/// stretches between suspension points, so two async operations on it can
/// still interleave whenever either one `await`s. A storybook build is
/// almost entirely awaits (LLM calls), hence this chained-Task queue.
final class SerialAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Returns once `work` has run to completion (after everything enqueued
    /// before it).
    func enqueue(_ work: @escaping @Sendable () async -> Void) async {
        let task = schedule(work)
        await task.value
    }

    // Synchronous on purpose: this toolchain marks NSLock.lock()/unlock()
    // unavailable from async contexts, so the locked section lives in a
    // plain function (same workaround DemoConnection uses).
    private func schedule(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        let next = Task {
            await previous?.value
            await work()
        }
        tail = next
        return next
    }
}
