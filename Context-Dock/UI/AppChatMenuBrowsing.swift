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

        adapterActions = AppAdapterManager.shared.adapter(for: appBundleID)?
            .actions.filter { !$0.name.isEmpty } ?? []
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
        rows = AppChatRowRanker.rank(
            commands: allMenuItems,
            actions: adapterActions,
            query: typed,
            limit: Self.menuRowLimit)
        // Kept for the surfaces that still ask specifically about commands.
        menuMatches = rows.compactMap {
            if case .command(let item) = $0 { return item }
            return nil
        }
        focusedMenuIndex = min(focusedMenuIndex, max(rows.count - 1, 0))
        syncListPhase()
    }

    /// The list has something to show.
    var isBrowsingMenus: Bool { !rows.isEmpty }

    /// What the card's height is computed from. Falls back to the handed-in suggestions
    /// for an app with no adapter and no cached menus — otherwise the surface would open
    /// on an empty card.
    var listRowCount: Int { rows.isEmpty ? suggestions.count : rows.count }

    var focusedRow: AppChatRow? {
        rows.indices.contains(focusedMenuIndex) ? rows[focusedMenuIndex] : nil
    }

    // MARK: - Keyboard

    /// Arrow keys walk the commands. They are only claimed while commands are on screen —
    /// the corner's surfaces share one key monitor, so an unclaimed arrow must fall through
    /// to whatever else is up.
    @discardableResult
    func moveMenuFocus(by delta: Int) -> Bool {
        guard isBrowsingMenus else { return false }
        let count = rows.count
        focusedMenuIndex = (focusedMenuIndex + delta + count) % count
        touch()
        return true
    }

    /// Runs whichever row the keyboard is on. Returns false when there is none, so Enter
    /// falls through to asking the question the user typed.
    @discardableResult
    func runFocusedRow() -> Bool {
        guard let row = focusedRow else { return false }
        run(row)
        return true
    }

    func run(_ row: AppChatRow) {
        switch row {
        case .command(let item): runMenuItem(item)
        case .action(let action): runAdapterAction(action)
        }
    }

    /// An adapter action runs through AppAdapterManager, which is where its approval and
    /// its context resolution already live.
    func runAdapterAction(_ action: AdapterAction) {
        let bundleID = appBundleID
        hasActed = true
        query = ""
        updateMenuMatches()
        touch()
        // The reader's latest snapshot, refreshed against the app the corner is about —
        // the corner opening is itself an app switch, so the resting snapshot can be of
        // something else.
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }) {
            AXContextReader.shared.refreshLightweight(from: app)
        }
        let context = AXContextReader.shared.current
        Task { @MainActor in
            _ = await AppAdapterManager.shared.execute(
                action, context: context, targetBundleId: bundleID)
        }
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

        // Running a command is using the surface: the opening list of what the app can do
        // does not come back afterwards.
        hasActed = true
        query = ""
        updateMenuMatches()
        touch()
    }
}
