import Foundation

/// One page of a locally-stored demo-mode storybook. The page's picture,
/// when there is one, lives in its own file (see LocalStoryStore.saveImage)
/// rather than inline in the JSON -- `hasImage` is what the UI is told.
public struct LocalStoryPage: Codable, Equatable, Sendable {
    public var text: String
    public var hasImage: Bool

    public init(text: String, hasImage: Bool = false) {
        self.text = text
        self.hasImage = hasImage
    }
}

/// A story made away from home, as stored on the phone. Field names and
/// statuses mirror server/tinytalk/story_store.py (and SavedStorySummary /
/// SavedStoryDetail), so mapping to what the UI already consumes is direct.
public struct LocalStory: Codable, Equatable, Sendable {
    public var id: String
    /// ISO 8601, exactly as PendingDemoStoryPayload.createdAt -- sorts
    /// chronologically as a plain string because it is always UTC.
    public var createdAt: String
    public var turns: [PendingDemoStoryTurn]
    public var sharedFacts: [[String]]
    /// The page count this story was created with (the parent's setting at
    /// the moment the story began) -- what its storybook rewrite asks for.
    public var pageCount: Int
    public var title: String?
    public var pages: [LocalStoryPage]
    public var epilogue: String?
    public var rewriteStatus: RewriteStatus
    public var illustrationsStatus: IllustrationsStatus?

    public init(
        id: String,
        createdAt: String,
        turns: [PendingDemoStoryTurn],
        sharedFacts: [[String]],
        pageCount: Int,
        title: String? = nil,
        pages: [LocalStoryPage] = [],
        epilogue: String? = nil,
        rewriteStatus: RewriteStatus = .pending,
        illustrationsStatus: IllustrationsStatus? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.turns = turns
        self.sharedFacts = sharedFacts
        self.pageCount = pageCount
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
        self.rewriteStatus = rewriteStatus
        self.illustrationsStatus = illustrationsStatus
    }
}

/// File-backed store for stories made in away-from-home demo mode, in the
/// app's Application Support directory: `<id>.json` for each story plus an
/// `<id>/page-<index>.jpg` per illustrated page. Same locking style as
/// PendingDemoStore (which stays, unchanged, as the sync queue of
/// transcripts) -- every method is synchronous and lock-guarded so it can be
/// called from the main actor (AppModel's sync path) and from background
/// tasks (a storybook build) alike.
public final class LocalStoryStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = LocalStoryStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("DemoStories", isDirectory: true)
    }

    /// Ids are generated locally (8 hex characters), but they also arrive
    /// via UI-supplied get_story/synthesize_page requests -- reject anything
    /// that could escape `directory` rather than trust them. "." is refused
    /// too: it would resolve to `directory` itself, so remove(ids: ["."])
    /// would delete every story.
    private func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id != "." && !id.contains("/") && !id.contains("\\") && !id.contains("..")
    }

    private func jsonURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    private func imageDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func imageURL(_ id: String, _ pageIndex: Int) -> URL {
        imageDirectory(id).appendingPathComponent("page-\(pageIndex).jpg")
    }

    public func save(_ story: LocalStory) {
        guard isSafeId(story.id) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(story) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: jsonURL(story.id), options: .atomic)
    }

    public func load(id: String) -> LocalStory? {
        guard isSafeId(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return loadLocked(id: id)
    }

    private func loadLocked(id: String) -> LocalStory? {
        guard let data = try? Data(contentsOf: jsonURL(id)) else { return nil }
        return try? JSONDecoder().decode(LocalStory.self, from: data)
    }

    /// Every stored story, newest first. A corrupt file is skipped, not
    /// raised -- one bad story must never break browsing the rest.
    public func loadAll() -> [LocalStory] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let stories: [LocalStory] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(LocalStory.self, from: data)
            }
        return stories.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveImage(_ data: Data, id: String, pageIndex: Int) {
        guard isSafeId(id), pageIndex >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: imageDirectory(id), withIntermediateDirectories: true)
        try? data.write(to: imageURL(id, pageIndex), options: .atomic)
    }

    public func imageData(id: String, pageIndex: Int) -> Data? {
        guard isSafeId(id), pageIndex >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: imageURL(id, pageIndex))
    }

    /// Deletes each story's JSON and its whole image directory. Unknown or
    /// unsafe ids are ignored.
    public func remove(ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids where isSafeId(id) {
            try? FileManager.default.removeItem(at: jsonURL(id))
            try? FileManager.default.removeItem(at: imageDirectory(id))
        }
    }
}
