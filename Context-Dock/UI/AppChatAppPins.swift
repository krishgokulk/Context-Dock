// AppChatAppPins.swift
// Context-Dock
//
// Pins in an app's Context Dock (00-NOW task 4b; owner 2026-09-25). Any row in the app's
// list — a menu command, an adapter action, an extension, the user's own action — and any
// tab can be pinned for that app. Its pins lead the bar beside the field, before the live
// tabs, and run with one click.
//
// One store: these are `DockPinStore` pins with the app's bundle id on them, saved in the
// same file as Global's. Pinning changes where a command is reached, never how it runs — a
// pinned menu command passes the same consent gate any menu click does, and a pinned action
// runs through AppAdapterManager, where its approval already lives.

import AppKit
import Foundation

extension AppChatPromptModel {

    // MARK: Pinning

    /// Whether a list row can be pinned in this app's Context Dock.
    func canPinToApp(_ row: AppChatRow) -> Bool {
        isAppContextDock && DockPinKind(appRow: row) != nil
    }

    func isPinnedToApp(_ row: AppChatRow) -> Bool {
        guard let kind = DockPinKind(appRow: row) else { return false }
        return dockPins.isPinned(kind, app: appBundleID)
    }

    /// Pins a row for this app, or unpins it when it already is.
    func toggleAppPin(_ row: AppChatRow) {
        guard isAppContextDock, let kind = DockPinKind(appRow: row) else { return }
        defer { updateTabStrip() }
        if let pin = dockPins.pins(forApp: appBundleID).first(where: { $0.kind == kind }) {
            dockPins.unpin(pin.id)
            return
        }
        let documentID: String? = {
            if case .global(let doc) = row { return doc.id }
            return nil
        }()
        dockPins.pin(kind, title: row.title, documentID: documentID, app: appBundleID)
    }

    // MARK: The bar's leading icons

    static func appPinIconID(_ pin: DockPin) -> String { "app-pin:\(pin.id.uuidString)" }

    /// This app's pins as the bar's icons — the same icons the tabs are, so they fold into
    /// the field's pill and back with them.
    func appPinIcons() -> [MatchDockIcon] {
        let pins = dockPins.pins(forApp: appBundleID)
        appPinsByIconID = Dictionary(
            pins.map { (Self.appPinIconID($0), $0) }, uniquingKeysWith: { a, _ in a })
        return pins.map { pin in
            let id = Self.appPinIconID(pin)
            return MatchDockIcon(
                id: id, bundleID: id, title: pin.title,
                icon: appPinImage(pin) ?? Self.symbolImage(
                    appPinSymbol(pin) ?? pin.kind.fallbackSymbol, title: pin.title),
                isRunning: false, isExpandable: false, score: 0, isExactAppPrefix: false)
        }
    }

    func isAppPinIcon(_ id: String) -> Bool { appPinsByIconID[id] != nil }

    func appPin(forIconID id: String) -> DockPin? { appPinsByIconID[id] }

