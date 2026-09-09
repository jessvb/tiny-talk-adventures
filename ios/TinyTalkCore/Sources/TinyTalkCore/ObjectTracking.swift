import Foundation

/// Swift port of server/tinytalk/object_recognition.py.
public final class ObjectTracker: @unchecked Sendable {
    private static let weaveInTemplate =
        "The child just showed you a photo of a %@. Let it inspire what " +
        "happens next -- it doesn't have to appear literally, but something " +
        "recognizable about it (its species, size, color, shape, or " +
        "personality) must carry through to whatever you introduce. A teddy " +
        "bear could become a real bear character, a couch could become a " +
        "mountain shaped like one, a computer could become a robot -- each " +
        "keeps a clear thread back to the original. If the child's own words " +
        "call for a new character, creature, or animal, make THIS the one " +
        "that shows up, rather than inventing an unrelated one."

    private let lock = NSLock()
    private var pendingLabel: String?

    public init() {}

    public func recordSeen(label: String) {
        guard Safety.isSafe(label) else { return }
        lock.lock(); defer { lock.unlock() }
        pendingLabel = label
    }

    public func consumeGuidance() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let label = pendingLabel else { return "" }
        pendingLabel = nil
        return String(format: Self.weaveInTemplate, label)
    }
}
