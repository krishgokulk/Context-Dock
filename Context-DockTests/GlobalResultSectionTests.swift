import ApplicationServices
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
        // An app's own rows have Global's sections too (G4); a CLI subcommand has none.
        #expect(GlobalResultSection.title(for: .file(URL(fileURLWithPath: "/tmp"))) == "Files & Folders")
        #expect(GlobalResultSection.title(for: .cliSuggestion("status")) == nil)
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
        #expect(GlobalResultSection.headers(for: [.cliSuggestion("status")]).isEmpty)
    }

    @Test func canonicalSectionOrderRanksApplicationsAboveMenusAndFiles() {
        let rows = [
            pill("Quit Safari", kind: "menu"),
            pill("readme.md", kind: "file"),
            pill("Safari", section: "Applications"),
            pill("Lock Screen", kind: "systemCommand")
        ]
        let canonical = GlobalResultSection.grouped(rows, query: "s", useCanonicalSectionOrder: true)
        let headers = GlobalResultSection.headers(for: canonical)
        #expect(canonical.first?.title == "Safari")
        #expect(headers[0] == "Applications")
    }

    @Test func intraSectionPriorityPutsExactAndPrefixMatchesFirst() {
        let rows = [
            pill("Mastermind", section: "Applications"),
            pill("Terminal", section: "Applications"),
            pill("iTerm", section: "Applications")
        ]
        let ranked = GlobalResultSection.grouped(rows, query: "term", useCanonicalSectionOrder: true)
        #expect(ranked.map(\.title) == ["Terminal", "Mastermind", "iTerm"])
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

/// An app's Context Dock lists what is typed in the same sections (#258 G4).
@MainActor
@Suite("App scope sections")
struct AppScopeSectionTests {
    private let copy = AppChatRow.command(AXMenuItem(
        title: "Copy", path: ["Edit", "Copy"], isEnabled: true,
        element: AXUIElementCreateSystemWide(), children: []))

    @Test func twoKindsTypedGetHeaders() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Finder", bundleID: "com.apple.finder")
        model.rows = [copy, .file(URL(fileURLWithPath: "/tmp/copy.txt"))]
        model.query = "cop"
        #expect(model.globalSectionHeaders == [0: "Menu commands", 1: "Files & Folders"])
    }

    @Test func oneKindOrNothingTypedHasNone() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Calculator", bundleID: "com.apple.calculator")
        model.rows = [copy]
        model.query = "cop"
        #expect(model.globalSectionHeaders.isEmpty)
        model.rows = [copy, .file(URL(fileURLWithPath: "/tmp/copy.txt"))]
        model.query = ""
        #expect(model.globalSectionHeaders.isEmpty)
    }
}

/// An app stepped into from Global that quits sends the field back to Global (owner 2026-10-14).
@MainActor
@Suite("Scoped app quits")
struct ScopedAppQuitTests {
    @Test func theSteppedIntoAppQuittingReturnsToGlobal() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.scopeIntoApp(name: "Calculator", bundleID: "com.apple.calculator")
        #expect(model.returnsToGlobalScope)
        #expect(!model.scopedAppQuit("com.apple.Safari"))
        #expect(model.scopedAppQuit("com.apple.calculator"))
        #expect(model.isGlobalScope)
        #expect(model.query.isEmpty)
    }

    @Test func aFrontAppScopeIsNotTheGlobalOnesToLeave() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Calculator", bundleID: "com.apple.calculator")
        #expect(!model.scopedAppQuit("com.apple.calculator"))
        #expect(model.appBundleID == "com.apple.calculator")
    }
}

@MainActor
@Suite("Unified Global Launcher: sections, window management, bounded search")
struct UnifiedGlobalLauncherSectionTests {
    private func pill(_ name: String, section: String) -> AppChatRow {
        var p = DockPill(id: name, name: name, icon: "app", badge: nil, execute: {})
        p.resultSection = section
        return .dock(p)
    }

    @Test func pinnedSectionRanksFirstInCanonicalOrder() {
        let appRow = pill("Safari", section: GlobalResultSection.applications)
        let windowRow = pill("Left", section: GlobalResultSection.windowLayouts)
        let pinnedRow = pill("Export PDF", section: GlobalResultSection.pinnedSectionTitle(forApp: "Safari"))

        let grouped = GlobalResultSection.grouped(
            [appRow, windowRow, pinnedRow],
            query: "e",
            useCanonicalSectionOrder: true
        )
        #expect(grouped.first?.title == "Export PDF")
    }

    @Test func windowManagementKeywordsMatchAllCanonicalCommands() {
        for keyword in ["left", "right", "center", "maximize", "tile", "arrange"] {
            let matches = WindowManagementService.shared.matchingCommands(query: keyword)
            #expect(!matches.isEmpty, "Expected window command match for '\(keyword)'")
        }
    }

    @Test func boundedRootsEnforceCustomDirectoryBoundary() {
        let custom = FileSearchService.boundedRoots(
            useCustom: true,
            customDirectories: ["/tmp/docs", "  "],
            homeDirectory: "/Users/test"
        )
        #expect(custom == ["/tmp/docs"])

        let emptyCustom = FileSearchService.boundedRoots(
            useCustom: true,
            customDirectories: [],
            homeDirectory: "/Users/test"
        )
        #expect(emptyCustom.isEmpty)
    }
}
