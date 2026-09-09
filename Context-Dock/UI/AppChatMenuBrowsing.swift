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

    /// How many apps Global Context reads, most recently used first. Every running app's
    /// full menu is thousands of rows and seconds of AX; the ranking only ever shows five.
    static let globalAppLimit = 12
    /// And how much of each app's menu it takes.
    static let globalPerAppLimit = 60

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
        // Global Context is the dock's index, queried through the same coordinator the dock
        // uses — apps, running apps, CLI tools, system commands, tabs and menus together.
        if isGlobalScope {
            rows = GlobalContextRow
                .documents(for: typed, limit: Self.menuRowLimit)
                .map(AppChatRow.global)
            menuMatches = []
            focusedMenuIndex = nil
            updateGlobalTyping(for: typed)
            syncListPhase()
            return
        }
        rows = AppChatRowRanker.rank(
            commands: allMenuItems,
            actions: adapterActions,
            query: typed,
            limit: Self.menuRowLimit,
            policy: isGlobalScope ? .globalContext : .cornerAppChat)
        // Kept for the surfaces that still ask specifically about commands.
        menuMatches = rows.compactMap {
            if case .command(let item) = $0 { return item }
            return nil
        }
        // A new list is a new offer: nothing is chosen until the user arrows into it.
        focusedMenuIndex = nil
        syncListPhase()
    }

    /// Every running app at once, in the same field the app scope uses.
    ///
    /// Global Context is the frontmost app's scope widened to the machine, so it reuses this
    /// surface rather than introducing a third one: the chip says which scope is answering
    /// and the list underneath changes with it.
    func summonGlobalContext() {
        adoptScope(name: Self.globalScopeName, bundleID: "")
        adapterActions = []
        allMenuItems = []
        hasActed = false
        updateMenuMatches()
        set(.prompt)
        syncListPhase()
        touch()
    }

    /// The menus of the apps that are running, from the same warm cache the app scope reads.
    static func runningAppMenuItems() -> [AXMenuItem] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .prefix(globalAppLimit)

        return apps.flatMap { app in
            AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: globalPerAppLimit)
        }
    }

    /// The top match and the matching app icons, from the dock's coordinator.
    ///
    /// Both are resolved from the same index the dock's global bar uses, so "the best match
    /// for what I typed" means one thing in this app rather than two. They are synchronous
    /// and cached by query — fast typing re-asks per keystroke without a hop, which is what
    /// keeps the leading icon in step with the field instead of a character behind it.
    func updateGlobalTyping(for typed: String) {
        // The pills are what is running, the way the dock's global bar shows them — they
        // are ambient, not a second copy of the results. The top match still comes from the
        // index, because that is what Tab takes.
        let running = Self.pillIcons()
        setGlobalTyping(
            top: typed.isEmpty
                ? nil
                : GlobalContextSearchCoordinator.shared.resolveFastTopMatch(query: typed),
            icons: Array(running.prefix(Self.matchIconLimit)),
            overflow: max(running.count - Self.matchIconLimit, 0))
    }

    /// The pills: what is running, and the clipboard when it is holding something.
    ///
    /// The clipboard leads, because it is the thing that just happened — the user copied
    /// something a moment ago and the pill is how they get back to it without leaving what
    /// they are doing.
    static func pillIcons() -> [MatchDockIcon] {
        var icons: [MatchDockIcon] = []
        if let clipboard = clipboardPill() { icons.append(clipboard) }
        return icons + runningAppIcons()
    }

    /// The clipboard, as a pill, when there is anything in it.
    static func clipboardPill() -> MatchDockIcon? {
        guard !ClipboardPanelController.shared.model.entries.isEmpty,
            let icon = NSImage(
                systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
        else { return nil }
        return MatchDockIcon(
            id: Self.clipboardPillID,
            bundleID: nil,
            title: "Clipboard",
            icon: icon,
            isRunning: false,
            isExpandable: true,
            score: 0,
            isExactAppPrefix: false)
    }

    static let clipboardPillID = "corner.clipboard"

    /// The apps that are running, newest first, as the pill row draws them.
    static func runningAppIcons() -> [MatchDockIcon] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular && !$0.isTerminated
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, let icon = app.icon else { return nil }
                return MatchDockIcon(
                    id: bundleID,
                    bundleID: bundleID,
                    title: app.localizedName ?? bundleID,
                    icon: icon,
                    isRunning: true,
                    isExpandable: false,
                    score: 0,
                    isExactAppPrefix: false)
            }
    }

    /// How many app icons fit beside a 372-point field before the rest become "+N".
    static let matchIconLimit = 3

    /// Tab takes the top match, the way it does in the dock: the fastest path from three
    /// letters to the thing you meant. Returns false when there is nothing to take, so the
    /// key falls through rather than eating a keystroke silently.
    @discardableResult
    func acceptGlobalTopMatch() -> Bool {
        guard isGlobalScope, let top = globalTopMatch else { return false }
        // The top match is a document in the same list the rows come from, so taking it is
        // running that row — not a second code path that might do something else.
        guard let row = rows.first(where: {
            if case .global(let doc) = $0 { return doc.id == top.id }
            return false
        }) else {
            // The top match outranked what fits in five rows; run it directly.
            guard let doc = GlobalContextRow.documents(for: query, limit: 40)
                .first(where: { $0.id == top.id })
            else { return false }
            run(.global(doc))
            return true
        }
        run(row)
        return true
    }

    /// Right arrow on an empty Global field scopes into an app — the leading chip becomes
    /// that app, the placeholder becomes what that app can do, and the field filters it.
    ///
    /// The dock does exactly this, and it is a step *into* something rather than sideways
    /// along the scopes, which is why it is not part of the left/right walk.
    @discardableResult
    func scopeIntoFirstRunningApp() -> Bool {
        guard isGlobalScope,
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let first = Self.runningAppIcons().first,
            let bundleID = first.bundleID
        else { return false }
        scopeIntoApp(name: first.title, bundleID: bundleID)
        return true
    }

    /// Scope the corner into one app, remembering that Global is where it came from so the
    /// chip's "−" has somewhere to go back to.
    func scopeIntoApp(name: String, bundleID: String) {
        returnsToGlobalScope = true
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
        adoptScope(
            name: name, bundleID: bundleID,
            suggestions: AppChatSuggestionProvider.suggestions(for: app),
            summary: AppChatSuggestionProvider.summary(for: app))
        hasActed = false
        loadMenuItems()
        updateGlobalTyping(for: "")
        syncListPhase()
        touch()
    }

    /// Leave a scope entered from Global and go back to it.
    @discardableResult
    func leaveScopeForGlobal() -> Bool {
        guard returnsToGlobalScope else { return false }
        returnsToGlobalScope = false
        summonGlobalContext()
        return true
    }

    /// Clicking one of the match pills opens that app, the way it does in the dock.
    func openGlobalMatchIcon(_ icon: MatchDockIcon) {
        hasActed = true
        touch()
        if icon.id == Self.clipboardPillID {
            ClipboardPanelController.shared.show()
            return
        }
        // An app pill scopes the field into that app rather than launching it: the pills
        // are how you get *into* something from here, and the row list is how you run it.
        guard let bundleID = icon.bundleID, !bundleID.isEmpty else { return }
        if isGlobalScope {
            scopeIntoApp(name: icon.title, bundleID: bundleID)
            return
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }) {
            running.activate()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The list has something to show.
    var isBrowsingMenus: Bool { !rows.isEmpty }

    /// What the card's height is computed from. Falls back to the handed-in suggestions
    /// for an app with no adapter and no cached menus — otherwise the surface would open
    /// on an empty card.
    var listRowCount: Int { rows.isEmpty ? suggestions.count : rows.count }

    /// The row the user has arrowed to. Nil until they do, which is what lets Enter mean
    /// "ask this question" by default.
    var focusedRow: AppChatRow? {
        guard let index = focusedMenuIndex, rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    // MARK: - Keyboard

    /// Arrow keys walk the commands. They are only claimed while commands are on screen —
    /// the corner's surfaces share one key monitor, so an unclaimed arrow must fall through
    /// to whatever else is up.
    /// Arrow keys walk the rows, and the first press is what chooses one at all.
    @discardableResult
    func moveMenuFocus(by delta: Int) -> Bool {
        guard isBrowsingMenus else { return false }
        let count = rows.count
        if let current = focusedMenuIndex {
            focusedMenuIndex = (current + delta + count) % count
        } else {
            // Down enters at the top, up enters at the bottom.
            focusedMenuIndex = delta > 0 ? 0 : count - 1
        }
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
        case .global(let doc):
            hasActed = true
            query = ""
            updateMenuMatches()
            touch()
            GlobalContextRow.run(doc)
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
    /// The corner is in Global Context — the scope is the machine, not one app.
    var isGlobalScope: Bool { appBundleID.isEmpty && appName == Self.globalScopeName }

    /// The name the scope goes by, in one place so the chip and the check cannot disagree.
    static let globalScopeName = "Global Context"

    func runMenuItem(_ item: AXMenuItem) {
        // In Global Context the row carries its own app: the scope has no single one, and
        // sending a Safari command to whatever happens to be frontmost is how a global list
        // becomes dangerous.
        let owner = NSWorkspace.shared.runningApplications.first {
            item.sourcePID != 0
                ? $0.processIdentifier == item.sourcePID
                : $0.bundleIdentifier == appBundleID
        }
        guard let app = owner, !app.isTerminated else { return }

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
