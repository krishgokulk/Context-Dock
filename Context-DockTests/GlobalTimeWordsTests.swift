import Foundation
import Testing

@testable import Context_Dock

/// Time words keep only what happened then; apps and commands stay (S3).
@Suite("Global time words")
struct GlobalTimeWordsTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    /// Wednesday 2026-10-14, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_990_000)

    private func day(_ offset: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(TimeInterval(hour * 3600))
    }

    @Test func eachTimeWordNamesItsRange() throws {
        let today = try #require(GlobalQuery.timeRange(in: "safari history today", now: now, calendar: calendar))
        #expect(today.start == calendar.startOfDay(for: now) && today.end == now)
        let yesterday = try #require(GlobalQuery.timeRange(in: "copied yesterday", now: now, calendar: calendar))
        #expect(yesterday.contains(day(-1)) && !yesterday.contains(day(0)))
        let lastWeek = try #require(GlobalQuery.timeRange(in: "pdf last week", now: now, calendar: calendar))
        #expect(lastWeek.contains(day(-7)) && !lastWeek.contains(day(0)))
        let thisWeek = try #require(GlobalQuery.timeRange(in: "this week", now: now, calendar: calendar))
        #expect(thisWeek.contains(day(-1)) && !thisWeek.contains(day(-3)))
        #expect(GlobalQuery.timeRange(in: "safari history", now: now, calendar: calendar) == nil)
    }

    private func page(_ title: String, visited: Date?) -> AppChatRow {
        .global(GlobalSearchService.SearchDocument(
            browserURL: BrowserURLLibraryEntry(
                title: title, url: URL(string: "https://example.com/\(title)")!, visitDate: visited,
                kind: visited == nil ? .bookmark : .history, browserName: "Safari",
                browserBundleId: "com.apple.Safari"),
            icon: nil))
    }

    @Test func onlyDatedRowsAreFilteredByTheTime() {
        var menu = DockPill(id: "m", name: "Show All History", icon: "app", badge: nil, execute: {})
        menu.rankingKind = "menu"
        let rows: [AppChatRow] = [
            .dock(menu), page("today", visited: day(0, hour: 9)),
            page("lastweek", visited: day(-7)), page("bookmark", visited: nil),
        ]
        let range = GlobalQuery.timeRange(in: "today", now: now, calendar: calendar)!
        #expect(GlobalQuery.within(range, rows).map(\.title) == ["Show All History", "today"])
    }

    @Test func historyIsLookedUpWithoutTheTimeAndTheBrowserName() {
        #expect(GlobalQuery.historySearchText("safari history today") == "")
        #expect(GlobalQuery.historySearchText("github pages last week") == "github")
        let entries = [
            BrowserURLLibraryEntry(title: "a", url: URL(string: "https://a.com")!, visitDate: day(0, hour: 9), kind: .history, browserName: "Safari", browserBundleId: "com.apple.Safari"),
            BrowserURLLibraryEntry(title: "b", url: URL(string: "https://b.com")!, visitDate: day(0, hour: 10), kind: .history, browserName: "Chrome", browserBundleId: "com.google.Chrome"),
            BrowserURLLibraryEntry(title: "c", url: URL(string: "https://c.com")!, visitDate: day(-2), kind: .history, browserName: "Safari", browserBundleId: "com.apple.Safari"),
        ]
        let range = GlobalQuery.timeRange(in: "today", now: now, calendar: calendar)!
        #expect(GlobalQuery.datedHistory(entries, query: "safari history today", range: range).map(\.title) == ["a"])
        #expect(GlobalQuery.datedHistory(entries, query: "today", range: range).map(\.title) == ["a", "b"])
    }

    @Test func aSourceIsFilteredByTheTimeBeforeItsNewestAreTaken() {
        let clips = (0..<12).map { DockCore.ClipboardEntry(text: "today \($0)", timestamp: day(0, hour: 1)) }
            + [DockCore.ClipboardEntry(text: "from yesterday", timestamp: day(-1))]
        let range = GlobalQuery.timeRange(in: "copied yesterday", now: now, calendar: calendar)!
        let rows = GlobalSources.rows(
            query: "copied yesterday", clips: clips, notes: [], notifications: [], now: now,
            within: range, copy: { _ in }, openNote: { _ in }, openNotification: { _ in })
        #expect(rows.map(\.title) == ["from yesterday"])
    }
}
