// Context-DockTests/CornerAppPinsTests.swift
//
// Pins in an app's Context Dock (00-NOW task 4b). Any row in the app's list and any tab can
// be pinned for that app; its pins lead the bar beside the field, ahead of the live tabs; a
// pinned destructive command still asks; the pins are never the ones cut for room.
//
// Every model here gets its own pin store in a temporary file and injected tab, page and
// menu hooks: the test host shares the developer's Application Support, and nothing here
// may touch their pins or script their Safari.

import AppKit
import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

@Suite("Corner app pins")
@MainActor
struct CornerAppPinsTests {

    private func temporaryStore() -> (DockPinStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-pins-\(UUID().uuidString).json")
        return (DockPinStore(fileURL: url), url)
    }

    private let tabs = [
        SafariTab(title: "Inbox", url: "https://mail.google.com/mail/u/0/", windowIndex: 1, tabIndex: 1),
        SafariTab(title: "Pull requests", url: "https://github.com/pulls", windowIndex: 1, tabIndex: 2),
    ]

    private func scope(
        _ store: DockPinStore, bundleID: String = "com.apple.Safari", name: String = "Safari",
        switched: ((SafariTab) -> Void)? = nil, opened: ((URL) -> Void)? = nil
    ) -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        let source = tabs
        model.dockPins = store
        model.tabSource = { source }
        model.refreshTabCache = { _ in }
        model.currentTabURL = { nil }
        model.switchTab = { switched?($0) }
        model.openPage = { url, _ in opened?(url) }
        model.summon(app: name, bundleID: bundleID)
        return model
    }

    private func menuRow(_ path: [String]) -> AppChatRow {
        .command(AXMenuItem(
            title: path.last ?? "", path: path, isEnabled: true,
            element: AXUIElementCreateSystemWide(), children: []))
    }

    // MARK: Store

    @Test("Pins belong to one app; another app and Global never see them")
    func pinsArePerApp() {
        let (store, _) = temporaryStore()
        store.pin(.menuCommand(path: ["File", "Export as PDF…"]), title: "Export as PDF…",
            app: "com.apple.Safari")
        store.pin(.tab(url: "https://github.com/pulls"), title: "Pull requests",
            app: "com.apple.Safari")
        store.pin(.menuCommand(path: ["Format", "Make Plain Text"]), title: "Make Plain Text",
            app: "com.apple.TextEdit")

        #expect(store.pins(forApp: "com.apple.Safari").map(\.title)
            == ["Export as PDF…", "Pull requests"])
        #expect(store.pins(forApp: "com.apple.TextEdit").map(\.title) == ["Make Plain Text"])
        #expect(store.pins.isEmpty, "an app's pin leaked into Global")
        // The same kind in the same app is one pin; in another app it is another pin.
        #expect(store.pin(.tab(url: "https://github.com/pulls"), title: "x",
            app: "com.apple.Safari") == nil)
        #expect(store.pin(.tab(url: "https://github.com/pulls"), title: "x",
            app: "com.apple.TextEdit") != nil)
    }

    @Test("Unpinning renumbers the app's own pins and leaves the others alone")
    func unpinRenumbersWithinTheApp() {
        let (store, _) = temporaryStore()
        let a = store.pin(.appAction(id: "a"), title: "A", app: "com.apple.Safari")!
        store.pin(.appAction(id: "b"), title: "B", app: "com.apple.Safari")
        store.pin(.appAction(id: "c"), title: "C", app: "com.apple.Safari")
        store.pin(.appAction(id: "z"), title: "Z", app: "com.apple.TextEdit")
        store.unpin(a.id)
        #expect(store.pins(forApp: "com.apple.Safari").map(\.title) == ["B", "C"])
        #expect(store.pins(forApp: "com.apple.Safari").map(\.order) == [0, 1])
        #expect(store.pins(forApp: "com.apple.TextEdit").map(\.order) == [0])
    }

    @Test("A drop back on the strip moves the pin to the end of its own app's pins")
    func moveToEndStaysInTheGroup() {
        let (store, _) = temporaryStore()
        let a = store.pin(.appAction(id: "a"), title: "A", app: "com.apple.Safari")!
        store.pin(.appAction(id: "b"), title: "B", app: "com.apple.Safari")
        store.pin(.app(bundleID: "com.apple.Mail"), title: "Mail")
        store.moveToEnd(a.id)
        #expect(store.pins(forApp: "com.apple.Safari").map(\.title) == ["B", "A"])
        #expect(store.pins.map(\.title) == ["Mail"])
    }

    @Test("One file: app pins and Global pins reload together, and old pins stay Global")
    func oneStoreOneFile() throws {
        let (store, url) = temporaryStore()
        store.pin(.app(bundleID: "com.apple.Mail"), title: "Mail")
        store.pin(.tab(url: "https://github.com/pulls"), title: "PRs", app: "com.apple.Safari")
        ContextDockStore.shared.flushNow()  // writes are debounced 300 ms
        let reloaded = DockPinStore(fileURL: url)
        #expect(reloaded.pins.map(\.title) == ["Mail"])
        #expect(reloaded.pins(forApp: "com.apple.Safari").map(\.title) == ["PRs"])

        // A pin saved before per-app pins existed has no appBundleID: it is Global's.
        let legacy = """
            [{"id":"\(UUID().uuidString)","kind":{"folder":{"path":"/tmp"}},"title":"tmp","order":0}]
            """
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-pins-legacy-\(UUID().uuidString).json")
        try Data(legacy.utf8).write(to: legacyURL)
        let old = DockPinStore(fileURL: legacyURL)
        #expect(old.pins.map(\.title) == ["tmp"])
        #expect(old.appPins.isEmpty)
    }

    // MARK: Pinning from the list and the tabs

    @Test("A menu command in the app's list pins for that app, and unpins again")
    func aListRowPinsForTheApp() {
        let (store, _) = temporaryStore()
        let model = scope(store)
        let row = menuRow(["File", "Export as PDF…"])
        #expect(model.canPinToApp(row))
        model.toggleAppPin(row)
        #expect(model.isPinnedToApp(row))
        #expect(store.pins(forApp: "com.apple.Safari").map(\.kind)
            == [.menuCommand(path: ["File", "Export as PDF…"])])
        model.toggleAppPin(row)
        #expect(!model.isPinnedToApp(row))
        #expect(store.appPins.isEmpty)
    }

    @Test("Global Context is not an app: its rows keep the Global pin, not an app pin")
    func globalRowsDoNotPinToAnApp() {
        let (store, _) = temporaryStore()
        let model = scope(store, bundleID: "", name: AppChatPromptModel.globalScopeName)
        #expect(!model.canPinToApp(menuRow(["File", "Export as PDF…"])))
    }

    @Test("A pinned tab leaves the live tabs and leads the bar as a pin")
    func aPinnedTabLeadsTheBar() {
        let (store, _) = temporaryStore()
        let model = scope(store)
        let prs = model.stripIcons.first { $0.title == "Pull requests" }!
        model.toggleTabPin(iconID: prs.id)
        // The pin is the bar's first icon — in the strip and in the field's pill alike —
        // and the tab it stands for is not drawn a second time among the live ones.
        #expect(model.stripIcons.map(\.title) == ["Pull requests", "Inbox"])
        #expect(model.globalMatchIcons.map(\.title) == ["Pull requests", "Inbox"])
        #expect(model.isAppPinIcon(model.stripIcons[0].id))
        #expect(!model.isTabIcon(model.stripIcons[0].id))
        // Never Global's pins in an app's bar.
        #expect(model.stripPins.isEmpty)
    }

    // MARK: Order and room

    @Test("The app's pins lead its bar, in pin order, before the live tabs")
    func pinsLeadTheTabs() {
        let (store, _) = temporaryStore()
        let model = scope(store)
        store.pin(.appAction(id: "b"), title: "B", app: "com.apple.Safari")
        store.pin(.menuCommand(path: ["File", "Export as PDF…"]), title: "Export as PDF…",
            app: "com.apple.Safari")
        model.updateTabStrip()
        #expect(model.stripIcons.map(\.title) == ["B", "Export as PDF…", "Inbox", "Pull requests"])
        // Each pin draws as something — its own image or a symbol, never an empty slot.
        #expect(model.stripIcons.prefix(2).allSatisfy { $0.icon.size.width > 0 })
    }

    @Test("A click on a pin in the bar runs that pin")
    func aPinIconRunsItsPin() {
        let (store, _) = temporaryStore()
        var opened: [URL] = []
        let model = scope(store, opened: { opened.append($0) })
        store.pin(.tab(url: "https://forums.swift.org/latest"), title: "Forums",
            app: "com.apple.Safari")
        model.updateTabStrip()
        let icon = model.stripIcons[0]
        let pin = try! #require(model.appPin(forIconID: icon.id))
        model.openAppPin(pin)
        #expect(opened == [URL(string: "https://forums.swift.org/latest")!])
    }

    @Test("Pins are never cut for room: the live tabs overflow into +N instead")
    func pinsNeverOverflow() {
        let (store, _) = temporaryStore()
        let many = (1...80).map {
            SafariTab(title: "Tab \($0)", url: "https://example.com/\($0)", windowIndex: 1, tabIndex: $0)
        }
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.dockPins = store
        model.tabSource = { many }
        model.refreshTabCache = { _ in }
        model.currentTabURL = { nil }
        model.switchTab = { _ in }
        for i in 0..<3 {
            store.pin(.appAction(id: "a\(i)"), title: "A\(i)", app: "com.apple.Safari")
        }
        model.summon(app: "Safari", bundleID: "com.apple.Safari")
        // The field's pill: what fits, cut from the end — the pins are all there.
        #expect(Array(model.globalMatchIcons.prefix(3).map(\.title)) == ["A0", "A1", "A2"])
        #expect(model.globalOverflowCount > 0)
        // The strip: the same, and +N counts only tabs.
        let plan = DockStripPlan.make(running: model.stripIcons, pins: [], tools: 0)
        #expect(Array(plan.composition.apps.prefix(3).map(\.title)) == ["A0", "A1", "A2"])
        #expect(plan.layout.overflow > 0)
    }

    @Test("Any app with pins gets the bar; one without keeps its plain field")
    func pinsGiveAnyAppTheBar() {
        let (store, _) = temporaryStore()
        let textEdit = scope(store, bundleID: "com.apple.TextEdit", name: "TextEdit")
        #expect(!textEdit.showsTabBar)
        store.pin(.menuCommand(path: ["Format", "Make Plain Text"]), title: "Make Plain Text",
            app: "com.apple.TextEdit")
        #expect(textEdit.showsTabBar)
        // No tabs outside Safari: the bar is the pins alone, never Safari's tabs.
        textEdit.updateTabStrip()
        #expect(textEdit.stripIcons.map(\.title) == ["Make Plain Text"])
    }

    // MARK: Running

    @Test("A pinned destructive command still asks, and does not run when refused")
    func aPinnedDestructiveCommandAsks() async {
        let (store, _) = temporaryStore()
        let model = scope(store)
        let pin = store.pin(.menuCommand(path: ["File", "Close Tab"]), title: "Close Tab",
            app: "com.apple.Safari")!
        var asked: [[String]] = []
        var ran: [[String]] = []
        model.askMenuConsent = { path, _, _ in asked.append(path); return false }
        model.performMenuPath = { ran.append($0) }
        model.openAppPin(pin)
        for _ in 0..<20 where asked.isEmpty { await Task.yield() }
        #expect(asked == [["File", "Close Tab"]])
        #expect(ran.isEmpty, "a refused Close Tab ran anyway")

        model.askMenuConsent = { _, _, _ in true }
        model.openAppPin(pin)
        for _ in 0..<20 where ran.isEmpty { await Task.yield() }
        #expect(ran == [["File", "Close Tab"]])
    }

    @Test("The gate asks for destructive and outbound commands, not for harmless ones")
    func whichCommandsAsk() {
        let app = "com.example.corner-app-pins-tests"
        #expect(AppPinRun.menuAsksFirst(path: ["File", "Close Tab"], bundleID: app))
        #expect(AppPinRun.menuAsksFirst(path: ["Message", "Send"], bundleID: app))
        #expect(!AppPinRun.menuAsksFirst(path: ["File", "Export as PDF…"], bundleID: app))
        #expect(!AppPinRun.menuAsksFirst(path: ["History", "Reopen Last Closed Window"], bundleID: app))
    }

    @Test("A pinned tab that is open is shown; one that was closed loads again")
    func pinnedTabsReopen() {
        let (store, _) = temporaryStore()
        var switched: [String] = []
        var opened: [URL] = []
        let model = scope(
            store, switched: { switched.append($0.url) }, opened: { opened.append($0) })
        let open = store.pin(.tab(url: "https://github.com/pulls/"), title: "PRs",
            app: "com.apple.Safari")!
        let closed = store.pin(.tab(url: "https://forums.swift.org/latest"), title: "Forums",
            app: "com.apple.Safari")!
        model.openAppPin(open)
        model.openAppPin(closed)
        #expect(switched == ["https://github.com/pulls"])
        #expect(opened == [URL(string: "https://forums.swift.org/latest")!])
    }

    // MARK: The field's pin button

    @Test("While typing, the pin button pins the matching result; with no match it is keep-open")
    func thePinButtonPinsTheMatch() {
        let (store, _) = temporaryStore()
        let model = scope(store, bundleID: "com.anthropic.claudefordesktop", name: "Claude")
        model.allMenuItems = [AXMenuItem(
            title: "Centre", path: ["Window", "Centre"], isEnabled: true,
            element: AXUIElementCreateSystemWide(), children: [])]
        // Nothing typed: no result to pin — the button is the ordinary keep-open pin.
        model.query = ""
        model.updateMenuMatches()
        #expect(model.pinnableResult == nil)

        model.query = "cen"
        model.updateMenuMatches()
        let row = try! #require(model.pinnableResult)
        #expect(row.title == "Centre")
        #expect(!model.isPinnedToApp(row))
        model.toggleAppPin(row)
        #expect(model.isPinnedToApp(row), "the button's tint reads this")
        #expect(store.pins(forApp: "com.anthropic.claudefordesktop").map(\.kind)
            == [.menuCommand(path: ["Window", "Centre"])])

        // Typed, but nothing matches: back to keep-open.
        model.query = "zzzz-no-such-command"
        model.updateMenuMatches()
        #expect(model.pinnableResult == nil)
    }

    // MARK: One width

    @Test("An app's field grows by its pill, and its result card is exactly as wide")
    func fieldAndCardShareOneWidth() {
        let (store, _) = temporaryStore()
        let model = scope(store, bundleID: "com.anthropic.claudefordesktop", name: "Claude")
        let base = AppChatPromptMetrics.width
        #expect(AppChatPromptMetrics.boardWidth(for: model) == base, "no pins: the base field")

        store.pin(.menuCommand(path: ["Window", "Centre"]), title: "Centre",
            app: "com.anthropic.claudefordesktop")
        store.pin(.menuCommand(path: ["Window", "Fill"]), title: "Fill",
            app: "com.anthropic.claudefordesktop")
        model.updateTabStrip()
        let pill = AppChatPromptMetrics.appBarPillWidth(for: model)
        #expect(pill == AppChatPromptMetrics.appBarPillWidth(icons: 2, divider: false))
        let field = AppChatPromptMetrics.size(
            for: .prompt, suggestions: 0, fitsContent: model.fitsField,
            appBarPillWidth: pill).width
        #expect(field == base + pill + AppChatPromptMetrics.appBarPillSpacing)
        #expect(AppChatListMetrics.size(
            rows: 3, width: AppChatPromptMetrics.boardWidth(for: model)).width == field)
    }

    @Test("Another app in the list (\"saf\" → Safari) pins as that app, and its picture is the app's")
    func anAppSwitchRowPinsAsTheApp() {
        var pill = DockPill(
            id: "corner-app-switch-com.apple.Safari", name: "Safari", icon: "app",
            badge: "Switch", execute: {})
        pill.sourceBundleId = "com.apple.Safari"
        pill.rankingKind = "appSwitch"
        pill.menuItemImage = NSImage(size: NSSize(width: 16, height: 16))
        #expect(DockPinKind(appRow: .dock(pill)) == .app(bundleID: "com.apple.Safari"))

        let (store, _) = temporaryStore()
        let model = scope(store, bundleID: "com.anthropic.claudefordesktop", name: "Claude")
        #expect(model.canPinToApp(.dock(pill)))
        #expect(model.resultPinArt(.dock(pill)).image != nil)
        // A quit row is not something to pin.
        var quit = pill
        quit.rankingKind = "runningAppQuit"
        #expect(DockPinKind(appRow: .dock(quit)) == nil)
    }

    // MARK: Hover and order

    @Test("Resting on the pill opens the big bar, even with keep-open on; typed text keeps the field")
    func hoverOnThePillOpensTheBigBar() {
        let (store, _) = temporaryStore()
        let model = scope(store)
        model.set(.prompt)
        #expect(model.expandAppBar())
        #expect(model.phase == .dock)

        let typing = scope(store)
        typing.set(.prompt)
        typing.query = "export"
        #expect(!typing.expandAppBar())
        #expect(typing.phase == .prompt)
    }

    @Test("Opening a tab does not move it: the bar keeps Safari's own order")
    func tabsKeepTheirPlace() {
        let (store, _) = temporaryStore()
        let model = scope(store)
        // Safari is showing the second tab — it must not jump to the front.
        model.currentTabURL = { "https://github.com/pulls" }
        model.updateTabStrip()
        #expect(model.stripIcons.map(\.title) == ["Inbox", "Pull requests"])
    }

    @Test("A click on the big bar does not open the field: a list refresh leaves the dock alone")
    func aListRefreshLeavesTheDock() {
        let (store, _) = temporaryStore()
        let model = scope(store)
        model.set(.prompt)
        #expect(model.expandAppBar())
        // What a tab switch sets off: the tabs re-read, the menu read lands.
        model.refreshTabs()
        model.updateMenuMatches()
        model.syncListPhase()
        #expect(model.phase == .dock)
    }
}
