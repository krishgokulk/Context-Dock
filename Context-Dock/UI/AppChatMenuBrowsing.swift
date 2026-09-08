// AppChatMenuBrowsing.swift
// Context-Dock
//
// The frontmost app's own commands, filtered as the user types, above the corner's input.
//
// The corner is becoming the surface that owns the frontmost app (decision: "The corner owns
// the frontmost app; the dock keeps global scope"). This is the first half of that: what the
// dock has always shown when you type into an app scope, shown where the app actually is.
//
// The ranking is not reimplemented here. `FrontmostMenuMatcher` is the dock's rule, moved out
// of LauncherView so both surfaces call it and neither can drift.

import AppKit
import Combine
import Foundation

extension AppChatPromptModel {

    /// How many commands the corner offers. Matches the suggestion list it replaces — the
    /// pill's height is a pure function of this count, so it cannot exceed what is drawn.
    static let menuRowLimit = 5

    // MARK: - Reading the app's menus

    /// The app's menus: the warm cache first, then a live read that fills in what the cache
    /// refuses to keep.
    ///
    /// The cache deliberately never persists the Window menu — it is live state (open
    /// documents, tabs, restored windows) and stale rows there are worse than none. So
    /// "Minimize" and "Zoom" exist in no snapshot, and a cache-only list answers "minimize"
    /// with nothing. The dock has always covered this by reading live menus alongside the
    /// cache; this does the same.
    ///
    /// Called when the prompt opens and when the app changes — never per keystroke. The
    /// cached rows land immediately so the list is never empty while the AX read runs.
    func loadMenuItems() {
        guard !appBundleID.isEmpty,
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == appBundleID && !$0.isTerminated
            })
        else {
            allMenuItems = []
            menuMatches = []
            return
        }

        allMenuItems = AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: 400)
        updateMenuMatches()

        // The AX read walks the whole menu bar, so it happens after the surface is up
        // rather than in front of it. Live items go first: where both have a row, the live
        // one is the one that is actually clickable, and dedupe keeps the first.
        let pid = app.processIdentifier
        let bundleID = appBundleID
        Task { @MainActor [weak self] in
            let live = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 7)
            guard let self, self.appBundleID == bundleID, !live.isEmpty else { return }
            self.allMenuItems = live + self.allMenuItems
            self.updateMenuMatches()
        }
    }

    /// Re-filters against what is typed. Pure and synchronous: the matcher does no I/O, so
    /// this runs on a keystroke without a hop.
    func updateMenuMatches() {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !allMenuItems.isEmpty else {
            menuMatches = []
            focusedMenuIndex = 0
            syncListPhase()
            return
        }
        menuMatches = FrontmostMenuMatcher.ranked(
            allMenuItems,
            query: typed,
            limit: Self.menuRowLimit,
            policy: .cornerAppChat)
        focusedMenuIndex = min(focusedMenuIndex, max(menuMatches.count - 1, 0))
        syncListPhase()
    }

    /// The list is showing commands rather than opening suggestions.
    var isBrowsingMenus: Bool { !menuMatches.isEmpty }

    /// What the pill's height is computed from, whichever list is on screen.
    var listRowCount: Int {
        isBrowsingMenus ? menuMatches.count : suggestions.count
    }

    // MARK: - Keyboard

    /// Arrow keys walk the commands. They are only claimed while commands are on screen —
    /// the corner's surfaces share one key monitor, so an unclaimed arrow must fall through
    /// to whatever else is up.
    @discardableResult
    func moveMenuFocus(by delta: Int) -> Bool {
        guard isBrowsingMenus else { return false }
        let count = menuMatches.count
        focusedMenuIndex = (focusedMenuIndex + delta + count) % count
        touch()
        return true
    }

    var focusedMenuItem: AXMenuItem? {
        guard isBrowsingMenus, menuMatches.indices.contains(focusedMenuIndex) else { return nil }
        return menuMatches[focusedMenuIndex]
    }

    // MARK: - Running one

    /// Runs a command through the dock's own execution path, so consent, the irreversible
    /// gate and live verification all still apply. The corner is a new place to choose a
    /// command, not a new way to run one.
    ///
    /// A menu click is normally the last resort — here the user picked the row by name,
    /// which is the one case where it is a choice rather than a guess.
    func runMenuItem(_ item: AXMenuItem) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == appBundleID && !$0.isTerminated
        }) else { return }

        let request = MenuExecutionCoordinator.DockMenuActionRequest(
            sourcePID: app.processIdentifier,
            path: item.path,
            shortcutChar: item.shortcutChar,
            shortcutModifiers: item.shortcutModifiers,
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

        query = ""
        updateMenuMatches()
        touch()
    }
}
