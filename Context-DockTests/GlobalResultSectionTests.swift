import Foundation
import Testing

@testable import Context_Dock

/// Global Context lists its results in sections, best kind first (owner 2026-10-14, #258 G1).
@Suite("Global result sections")
struct GlobalResultSectionTests {
    private func pill(_ name: String, kind: String = "", section: String = "") -> AppChatRow {
        var pill = DockPill(id: name, name: name, icon: "app", badge: nil, execute: {})
        pill.rankingKind = kind
        pill.resultSection = section
        return .dock(pill)
    }

    @Test func eachKindHasItsSection() {
        #expect(GlobalResultSection.title(for: pill("Safari", section: "Applications")) == "Applications")
        #expect(GlobalResultSection.title(for: pill("Quit Safari", kind: "menu")) == "Menu commands")
        #expect(GlobalResultSection.title(for: pill("apple.com", kind: "recentURL")) == "Web")
        #expect(GlobalResultSection.title(for: pill("Sleep", kind: "systemCommand")) == "Commands")
        var file = DockPill(id: "f", name: "notes.md", icon: "doc", badge: nil, execute: {})
        file.previewPath = "/tmp/notes.md"
        #expect(GlobalResultSection.title(for: .dock(file)) == "Files & Folders")
        #expect(GlobalResultSection.title(for: SearchResult.ResultType.cliTool) == "Commands")
        // A row that is not a Global result has no section.
        #expect(GlobalResultSection.title(for: .file(URL(fileURLWithPath: "/tmp"))) == nil)
    }

    @Test func rowsGatherUnderTheSectionOfTheirBestRowInOrder() {
        let ranked = [
            pill("Safari", section: "Applications"),
            pill("Quit Safari", kind: "menu"),
            pill("Safari Preview", section: "Applications"),
            pill("About Safari", kind: "menu"),
        ]
        #expect(GlobalResultSection.grouped(ranked).map(\.id)
            == ["dock:Safari", "dock:Safari Preview", "dock:Quit Safari", "dock:About Safari"])
    }

    @Test func aMenuFirstRankingKeepsMenusFirst() {
        let ranked = [pill("Quit Safari", kind: "menu"), pill("Safari", section: "Applications")]
        #expect(GlobalResultSection.grouped(ranked).map(\.id) == ["dock:Quit Safari", "dock:Safari"])
    }

    @Test func aHeaderStandsOverEachSectionsFirstRow() {
        let rows = GlobalResultSection.grouped([
            pill("Safari", section: "Applications"),
            pill("Quit Safari", kind: "menu"),
            pill("Safari Preview", section: "Applications"),
        ])
        #expect(GlobalResultSection.headers(for: rows) == [0: "Applications", 2: "Menu commands"])
        #expect(GlobalResultSection.headers(for: [.file(URL(fileURLWithPath: "/tmp"))]).isEmpty)
    }
}

/// Long sections show their best rows and "Show N more" (#258 G4).
@Suite("Global result sections: show more")
struct GlobalShowMoreTests {
    private func row(_ name: String, _ section: String) -> AppChatRow {
        var pill = DockPill(id: name, name: name, icon: "app", badge: nil, execute: {})
        pill.resultSection = section
        return .dock(pill)
    }

    private func more(_ section: String, _ hidden: Int) -> DockPill {
        var pill = DockPill(id: "more-\(section)", name: "Show \(hidden) more", icon: "chevron.down", badge: nil, execute: {})
        pill.rankingKind = GlobalResultSection.showMoreKind
        pill.resultSection = section
        return pill
    }

    private var rows: [AppChatRow] {
        [row("Safari", "Applications")] + (1...8).map { row("Menu \($0)", "Menu commands") }
    }

    @Test func aLongSectionShowsItsBestRowsAndTheRest() {
        let capped = GlobalResultSection.capped(rows, expanded: [], showMore: more)
        #expect(capped.map(\.id) == ["dock:Safari"] + (1...5).map { "dock:Menu \($0)" } + ["dock:more-Menu commands"])
        #expect(capped.last.map(\.title) == "Show 3 more")
    }

    @Test func anOpenedSectionAndASingleSectionStayWhole() {
        #expect(GlobalResultSection.capped(rows, expanded: ["Menu commands"], showMore: more).count == 9)
        let one = (1...8).map { row("Menu \($0)", "Menu commands") }
        #expect(GlobalResultSection.capped(one, expanded: [], showMore: more).count == 8)
        // The fallbacks under one section do not make it two.
        let withFallbacks = one + [row("Ask", GlobalFallbacks.section)]
        #expect(GlobalResultSection.capped(withFallbacks, expanded: [], showMore: more).count == 9)
    }

    @Test func theFallbacksAreNeverCut() {
        let many = [row("Safari", "Applications")] + (1...7).map { row("F\($0)", GlobalFallbacks.section) }
        #expect(GlobalResultSection.capped(many, expanded: [], showMore: more).count == 8)
    }
}
