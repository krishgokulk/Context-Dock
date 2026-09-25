// Context-DockTests/CornerSafariTabsTests.swift
//
// Safari's open tabs in the Corner's Safari scope (inventory D13), from the loader the Dock
// uses (`SafariTabManager`) through the shared `BrowserTabList`.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Corner Safari tabs")
@MainActor
struct CornerSafariTabsTests {
    private let tabs = [
        SafariTab(title: "Pull requests", url: "https://github.com/pulls", windowIndex: 1, tabIndex: 2),
        SafariTab(title: "Inbox", url: "https://mail.google.com/mail/u/0/", windowIndex: 1, tabIndex: 1),
        SafariTab(title: "Swift Forums", url: "https://forums.swift.org/latest", windowIndex: 2, tabIndex: 1),
    ]

    private func safariScope() -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.tabSource = { self.tabs }
        model.refreshTabCache = { _ in }
        model.summon(app: "Safari", bundleID: "com.apple.Safari")
        return model
    }

    private func tabTitles(_ model: AppChatPromptModel) -> [String] {
        model.rows.compactMap { row -> String? in
            guard case .dock(let pill) = row, pill.id.hasPrefix("safari-tab:") else { return nil }
            return pill.name
        }
    }

    @Test("The Corner's Safari scope lists the open tabs from the shared loader, in order")
    func theSafariScopeListsTabs() {
        let model = safariScope()
        #expect(tabTitles(model) == ["Inbox", "Pull requests", "Swift Forums"])
        guard case .dock(let first) = model.rows.first else {
            Issue.record("tabs lead the list")
            return
        }
        #expect(first.id.hasPrefix("safari-tab:"))
    }

    @Test("Typing filters the tabs by title, site or address")
    func typingFiltersTabs() {
        let model = safariScope()
        model.query = "swift"
        model.updateMenuMatches()
        #expect(tabTitles(model) == ["Swift Forums"])
        #expect(BrowserTabList.matching(tabs, query: "github pull").map(\.title) == ["Pull requests"])
        #expect(BrowserTabList.matching(tabs, query: "nothing-like-this").isEmpty)
    }

    @Test("The current page's tab comes first")
    func currentTabFirst() {
        let ordered = BrowserTabList.ordered(tabs, currentURL: "https://forums.swift.org/latest#top")
        #expect(ordered.first?.title == "Swift Forums")
        #expect(BrowserTabList.normalizedURLKey("https://A.com/x/#frag") == "https://a.com/x")
    }

    @Test("Other apps and other browsers list no tabs")
    func onlySafariListsTabs() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.tabSource = { self.tabs }
        model.refreshTabCache = { _ in }
        model.summon(app: "Google Chrome", bundleID: "com.google.Chrome")
        #expect(tabTitles(model).isEmpty)
        #expect(!BrowserTabList.listsTabs(bundleID: "com.google.Chrome"))
    }

    @Test("The hint says tabs only where tabs are shown")
    func theHintMatchesWhatIsShown() {
        #expect(AppScopeHint.hint(bundleId: "com.apple.Safari", appName: "Safari")
            == "tabs, page cmds, menu cmds")
        #expect(AppScopeHint.hint(bundleId: "com.google.Chrome", appName: "Google Chrome")
            == "page cmds, menu cmds")
    }

    @Test("A tab row switches to its tab and names its site")
    func aTabRowSwitches() {
        let pill = BrowserTabList.pill(for: tabs[0])
        #expect(pill.name == "Pull requests")
        #expect(pill.badge == "github.com")
        #expect(pill.resolvedURL?.absoluteString == "https://github.com/pulls")
    }
}
