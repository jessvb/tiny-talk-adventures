/// Measures the metric the design spec calls out as the one that matters
/// most: how long from the moment VAD detects the child speaking to the
/// moment playback actually stops. Uses monotonic time (DispatchTime), not
/// wall-clock time, since wall-clock can jump (NTP sync, timezone changes)
/// and would corrupt a latency measurement.
import Foundation

public struct InterruptLatency: Sendable, Equatable {
    public let vadFireToInterruptSentMillis: Double
    public let vadFireToPlaybackStoppedMillis: Double
}

private struct PendingEvent {
    let vadFireTime: DispatchTime
    var interruptSentTime: DispatchTime?
}

public final class LatencyLogger {
    private var pending: [UUID: PendingEvent] = [:]
    public private(set) var history: [InterruptLatency] = []

    public init() {}

    public func recordVADFire() -> UUID {
        let id = UUID()
        pending[id] = PendingEvent(vadFireTime: .now(), interruptSentTime: nil)
        return id
    }

    public func recordInterruptSent(for id: UUID) {
        pending[id]?.interruptSentTime = .now()
    }

    @discardableResult
    public func recordPlaybackStopped(for id: UUID) -> InterruptLatency? {
        guard let event = pending.removeValue(forKey: id) else { return nil }
        let stoppedTime = DispatchTime.now()
        let toStopped = Double(stoppedTime.uptimeNanoseconds - event.vadFireTime.uptimeNanoseconds) / 1_000_000
        let toSent: Double
        if let sentTime = event.interruptSentTime {
            toSent = Double(sentTime.uptimeNanoseconds - event.vadFireTime.uptimeNanoseconds) / 1_000_000
        } else {
            toSent = 0
        }
        let result = InterruptLatency(
            vadFireToInterruptSentMillis: toSent,
            vadFireToPlaybackStoppedMillis: toStopped
        )
        history.append(result)
        return result
    }
}
