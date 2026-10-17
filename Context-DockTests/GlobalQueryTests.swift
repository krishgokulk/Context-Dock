import Foundation
import Testing

@testable import Context_Dock

/// Global Context reads the query before it lists (owner 2026-10-17, S1).
@Suite("Global query reading")
struct GlobalQueryTests {
    private func menu(_ title: String, app: String, path: [String] = []) -> AppChatRow {
        var pill = DockPill(id: "\(app)-\(title)", name: title, icon: "app", badge: nil, execute: {})
        pill.rankingKind = "menu"
        pill.sourceAppName = app
        pill.menuPath = path
        return .dock(pill)
    }

    private func history(_ title: String, app: String = "Safari") -> AppChatRow {
        var pill = DockPill(id: "h-\(title)", name: title, icon: "clock", badge: nil, execute: {})
        pill.rankingKind = "recentURL"
        pill.sourceAppName = app
        pill.menuContext = "Today"
        return .dock(pill)
    }

    @Test func glueTimeAndAppWordsAreNotWhatIsAsked() {
        #expect(GlobalQuery.askedWords(in: "today history in safari", appNames: ["Safari"]) == ["history"])
        #expect(GlobalQuery.askedWords(in: "safari", appNames: ["Safari"]).isEmpty)
    }

    @Test func aDestructiveCommandIsNotTheAnswerUnlessItsVerbWasTyped() {
        let rows = [menu("Clear History…", app: "Safari", path: ["History", "Clear History…"]),
                    history("New session - Claude")]
        let refined = GlobalQuery.refine(rows, query: "safari history")
        #expect(refined.first?.title == "New session - Claude")
        let (safe, risky) = GlobalQuery.split(rows, query: "safari history")
        #expect(safe.map(\.title) == ["New session - Claude"])
        #expect(risky.map(\.title) == ["Clear History…"])

        let asked = GlobalQuery.refine(rows, query: "clear safari history")
        #expect(asked.first?.title == "Clear History…")
    }

    @Test func rowsThatAnswerOnlyTheAppsNameAreDropped() {
        var tool = DockPill(id: "js", name: "Copy GitHub Links", icon: "link", badge: "Browser JavaScript", execute: {})
        tool.sourceAppName = "Safari"
        let rows = [.dock(tool), menu("Clear History…", app: "Safari", path: ["History", "Clear History…"])]
        let refined = GlobalQuery.refine(rows, query: "today history in safari")
        #expect(!refined.contains { $0.title == "Copy GitHub Links" })
        #expect(refined.contains { $0.title == "Clear History…" })
    }

    @Test func nothingIsDroppedWhenNothingWouldBeLeft() {
        let rows = [menu("About Tailscale", app: "Tailscale")]
        #expect(GlobalQuery.refine(rows, query: "tailscale zebra").count == 1)
    }

    @Test func aSingleAppNameKeepsEveryRow() {
        let rows = [menu("About Safari", app: "Safari"), history("Page")]
        #expect(GlobalQuery.refine(rows, query: "safari").count == 2)
    }
}

@MainActor
@Suite("Global query: menu and web rows say what they are")
struct GlobalRowKindTests {
    @Test func aMenuRowPreviewsAsItsCommand() {
        var pill = DockPill(id: "m", name: "Clear History…", icon: "clock", badge: nil, execute: {})
        pill.rankingKind = "menu"
        pill.sourceAppName = "Safari"
        pill.sourceBundleId = "com.apple.Safari"
        pill.menuPath = ["History", "Clear History…"]
        let preview = CornerBoardLayout.preview(for: .dock(pill))
        #expect(preview == .command(title: "Clear History…", path: ["History", "Clear History…"],
                                    appName: "Safari", bundleID: "com.apple.Safari"))
    }

    @Test func aHistoryRowPreviewsAsAWebPage() {
        var pill = DockPill(id: "w", name: "New session", icon: "clock", badge: nil, execute: {})
        pill.rankingKind = "recentURL"
        pill.resolvedURL = URL(string: "https://claude.ai/new")
        pill.sourceAppName = "Safari"
        if case .web = CornerBoardLayout.preview(for: .dock(pill)) {} else { Issue.record("not a web page") }
    }
}

/// S2: the row that plainly answers the query leads, under "Top Hit".
@Suite("Global query: Top Hit")
struct GlobalTopHitTests {
    private func menu(_ title: String, app: String) -> AppChatRow {
        var pill = DockPill(id: "\(app)-\(title)", name: title, icon: "app", badge: nil, execute: {})
        pill.rankingKind = "menu"
        pill.sourceAppName = app
        return .dock(pill)
    }

    @Test func theNamedAppsCommandWithEveryAskedWordIsTheTopHit() {
        let rows = [menu("Clear History…", app: "Safari"), menu("Show Personal History", app: "Safari"),
                    menu("History", app: "Obsidian")]
        #expect(GlobalQuery.topHit(rows, query: "safari history")?.title == "Show Personal History")
    }

    @Test func aQuitIsTheTopHitWhenItWasAskedFor() {
        let rows = [menu("About Tailscale", app: "Tailscale"), menu("Quit Tailscale", app: "Tailscale")]
        #expect(GlobalQuery.topHit(rows, query: "tailscale quit")?.title == "Quit Tailscale")
    }

    @Test func noTopHitWithoutAnAppOrAnAskedWord() {
        let rows = [menu("Show Personal History", app: "Safari")]
        #expect(GlobalQuery.topHit(rows, query: "safari") == nil)
        #expect(GlobalQuery.topHit(rows, query: "history") == nil)
    }

    @Test func aBrowsersHistoryCommandsAreStable() {
        #expect(BrowserStableMenuCommand.isStable(title: "Show Personal History"))
        #expect(!BrowserStableMenuCommand.isStable(title: "New session - Claude"))
    }
}

/// S2: a named app's own commands join a list the engine filled with its pages.
@Suite("Global query: the named app's commands")
struct NamedAppCommandTests {
    private func menuDoc(_ title: String, app: String, path: [String]) -> GlobalSearchService.SearchDocument {
        GlobalSearchService.SearchDocument(
            id: "menu:\(app):\(title)", title: title, subtitle: app, bundleId: "b.\(app)",
            filePath: nil, normalizedTitle: title.lowercased(), titleWords: [title.lowercased()],
            acronym: "x", aliases: [], aliasWords: [], sourceKind: .runningMenu,
            rankingBoost: 0, icon: nil, usageTrackingKey: title,
            action: .cachedMenu(bundleId: "b.\(app)", appName: app, path: path,
                                shortcutChar: "y", shortcutModifiers: 0))
    }

    @Test func theNamedAppsCommandsForTheAskedWordJoin() {
        let docs = [menuDoc("Show Personal History", app: "Safari", path: ["History", "Show Personal History"]),
                    menuDoc("History", app: "Obsidian", path: ["View", "History"]),
                    menuDoc("New Tab", app: "Safari", path: ["File", "New Tab"])]
        let added = GlobalQuery.namedAppCommands(docs, query: "safari history", besides: [])
        #expect(added.map(\.title) == ["Show Personal History"])
    }

    @Test func aCommandAlreadyListedIsNotAddedTwice() {
        let doc = menuDoc("Show Personal History", app: "Safari", path: ["History", "Show Personal History"])
        #expect(GlobalQuery.namedAppCommands([doc], query: "safari history", besides: [.global(doc)]).isEmpty)
    }
}
