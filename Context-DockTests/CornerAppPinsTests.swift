// Context-DockTests/CornerAppPinsTests.swift
//
// Pins in an app's Context Dock (00-NOW task 4b). Any row in the app's list and any tab can
// be pinned for that app; its pins lead the bar beside the field, ahead of the live tabs; a
// pinned destructive command still asks; the pins are never the ones cut for room.
//
// Every model here gets its own pin store in a temporary file and injected tab, page and
// menu hooks: the test host shares the developer's Application Support, and nothing here
// may touch their pins or script their Safari.

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
        model.pinStore = store
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
        #expect(model.stripPins.map(\.kind) == [.tab(url: "https://github.com/pulls")])
        #expect(model.stripIcons.map(\.title) == ["Inbox"], "the pinned tab is drawn twice")
        #expect(model.stripPinsLead)
    }

    // MARK: Order and room

    @Test("An app's pins come before its live tabs, and the geometry agrees")
    func pinsLeadTheTabs() {
        let (store, _) = temporaryStore()
        let pin = store.pin(.appAction(id: "a"), title: "A", app: "com.apple.Safari")!
        let running = tabs.map(BrowserTabList.icon(for:))
        let plan = DockStripPlan.make(
            running: running, pins: store.pins(forApp: "com.apple.Safari"),
            runningBundleIDs: [], tools: 0, pinsLead: true)
        let pinCentre = plan.iconCenterOffset(for: .pin(id: pin.id))
        let firstTab = plan.iconCenterOffset(for: .app(bundleID: running[0].bundleID!))
        #expect(pinCentre != nil && firstTab != nil)
        #expect(pinCentre! < firstTab!, "the pin should draw before the tabs")
        // The first tab sits exactly one leading-pins span further along than it would with
        // no pins in front of it.
        let bare = DockStripPlan.make(
            running: running, pins: [], runningBundleIDs: [], tools: 0, pinsLead: true)
        let bareFirst = bare.iconCenterOffset(for: .app(bundleID: running[0].bundleID!))!
        #expect(abs(firstTab! - bareFirst
            - plan.composition.leadingPinsSpan
            - (plan.layout.appSpread - bare.layout.appSpread)) < 0.5)
    }

    @Test("Pins are never cut for room: the live tabs overflow into +N instead")
    func pinsNeverOverflow() {
        let (store, _) = temporaryStore()
        for i in 0..<3 {
            store.pin(.appAction(id: "a\(i)"), title: "A\(i)", app: "com.apple.Safari")
        }
        let many = (1...80).map {
            BrowserTabList.icon(for: SafariTab(
                title: "Tab \($0)", url: "https://example.com/\($0)", windowIndex: 1, tabIndex: $0))
        }
        let plan = DockStripPlan.make(
            running: many, pins: store.pins(forApp: "com.apple.Safari"),
            runningBundleIDs: [], tools: 0, pinsLead: true)
        #expect(plan.composition.otherPins.count == 3)
        #expect(plan.layout.overflow > 0)
        #expect(plan.composition.apps.count + plan.layout.overflow == 80)
    }

    @Test("Any app with pins gets the bar; one without keeps its plain field")
    func pinsGiveAnyAppTheBar() {
        let (store, _) = temporaryStore()
        let textEdit = scope(store, bundleID: "com.apple.TextEdit", name: "TextEdit")
        #expect(!textEdit.showsTabBar)
        store.pin(.menuCommand(path: ["Format", "Make Plain Text"]), title: "Make Plain Text",
            app: "com.apple.TextEdit")
        #expect(textEdit.showsTabBar)
        #expect(textEdit.stripPins.count == 1)
        // No tabs outside Safari: the bar is the pins alone, never Safari's tabs.
        textEdit.updateTabStrip()
        #expect(textEdit.stripIcons.isEmpty)
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
}