    /// A symbol drawn light, for the corner's dark glass: a template image would come out
    /// black where the view does not tint it.
    private static func symbolImage(_ name: String, title: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.85)]))
        return NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "pin", accessibilityDescription: title)
            ?? NSImage()
    }

    /// The result the field's pin button acts on while typing: the row the arrows landed on,
    /// or the top match. Nil when nothing typed matches — the button is then the plain
    /// "keep open" pin (owner 2026-09-26).
    var pinnableResult: AppChatRow? {
        guard isAppContextDock,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let row = focusedRow ?? rows.first,
            canPinToApp(row)
        else { return nil }
        return row
    }

    /// A row's picture, for the pin button that pins it: the menu item's own image, else the
    /// symbol the list draws for it.
    func resultPinArt(_ row: AppChatRow) -> (image: NSImage?, symbol: String) {
        switch row {
        case .command(let item):
            return (item.image, SFSymbolResolver.menuSymbol(
                title: item.title, path: item.path, isAppleMenu: item.isAppleMenu))
        case .action(let action):
            return (nil, action.icon.isEmpty ? "bolt" : action.icon)
        case .global(let doc):
            return (doc.icon, GlobalContextRow.symbol(for: doc))
        case .file(let url):
            return (NSWorkspace.shared.icon(forFile: url.path), "doc")
        case .dock(let pill):
            return (pill.menuItemImage, pill.icon.isEmpty ? "app" : pill.icon)
        case .cliSuggestion:
            return (nil, "pin")
        }
    }

    /// The tab behind a strip icon, as a pin kind.
    func tabPinKind(forIconID id: String) -> DockPinKind? {
        tabsByIconID[id].map { .tab(url: $0.url) }
    }

    func isTabPinned(iconID id: String) -> Bool {
        guard let kind = tabPinKind(forIconID: id) else { return false }
        return dockPins.isPinned(kind, app: appBundleID)
    }

    /// Pins the tab behind a strip icon for this app, or unpins it.
    func toggleTabPin(iconID id: String) {
        guard let tab = tabsByIconID[id], !appBundleID.isEmpty else { return }
        let kind = DockPinKind.tab(url: tab.url)
        if let pin = dockPins.pins(forApp: appBundleID).first(where: { $0.kind == kind }) {
            dockPins.unpin(pin.id)
        } else {
            dockPins.pin(kind, title: tab.title.isEmpty ? tab.domain : tab.title, app: appBundleID)
        }
        updateTabStrip()
    }

    // MARK: Running

    /// A click on one of this app's pins: the tab shows or reloads, the action runs through
    /// its adapter, and a menu command asks first when it is destructive or outbound.
    func openAppPin(_ pin: DockPin) {
        touch()
        switch pin.kind {
        case .tab(let url):
            if let tab = AppPinRun.openTab(for: url, among: tabSource()) {
                switchTab(tab)
            } else if let page = URL(string: url) {
                openPage(page, pin.appBundleID ?? appBundleID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.refreshTabs()
            }
        case .appAction(let id):
            guard let action = adapterActions.first(where: { $0.id == id })
                ?? AppAdapterManager.shared.adapter(for: appBundleID)?.actions
                    .first(where: { $0.id == id })
            else { return }
            runAdapterAction(action)
        case .menuCommand(let path):
            let bundleID = pin.appBundleID ?? appBundleID
            let name = appName
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A pinned command is one click from being run without its name being read
                // again, so the gate that guards every AI menu click guards this one too.
                guard await self.askMenuConsent(path, bundleID, name) else { return }
                self.runPinnedMenuPath(path)
            }
        case .app(let bundleID):
            AppActivation.bringForward(bundleID: bundleID, name: pin.title)
        case .globalCommand, .cliTool, .file, .folder:
            break  // the strip opens these itself, as it does Global's
        }
    }

    /// Runs a menu path through the dock's own execution path, the one a list row uses.
    private func runPinnedMenuPath(_ path: [String]) {
        if let performMenuPath {
            performMenuPath(path)
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == appBundleID && !$0.isTerminated
        }) else { return }
        let known = allMenuItems.first { $0.path == path }
        let request = MenuExecutionCoordinator.DockMenuActionRequest(
            sourcePID: app.processIdentifier,
            path: path,
            shortcutChar: known?.shortcutChar,
            shortcutModifiers: known?.shortcutModifiers ?? 0,
            knownMenuItems: allMenuItems,
            isGlobalContextActive: false,
            hasActiveDockContextSelection: false,
            keepsDockFloating: true)
        MenuExecutionCoordinator.shared.executeDockMenuAction(
            request: request,
            callbacks: MenuExecutionCoordinator.DockMenuActionCallbacks(
                hideBeforeExecution: {},
                refreshRunningApps: {},
                scheduleTerminationRefresh: { _ in },
                reloadMenu: { _ in },
                clearLiveDockMenuState: {},
                refocusDockInput: {}))
    }

    // MARK: Drawing

    /// The picture on one of this app's pins: the tab's favicon, the menu item's own image.
    func appPinImage(_ pin: DockPin) -> NSImage? {
        if let icon = pin.kind.icon { return icon }  // an app, a file, a folder
        switch pin.kind {
        case .tab(let url):
            guard let page = URL(string: url) else { return nil }
            if let icon = FaviconStore.shared.icon(for: page) { return icon }
            FaviconStore.shared.fetchIfNeeded(for: page)
            return nil
        case .menuCommand(let path):
            return allMenuItems.first { $0.path == path }?.image
        default:
            return nil
        }
    }

    /// The symbol a pin falls back to: the menu command's own, the action's icon.
    func appPinSymbol(_ pin: DockPin) -> String? {
        switch pin.kind {
        case .menuCommand(let path):
            return SFSymbolResolver.menuSymbol(
                title: path.last ?? pin.title, path: path, isAppleMenu: false)
        case .appAction(let id):
            return adapterActions.first { $0.id == id }?.icon
        default:
            return nil
        }
    }
}

/// The pure half of running an app's pins, kept apart so it can be tested without an app.
enum AppPinRun {
    /// The open tab a pinned tab stands for, matched on the address rather than the title.
    static func openTab(for url: String, among tabs: [SafariTab]) -> SafariTab? {
        guard let key = BrowserTabList.normalizedURLKey(url) else { return nil }
        return tabs.first { BrowserTabList.normalizedURLKey($0.url) == key }
    }

    /// The live tabs left once the pinned ones are taken out: a pinned tab that is open is
    /// one icon, at the pin's place, never a second copy among the live ones.
    static func unpinnedTabs(_ tabs: [SafariTab], pins: [DockPin]) -> [SafariTab] {
        let pinned = Set(pins.compactMap { pin -> String? in
            guard case .tab(let url) = pin.kind else { return nil }
            return BrowserTabList.normalizedURLKey(url)
        })
        guard !pinned.isEmpty else { return tabs }
        return tabs.filter { tab in
            guard let key = BrowserTabList.normalizedURLKey(tab.url) else { return true }
            return !pinned.contains(key)
        }
    }

    /// Whether a pinned menu command will ask before it runs: destructive or outbound, and
    /// not already allowed for this app.
    @MainActor
    static func menuAsksFirst(path: [String], bundleID: String) -> Bool {
        let consent = AppMenuConsentStore.shared
        return consent.isDestructive(path: path)
            && !consent.isAllowed(bundleId: bundleID, path: path)
    }
}
