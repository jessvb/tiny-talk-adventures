import Foundation

/// One page of a saved story's rewritten storybook prose -- text only, no
/// illustration or photo tie-in (explicitly out of scope, see
/// docs/superpowers/specs/2026-09-08-storybook-persistence-design.md).
/// Field name matches the server's future `story_detail` wire message
/// (`pages: [{"text": ...}]`) so decoding real server JSON later is a
/// straight mapping, not a rewrite.
public struct StoryPage: Equatable, Sendable {
    public let text: String
    public let hasImage: Bool

    public init(text: String, hasImage: Bool = false) {
        self.text = text
        self.hasImage = hasImage
    }
}

/// Mirrors story_store.py's `rewrite_status` field exactly (`"pending"`,
/// `"done"`, `"failed"`).
public enum RewriteStatus: String, Equatable, Sendable {
    case pending
    case done
    case failed
}

/// Mirrors story_store.py's `illustrations_status` field exactly
/// (`"pending"`, `"done"`, `"partial"`, `"failed"`). Absent entirely
/// (`nil`) means the text rewrite hasn't finished yet, or finished but
/// no illustration pass has run at all -- distinct from any of the four
/// named states.
public enum IllustrationsStatus: String, Equatable, Sendable {
    case pending
    case done
    case partial
    case failed
}

/// One row of the Library screen's grid -- the shape of one entry in the
/// server's future `story_list` wire message (`{id, title, created_at,
/// page_count, rewrite_status}`). `title` is nil while `rewriteStatus` is
/// `.pending` or `.failed` -- the background rewrite hasn't produced one
/// yet.
public struct SavedStorySummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let createdAt: Date
    public let pageCount: Int
    public let rewriteStatus: RewriteStatus

    public init(id: String, title: String?, createdAt: Date, pageCount: Int, rewriteStatus: RewriteStatus) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.rewriteStatus = rewriteStatus
    }
}

/// Full contents of one saved story for the Reading/The End screens -- the
/// shape of the server's future `story_detail` wire message (`{title,
/// pages, epilogue, rewrite_status}`). `epilogue` is nil whenever no real
/// animal fact was shared during that story -- never a fabricated one.
public struct SavedStoryDetail: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let pages: [StoryPage]
    public let epilogue: String?
    public let rewriteStatus: RewriteStatus
    public let illustrationsStatus: IllustrationsStatus?

    public init(
        id: String, title: String?, pages: [StoryPage], epilogue: String?,
        rewriteStatus: RewriteStatus, illustrationsStatus: IllustrationsStatus? = nil
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
        self.rewriteStatus = rewriteStatus
        self.illustrationsStatus = illustrationsStatus
    }
}

/// Library card caption text ("today" / "yesterday" / "N days ago" / "N
/// weeks ago"), based on calendar-day difference (not raw elapsed hours) so
/// "11pm yesterday" reads as "yesterday" rather than "0 days ago". A
/// simplification of the design canvas's exact wording (which used a
/// weekday name, e.g. "last Tuesday", for one example) -- easy to revisit
/// if the household wants exact weekday names later.
public func relativeDateLabel(from date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let startOfDate = calendar.startOfDay(for: date)
    let startOfNow = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

    switch days {
    case ..<1:
        return "today"
    case 1:
        return "yesterday"
    case 2...6:
        return "\(days) days ago"
    default:
        let weeks = max(1, days / 7)
        return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
    }
}
