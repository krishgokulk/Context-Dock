// Context-DockTests/CornerSafariTabsTests.swift
//
// Safari's open tabs in its Context Dock (inventory D13; owner 2026-09-25). An app scope has
// the app bar only once the user has pinned something for that app (owner 2026-11-03, "compact
// pill for unpinned app scopes"); then the field folds away at rest into a bar of the app's own
// things — its pins, then its open tabs, never Global's pins — the way Global Context folds into
// its running apps, and expands back; "+N" for the rest. Without a pin the scope is the compact
// pill: no bar, no dock height, no fold, the running apps in its strip, and Safari's tabs live
// in the chat sheet. From the loader the Dock uses (`SafariTabManager`) through the shared
// `BrowserTabList`.
//
// The `scope()` helper pins one thing for the app by default, which is what gives it the bar;
// `pinned: false` is the compact pill.
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
        bundleID: String = "com.apple.Safari", name: String = "Safari", pinned: Bool = true
    ) -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        // Its own pins: the test host shares the developer's, and a Safari pin of theirs
        // would put something in this bar that the tests did not.
        let store = DockPinStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-pins-\(UUID().uuidString).json"))
        // The bar exists only for an app with a pin (owner 2026-11-03).
        if pinned { store.pin(.appAction(id: "bar"), title: "Pinned", app: bundleID) }
        model.dockPins = store
        let source = tabs ?? self.tabs
        model.tabSource = { source }
        model.refreshTabCache = { _ in }
        model.currentTabURL = { nil }
        model.switchTab = { switched?($0) }
        model.summon(app: name, bundleID: bundleID)
        return model
    }

    @Test("Safari's Context Dock folds into the big bar at rest and opens into the compact field")
    func theSafariScopeFoldsAndOpensCompact() {
        // Owner 2026-09-26: idle it is a big bar of pins and tabs, like Global's running
        // apps; open it is the compact field — fitted, never the bar's width.
        let model = scope()
        #expect(model.showsTabBar && model.usesDockShell && model.fitsField)
        // Open, every field is the Dock's input bar height (owner 2026-10-05).
        #expect(AppChatPromptMetrics.fieldHeight(global: model.usesDockHeight)
            == AppChatPromptMetrics.inputHeight)
        #expect(model.canRestAsDock == model.autoShrinkEnabled())
        // Guarded on "keep open": the test host reads the developer's own setting.
        if model.autoShrinkEnabled(), !model.isPinned {
            model.set(.prompt)
            #expect(model.foldToDock())
            #expect(model.phase == .dock)
        }
        // Open, the field is the shell's one width (#189) — the bar's own width at rest too.
        let open = AppChatPromptMetrics.shellSize(for: model, phase: .prompt).width
        #expect(open == AppChatPromptMetrics.boardWidth(for: model))
        // At rest the bar fits its icons, never wider than the field it opens into.
        #expect(AppChatPromptMetrics.shellSize(for: model, phase: .dock).width <= open)
        #expect(open == DockShellWidth.current)
    }

    @Test("Without a pin Safari is the compact pill: no bar, no dock, no fold, the running apps in the strip")
    func anUnpinnedSafariIsTheCompactPill() {
        let model = scope(pinned: false)
        #expect(!model.showsTabBar && !model.usesDockShell && !model.usesDockHeight)
        #expect(!model.canRestAsDock)
        model.set(.prompt)
        #expect(!model.foldToDock())
        #expect(model.phase == .prompt)
        // Safari's tabs are in the chat sheet, never icons beside the input.
        #expect(!model.stripIcons.contains { model.isTabIcon($0.id) })
        #expect(!model.globalMatchIcons.contains { model.isTabIcon($0.id) })
        #expect(model.stripIcons.map(\.title) == ["Finder"])
    }

    @Test("With a pin, the bar leads with the pin and then the open tabs, all of them, in order")
    func theTabsAreTheStripIcons() {
        let model = scope()
        #expect(model.stripIcons.map(\.title) == ["Pinned", "Inbox", "Pull requests", "Swift Forums"])
        #expect(model.globalMatchIcons.map(\.title)
            == ["Pinned", "Inbox", "Pull requests", "Swift Forums"])
        #expect(model.stripIcons.dropFirst().allSatisfy { model.isTabIcon($0.id) })
        // Pills, not rows: the list is the app's own commands.
        #expect(!model.rows.contains {
            if case .dock(let pill) = $0 { return pill.id.hasPrefix("safari-tab:") }
            return false
        })
    }

    @Test("The bar is the app's own: no Global pins, no Global tools")
    func theBarIsTheAppsOwn() {
        let model = scope()
        model.shelfVisible = { true }
        #expect(model.stripPins.isEmpty)
        // The clipboard (for a copy's few seconds), the selection (while there is one) and
        // the last action's result (owner 2026-10-12: a quit shows on every bar) join it,
        // then the Drop Shelf, which every row ends with.
        let selected = model.selection != nil ? 1 : 0
        #expect(model.dockToolCount(clipboardVisible: true, feedbackVisible: true) == 1 + selected + 1 + 1)
        #expect(model.dockToolCount(clipboardVisible: false, feedbackVisible: true) == selected + 1 + 1)
        let chrome = scope(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(chrome.stripPins.count == chrome.dockPins.pins.count)
    }

    @Test("The field keeps room for a few icons; the rest scroll inside the pill")
    func theRestScroll() {
        let many = (1...60).map {
            SafariTab(title: "Tab \($0)", url: "https://example.com/\($0)", windowIndex: 1, tabIndex: $0)
        }
        let model = scope(tabs: many)
        // The room: a compact few, whatever the screen.
        #expect(model.globalMatchIcons.count == AppChatPromptModel.appBarVisibleIcons)
        // The content: the pin and every tab, which the pill scrolls through.
        #expect(model.allRunningIcons.count == 61)
        #expect(model.stripIcons.count == 61)
        // The field keeps room for the Safari chip as well as the pill.
        #expect(model.promptIconCount
            == model.globalMatchIcons.count + AppChatPromptMetrics.appFieldChromeSlots)
    }

    @Test("Choosing a tab, in the strip or the pill, switches Safari to it")
    func aTabSwitches() throws {
        var switched: [String] = []
        let model = scope(switched: { switched.append($0.title) })
        let icon = try #require(model.globalMatchIcons.first { $0.title == "Swift Forums" })
        model.openGlobalMatchIcon(icon)
        #expect(switched == ["Swift Forums"])
    }

    @Test("The current page's tab comes first")
    func currentTabFirst() {
        let ordered = BrowserTabList.ordered(tabs, currentURL: "https://forums.swift.org/latest#top")
        #expect(ordered.first?.title == "Swift Forums")
        #expect(BrowserTabList.normalizedURLKey("https://A.com/x/#frag") == "https://a.com/x")
        #expect(BrowserTabList.matching(tabs, query: "github pull").map(\.title) == ["Pull requests"])
    }

    @Test("Other browsers have the app's bar once pinned, but show no tabs")
    func onlySafariShowsTabs() {
        let chrome = scope(bundleID: "com.google.Chrome", name: "Google Chrome")
        // A pinned app's Context Dock has the bar (owner 2026-11-03); Chrome's holds no tabs.
        #expect(chrome.showsTabBar && chrome.usesDockShell)
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

    @Test("A pinned app's Context Dock is Global's height; an unpinned one is the compact pill")
    func contextDockHeightAndFit() {
        let textEdit = scope(bundleID: "com.apple.TextEdit", name: "TextEdit")
        // A pinned app's Context Dock rests as a dock (owner 2026-10-08, pins only since
        // 2026-11-03); Finder's file search does not.
        #expect(textEdit.usesDockHeight && textEdit.usesDockShell)
        // Finder too once pinned: in front it rests and folds like any app's.
        let finder = scope(bundleID: "com.apple.finder", name: "Finder")
        #expect(finder.usesDockHeight && finder.usesDockShell)
        // Unpinned, either is the compact pill (owner 2026-11-03).
        let bare = scope(bundleID: "com.apple.TextEdit", name: "TextEdit", pinned: false)
        #expect(!bare.usesDockHeight && !bare.usesDockShell)
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

    @Test("Typing hides the pill but keeps its icons loaded, so clearing the text brings it straight back")
    func typingKeepsTheTabsLoaded() {
        let model = scope()
        model.query = "summarise this"
        model.queryChanged()
        #expect(model.globalMatchIcons.map(\.title)
            == ["Pinned", "Inbox", "Pull requests", "Swift Forums"])
        #expect(AppChatPromptMetrics.appFieldTrailingReserve(typed: true)
            > AppChatPromptMetrics.appFieldTrailingReserve(typed: false))
    }

    @Test("Safari tabs remain tabs on strip click, and pinned non-running apps remain explicit launches")
    func safariTabsRemainTabsAndOfflinePinsRemainExplicitLaunches() throws {
        var switched: [String] = []
        let model = scope(switched: { switched.append($0.title) })
        let tabIcon = try #require(model.stripIcons.first { $0.title == "Inbox" })
        let tabSlot = DockAppSlot(
            bundleID: tabIcon.id,
            title: tabIcon.title,
            pin: nil,
            running: tabIcon,
            isRunning: false)

        #expect(model.stripClickIntent(for: tabSlot) == .openTab(tabIcon))
        model.handleStripClick(tabSlot)
        #expect(switched == ["Inbox"])
        #expect(model.appBundleID == "com.apple.Safari")

        let offlinePin = DockPin(
            id: UUID(), kind: .app(bundleID: "com.example.offline-app"), title: "OfflineApp",
            order: 0, documentID: nil)
        let offlineSlot = DockAppSlot(
            bundleID: "com.example.offline-app",
            title: "OfflineApp",
            pin: offlinePin,
            running: nil,
            isRunning: false)
        #expect(
            model.stripClickIntent(for: offlineSlot)
                == .openApplication(bundleID: "com.example.offline-app", name: "OfflineApp"))
    }
}

