import Foundation

// Diagnostics-only helpers for RealAudioEngine's mic-capture path (issue
// #39: capture silently delivering nothing in server mode after a
// demo-mode session, root cause not yet established). Everything here is
// observation -- nothing feeds back into capture/teardown behavior. Kept
// out of AudioEngine.swift's `#if os(iOS)` gate, with no AVFoundation
// dependency, so `swift test` can cover the logic; AudioEngine.swift holds
// only the thin glue that reads AVAudioEngine/AVAudioSession into these.

/// What the mic path has actually done so far, plus the few flags the
/// state snapshot needs. Lock-protected and `@unchecked Sendable`, the same
/// idiom as PlaybackQueueTracker/PlaybackCompletionGate: it is written from
/// the real-time tap callback and read from the watchdog Task and from
/// whoever calls startCapturing()/stopCapturing().
///
/// The tap callback pays two uncontended NSLock acquisitions per buffer
/// (one when the buffer arrives, one when its converted chunk is handed to
/// the caller) -- with a ~2400-frame tap that is ~10-20 buffers a second,
/// and no allocation beyond what the tap already does.
///
/// One capture session per instance, matching how AppModel uses
/// RealAudioEngine (a fresh instance per connect): counts are never reset.
final class CaptureDiagnostics: @unchecked Sendable {
    /// Two counters, deliberately separate: "buffers arrived" is the raw tap
    /// callback (did the hardware deliver anything to the app at all?),
    /// "chunks delivered" is what survived conversion and was handed to the
    /// caller's onAudioCaptured. arrived == 0 means nothing reached the app
    /// (stale AVAudioEngine hardware contention); arrived > 0 with
    /// delivered == 0 means conversion is dropping everything; both > 0
    /// with peak == 0 means the mic is delivering digital silence; all
    /// healthy means whatever is wrong is downstream of RealAudioEngine
    /// (VAD, the coordinator).
    struct Counts: Equatable {
        var buffersReceived = 0
        var chunksDelivered = 0
        /// Largest |sample| seen across every delivered chunk (Int16 scale,
        /// so 0...32768). 0 == every delivered chunk was digital silence.
        var peakAmplitude = 0
    }

    private let lock = NSLock()
    private var current = Counts()
    private var tapInstalled = false
    private var stopped = false
    private var watchdog: Task<Void, Never>?

    private var buffersAtLastCheck = 0

    var counts: Counts { lock.withLock { current } }

    /// Buffers received since the previous call (or since init, the first
    /// time) -- for on-demand checks like AppModel's New Story snapshot
    /// (issue #49), where "has the tap delivered anything lately?" matters
    /// more than the engine's lifetime total.
    func buffersSinceLastCheck() -> Int {
        lock.withLock {
            defer { buffersAtLastCheck = current.buffersReceived }
            return current.buffersReceived - buffersAtLastCheck
        }
    }

    /// Real-time tap callback: a buffer reached the app, before conversion.
    func bufferArrived() {
        lock.withLock { current.buffersReceived += 1 }
    }

    /// A converted chunk was handed to the caller's onAudioCaptured.
    func chunkDelivered(peak: Int) {
        lock.withLock {
            current.chunksDelivered += 1
            current.peakAmplitude = max(current.peakAmplitude, peak)
        }
    }

    /// AVAudioNode has no public "is a tap installed" property, so
    /// RealAudioEngine tracks it at its own installTap/removeTap sites.
    var isTapInstalled: Bool { lock.withLock { tapInstalled } }

    func setTapInstalled(_ installed: Bool) {
        lock.withLock { tapInstalled = installed }
    }

    /// True once stopCapturing() has run. Lets another engine's snapshot
    /// tell a healthy live engine from an OLD one that was already told to
    /// stop yet still shows `engine.isRunning == true`.
    var wasStopped: Bool { lock.withLock { stopped } }

    /// Called from stopCapturing(): records the stop and cancels the
    /// zero-buffer watchdog, so a normal teardown inside its window can't
    /// produce a false "no buffers" warning.
    func markStopped() {
        let toCancel: Task<Void, Never>? = lock.withLock {
            stopped = true
            defer { watchdog = nil }
            return watchdog
        }
        toCancel?.cancel()
    }

