// Context-DockTests/CornerSafariTabsTests.swift
//
// Safari's open tabs in the Corner's Safari scope (inventory D13): pills beside the field,
// like the Dock's tab strip — the field sizes itself for them and the rest are "+N". From the
// loader the Dock uses (`SafariTabManager`) through the shared `BrowserTabList`.
//
// Nothing here depends on Safari running: the tab source, refresh, capacity and switch are all
// injected. (The first version read the scope's rows only after a running-app check, and so
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

    private func safariScope(
        capacity: Int = 10, tabs: [SafariTab]? = nil, switched: ((SafariTab) -> Void)? = nil,
        bundleID: String = "com.apple.Safari", name: String = "Safari"
    ) -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        let source = tabs ?? self.tabs
        model.tabSource = { source }
        model.refreshTabCache = { _ in }
        model.tabCapacity = { capacity }
        model.currentTabURL = { nil }
        model.switchTab = { switched?($0) }
        model.summon(app: name, bundleID: bundleID)
        return model
    }

    @Test("The Safari scope shows the open tabs as pills beside the field, in order")
    func theSafariScopeShowsTabPills() {
        let model = safariScope()
        #expect(model.tabIcons.map(\.title) == ["Inbox", "Pull requests", "Swift Forums"])
        #expect(model.tabOverflowCount == 0)
        // Pills, not rows: the list is the app's own commands.
        #expect(!model.rows.contains {
            if case .dock(let pill) = $0 { return pill.id.hasPrefix("safari-tab:") }
            return false
        })
        // The field is sized for the tabs and its own chip and buttons, not the running apps.
        #expect(model.promptIconCount == 3 + AppChatPromptMetrics.appFieldChromeSlots)
    }

    @Test("More tabs than fit: the strip shows what fits and the rest are +N")
    func overflowGoesToPlusN() {
        let many = (1...9).map {
            SafariTab(title: "Tab \($0)", url: "https://example.com/\($0)", windowIndex: 1, tabIndex: $0)
        }
        let model = safariScope(capacity: 5, tabs: many)
        #expect(model.tabIcons.count == 4)
        #expect(model.tabOverflowCount == 5)
        #expect(BrowserTabList.strip(many, capacity: 9).overflow == 0)
        #expect(BrowserTabList.strip(many, capacity: 0).shown.isEmpty)
        // The app field's chrome comes out of the room first, so its text is never crushed.
        #expect(AppChatPromptMetrics.tabCapacity(maximumWidth: 900)
            == AppChatPromptMetrics.matchIconCapacity(maximumWidth: 900)
                - AppChatPromptMetrics.appFieldChromeSlots)
    }

    @Test("Typing narrows the tab pills by title, site or address")
    func typingFiltersTabs() {
        let model = safariScope()
        model.query = "swift"
        model.updateMenuMatches()
        #expect(model.tabIcons.map(\.title) == ["Swift Forums"])
        #expect(BrowserTabList.matching(tabs, query: "github pull").map(\.title) == ["Pull requests"])
        model.query = "nothing-like-this"
        model.updateMenuMatches()
        #expect(model.tabIcons.isEmpty && model.tabOverflowCount == 0)
    }

    @Test("Choosing a tab pill switches Safari to that tab")
    func aTabPillSwitches() {
        var switched: [String] = []
        let model = safariScope(switched: { switched.append($0.title) })
        model.openTabIcon(model.tabIcons[2])
        #expect(switched == ["Swift Forums"])
    }

    @Test("The current page's tab comes first")
    func currentTabFirst() {
        let ordered = BrowserTabList.ordered(tabs, currentURL: "https://forums.swift.org/latest#top")
        #expect(ordered.first?.title == "Swift Forums")
        #expect(BrowserTabList.normalizedURLKey("https://A.com/x/#frag") == "https://a.com/x")
    }

    @Test("Other apps and other browsers show no tab pills")
    func onlySafariShowsTabs() {
        let chrome = safariScope(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(chrome.tabIcons.isEmpty)
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
