import Foundation

/// What a StoryIllustrating pass produced for one story: positional with
/// the story's pages (nil = no picture for that page), and the same
/// done/partial/failed status server/tinytalk/illustrations.py records.
public struct IllustrationResult: Equatable, Sendable {
    public let images: [Data?]
    public let status: IllustrationsStatus

    public init(images: [Data?], status: IllustrationsStatus) {
        self.images = images
        self.status = status
    }
}

/// The seam between DemoStoryLibrary and whatever draws a story's pictures.
/// Phase 1 ships without an implementation (a nil illustrator means
/// text-only storybooks); Phase 2's IllustrationPass conforms to it.
public protocol StoryIllustrating: Sendable {
    func illustrate(pages: [String]) async -> IllustrationResult
}

/// The on-phone library of stories made away from home: save a finished
/// story, list/detail it in exactly the shapes the Library/Reading screens
/// already consume, and turn its transcript into a storybook. Immutable
/// dependencies only -- storybook builds are serialized through one
/// process-wide queue, so several libraries (e.g. one per demo connection)
/// can never build at the same time.
public struct DemoStoryLibrary: Sendable {
    private static let buildQueue = SerialAsyncQueue()

    private let store: LocalStoryStore
    private let writer: StorybookWriter
    private let illustrator: (any StoryIllustrating)?

    public init(store: LocalStoryStore, writer: StorybookWriter, illustrator: (any StoryIllustrating)? = nil) {
        self.store = store
        self.writer = writer
        self.illustrator = illustrator
    }

    /// Saves a just-finished story's transcript as `pending`, awaiting its
    /// storybook. `pageCount` is the page count in force when the story began.
    public func begin(_ payload: PendingDemoStoryPayload, pageCount: Int) {
        store.save(LocalStory(
            id: payload.id,
            createdAt: payload.createdAt,
            turns: payload.turns,
            sharedFacts: payload.sharedFacts,
            pageCount: pageCount
        ))
    }

    /// Newest first -- what a `story_list` event carries.
    public func list() -> [SavedStorySummary] {
        let formatter = ISO8601DateFormatter()
        return store.loadAll().map { story in
            SavedStorySummary(
                id: story.id,
                title: story.title,
                createdAt: formatter.date(from: story.createdAt) ?? Date(),
                pageCount: story.pages.count,
                rewriteStatus: story.rewriteStatus
            )
        }
    }

    /// What a `story_detail` event carries; nil for an unknown id.
    public func detail(id: String) -> SavedStoryDetail? {
        guard let story = store.load(id: id) else { return nil }
        return SavedStoryDetail(
            id: story.id,
            title: story.title,
            pages: story.pages.map { StoryPage(text: $0.text, hasImage: $0.hasImage) },
            epilogue: story.epilogue,
            rewriteStatus: story.rewriteStatus,
            illustrationsStatus: story.illustrationsStatus
        )
    }

    public func pageText(id: String, index: Int) -> String? {
        guard let story = store.load(id: id), story.pages.indices.contains(index) else { return nil }
        return story.pages[index].text
    }

    /// nil when the story/page doesn't exist or the page has no picture.
    public func pageImage(id: String, index: Int) -> Data? {
        guard let story = store.load(id: id),
              story.pages.indices.contains(index),
              story.pages[index].hasImage
        else { return nil }
        return store.imageData(id: id, pageIndex: index)
    }

    /// Turns a `pending` story's transcript into its storybook, then (when
    /// an illustrator is configured) its pictures. Serialized process-wide,
    /// and a no-op for a story that is no longer `pending`, so it is safe to
    /// call twice for the same id.
    public func buildStorybook(id: String) async {
        let store = self.store
        let writer = self.writer
        let illustrator = self.illustrator
        await Self.buildQueue.enqueue {
            await Self.performBuild(id: id, store: store, writer: writer, illustrator: illustrator)
        }
    }

    /// A build interrupted by the app being backgrounded or killed leaves
    /// its story `pending` forever -- rebuild any such story. Idempotent.
    public func resumeInterruptedBuilds() async {
        for story in store.loadAll() where story.rewriteStatus == .pending {
            await buildStorybook(id: story.id)
        }
    }

    private static func performBuild(
        id: String, store: LocalStoryStore, writer: StorybookWriter, illustrator: (any StoryIllustrating)?
    ) async {
        guard var story = store.load(id: id), story.rewriteStatus == .pending else { return }

        let written = await writer.write(
            turns: story.turns, sharedFacts: story.sharedFacts, pageCount: story.pageCount
        )
        // The story may have been synced home (and its local copy deleted)
        // while the model was thinking -- never re-save it, or it would
        // reappear in the away Library as a duplicate of the synced one.
        guard store.load(id: id) != nil else { return }
        guard let written else {
            story.rewriteStatus = .failed
            store.save(story)
            return
        }
        story.title = written.title
        story.pages = written.pages.map { LocalStoryPage(text: $0) }
        story.epilogue = written.epilogue
        story.rewriteStatus = .done
        store.save(story)

        guard let illustrator else { return }
        story.illustrationsStatus = .pending
        store.save(story)
        let result = await illustrator.illustrate(pages: written.pages)
        guard store.load(id: id) != nil else { return } // same reason as above
        for (index, image) in result.images.enumerated() where story.pages.indices.contains(index) {
            guard let image else { continue }
            store.saveImage(image, id: id, pageIndex: index)
            story.pages[index].hasImage = true
        }
        story.illustrationsStatus = result.status
        store.save(story)
    }

    /// The payloads to send at sync time: each pending transcript, plus its
    /// finished storybook when the local rewrite reached `done`. Needs only
    /// the store, not a live library, because the sync runs from the
    /// real-server connect path, where no DemoStoryLibrary exists. A story
    /// that failed, is still pending, or has no local record syncs
    /// transcript-only, so the Mac rewrites it as it always has.
    public static func syncPayloads(
        store: LocalStoryStore, pending: [PendingDemoStoryPayload]
    ) -> [PendingDemoStoryPayload] {
        pending.map { payload in
            guard let story = store.load(id: payload.id),
                  story.rewriteStatus == .done,
                  let title = story.title,
                  !story.pages.isEmpty
            else { return payload }
            let pages = story.pages.enumerated().map { index, page in
                DemoSyncPage(
                    text: page.text,
                    imageJPEG: page.hasImage ? store.imageData(id: payload.id, pageIndex: index) : nil
                )
            }
            return PendingDemoStoryPayload(
                id: payload.id,
                createdAt: payload.createdAt,
                turns: payload.turns,
                sharedFacts: payload.sharedFacts,
                storybook: DemoSyncStorybook(title: title, pages: pages, illustrationsStatus: story.illustrationsStatus)
            )
        }
    }
}