    /// Stores the watchdog Task (cancelling any previous one).
    func replaceWatchdog(with task: Task<Void, Never>?) {
        let previous: Task<Void, Never>? = lock.withLock {
            defer { watchdog = task }
            return watchdog
        }
        previous?.cancel()
    }

    /// Largest |sample| in a PCM16 buffer. Uses `Int16.magnitude` (a
    /// UInt16), since `abs(Int16.min)` traps. A trailing odd byte (never
    /// produced by the tap, which emits whole Int16 samples) is ignored
    /// rather than read. No allocation -- safe on the audio thread.
    static func peakAmplitude(ofPCM16 data: Data) -> Int {
        data.withUnsafeBytes { raw in
            var peak = 0
            for i in 0..<(raw.count / MemoryLayout<Int16>.size) {
                let sample = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                peak = max(peak, Int(sample.magnitude))
            }
            return peak
        }
    }
}

/// The zero-buffer watchdog's decision logic, separated from the AVAudioEngine
/// glue so it can be tested with a short delay. Log-only by design: it
/// reports, it never restarts or otherwise touches capture.
enum CaptureWatchdog {
    /// Sleeps `delayNanos`, then -- unless cancelled first (stopCapturing()
    /// cancels it) -- calls exactly one of the two callbacks with the counts
    /// as of that moment. A healthy report is deliberate, not just an absent
    /// warning: reading the on-screen log mid-session, "no warning" alone
    /// can't distinguish "capture is fine" from "the watchdog never ran".
    ///
    /// `baselineBuffers` (issue #49): buffersReceived when the watchdog was
    /// armed -- 0 from startCapturing(), the current count when armed after
    /// a rebuildCaptureTap(). Counts are cumulative per engine, so buffers
    /// the OLD tap delivered before a rebuild must not make a dead rebuilt
    /// tap look healthy.
    static func run(
        after delayNanos: UInt64,
        diagnostics: CaptureDiagnostics,
        baselineBuffers: Int = 0,
        onZeroBuffers: (CaptureDiagnostics.Counts) -> Void,
        onBuffersFlowing: (CaptureDiagnostics.Counts) -> Void
    ) async {
        do {
            try await Task.sleep(nanoseconds: delayNanos)
        } catch {
            return
        }
        let counts = diagnostics.counts
        if counts.buffersReceived <= baselineBuffers {
            onZeroBuffers(counts)
        } else {
            onBuffersFlowing(counts)
        }
    }
}

/// Weak registry of every live instance of a class, with a stable per-
/// instance sequence id -- how RealAudioEngine answers "are two engines
/// alive at once?" (hypothesis 1 of issue #39) without itself keeping any
/// engine alive. Instances are registered lazily, the first time
/// id(for:) is asked about them (RealAudioEngine does that from
/// startCapturing()/stopCapturing(), so an engine that was constructed but
/// never asked to capture is not counted -- it can't be holding the mic).
final class WeakInstanceRegistry<Instance: AnyObject>: @unchecked Sendable {
    private struct Entry {
        let id: Int
        weak var instance: Instance?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextId = 1

    /// The instance's sequence id (1, 2, 3, ... in registration order),
    /// registering it on first sight. Ids are never reused, so a log line
    /// from an engine that has since deallocated stays attributable.
    func id(for instance: Instance) -> Int {
        lock.withLock {
            entries.removeAll { $0.instance == nil }
            if let existing = entries.first(where: { $0.instance === instance }) {
                return existing.id
            }
            let id = nextId
            nextId += 1
            entries.append(Entry(id: id, instance: instance))
            return id
        }
    }

    /// How many registered instances have not deallocated yet.
    var liveCount: Int {
        lock.withLock { entries.filter { $0.instance != nil }.count }
    }

    /// The registered instances still alive, oldest first. Hands back
    /// strong references for the caller's immediate use (e.g. reading each
    /// engine's isRunning) -- don't stash them.
    func liveInstances() -> [(id: Int, instance: Instance)] {
        lock.withLock {
            entries.compactMap { entry in entry.instance.map { (id: entry.id, instance: $0) } }
        }
    }
}
