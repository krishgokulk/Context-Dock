import Foundation
import Testing

@testable import Context_Dock

/// The result sheet's polish pass (owner 2026-10-17).
@Suite("Result sheet polish")
struct ResultSheetPolishTests {
    /// #1: "tailscale quit" found nothing; the app may come before the verb.
    @Test func aQuitReadsEitherWayRound() {
        #expect(AppChatPromptModel.quitAppQuery("quit") == "")
        #expect(AppChatPromptModel.quitAppQuery("quit Mail") == "mail")
        #expect(AppChatPromptModel.quitAppQuery("tailscale quit") == "tailscale")
        #expect(AppChatPromptModel.quitAppQuery("  Visual Studio Code   quit ") == "visual studio code")
        #expect(AppChatPromptModel.quitAppQuery("quitter") == nil)
        #expect(AppChatPromptModel.quitAppQuery("mail") == nil)
    }
}

/// #2: the app the words name comes first within its section.
@Suite("Result sheet polish: own app first")
struct OwnAppFirstTests {
    private func menu(_ title: String, app: String) -> AppChatRow {
        var pill = DockPill(id: "\(app)-\(title)", name: title, icon: "app", badge: nil, execute: {})
        pill.rankingKind = "menu"
        pill.sourceAppName = app
        return .dock(pill)
    }

    @Test func theNamedAppsRowsLeadTheirSection() {
        let rows = [menu("Tailscale", app: "Obsidian"), menu("Tailscale", app: "Preview"),
                    menu("About Tailscale", app: "Tailscale")]
        let grouped = GlobalResultSection.grouped(rows, query: "tailscale")
        #expect(grouped.map(\.id) == ["dock:Tailscale-About Tailscale", "dock:Obsidian-Tailscale", "dock:Preview-Tailscale"])
    }

    @Test func withNoWordsTheOrderStands() {
        let rows = [menu("A", app: "One"), menu("B", app: "Two")]
        #expect(GlobalResultSection.grouped(rows).map(\.id) == rows.map(\.id))
    }
}

/// #5: a hand scroll keeps the highlighted row in view.
@MainActor
@Suite("Result sheet polish: highlight in view")
struct HighlightInViewTests {
    private func model(rows count: Int) -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Calculator", bundleID: "com.apple.calculator")
        model.rows = (0..<count).map { .file(URL(fileURLWithPath: "/tmp/f\($0)")) }
        return model
    }

    @Test func scrolledPastTheHighlightItMovesToTheTopRowInView() {
        let model = model(rows: 20)
        model.focusedMenuIndex = 1
        model.keepFocusInView(topItemID: model.rows[8].id, slots: 5)
        #expect(model.focusedMenuIndex == 8)
    }

    @Test func scrolledAboveTheHighlightItMovesToTheLastRowInView() {
        let model = model(rows: 20)
        model.focusedMenuIndex = 15
        model.keepFocusInView(topItemID: model.rows[2].id, slots: 5)
        #expect(model.focusedMenuIndex == 6)
    }

    @Test func aHighlightInViewStays() {
        let model = model(rows: 20)
        model.focusedMenuIndex = 4
        model.keepFocusInView(topItemID: model.rows[2].id, slots: 5)
        #expect(model.focusedMenuIndex == 4)
    }
}

/// #3: a tool's row never shows its internal "cli://" id.
@Suite("Result sheet polish: tool subtitle")
struct ToolSubtitleTests {
    @Test func aToolSaysWhatItIsNotItsScopeID() {
        let doc = GlobalSearchService.SearchDocument(
            id: "cli://tailscale", title: "tailscale", subtitle: "cli://tailscale", bundleId: "",
            filePath: nil, normalizedTitle: "tailscale", titleWords: ["tailscale"],
            acronym: "t", aliases: [], aliasWords: [], sourceKind: .installed,
            rankingBoost: 0, icon: nil, usageTrackingKey: "cli://tailscale",
            action: .cliScope(command: "tailscale", displayName: "tailscale"))
        #expect(!GlobalContextRow.subtitle(for: doc).contains("cli://"))
    }
}
