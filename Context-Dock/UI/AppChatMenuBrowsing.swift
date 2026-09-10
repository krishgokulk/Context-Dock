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
        // A CLI scope offers the tool's own subcommands, and Return runs the line.
        if isCLIScope {
            rows = cliSubcommandRows(for: typed)
            menuMatches = []
            focusedMenuIndex = nil
            updateGlobalTyping(for: typed)
            syncListPhase()
            return
        }
        // Finder searches the disk instead of its own menus.
        if isFinderScope {
            updateFinderResults(for: typed)
            updateGlobalTyping(for: typed)
            return
        }
        // A window snapshot answers the untyped scope; typing turns it back into a filter
        // over that app, because now the user is asking for something specific.
        if showsWindowSnapshot, typed.isEmpty {
            rows = []
            menuMatches = []
            focusedMenuIndex = nil
            syncListPhase()
            return
        }
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
        let running = Self.pillIcons(excluding: appBundleID)
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
    static func pillIcons(excluding scopedBundleID: String = "") -> [MatchDockIcon] {
        var icons: [MatchDockIcon] = []
        if let clipboard = clipboardPill() { icons.append(clipboard) }
        // A panel the user minimised is a thing they put down mid-use, so it sits with the
        // clipboard at the front rather than at the end of a list of apps they never
        // touched. macOS's own Dock has it too — but that is a different dock, and the
        // corner is where they opened it.
        icons += minimizedPanelPills()
        let apps = runningAppIcons()
            .filter { $0.bundleID != scopedBundleID || scopedBundleID.isEmpty }
        // Finder leads the apps, always. It is the one scope that is always there and
        // always means the same thing, so it is the fixed point the eye starts from — the
        // dock puts it first for the same reason.
        let finder = apps.filter { $0.bundleID == "com.apple.finder" }
        let rest = apps.filter { $0.bundleID != "com.apple.finder" }
        return icons + finder + rest
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
    /// Marks a pill as a minimised panel rather than an app, so opening it restores a
    /// window instead of scoping into a bundle it does not have.
    static let minimizedPillPrefix = "corner.panel."

    /// The panels that are minimised, as pills.
    static func minimizedPanelPills() -> [MatchDockIcon] {
        MinimizedPanelRegistry.shared.entries.compactMap { entry in
            guard
                let icon = NSImage(
                    systemSymbolName: entry.symbol, accessibilityDescription: entry.title)
                    ?? NSImage(
                        systemSymbolName: "macwindow", accessibilityDescription: entry.title)
            else { return nil }
            return MatchDockIcon(
                id: minimizedPillPrefix + entry.id,
                bundleID: nil,
                title: entry.title,
                icon: icon,
                isRunning: true,
                isExpandable: true,
                score: 0,
                isExactAppPrefix: false)
        }
    }

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
    static let matchIconLimit = 4

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
    /// The apps in the order the pills show them — Finder first, then the rest. Right
    /// arrow walks *this* list, because the pills are what the user is looking at: stepping
    /// into an app the row does not lead with makes the gesture look broken even when it
    /// picked something reasonable.
    static func orderedAppPills() -> [MatchDockIcon] {
        pillIcons().filter { $0.id != clipboardPillID && $0.bundleID != nil }
    }

    @discardableResult
    func scopeIntoFirstRunningApp() -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let apps = Self.orderedAppPills()
        guard !apps.isEmpty else { return false }

        if isGlobalScope {
            guard let first = apps.first, let bundleID = first.bundleID else { return false }
            scopeIntoApp(name: first.title, bundleID: bundleID)
            return true
        }
        // Already inside one: walk to the next, which is what makes this a switcher rather
        // than a one-way door.
        guard returnsToGlobalScope,
            let index = apps.firstIndex(where: { $0.bundleID == appBundleID })
        else { return false }
        let next = apps[(index + 1) % apps.count]
        guard let bundleID = next.bundleID else { return false }
        scopeIntoApp(name: next.title, bundleID: bundleID)
        return true
    }

    /// Return, on a snapshot with nothing typed, switches to the app — the switcher's whole
    /// point. Returns false otherwise so Return still sends the question.
    @discardableResult
    func activateSnapshotApp() -> Bool {
        guard showsWindowSnapshot,
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == appBundleID && !$0.isTerminated
            })
        else { return false }
        app.activate()
        hasActed = true
        touch()
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
        // `loadMenuItems` returns early when the scope is not a running app — a CLI tool
        // never is — so the rows have to be rebuilt here or the scope opens still showing
        // the Global results it was entered from.
        updateMenuMatches()
        updateGlobalTyping(for: "")

        // Scoping in from Global asks "what is this app doing?", and a list of its menu
        // commands does not answer that — the window does. Finder is the exception the user
        // named: there the question really is about files, so it keeps its own behaviour.
        if showsWindowSnapshot {
            AppWindowSnapshotService.shared.refresh(bundleID: bundleID)
        }
        syncListPhase()
        touch()
    }

    /// Whether a Global result is a Global Command — the `syscmd://` kind.
    func isSystemCommandAction(_ action: GlobalSearchService.ActionSpec) -> Bool {
        if case .systemCommandScope = action { return true }
        return false
    }

    /// Whether a Global result is a Global Extension, which the corner steps into.
    func isUserExtensionAction(_ action: GlobalSearchService.ActionSpec) -> Bool {
        if case .userExtension = action { return true }
        return false
    }

    /// Whether a Global result is a CLI tool, which the corner steps into rather than runs.
    func isCLIScopeAction(_ action: GlobalSearchService.ActionSpec) -> Bool {
        if case .cliScope = action { return true }
        return false
    }

    /// Step into a Global Extension: its own panel, in the corner's board.
    ///
    /// The launcher opens these in a window of their own. In the corner that would be a
    /// second floating container beside the one the user is already in, which is the thing
    /// the shell's whole design refuses — so the extension's view is mounted here instead.
    func scopeIntoExtension(_ ext: UserGlobalExtension) {
        scopedCommand = nil
        scopedExtension = ext
        returnsToGlobalScope = true
        adoptScope(name: ext.name, bundleID: "userext://\(ext.id.uuidString)")
        hasActed = false
        rows = []
        updateGlobalTyping(for: "")
        syncListPhase()
        touch()
    }

    /// The board is showing an extension's own interface.
    var showsExtensionPanel: Bool { scopedExtension != nil || scopedCommand != nil }

    /// Ask the panel on screen, from the field under it.
    ///
    /// The panel's own assistant sat beside its rows in a second pane. In the corner there
    /// is already a field, and two places to ask one question is one too many — so the
    /// field asks, through the same prompt the pane used.
    func askPanelAssistant() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, showsExtensionPanel, !isAskingPanel else { return }

        let title = scopedExtension?.name ?? scopedCommand?.name ?? ""
        let subtitle = scopedExtension?.description ?? scopedCommand?.description ?? ""
        let extra = scopedExtension?.aiPrompt ?? ""
        let history = panelConversation
        let provider = AppSettings.shared.selectedAIProvider

        panelConversation.append(ChatMessage(role: .user, content: question))
        query = ""
        isAskingPanel = true
        hasActed = true
        syncListPhase()

        Task { @MainActor [weak self] in
            do {
                let reply = try await PanelAssistant.ask(
                    question, title: title, subtitle: subtitle, extraPrompt: extra,
                    history: history, provider: provider)
                self?.panelConversation.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                self?.panelConversation.append(
                    ChatMessage(role: .assistant, content: error.localizedDescription))
            }
            self?.isAskingPanel = false
            self?.syncListPhase()
            self?.touch()
        }
    }

    /// Step into a Global Command — the panel the pinned window shows, in the corner's
    /// board. These are what Settings calls Commands, and they carry `syscmd://` ids; the
    /// extension work before this one covered `userext://` and so never reached them.
    func scopeIntoCommand(_ command: SystemCommand) {
        scopedExtension = nil
        scopedCommand = command
        returnsToGlobalScope = true
        adoptScope(name: command.name, bundleID: "syscmd://\(command.id.uuidString)")
        hasActed = false
        rows = []
        updateGlobalTyping(for: "")
        syncListPhase()
        touch()
    }

    /// The corner is inside a command-line tool's scope.
    var isCLIScope: Bool { appBundleID.hasPrefix("cli://") }

    /// The tool this scope runs, without the `cli://`.
    var cliCommand: String {
        isCLIScope ? String(appBundleID.dropFirst("cli://".count)) : ""
    }

    /// Step into a CLI tool. The dock scopes to `cli://<tool>` for this, so the corner uses
    /// the same identity — one scope, described the same way in both surfaces.
    func scopeIntoCLI(command: String, displayName: String) {
        scopeIntoApp(name: displayName.isEmpty ? command : displayName, bundleID: "cli://\(command)")
    }

    /// The subcommands this tool is known to take, filtered by what has been typed. Read
    /// from the package the app already scanned — no help text is run to find them.
    func cliSubcommandRows(for typed: String) -> [AppChatRow] {
        guard let package = TerminalPackageManager.shared.packages.first(where: {
            $0.command == cliCommand
        }) else { return [] }

        let words = package.subcommands + package.usageExamples
        let query = DockTextMatch.normalized(typed)
        let matches = query.isEmpty
            ? words
            : words.filter { DockTextMatch.normalized($0).contains(query) }
        return Array(matches.prefix(Self.menuRowLimit)).map { AppChatRow.cliSuggestion($0) }
    }

    /// Ask this tool something, through the pipeline that already knows how.
    ///
    /// The dock's CLI scope is a chat with the tool: it works out what to run, asks for
    /// approval when the command deserves one, and shows the steps. Running the binary
    /// directly from here was a second, quieter path to the same machine — no approval, no
    /// reasoning, and no way for the two surfaces to agree. This hands the question to the
    /// same pipeline with the same `cli://` scope, so the corner behaves like the dock
    /// because it *is* the dock's behaviour.
    func runCLICommand() {
        guard isCLIScope else { return }
        submit()
    }

    /// The Finder scope searches the disk rather than Finder's menus — the question there
    /// is about files, which is why the user carved it out of the snapshot behaviour.
    var isFinderScope: Bool {
        returnsToGlobalScope && appBundleID == "com.apple.finder"
    }

    /// Files and folders matching what is typed, from the same Spotlight index the dock's
    /// Finder scope reads. Async: a metadata query cannot answer on the keystroke, so the
    /// rows land a moment later and the generation guard drops anything overtaken by the
    /// next keystroke.
    func updateFinderResults(for typed: String) {
        guard isFinderScope else { return }
        guard !typed.isEmpty else {
            rows = []
            syncListPhase()
            return
        }
        finderSearchGeneration &+= 1
        let generation = finderSearchGeneration
        let home = NSHomeDirectory()

        Task { @MainActor [weak self] in
            let paths = await LauncherView.spotlightSearchPaths(
                predicate: NSPredicate(
                    format: "kMDItemFSName LIKE[cd] %@", "*\(typed)*"),
                inDirectories: [home],
                sortByLastUsed: true,
                limit: Self.menuRowLimit)
            guard let self, self.finderSearchGeneration == generation, self.isFinderScope
            else { return }
            self.rows = paths.map { AppChatRow.file(URL(fileURLWithPath: $0)) }
            self.focusedMenuIndex = nil
            self.syncListPhase()
        }
    }

    /// This scope shows the app's window rather than its commands.
    var showsWindowSnapshot: Bool {
        returnsToGlobalScope && !appBundleID.isEmpty
            && appBundleID != "com.apple.finder"
            && !isCLIScope && !showsExtensionPanel
    }

    /// Leave a scope entered from Global and go back to it.
    @discardableResult
    func leaveScopeForGlobal() -> Bool {
        guard returnsToGlobalScope else { return false }
        returnsToGlobalScope = false
        scopedExtension = nil
        scopedCommand = nil
        panelConversation = []
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
        if icon.id.hasPrefix(Self.minimizedPillPrefix) {
            MinimizedPanelRegistry.shared.restore(
                String(icon.id.dropFirst(Self.minimizedPillPrefix.count)))
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

    /// The file a row stands for, when it stands for one: an app bundle, a folder, a
    /// document. Quick Look needs a path, and rows that have none simply do not preview.
    func previewPath(for row: AppChatRow) -> String? {
        switch row {
        case .file(let url): return url.path
        case .global(let doc):
            if let path = doc.filePath, !path.isEmpty { return path }
            switch doc.action {
            case .launchPath(let path): return path
            case .launchBundleId(_, let path): return path
            case .activatePID(_, _, let path): return path
            default: return nil
            }
        case .command, .action, .cliSuggestion: return nil
        }
    }

    /// Space previews the focused row, the way it does in the dock — but only once the user
    /// has arrowed into the list. With the caret still in the field, space is a space.
    @discardableResult
    func previewFocusedRow() -> Bool {
        guard focusedMenuIndex != nil, let row = focusedRow,
            let path = previewPath(for: row)
        else { return false }
        FileQuickLookPanel.shared.toggle(path: path)
        touch()
        return true
    }

    /// The icon of whatever the field is pointing at — the focused row, or the first one.
    var leadingResultIcon: NSImage? {
        let row = focusedRow ?? rows.first
        switch row {
        case .file(let url): return NSWorkspace.shared.icon(forFile: url.path)
        case .global(let doc): return doc.icon
        default: return nil
        }
    }

    /// Right arrow takes the ghost, the way a shell completes a path: with something typed
    /// and a completion showing, → fills it in rather than walking scopes. Returns false
    /// when there is no ghost, so the key keeps its other meanings.
    @discardableResult
    func acceptGhostCompletion() -> Bool {
        let ghost = globalGhostCompletion
        guard !ghost.isEmpty else { return false }
        query += ghost
        queryChanged()
        return true
    }

    /// What the rest of the top match would be, if the user accepted it: the ghost the dock
    /// shows after what they have typed.
    var globalGhostCompletion: String {
        guard isGlobalScope, let title = globalTopMatch?.title else { return "" }
        let typed = query
        guard !typed.isEmpty, title.count > typed.count,
            title.lowercased().hasPrefix(typed.lowercased())
        else { return "" }
        return String(title.dropFirst(typed.count))
    }

    /// The list has something to show.
    var isBrowsingMenus: Bool { !rows.isEmpty }

    /// What the card's height is computed from. Falls back to the handed-in suggestions
    /// for an app with no adapter and no cached menus — otherwise the surface would open
    /// on an empty card.
    var listRowCount: Int {
        // A scope stepped into from Global answers with what was asked for — files in
        // Finder, a window elsewhere. Falling back to that app's menu list there filled the
        // board with "About Finder" and "AirDrop", which is not what the user came for.
        if returnsToGlobalScope { return rows.count }
        return rows.isEmpty ? suggestions.count : rows.count
    }

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

    /// Take the row the arrows landed on — enter its scope, or run it.
    ///
    /// Tab and right arrow used to ignore the focused row entirely: Tab acted on the top
    /// match and right arrow completed the ghost, so arrowing down to a CLI tool and
    /// pressing either did nothing to that row. The row under the highlight is what the
    /// user is pointing at, and it wins over both.
    @discardableResult
    func enterFocusedRow() -> Bool {
        guard let row = focusedRow else { return false }
        run(row)
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
        case .cliSuggestion(let word):
            // Fills the field rather than running: a subcommand usually needs an argument,
            // and running it half-written would be a guess at what the user meant.
            query = word
            queryChanged()
            touch()
        case .file(let url):
            hasActed = true
            query = ""
            updateMenuMatches()
            touch()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .global(let doc) where isSystemCommandAction(doc.action):
            // A Global Command opens its panel in the board. Running it outright is what
            // the launcher does, and it is the wrong move here: the corner is where the
            // user is working, and a command with an interface has one for a reason.
            if case .systemCommandScope(let key) = doc.action,
                let id = UUID(uuidString: key),
                let command = SystemCommandsRegistry.shared.commands.first(where: {
                    $0.id == id
                })
            {
                scopeIntoCommand(command)
            }
        case .global(let doc) where isUserExtensionAction(doc.action):
            // Stepping into the extension, in this field's board.
            if case .userExtension(let id) = doc.action,
                let ext = UserGlobalExtensionStore.shared.extensions.first(where: {
                    $0.id == id
                })
            {
                scopeIntoExtension(ext)
            }
        case .global(let doc) where isCLIScopeAction(doc.action):
            // Stepping into a tool changes *this* field's scope, so it is done here rather
            // than through the shared controller — which is also what makes it testable.
            if case .cliScope(let command, let displayName) = doc.action {
                scopeIntoCLI(command: command, displayName: displayName)
            }
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

    /// This field searches rather than composes: Global itself, and any scope stepped into
    /// from it. Neither carries the composer's attach, send, expand or pin — the dock does
    /// not show them there either.
    var isSearchField: Bool { isGlobalScope || returnsToGlobalScope }

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
