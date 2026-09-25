// Context-DockTests/CornerSafariTabsTests.swift
//
// Safari's open tabs in the Corner's Safari scope (inventory D13), exactly like Global
// Context's running apps (owner 2026-09-25): the same shell and height, a strip of big tab
// icons at rest that folds into a small pill in the field, "+N" for the rest. From the loader
// the Dock uses (`SafariTabManager`) through the shared `BrowserTabList`.
//
// Nothing here depends on Safari running: the tab source, refresh and switch are injected. (The first version read the scope's rows only after a running-app check, and so
// passed on a Mac with Safari open and failed on CI.)

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

    private func scope(
        tabs: [SafariTab]? = nil, switched: ((SafariTab) -> Void)? = nil,
        bundleID: String = "com.apple.Safari", name: String = "Safari"
    ) -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        let source = tabs ?? self.tabs
        model.tabSource = { source }
        model.refreshTabCache = { _ in }
        model.currentTabURL = { nil }
        model.switchTab = { switched?($0) }
        model.summon(app: name, bundleID: bundleID)
        return model
    }

    @Test("A Safari scope uses Global Context's shell: its height, and it rests as a dock")
    func theSafariScopeUsesTheGlobalShell() {
        let model = scope()
        #expect(model.showsTabBar && model.usesDockShell && model.showsFieldPills)
        #expect(AppChatPromptMetrics.fieldHeight(global: model.usesDockShell)
            == AppChatPromptMetrics.dockHeight)
        #expect(model.canRestAsDock == model.autoShrinkEnabled())
        // At rest it folds into the dock of tabs, as Global does, rather than the app badge.
        if model.autoShrinkEnabled() {
            model.set(.prompt)
            #expect(model.foldToDock())
            #expect(model.phase == .dock)
        }
    }

    @Test("The tabs take the running apps' place: all of them in the strip, in order")
    func theTabsAreTheStripIcons() {
        let model = scope()
        #expect(model.stripIcons.map(\.title) == ["Inbox", "Pull requests", "Swift Forums"])
        #expect(model.globalMatchIcons.map(\.title) == ["Inbox", "Pull requests", "Swift Forums"])
        #expect(!model.stripIcons.map(\.id).contains { !model.isTabIcon($0) })
        // Pills, not rows: the list is the app's own commands.
        #expect(!model.rows.contains {
            if case .dock(let pill) = $0 { return pill.id.hasPrefix("safari-tab:") }
            return false
        })
    }

    @Test("The field's pill holds what Global's holds; the rest are +N")
    func overflowGoesToPlusN() {
        let many = (1...60).map {
            SafariTab(title: "Tab \($0)", url: "https://example.com/\($0)", windowIndex: 1, tabIndex: $0)
        }
        let model = scope(tabs: many)
        let capacity = AppChatPromptModel.pillFieldCapacity
        #expect(model.globalMatchIcons.count == max(1, capacity))
        #expect(model.globalOverflowCount == 60 - model.globalMatchIcons.count)
        #expect(model.stripIcons.count == 60)
        // The field keeps room for the Safari chip as well as the pill.
        #expect(model.promptIconCount
            == model.globalMatchIcons.count + AppChatPromptMetrics.appFieldChromeSlots)
    }

    @Test("Choosing a tab, in the strip or the pill, switches Safari to it")
    func aTabSwitches() {
        var switched: [String] = []
        let model = scope(switched: { switched.append($0.title) })
        model.openGlobalMatchIcon(model.globalMatchIcons[2])
        #expect(switched == ["Swift Forums"])
    }

    @Test("The current page's tab comes first")
    func currentTabFirst() {
        let ordered = BrowserTabList.ordered(tabs, currentURL: "https://forums.swift.org/latest#top")
        #expect(ordered.first?.title == "Swift Forums")
        #expect(BrowserTabList.normalizedURLKey("https://A.com/x/#frag") == "https://a.com/x")
        #expect(BrowserTabList.matching(tabs, query: "github pull").map(\.title) == ["Pull requests"])
    }

    @Test("Other apps and other browsers keep their own shell and show no tabs")
    func onlySafariShowsTabs() {
        let chrome = scope(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(!chrome.showsTabBar && !chrome.usesDockShell)
        #expect(!chrome.stripIcons.contains { chrome.isTabIcon($0.id) })
        #expect(!BrowserTabList.listsTabs(bundleID: "com.google.Chrome"))
    }

    @Test("The hint says tabs only where tabs are shown")
    func theHintMatchesWhatIsShown() {
        #expect(AppScopeHint.hint(bundleId: "com.apple.Safari", appName: "Safari")
            == "tabs, page cmds, menu cmds")
        #expect(AppScopeHint.hint(bundleId: "com.google.Chrome", appName: "Google Chrome")
            == "page cmds, menu cmds")
    }
}
