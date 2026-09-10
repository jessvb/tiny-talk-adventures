import Foundation

/// Local, on-phone holding pen for stories completed away from home,
/// until AppModel (Task 15) hands them to the real server on next
/// reconnect. One JSON file per story, named by story id.
public final class PendingDemoStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = PendingDemoStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("PendingDemoStories", isDirectory: true)
    }

    public func save(_ payload: PendingDemoStoryPayload) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(payload.id).json"))
    }

    public func loadAll() -> [PendingDemoStoryPayload] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(PendingDemoStoryPayload.self, from: data)
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
