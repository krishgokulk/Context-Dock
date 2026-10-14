import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct ContextDockBottomListFlip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.rotationEffect(.degrees(180))
        } else {
            content
        }
    }
}

extension View {
    func contextDockBottomListFlip(_ enabled: Bool) -> some View {
        modifier(ContextDockBottomListFlip(enabled: enabled))
    }
}

extension DockCore {
    // MARK: - List view (Spotlight / Raycast-style vertical result sheet)


    /// Cluster pills so every pill sharing a group title is contiguous, keeping
    /// the order each group first appears and the relevance order within a group.
    /// Without this, score-interleaved results (app, file, app, file…) render a
    /// repeated "Applications" header instead of one grouped section.
    /// Pills carrying explicit separators define their own sections, so leave
    /// those lists untouched.
    func clusterPillsByGroup(_ pills: [DockPill]) -> [DockPill] {
        guard !pills.contains(where: { $0.isSeparator }) else { return pills }
        var order: [String] = []
        var buckets: [String: [DockPill]] = [:]
        for pill in pills {
            let group = dockListGroupTitle(for: pill)
            if buckets[group] == nil {
                order.append(group)
                buckets[group] = []
            }
            buckets[group]?.append(pill)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }

    func dockListGroupTitle(for pill: DockPill) -> String {
        let kind = pill.rankingKind.lowercased()
        let badge = (pill.badge ?? "").lowercased()
        let context = (pill.menuContext ?? "").lowercased()
        let name = pill.name.lowercased()

        if kind == "setuphint" {
            return "Search"
        }
        // Safari history rows group under their Safari-style date bucket
        // ("Earlier Today", "Today", "Yesterday", "Wednesday, 24 June 2026").
        if kind == "recenturl" {
            if let bucket = pill.menuContext, !bucket.isEmpty { return bucket }
            return "Safari History"
        }
        if kind == "clipboard" {
            return "Clipboard Items"
        }
        if kind == "findermenu" {
            return "Finder Menus"
        }
        if kind == "submenuchild", let context = pill.menuContext, !context.isEmpty {
            return context == "Apple Menu" ? context : "\(context) Menu"
        }
        if kind == "finderselection" || kind == "findercontext" {
            return "Finder Actions"
        }
        if kind == "findergoto" {
            return "Home Folders"
        }
        if kind == "findercurrent" || kind == "findersearch" {
            // Folder drill-in children carry the parent folder name in menuContext —
            // keep them in the "Current Folder" group, right under the matched folder.
            if kind == "findercurrent", let context = pill.menuContext, !context.isEmpty {
                return "Current Folder"
            }
            if pill.icon.localizedCaseInsensitiveContains("folder")
                || badge.contains("folder")
                || name.contains("folder")
            {
                return kind == "findercurrent" ? "Current Folder" : "Home Folders"
            }
            return "Files"
        }
        if kind == "finderrecentapp" {
            return "Applications"
        }
        if kind == "finderrecent" || kind == "spotlightsearch" {
            // Group by type (Folders / Images / Documents / Media / Files) — the ranker clusters
            // the pills so each header appears once, best-matching group first.
            return finderDesktopTypeGroup(pill)
        }
        if kind.contains("finder") || badge.contains("finder") {
            return "Finder"
        }
        if kind.contains("menu") || !context.isEmpty {
            if let root = dockMenuRootTitle(for: pill) {
                return root == "Apple" ? "Apple Menu" : "\(root) Menu"
            }
            if let context = pill.menuContext, !context.isEmpty {
                return context == "Apple Menu" ? context : "\(context) Menu"
            }
            return "Menus"
        }
        if kind.contains("semantic") || kind.contains("payload") {
            return "Actions"
        }
        if kind.contains("applaunch") {
            return "Apps"
        }
        if badge.contains("folder") {
            return "Folders"
        }
        if badge.contains("file") || name.contains(".") {
            return "Files"
        }
        return "Actions"
    }

    func dockMenuRootTitle(for pill: DockPill) -> String? {
        let knownRoots = [
            "Apple", "File", "Edit", "Selection", "View", "Go", "Run", "Terminal",
            "Window", "Help", "History", "Bookmarks", "Navigate", "Product",
            "Debug", "Source Control", "Format", "Tools", "Playback", "Controls",
            "Audio", "Video", "Subtitles",
        ]
        for term in pill.searchTerms {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = knownRoots.first(where: {
                normalizedDockPillText($0) == normalizedDockPillText(cleaned)
            }) {
                return match
            }
        }
        return nil
    }













    /// Resolves the SystemCommand behind a pill when it should render a live
    /// control (slider/toggle) instead of plain run-on-enter behavior.
    func interactiveSystemCommand(for pill: DockPill) -> SystemCommand? {
        guard pill.rankingKind == "systemCommand" else { return nil }
        let parts = pill.trackingIdentifier.split(separator: ":")
        guard parts.count >= 3, parts[0] == "system", parts.last == "interactive",
            let id = UUID(uuidString: String(parts[1])),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.isEnabled,
            command.interactionType != .none
        else { return nil }
        return command
    }

    /// Resolves the interactive SystemCommand behind a global search result so its
    /// live control (Bluetooth/Wi-Fi toggle, Volume slider) can render inline in the
    /// results sheet instead of requiring the user to scope in.
    func interactiveSystemCommand(forResult result: SearchResult) -> SystemCommand? {
        guard result.subtitle.hasPrefix("syscmd://"),
            let id = UUID(uuidString: String(result.subtitle.dropFirst("syscmd://".count))),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.isEnabled,
            command.interactionType != .none
        else { return nil }
        return command
    }





    var isExplicitAppScope: Bool {
        resolveDockScope(
            for: searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ).isExplicitAppScope
    }

    /// The exact pill order the List View renders (clustered by group). Keyboard
    /// navigation MUST walk this order — navigating the raw score-interleaved array
    /// while the list renders a re-clustered copy makes ↑/↓ jump between sections.
    /// Horizontal pill row renders the raw order, so it returns the raw list there.
    func renderedOrderDockPills(for query: String) -> [DockPill] {
        let cached = contextDockViewModel.visiblePills
        let base = cached.isEmpty ? currentVisibleDockPills(for: query) : cached
        guard usesVerticalListDockLayout else { return base }
        return clusterPillsByGroup(Array(base.prefix(maxListViewDockPills)))
    }

    var shouldShowL2UnifiedDockRow: Bool {
        guard showContextInDock, !aiMode.isActive else { return false }
        if isContextDockChatRoutingLocked { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isCompactSmartScope {
            return false
        }
        if isGlobalContextActive {
            let hasExtensionScope =
                currentGlobalScopedBundleID?.hasPrefix("syscmd://") == true
                || currentGlobalScopedBundleID?.hasPrefix("cli://") == true
            // A browsed folder is a scope of its own, and its field starts empty on
            // purpose. Hiding the row on an empty query took the folder's contents down
            // with it the moment the user stepped inside.
            if q.isEmpty, !hasExtensionScope, !isBrowsingFinderFolder {
                return false
            }
            if shouldUsePureGlobalAppSearch {
                return true
            }
            if currentGlobalScopedBundleID != nil {
                if pendingDockPillQuery == q || isResolvingDockPills(for: q) {
                    return true
                }
                return stableVisibleDockPills(for: q).contains { !$0.isSeparator }
            }
            let visiblePills = currentVisibleDockPills(for: q)
            if pendingDockPillQuery == q || isResolvingDockPills(for: q) {
                return true
            }
            return visiblePills.contains { !$0.isSeparator }
        }
        if hasSelectionScopeSurface {
            return true
        }
        if isBrowsingFinderFolder { return true }
        guard !q.isEmpty else { return false }
        // Finder desktop search must keep its shared sheet alive while its cache and
        // Spotlight passes exchange snapshots. The rendered list supplies either files,
        // setup guidance, or a no-results row, so an empty intermediate array is not a
        // reason to hide the surface.
        if isFinderDesktopOnlyMode { return true }
        if !isGlobalContextActive {
            // Keep the row while the debounced pill build is in flight (no flicker), but
            // once the query resolves to ZERO results collapse back to the compact input
            // capsule — never park an empty results container under the search bar.
            if pendingDockPillQuery == q || isResolvingDockPills(for: q) {
                return true
            }
            if pendingDockPreviewPills.contains(where: { !$0.isSeparator }) {
                return true
            }
            return currentVisibleDockPills(for: q).contains { !$0.isSeparator }
        }
        if pendingDockPillQuery == q, pendingDockPreviewPills.contains(where: { !$0.isSeparator }) {
            return true
        }
        let visiblePills = contextDockViewModel.visiblePills
        return visiblePills.contains { !$0.isSeparator }
    }


    /// Resolve an optional color name string into a SwiftUI Color.
    func accentColor(for name: String?) -> SwiftUI.Color { .named(name) }

    /// Best-effort icon for a menu item. AXImage covers most items; Services items need name lookup.
    func resolvedMenuIcon(for item: AXMenuItem) -> NSImage? {
        if let appIcon = resolvedApplicationMenuIcon(for: item) { return appIcon }
        if let shareIcon = resolvedShareMenuIcon(for: item) { return shareIcon }
        if let img = item.image { return img }
        let isService = item.path.contains(where: { $0 == "Services" })
        guard isService else { return nil }
        let cacheKey = item.path.joined(separator: " > ")
        return MenuIconMemoryCache.shared.image(for: cacheKey) {
            resolveUncachedServiceMenuIcon(for: item)
        }
    }

    func resolvedApplicationMenuIcon(for item: AXMenuItem) -> NSImage? {
        let normalizedPath = item.path.map(normalizedDockPillText)
        // Match "Open With" AND Safari's "Open Page With" (any "open … with" parent),
        // plus any row whose own title ends in ".app" — so every app row in those
        // dynamic menus shows its real app icon, not a generic doc icon.
        let isOpenWithContext =
            normalizedPath.contains { $0.contains("open") && $0.contains("with") }
            || normalizedDockPillText(item.title).hasSuffix(".app")
            || item.title.contains(".app")
        guard isOpenWithContext else { return nil }
        // Open With titles arrive decorated: "Music.app (default)", "IINA.app",
        // "Books.app". Strip the trailing "(default)"/parenthetical and the ".app"
        // suffix so the name resolves to a real app icon (not a generic doc icon).
        let rawTitle = item.title
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(
                of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }
        let appName =
            rawTitle.hasSuffix(".app")
            ? String(rawTitle.dropLast(4)) : rawTitle
        return MenuIconMemoryCache.shared.image(for: "open-with:\(appName)", cacheMisses: false) {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").caseInsensitiveCompare(appName) == .orderedSame
                    && !$0.isTerminated
            }) {
                // Prefer the static bundle icon over NSRunningApplication.icon —
                // some apps (DuckDuckGo) set a generic runtime icon that isn't the
                // real app icon.
                if let bundleURL = app.bundleURL {
                    return preparedDockIcon(NSWorkspace.shared.icon(forFile: bundleURL.path))
                }
                return preparedDockIcon(app.icon)
            }
            for dir in [
                "/Applications", "/System/Applications",
                "/System/Applications/Utilities", "\(NSHomeDirectory())/Applications",
            ] {
                let path = "\(dir)/\(appName).app"
                if FileManager.default.fileExists(atPath: path) {
                    return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
                }
            }
            // Last resort: let LaunchServices find it anywhere by display name.
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: appName)
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: url.path))
            }
            return nil
        }
    }

    func resolvedShareMenuIcon(for item: AXMenuItem) -> NSImage? {
        let normalizedPath = item.path.map(normalizedDockPillText)
        guard normalizedPath.contains("share") else { return nil }
        return shareDestinationIcon(forTitle: item.title)
    }

    /// Resolve a share-destination icon purely from its title (Notes, Mail, AirDrop,
    /// app extensions). Use when the caller already KNOWS the row is a share child —
    /// the AX path of a flattened submenu child often drops the "Share" segment, so
    /// the path-guarded `resolvedShareMenuIcon` would miss it.
    func shareDestinationIcon(forTitle title: String) -> NSImage? {
        let rawTitle = title
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }

        return MenuIconMemoryCache.shared.image(for: "share:\(rawTitle)", cacheMisses: false) {
            // Cheap, deterministic lookups first (installed-app catalog + aliases) so
            // the common destinations resolve fast and cache as a hit. The expensive
            // NSSharingService enumeration is the last resort for unknown extensions.
            let normalizedTitle = normalizedDockPillText(rawTitle)
            let aliases: [(String, String)] = [
                ("add to photos", "Photos"),
                ("photos", "Photos"),
                ("mail", "Mail"),
                ("messages", "Messages"),
                ("notes", "Notes"),
                ("reminders", "Reminders"),
                ("freeform", "Freeform"),
                ("maps", "Maps"),
                ("shortcuts", "Shortcuts"),
            ]
            if let alias = aliases.first(where: { normalizedTitle.contains($0.0) }),
                let icon = resolvedInstalledAppIcon(named: alias.1)
            {
                return icon
            }
            if normalizedTitle.contains("airdrop") {
                return NSImage(
                    systemSymbolName: "antenna.radiowaves.left.and.right",
                    accessibilityDescription: "AirDrop")
            }
            // The real NSSharingService image is the exact icon the native menu shows
            // (QR code, Downie, Bridges, share-extensions). Use it BEFORE the loose
            // installed-app lookup, which falsely matched "Create QR Code" → "Code".
            if let serviceIcon = resolvedSharingServiceIcon(named: rawTitle) {
                return serviceIcon
            }
            // SF-symbol fallbacks for service-only destinations with no app/icon.
            let symbolFallbacks: [(String, String)] = [
                ("qr code", "qrcode"),
                ("copy link", "link"),
                ("copy", "doc.on.doc"),
                ("reading list", "eyeglasses"),
            ]
            if let s = symbolFallbacks.first(where: { normalizedTitle.contains($0.0) }),
                let img = NSImage(systemSymbolName: s.1, accessibilityDescription: nil)
            {
                return img
            }
            if let direct = resolvedInstalledAppIcon(named: rawTitle) {
                return direct
            }
            return nil
        }
    }

    func resolvedSharingServiceIcon(named title: String) -> NSImage? {
        let context = effectiveShareAXContext()
        var items = ShareIntentRouter.shared.shareItems(for: context)
        if items.isEmpty, let app = AppDelegate.shared?.previousFrontmostApp,
            let bid = app.bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        {
            items = [url]
        }
        guard !items.isEmpty else { return nil }

        let normalizedTitle = normalizedShareDestinationText(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let services = NSSharingService.sharingServices(forItems: items)
        let match = services.first { service in
            let serviceTitle = normalizedShareDestinationText(service.title)
            return serviceTitle == normalizedTitle
                || serviceTitle.contains(normalizedTitle)
                || normalizedTitle.contains(serviceTitle)
        }
        return match?.image
    }

    func resolvedInstalledAppIcon(named appName: String) -> NSImage? {
        let cleaned = cleanShareDestinationAppName(appName)
        guard !cleaned.isEmpty else { return nil }
        let normalizedCleaned = normalizedDockPillText(cleaned)

        if let match = allApplications.first(where: {
            let title = normalizedDockPillText($0.title)
            return title == normalizedCleaned
                || title.contains(normalizedCleaned)
                || normalizedCleaned.contains(title)
        }), let path = match.filePath {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        }

        let rawBundleName =
            appName
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").caseInsensitiveCompare(cleaned) == .orderedSame
                && !$0.isTerminated
        }) {
            return preparedDockIcon(app.icon)
        }

        if let match = allApplications.first(where: {
            normalizedDockPillText($0.title) == normalizedDockPillText(cleaned)
        }), let path = match.filePath {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleaned) {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: url.path))
        }

        let candidates = [
            "/Applications/\(cleaned).app",
            "/Applications/\(rawBundleName).app",
            "/System/Applications/\(cleaned).app",
            "/System/Applications/\(rawBundleName).app",
            "/System/Applications/Utilities/\(cleaned).app",
            "/System/Applications/Utilities/\(rawBundleName).app",
            "\(NSHomeDirectory())/Applications/\(cleaned).app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        }

        if let discovered = InstalledApplicationsCatalog.discoverInstalledApps().first(where: {
            let name = normalizedDockPillText($0.name)
            return name == normalizedCleaned
                || name.contains(normalizedCleaned)
                || normalizedCleaned.contains(name)
        }) {
            return preparedDockIcon(
                discovered.icon ?? NSWorkspace.shared.icon(forFile: discovered.url.path))
        }
        return nil
    }

    func cleanShareDestinationAppName(_ value: String) -> String {
        value
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(
                of: "\\b(share|sharing|extension|service)\\b", with: "", options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedShareDestinationText(_ value: String) -> String {
        cleanShareDestinationAppName(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveUncachedServiceMenuIcon(for item: AXMenuItem) -> NSImage? {
        let name = item.title.lowercased()
        // 1. Running app whose display name matches
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == name && !($0.isTerminated)
        }) {
            return app.icon
        }
        // 2. Walk common app directories
        let dirs = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"]
        for dir in dirs {
            let appPath = "\(dir)/\(item.title).app"
            if FileManager.default.fileExists(atPath: appPath) {
                return NSWorkspace.shared.icon(forFile: appPath)
            }
        }
        // 3. Workflow bundle in ~/Library/Services (Automator quick actions)
        let workflowPath = "\(NSHomeDirectory())/Library/Services/\(item.title).workflow"
        if FileManager.default.fileExists(atPath: workflowPath) {
            return NSWorkspace.shared.icon(forFile: workflowPath)
        }
        // 4. Shortcuts-provided service. The public Shortcuts CLI does not expose
        // the user's exact glyph/color, so use a deterministic per-shortcut symbol
        // instead of making every service look like Shortcuts.app.
        if let icon = NSImage(
            systemSymbolName: ShortcutsCatalog.iconName(for: item.title),
            accessibilityDescription: item.title
        ) {
            return icon
        }
        return nil
    }

    func menuSymbol(for item: AXMenuItem) -> String {
        if item.sourceAppName == "System Settings" || frontmost.bundleID == "com.apple.systempreferences" {
            return SFSymbolResolver.systemSettingsPaneSymbol(title: item.title)
        }
        if item.path.contains(where: { $0 == "Services" }) {
            return ShortcutsCatalog.iconName(for: item.title)
        }
        return SFSymbolResolver.menuSymbol(
            title: item.title,
            path: item.path,
            isAppleMenu: item.isAppleMenu
        )
    }

    func resolvedBundleId(for pid: pid_t, fallbackBundleId: String) -> String {
        if pid != 0,
            let bundleId = NSWorkspace.shared.runningApplications.first(
                where: { $0.processIdentifier == pid && !$0.isTerminated }
            )?.bundleIdentifier,
            !bundleId.isEmpty
        {
            return bundleId
        }
        return fallbackBundleId
    }





    func executeAppShortcut(_ sc: AppShortcut) {
        // ── Gather context ───────────────────────────────────────────────
        // Selected file: the highlighted search result.
        var selectedFilePaths: [String] = []
        if let idx = searchState.selectedIndex, idx < searchState.results.count,
            let path = searchState.results[idx].filePath, !path.isEmpty
        {
            selectedFilePaths = [path]
        }
        // Also pick up any multi-selection from Finder if no in-app selection
        if selectedFilePaths.isEmpty {
            selectedFilePaths = ContextDetector.shared.getFinderSelectedFiles().map { $0.path }
        }

        // Use the app that was frontmost BEFORE ILauncher activated — never ILauncher itself.
        let prevApp = AppDelegate.shared?.previousFrontmostApp

        // Selected text: accessibility API on the pre-ILauncher frontmost app
        let selectedText: String = {
            guard let app = prevApp else { return "" }
            return ContextDetector.shared.getSelectedText(from: app) ?? ""
        }()

        // ── Substitution helper ──────────────────────────────────────────
        func inject(_ value: String) -> String {
            var result = value
            // $1..$N — individual file paths
            for (i, path) in selectedFilePaths.enumerated() {
                let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                result = result.replacingOccurrences(of: "$\(i + 1)", with: escaped)
            }
            // $SELECTED_FILES — space-separated list of all paths (shell-quoted)
            let allEscaped = selectedFilePaths.map {
                "'\($0.replacingOccurrences(of: "'", with: "\\'"))'"
            }.joined(separator: " ")
            result = result.replacingOccurrences(of: "$SELECTED_FILES", with: allEscaped)
            // $SELECTED_TEXT — text selected in frontmost app
            let textEscaped = selectedText.replacingOccurrences(of: "'", with: "'\\''")
            result = result.replacingOccurrences(of: "$SELECTED_TEXT", with: textEscaped)
            // $FRONTMOST_APP — name of the app that was active before ILauncher opened
            let frontmostName = prevApp?.localizedName ?? ""
            result = result.replacingOccurrences(of: "$FRONTMOST_APP", with: frontmostName)
            // $FRONTMOST_BUNDLE — bundle identifier of the pre-ILauncher app
            let frontmostBundle = prevApp?.bundleIdentifier ?? ""
            result = result.replacingOccurrences(of: "$FRONTMOST_BUNDLE", with: frontmostBundle)
            // AX-read context variables ─────────────────────────────────────────
            // $CURRENT_URL — URL currently open in the frontmost browser/app window
            let axURL = axContext.currentURL ?? ""
            result = result.replacingOccurrences(of: "$CURRENT_URL", with: axURL)
            // $WINDOW_TITLE — title of the frontmost window
            let axTitle = axContext.windowTitle ?? ""
            result = result.replacingOccurrences(of: "$WINDOW_TITLE", with: axTitle)
            // $AX_SELECTED_TEXT — selected text read via AX API (more reliable than clipboard)
            let axSel = axContext.selectedText ?? ""
            result = result.replacingOccurrences(of: "$AX_SELECTED_TEXT", with: axSel)
            return result
        }

        switch sc.actionType {
        case .openURL:
            if let url = URL(string: inject(sc.actionValue)) { NSWorkspace.shared.open(url) }
        case .openFile:
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: sc.actionValue),
                configuration: NSWorkspace.OpenConfiguration())
        case .shellCommand:
            let cmd = inject(sc.actionValue)
            let ck = activeConsoleKey
            // Always create panel terminal if needed, open drawer, run command in real PTY
            let panelTerm = panelTerminal(for: ck)
            panelShowConsoleMap[ck] = true
            panelTerm.sendCommand(cmd)
            // Give the terminal focus so output is visible and interactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                panelTerm.terminalView.window?.makeFirstResponder(panelTerm.terminalView)
            }
        case .appleScript:
            if let script = NSAppleScript(source: inject(sc.actionValue)) {
                script.executeSerialized(error: nil)
            }
        case .jxa:
            // JXA runs via osascript -l JavaScript, passing selected file + text as argv
            let scriptCode = sc.actionValue
            let ck = activeConsoleKey
            let file1 = selectedFilePaths.first ?? ""
            let selText = selectedText
            Task.detached {
                // Write script to a temp file so we can pass it cleanly
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ilauncher_jxa_\(UUID().uuidString).js")
                try? scriptCode.write(to: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                var args = ["-l", "JavaScript", tmp.path]
                if !file1.isEmpty { args.append(file1) }
                if !selText.isEmpty { args.append(selText) }
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                try? proc.run()
                proc.waitUntilExit()
                let out =
                    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? ""
                // Show JXA output in the panel terminal drawer
                await MainActor.run {
                    self.panelShowConsoleMap[ck] = true
                    for line in out.components(separatedBy: "\n") where !line.isEmpty {
                        self.panelConsoleLinesMap[ck, default: []].append(
                            (line: line, isCommand: false))
                    }
                }
            }
        case .scriptFile:
            // Delegate to AXTriggerRuleEngine which handles all script file execution + notifications
            let envVars: [String: String] = [
                "CD_APP_NAME": frontmost.name,
                "CD_BUNDLE_ID": frontmost.bundleID,
                "CD_WINDOW_TITLE": axContext.windowTitle ?? "",
                "CD_SELECTED_TEXT": axContext.selectedText ?? selectedText,
                "CD_URL": axContext.currentURL ?? AXContextReader.shared.current.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
                "CD_FILE": axContext.selectedFilePaths.first ?? selectedFilePaths.first ?? "",
                "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            AXTriggerRuleEngine.shared.run(
                type: .scriptFile, value: sc.actionValue, envVars: envVars)
        case .menuItem:
            let envVars: [String: String] = [
                "CD_APP_NAME": frontmost.name,
                "CD_BUNDLE_ID": frontmost.bundleID,
                "CD_WINDOW_TITLE": axContext.windowTitle ?? "",
                "CD_SELECTED_TEXT": axContext.selectedText ?? selectedText,
                "CD_URL": axContext.currentURL ?? AXContextReader.shared.current.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
                "CD_FILE": axContext.selectedFilePaths.first ?? selectedFilePaths.first ?? "",
                "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            AXTriggerRuleEngine.shared.run(type: .menuItem, value: sc.actionValue, envVars: envVars)
        case .shortcut:
            let envVars: [String: String] = [
                "CD_APP_NAME": frontmost.name,
                "CD_BUNDLE_ID": frontmost.bundleID,
                "CD_WINDOW_TITLE": axContext.windowTitle ?? "",
                "CD_SELECTED_TEXT": axContext.selectedText ?? selectedText,
                "CD_URL": axContext.currentURL ?? AXContextReader.shared.current.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
                "CD_FILE": axContext.selectedFilePaths.first ?? selectedFilePaths.first ?? "",
                "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            AXTriggerRuleEngine.shared.run(type: .shortcut, value: sc.actionValue, envVars: envVars)
        }
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func appPillScriptExtensions(for appKey: String, query: String) -> [AppToolExtension] {
        settings.pillScriptExtensions(for: appKey, query: query, maxCount: query.isEmpty ? 6 : 4)
    }

    func executeAppToolExtension(_ ext: AppToolExtension, launchQuery: String = "") {
        guard ext.kind == .script,
            let lang = ext.scriptLanguage,
            !ext.toolPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let queryText = launchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFile: String = {
            if let idx = searchState.selectedIndex, idx < searchState.results.count,
                let path = searchState.results[idx].filePath, !path.isEmpty
            {
                return path
            }
            if let finderSelected = ContextDetector.shared.getFinderSelectedFiles().first?.path,
                !finderSelected.isEmpty
            {
                return finderSelected
            }
            if let axSelected = axContext.selectedFilePaths.first, !axSelected.isEmpty {
                return axSelected
            }
            return ""
        }()

        let fallbackQuery =
            axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveQuery = queryText.isEmpty ? fallbackQuery : queryText
        let command = [
            lang.runCommand(scriptPath: ext.toolPath),
            shellQuote(selectedFile),
            shellQuote(effectiveQuery),
        ].joined(separator: " ")

        let ck = activeConsoleKey
        let panelTerm = panelTerminal(for: ck)
        panelShowConsoleMap[ck] = true
        panelTerm.sendCommand(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            panelTerm.terminalView.window?.makeFirstResponder(panelTerm.terminalView)
        }
    }




}
