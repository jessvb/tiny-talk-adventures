import XCTest
@testable import TinyTalkCore

final class SavedStoryTests: XCTestCase {
    func test_relativeDateLabel_sameCalendarDay_isToday() {
        let now = Date()
        let earlierToday = now.addingTimeInterval(-3600)
        XCTAssertEqual(relativeDateLabel(from: earlierToday, now: now), "today")
    }

    func test_relativeDateLabel_oneCalendarDayBack_isYesterday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(relativeDateLabel(from: yesterday, now: now), "yesterday")
    }

    func test_relativeDateLabel_threeDaysBack_showsDayCount() {
        let now = Date()
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(relativeDateLabel(from: threeDaysAgo, now: now), "3 days ago")
    }

    func test_relativeDateLabel_eightDaysBack_isOneWeekAgoSingular() {
        let now = Date()
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        XCTAssertEqual(relativeDateLabel(from: eightDaysAgo, now: now), "1 week ago")
    }

    func test_relativeDateLabel_fifteenDaysBack_showsWeekCount() {
        let now = Date()
        let fifteenDaysAgo = Calendar.current.date(byAdding: .day, value: -15, to: now)!
        XCTAssertEqual(relativeDateLabel(from: fifteenDaysAgo, now: now), "2 weeks ago")
    }

    func test_savedStorySummary_isIdentifiableById() {
        let summary = SavedStorySummary(id: "abc123", title: "Pip", createdAt: Date(), pageCount: 5, rewriteStatus: .done)
        XCTAssertEqual(summary.id, "abc123")
    }
}
