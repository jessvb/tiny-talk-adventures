import Foundation

/// Shared timestamp formatting for debugLog-style diagnostic lines, so
/// entries from different sources (SessionCoordinator's own debugLog,
/// RealAudioEngine's onDebugEvent hook -- see its doc comment) can be
/// merged by the app and still sort into the right chronological order.
/// Deliberately not DateFormatter-based: DateFormatter is a class with no
/// documented thread-safety guarantee for concurrent use, and these two
/// sources can call this from different actors/threads (SessionCoordinator's
/// own isolation vs. an AVAudioEngine notification/completion callback).
/// Pure value-type arithmetic on Date/Double/Int64 sidesteps that entirely.
public enum DebugTimestamp {
    public static func now() -> String {
        let interval = Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())
        let totalMillis = Int64((interval * 1000).rounded())
        let millisOfDay = ((totalMillis % 86_400_000) + 86_400_000) % 86_400_000
        let hours = millisOfDay / 3_600_000
        let minutes = (millisOfDay / 60_000) % 60
        let seconds = (millisOfDay / 1000) % 60
        let millis = millisOfDay % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }
}
