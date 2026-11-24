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
        let contextRow = pill("New Tab", section: GlobalResultSection.contextualActionsTitle(forApp: "Safari"))
        let windowRow = pill("Left", section: GlobalResultSection.windowLayouts)
        let pinnedRow = pill("Export PDF", section: GlobalResultSection.pinnedSectionTitle(forApp: "Safari"))

        let grouped = GlobalResultSection.grouped(
            [appRow, windowRow, contextRow, pinnedRow],
            query: "e",
            useCanonicalSectionOrder: true
        )
        #expect(grouped.map(\.title) == ["Export PDF", "New Tab", "Safari", "Left"])
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

    @Test func globalFileAndFolderRowsMatchBoundedRootFolders() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        let settings = AppSettings.shared
        let prevUseCustom = settings.useCustomSearchDirectories
        let prevDirs = settings.searchDirectories
        defer {
            settings.useCustomSearchDirectories = prevUseCustom
            settings.searchDirectories = prevDirs
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnifiedLauncherDownloadsTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        settings.useCustomSearchDirectories = true
        settings.searchDirectories = [SearchDirectory(path: tempDir.path, displayName: tempDir.lastPathComponent)]

        let rows = model.globalFileAndFolderRows(for: "DownloadsTest")
        #expect(rows.count == 1)
        if case .file(let url) = rows.first {
            #expect(url.standardizedFileURL.path == tempDir.standardizedFileURL.path)
            #expect(GlobalResultSection.title(for: rows[0]) == GlobalResultSection.files)
        } else {
            Issue.record("Expected .file row for bounded root folder")
        }
    }

    @Test func multiSectionGlobalContextShowsUpToNineVisibleSlots() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.query = "s"
        model.rows = [
            pill("Safari", section: GlobalResultSection.applications),
            pill("Screenshot", section: GlobalResultSection.commands),
            .file(URL(fileURLWithPath: "/tmp/screenshot.png")),
            pill("Ask Dora: s", section: GlobalFallbacks.section),
        ]
        // 4 section headers + 4 rows = 8 slots (all visible within 9-slot Global viewport)
        #expect(model.listRowCount == 8)
    }

    @Test func windowLayoutsRankAboveMenuCommandsInCanonicalOrder() {
        let menuRow = pill("Centre", section: GlobalResultSection.menuCommands)
        let windowRow = pill("Centre", section: GlobalResultSection.windowLayouts)

        let grouped = GlobalResultSection.grouped(
            [menuRow, windowRow],
            query: "centre",
            useCanonicalSectionOrder: true
        )
        #expect(GlobalResultSection.title(for: grouped[0]) == GlobalResultSection.windowLayouts)
        #expect(GlobalResultSection.title(for: grouped[1]) == GlobalResultSection.menuCommands)
    }

    @Test func rightArrowOnFolderInGlobalContextListsFolderContents() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("UnifiedFolderNav-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("passport.pdf"))

        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.query = "UnifiedFolderNav"
        model.rows = [.file(dir)]
        model.focusedMenuIndex = 0

        #expect(model.stepIntoFocusedRow())
        #expect(model.isFinderScope)
        #expect(model.returnsToGlobalScope)
        #expect(model.rows.map(\.title) == ["passport.pdf"])
        #expect(model.focusedMenuIndex == 0)
    }

    @Test func folderWalkFromGlobalContextClimbsBackWithLeftArrowAndRestoresOrigin() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("UnifiedWalk-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Projects")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("b".utf8).write(to: sub.appendingPathComponent("spec.md"))

        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.query = "UnifiedWalk"
        model.rows = [.file(root)]
        model.focusedMenuIndex = 0

        // Step into root folder -> top item ("Projects") is immediately focused
        #expect(model.stepIntoFocusedRow())
        #expect(model.finderBrowseStack == [root])
        #expect(model.rows.map(\.title) == ["Projects", "notes.txt"])
        #expect(model.focusedMenuIndex == 0)

        // Pressing → again immediately steps into "Projects" without needing ↓ first
        #expect(model.stepIntoFocusedRow())
        #expect(model.finderBrowseStack.map { $0.resolvingSymlinksInPath().path }
            == [root, sub].map { $0.resolvingSymlinksInPath().path })
        #expect(model.rows.map(\.title) == ["spec.md"])
        #expect(model.focusedMenuIndex == 0)

        // Pressing ← climbs back to root and highlights "Projects"
        #expect(model.applyResultFocusKey(.left))
        #expect(model.finderBrowseStack == [root])
        #expect(model.rows.map(\.title) == ["Projects", "notes.txt"])
        #expect(model.focusedMenuIndex == 0)

        // Pressing ← at outermost folder returns to Global Context
        #expect(model.applyResultFocusKey(.left))
        #expect(model.finderBrowseStack.isEmpty)
        #expect(model.isGlobalScope)
        #expect(model.query == "UnifiedWalk")
    }

    @Test func homeAndICloudSearchFindsPicturesAndNestedScreenshotFolders() throws {
        let fm = FileManager.default
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("FakeHome-\(UUID().uuidString)")
        let fakeCloud = fakeHome.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let homePictures = fakeHome.appendingPathComponent("Pictures")
        let docPictures = fakeHome.appendingPathComponent("Documents/Pictures")
        let cloudPictures = fakeCloud.appendingPathComponent("Pictures")
        let homeScreenshotSingular = homePictures.appendingPathComponent("Screenshot")
        let homeScreenshotsPlural = homePictures.appendingPathComponent("Screenshots")
        let downloadsPhotos = fakeHome.appendingPathComponent("Downloads/Photos")

        for dir in [homePictures, docPictures, cloudPictures, homeScreenshotSingular, homeScreenshotsPlural, downloadsPhotos] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: fakeHome) }
        try Data("png".utf8).write(to: downloadsPhotos.appendingPathComponent("Screenshot 2026-08-24 at 14.58.15.png"))

        let settings = AppSettings.shared
        let prevUseCustom = settings.useCustomSearchDirectories
        let prevDirs = settings.searchDirectories
        defer {
            settings.useCustomSearchDirectories = prevUseCustom
            settings.searchDirectories = prevDirs
        }

        // User added iCloud Drive and Home dir in Search Directories
        settings.useCustomSearchDirectories = false
        settings.searchDirectories = [
            SearchDirectory(path: fakeCloud.path, displayName: "com~apple~CloudDocs"),
            SearchDirectory(path: fakeHome.path, displayName: "FakeHome"),
        ]

        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()

        // 1. Searching "pictures" finds all Pictures folders and ranks ~/Pictures ahead of ~/Documents/Pictures and iCloud
        let picRows = model.globalFileAndFolderRows(for: "pictures")
        let picPaths = picRows.compactMap { row -> String? in
            if case .file(let u) = row { return u.resolvingSymlinksInPath().path }
            return nil
        }
        #expect(picPaths.contains(homePictures.resolvingSymlinksInPath().path))
        #expect(picPaths.contains(docPictures.resolvingSymlinksInPath().path))
        #expect(picPaths.contains(cloudPictures.resolvingSymlinksInPath().path))
        #expect(picPaths.first == homePictures.resolvingSymlinksInPath().path)

        // 2. Searching "screenshots" (plural) finds BOTH ~/Pictures/Screenshots AND ~/Pictures/Screenshot (singular) ahead of .png files
        let shotRows = model.globalFileAndFolderRows(for: "screenshots")
        let shotPaths = shotRows.compactMap { row -> String? in
            if case .file(let u) = row { return u.resolvingSymlinksInPath().path }
            return nil
        }
        #expect(shotPaths.contains(homeScreenshotsPlural.resolvingSymlinksInPath().path))
        #expect(shotPaths.contains(homeScreenshotSingular.resolvingSymlinksInPath().path))
        let topTwo = Array(shotPaths.prefix(2))
        #expect(topTwo.contains(homeScreenshotsPlural.resolvingSymlinksInPath().path))
        #expect(topTwo.contains(homeScreenshotSingular.resolvingSymlinksInPath().path))

        // 3. Entering full path "/.../Pictures/Screenshot" is NOT intercepted by slashAppFilter and resolves directly
        model.query = homeScreenshotSingular.path
        #expect(model.slashAppFilter == nil)
        let pathRows = model.globalFileAndFolderRows(for: homeScreenshotSingular.path)
        if case .file(let firstURL) = pathRows.first {
            #expect(firstURL.resolvingSymlinksInPath().path == homeScreenshotSingular.resolvingSymlinksInPath().path)
        } else {
            Issue.record("Expected direct folder match for full path query")
        }
    }
}
