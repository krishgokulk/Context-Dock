// Context-DockTests/CornerSafariTabsTests.swift
//
// Safari's open tabs in its Context Dock (inventory D13; owner 2026-09-25): the field folds
// away at rest into a bar of the app's own things — its open tabs, never Global's pins — the
// way Global Context folds into its running apps, and expands back; "+N" for the rest. From the loader
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
        // Its own pins: the test host shares the developer's, and a Safari pin of theirs
        // would put something in this bar that the tests did not.
        model.dockPins = DockPinStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-pins-\(UUID().uuidString).json"))
        let source = tabs ?? self.tabs
        model.tabSource = { source }
        model.refreshTabCache = { _ in }
        model.currentTabURL = { nil }
        model.switchTab = { switched?($0) }
        model.summon(app: name, bundleID: bundleID)
        return model
    }

    @Test("Safari's Context Dock uses the Global shell: its height, and it folds away at rest")
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

    @Test("The open tabs are the bar's icons, all of them, in order")
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

    @Test("The bar is the app's own: no Global pins, no Global tools")
    func theBarIsTheAppsOwn() {
        let model = scope()
        #expect(model.stripPins.isEmpty)
        #expect(model.dockToolCount(clipboardVisible: true, feedbackVisible: true) == 0)
        let chrome = scope(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(chrome.stripPins.count == chrome.dockPins.pins.count)
    }

    @Test("The field's pill holds what fits; the rest are +N")
    func overflowGoesToPlusN() {
        let many = (1...60).map {
            SafariTab(title: "Tab \($0)", url: "https://example.com/\($0)", windowIndex: 1, tabIndex: $0)
        }
        let model = scope(tabs: many)
        let capacity = AppChatPromptMetrics.matchIconCapacity(maximumWidth: DockStripPlan.screenBudget)
            - AppChatPromptMetrics.appFieldChromeSlots
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

    @Test("Every app's Context Dock is Global's height; without tabs it fits its field")
    func contextDockHeightAndFit() {
        let textEdit = scope(bundleID: "com.apple.TextEdit", name: "TextEdit")
        #expect(textEdit.usesDockHeight && !textEdit.usesDockShell)
        // Finder too, desktop-only mode included: one bar for every app (owner 2026-09-25).
        let finder = scope(bundleID: "com.apple.finder", name: "Finder")
        #expect(finder.usesDockHeight && !finder.usesDockShell)
        let fitted = AppChatPromptMetrics.size(
            for: .prompt, suggestions: 0, running: 12, pinned: 3,
            fieldHeight: AppChatPromptMetrics.dockHeight, fitsContent: true)
        #expect(fitted.width == AppChatPromptMetrics.width)
        #expect(fitted.height == AppChatPromptMetrics.dockHeight)
        // Not fitted, the same counts take the Global strip's width.
        let strip = AppChatPromptMetrics.size(
            for: .prompt, suggestions: 0, running: 12, pinned: 3,
            fieldHeight: AppChatPromptMetrics.dockHeight)
        #expect(strip.width > fitted.width)
    }

    @Test("Typing keeps the tabs, and their pill ends before the field's + and send")
    func typingKeepsTheTabs() {
        let model = scope()
        model.query = "summarise this"
        model.queryChanged()
        #expect(model.globalMatchIcons.map(\.title) == ["Inbox", "Pull requests", "Swift Forums"])
        #expect(AppChatPromptMetrics.appFieldTrailingReserve(typed: true)
            > AppChatPromptMetrics.appFieldTrailingReserve(typed: false))
    }
}

