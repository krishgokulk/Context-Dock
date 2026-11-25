// UnifiedGlobalContextSupport.swift
// Context-Dock
//
// Keeps Unified Global Context alive with frontmost-app Contextual Actions,
// Finder front-folder browsing, and running-application rows without growing
// AppChatMenuBrowsing.swift.

import AppKit
import Foundation
import Quartz
import SwiftUI

extension SystemCommand {
    /// The Global Command for native Window Management (`provider:windows`).
    var isWindowsBoard: Bool {
        provider == "windows" || keywords.contains { $0.lowercased() == "provider:windows" }
    }
}

extension AppChatPromptModel {
    /// Contextual actions for the underlying frontmost app in Global Context:
    /// - When Finder is frontmost: lists the active Finder folder (or Desktop / current
    ///   `finderBrowseStack` subfolder) so files/folders appear immediately.
    /// - For other apps: lists matching adapter actions (and top cached menu commands when empty).
    func frontmostContextualActionRows(for typed: String) -> [AppChatRow] {
        let resolvedFrontApp: NSRunningApplication? = {
            if let prev = AppDelegate.shared?.previousFrontmostApp,
                !prev.isTerminated,
                let bid = prev.bundleIdentifier,
                !bid.isEmpty,
                bid != Bundle.main.bundleIdentifier
            {
                return prev
            }
            if let owner = AppDelegate.shared?.menuBarOwningUserFacingApplication(),
                !owner.isTerminated,
                let bid = owner.bundleIdentifier,
                !bid.isEmpty,
                bid != Bundle.main.bundleIdentifier
            {
                return owner
            }
            if let front = NSWorkspace.shared.frontmostApplication.flatMap({ AppDelegate.shared?.resolvedUserFacingApplication($0) }),
                !front.isTerminated,
                let bid = front.bundleIdentifier,
                !bid.isEmpty,
                bid != Bundle.main.bundleIdentifier
            {
                return front
            }
            return nil
        }()
        guard let frontApp = resolvedFrontApp,
            let bundleID = frontApp.bundleIdentifier,
            !bundleID.isEmpty
        else { return [] }

        let appName = frontApp.localizedName ?? "App"
        let section = GlobalResultSection.contextualActionsTitle(forApp: appName)
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if bundleID == "com.apple.finder" {
            guard let folder = finderBrowseStack.last
                ?? (finderShowsDesktopOnly ? FinderFrontFolder.desktop : finderFrontFolder)
                ?? FinderFrontFolder.desktop
            else { return [] }
            let urls = Self.folderListing(folder, matching: typed)
            return urls.prefix(8).map { url in
                let isDir = Self.isFolder(url)
                var pill = DockPill(
                    id: "global-finder-\(url.path)",
                    name: url.lastPathComponent,
                    icon: isDir ? "folder" : "doc",
                    badge: folder.lastPathComponent,
                    execute: { [weak self] in
                        if isDir {
                            _ = self?.enterFolder(url)
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                pill.menuItemImage = NSWorkspace.shared.icon(forFile: url.path)
                pill.resolvedURL = url
                pill.previewPath = url.path
                pill.sourceBundleId = bundleID
                pill.sourceAppName = appName
                pill.resultSection = section
                return AppChatRow.dock(pill)
            }
        }

        var items: [AppChatRow] = []
        if let adapter = AppAdapterManager.shared.adapter(for: bundleID) {
            let matching = trimmed.isEmpty
                ? Array(adapter.actions.prefix(4))
                : adapter.actions.filter {
                    $0.name.lowercased().contains(trimmed)
                        || $0.description.lowercased().contains(trimmed)
                }
            for action in matching.prefix(5) {
                var pill = DockPill(
                    id: "global-ctx-action-\(bundleID)-\(action.id)",
                    name: action.name,
                    icon: "bolt.fill",
                    badge: "\(appName) Action",
                    execute: { [weak self] in self?.runAdapterAction(action) }
                )
                pill.sourceBundleId = bundleID
                pill.sourceAppName = appName
                pill.resultSection = section
                items.append(.dock(pill))
            }
        }

        // Native Window layouts answering the query for the frontmost app
        if !trimmed.isEmpty {
            let matchingWindowCmds = WindowManagementService.shared.matchingCommands(query: trimmed)
            for cmd in matchingWindowCmds.prefix(4) {
                var pill = DockPill(
                    id: "global-ctx-window-\(bundleID)-\(cmd.id)",
                    name: cmd.title,
                    icon: cmd.icon,
                    accentColorName: "blue",
                    badge: appName,
                    execute: {
                        _ = WindowManagementService.shared.execute(cmd, sourceApp: frontApp)
                    }
                )
                pill.rankingKind = "nativeWindow"
                pill.resultSection = GlobalResultSection.windowLayouts
                pill.sourceBundleId = bundleID
                pill.sourceAppName = appName
                items.append(.dock(pill))
            }
        }

        // Frontmost app menu commands from capability cache (or AX menu scrape)
        let cachedMenus = AppMenuCapabilityCache.shared.menuItems(for: frontApp, maxResults: 400)
        let menuSource: [AXMenuItem]
        if !cachedMenus.isEmpty {
            menuSource = cachedMenus
        } else if AXIsProcessTrusted() {
            let live = AXMenuReader.shared.liveAXMenuItems(for: frontApp.processIdentifier, maxDepth: 5)
            if !live.isEmpty {
                AppMenuCapabilityCache.shared.store(items: live, for: frontApp)
            }
            menuSource = live
        } else {
            menuSource = []
        }

        let filteredMenus: [AXMenuItem] = {
            if trimmed.isEmpty {
                return Array(menuSource.filter { item in
                    item.children.isEmpty && !item.title.isEmpty && item.title != "-"
                        && !FrontmostMenuMatcher.isPlaceholderTitle(item.title)
                        && !WindowManagementService.shared.handlesMenuPath(item.path)
                }.prefix(4))
            } else {
                return menuSource.filter { item in
                    guard item.children.isEmpty, !item.title.isEmpty, item.title != "-",
                        !FrontmostMenuMatcher.isPlaceholderTitle(item.title)
                    else { return false }
                    let titleLower = item.title.lowercased()
                    let pathLower = item.path.joined(separator: " ").lowercased()
                    return titleLower.contains(trimmed) || pathLower.contains(trimmed) || trimmed.contains(titleLower)
                }.sorted { a, b in
                    let aTitle = a.title.lowercased()
                    let bTitle = b.title.lowercased()
                    let aExact = aTitle == trimmed
                    let bExact = bTitle == trimmed
                    if aExact != bExact { return aExact }
                    let aPrefix = aTitle.hasPrefix(trimmed)
                    let bPrefix = bTitle.hasPrefix(trimmed)
                    if aPrefix != bPrefix { return aPrefix }
                    return aTitle.count < bTitle.count
                }
            }
        }()

        for item in filteredMenus.prefix(6) {
            if items.contains(where: { $0.title.lowercased() == item.title.lowercased() }) {
                continue
            }
            var pill = DockPill(
                id: "global-ctx-menu-\(bundleID)-\(item.path.joined(separator: ">"))",
                name: item.title,
                icon: "command",
                badge: item.path.dropLast().joined(separator: " ▸ "),
                execute: { [weak self] in
                    self?.runMenuItem(item)
                }
            )
            pill.sourceBundleId = bundleID
            pill.sourceAppName = appName
            pill.resultSection = section
            pill.rankingKind = "menu"
            pill.keyboardShortcutLabel = item.shortcutDisplay
            items.append(.dock(pill))
        }

        return items
    }

    /// Currently running regular applications for the empty-query Global Context board.
    func globalRunningApplicationRows(limit: Int = 6) -> [AppChatRow] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular && !$0.isTerminated
                    && $0.bundleIdentifier != own
            }
            .prefix(limit)
            .compactMap { app -> AppChatRow? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
                let name = app.localizedName ?? bundleID
                var pill = DockPill(
                    id: "global-running-\(bundleID)",
                    name: name,
                    icon: "app",
                    badge: "Running",
                    execute: { AppActivation.bringForward(bundleID: bundleID, name: name) }
                )
                pill.menuItemImage = app.icon
                pill.sourceBundleId = bundleID
                pill.sourceAppName = name
                pill.rankingKind = "application"
                pill.resultSection = GlobalResultSection.applications
                return .dock(pill)
            }
    }

    /// Populates the Global Context board when `↓` opens the list on an empty query.
    func populateEmptyGlobalContextBoard() {
        var combined: [AppChatRow] = []
        combined += elevatedFrontmostPinRows(for: "")
        combined += frontmostContextualActionRows(for: "")
        combined += globalRunningApplicationRows(limit: 6)
        rows = GlobalResultSection.capped(
            combined,
            expanded: expandedGlobalSections
        ) { section, hidden in
            var pill = DockPill(
                id: "show-more-\(section)", name: "Show \(hidden) more",
                icon: "chevron.down", badge: nil, execute: {})
            pill.rankingKind = GlobalResultSection.showMoreKind
            pill.resultSection = section
            return pill
        }
        focusedMenuIndex = rows.isEmpty ? nil : 0
    }

    /// Running app targets for Siri-style AI fallbacks: frontmost app first, then up to 3
    /// other currently running regular apps, each carrying its app icon.
    func globalFallbackAppTargets(runningLimit: Int = 3) -> [GlobalFallbackAppTarget] {
        let own = Bundle.main.bundleIdentifier
        var targets: [GlobalFallbackAppTarget] = []
        var seen = Set<String>()

        if let front = AppDelegate.shared?.previousFrontmostApp,
            !front.isTerminated,
            let bundleID = front.bundleIdentifier,
            !bundleID.isEmpty,
            bundleID != own
        {
            seen.insert(bundleID)
            targets.append(
                GlobalFallbackAppTarget(
                    bundleID: bundleID,
                    name: front.localizedName ?? "App",
                    icon: front.icon,
                    isFrontmost: true
                )
            )
        }

        for app in NSWorkspace.shared.runningApplications {
            guard targets.count < 1 + runningLimit else { break }
            guard app.activationPolicy == .regular,
                !app.isTerminated,
                let bundleID = app.bundleIdentifier,
                !bundleID.isEmpty,
                bundleID != own,
                seen.insert(bundleID).inserted
            else { continue }
            targets.append(
                GlobalFallbackAppTarget(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    icon: app.icon,
                    isFrontmost: false
                )
            )
        }
        return targets
    }

    /// Opens a running app's App Pet chat from Global Context and submits the question.
    func askAppChatFromGlobal(bundleID: String, name: String, question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
        let target = CornerChatTarget(
            name: name,
            bundleID: bundleID,
            suggestions: AppChatSuggestionProvider.suggestions(for: running),
            summary: AppChatSuggestionProvider.summary(for: running)
        )
        CornerDockController.shared.chatPresentation.showFrontmostApp(target: target)
        query = trimmed
        _ = submit()
    }

    /// Bounded Files & Folders matches for Global Context:
    /// 1. Direct or partial filesystem path resolution (e.g. `/Users/name/Pictures/Screenshot`, `~/Pictures/Screenshot`, `Pictures/Screenshot`).
    /// 2. Multi-level bounded folder & file scan across all configured roots (including user home subfolders like `~/Pictures`, `~/Pictures/Screenshot`, and `iCloud Drive`), ranked folder-first and shallow-local-path-first.
    /// 3. Indexed files/folders from `FileIndexManager.shared.search`, strictly bounded to `FileSearchService.boundedRoots`.
    func globalFileAndFolderRows(for typed: String, limit: Int = 8) -> [AppChatRow] {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let lower = trimmed.lowercased()
        let singularLower = (lower.count > 3 && lower.hasSuffix("s") && !lower.hasSuffix("ss"))
            ? String(lower.dropLast()) : lower

        let settings = AppSettings.shared
        let roots = FileSearchService.boundedRoots(
            useCustom: settings.useCustomSearchDirectories,
            customDirectories: settings.searchDirectories.map(\.path)
        )
        guard !roots.isEmpty else { return [] }

        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let normalizedRoots = roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let enforceBoundary = settings.useCustomSearchDirectories || !settings.searchDirectories.isEmpty

        var seenPaths = Set<String>()
        var candidates: [URL] = []

        func addCandidate(_ url: URL) {
            let std = url.standardizedFileURL.path
            guard !std.isEmpty else { return }
            if enforceBoundary {
                guard FileSearchService.isInsideAny(std, roots: normalizedRoots) else { return }
            }
            guard !FileSearchService.isExcluded(std, roots: normalizedRoots, home: home) else { return }
            if seenPaths.insert(std).inserted {
                candidates.append(URL(fileURLWithPath: std))
            }
        }

        // 0. Direct or partial path query (e.g. "/Users/gokulakannan/Pictures/Screenshot", "~/Pictures/Screenshot", "Pictures/Screenshot")
        var resolvedExactPaths = Set<String>()
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("/") {
            let tildeExpanded: String = {
                if trimmed == "~" { return home }
                if trimmed.hasPrefix("~/") { return home + "/" + String(trimmed.dropFirst(2)) }
                return trimmed
            }()

            var pathQueries: [String] = []
            if tildeExpanded.hasPrefix("/") {
                pathQueries.append(tildeExpanded)
            } else {
                for r in normalizedRoots {
                    pathQueries.append(r + "/" + tildeExpanded)
                }
                if !normalizedRoots.contains(home) {
                    pathQueries.append(home + "/" + tildeExpanded)
                }
            }

            for rawCandidate in pathQueries {
                let cleanedPath = rawCandidate.hasSuffix("/") && rawCandidate.count > 1
                    ? String(rawCandidate.dropLast()) : rawCandidate
                let stdPath = URL(fileURLWithPath: cleanedPath).standardizedFileURL.path
                if fm.fileExists(atPath: stdPath) {
                    let exactURL = URL(fileURLWithPath: stdPath)
                    resolvedExactPaths.insert(stdPath.lowercased())
                    addCandidate(exactURL)
                    if Self.isFolder(exactURL),
                        let children = try? fm.contentsOfDirectory(
                            at: exactURL,
                            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        )
                    {
                        for child in children.prefix(limit * 2) {
                            addCandidate(child)
                        }
                    }
                }
                let parentPath = (stdPath as NSString).deletingLastPathComponent
                let leafPrefix = (stdPath as NSString).lastPathComponent.lowercased()
                if !leafPrefix.isEmpty, parentPath != stdPath, fm.fileExists(atPath: parentPath),
                    let siblings = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: parentPath, isDirectory: true),
                        includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                {
                    for sibling in siblings where sibling.lastPathComponent.lowercased().contains(leafPrefix) {
                        addCandidate(sibling)
                    }
                }
            }
        }

        func nameMatches(_ fileName: String) -> Bool {
            let fLower = fileName.lowercased()
            return fLower.contains(lower) || (singularLower != lower && fLower.contains(singularLower))
        }

        // 1. Expand roots to scan depth-1 and depth-2 user & iCloud directories (e.g. ~/Pictures, ~/Pictures/Screenshot, iCloud Drive/Pictures).
        var scanDirs: [String] = []
        var seenScanDirs = Set<String>()
        func enqueueScanDir(_ dirPath: String) {
            let std = URL(fileURLWithPath: dirPath).standardizedFileURL.path
            guard !std.isEmpty,
                !FileSearchService.isExcluded(std, roots: normalizedRoots, home: home),
                seenScanDirs.insert(std).inserted
            else { return }
            scanDirs.append(std)
        }

        // Put local home roots ahead of iCloud Drive when scanning
        let orderedRoots = normalizedRoots.sorted { a, b in
            let aCloud = a.contains("/Mobile Documents/") || a.contains("com~apple~CloudDocs")
            let bCloud = b.contains("/Mobile Documents/") || b.contains("com~apple~CloudDocs")
            if aCloud != bCloud { return !aCloud }
            return a.count < b.count
        }

        let prioritySubfolderNames: Set<String> = [
            "pictures", "documents", "downloads", "desktop", "movies", "music",
            "projects", "developer", "screenshots", "screenshot",
        ]

        for root in orderedRoots {
            enqueueScanDir(root)
            guard let level1 = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for item in level1.prefix(120) {
                guard Self.isFolder(item) else { continue }
                let itemPath = item.standardizedFileURL.path
                enqueueScanDir(itemPath)
                if prioritySubfolderNames.contains(item.lastPathComponent.lowercased()),
                    scanDirs.count < 160,
                    let level2 = try? fm.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                {
                    for sub in level2.prefix(60) where Self.isFolder(sub) {
                        enqueueScanDir(sub.standardizedFileURL.path)
                    }
                }
            }
        }

        for dir in scanDirs {
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            if nameMatches(dirURL.lastPathComponent), fm.fileExists(atPath: dir) {
                addCandidate(dirURL)
            }
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for child in children.prefix(250) {
                if nameMatches(child.lastPathComponent) {
                    addCandidate(child)
                }
            }
        }

        // 2. Indexed files & folders within bounded roots
        let indexed = FileIndexManager.shared.search(query: trimmed, limit: limit * 3)
        for item in indexed {
            guard let path = item.filePath, !path.isEmpty else { continue }
            addCandidate(URL(fileURLWithPath: path))
        }

        // 3. Rank all candidates: exact path first, then exact/prefix folders (local home before iCloud), then files.
        func rankTuple(for url: URL) -> (Int, Int, Int, Int, String) {
            let stdPath = url.standardizedFileURL.path
            let pathLower = stdPath.lowercased()
            let exactPathRank = resolvedExactPaths.contains(pathLower) ? 0 : 1
            let isDir = Self.isFolder(url)
            let nameLower = url.lastPathComponent.lowercased()
            let baseLower = url.deletingPathExtension().lastPathComponent.lowercased()

            let matchTier: Int = {
                if isDir && nameLower == lower { return 0 }
                if isDir && nameLower == singularLower { return 1 }
                if !isDir && (nameLower == lower || baseLower == lower || baseLower == singularLower) { return 2 }
                if isDir && (nameLower.hasPrefix(lower) || nameLower.hasPrefix(singularLower)) { return 3 }
                if isDir && (nameLower.contains(lower) || nameLower.contains(singularLower)) { return 4 }
                if !isDir && (nameLower.hasPrefix(lower) || nameLower.hasPrefix(singularLower)) { return 5 }
                return 6
            }()

            let isCloud = stdPath.contains("/Mobile Documents/") || stdPath.contains("com~apple~CloudDocs")
            let localBaseRoot = orderedRoots.first(where: { r in
                let rCloud = r.contains("/Mobile Documents/") || r.contains("com~apple~CloudDocs")
                return !rCloud && (stdPath == r || stdPath.hasPrefix(r + "/"))
            }) ?? home
            let relativeDepth: Int = {
                if !isCloud, stdPath == localBaseRoot {
                    return 0
                }
                if !isCloud, stdPath.hasPrefix(localBaseRoot + "/") {
                    let rel = String(stdPath.dropFirst(localBaseRoot.count + 1))
                    return rel.split(separator: "/").count
                }
                return (isCloud ? 50 : 20) + stdPath.split(separator: "/").count
            }()

            return (exactPathRank, matchTier, relativeDepth, nameLower.count, nameLower)
        }

        let sorted = candidates.sorted { lhs, rhs in
            rankTuple(for: lhs) < rankTuple(for: rhs)
        }

        return sorted.prefix(limit).map { AppChatRow.file($0) }
    }

    /// Async deeper bounded disk/Spotlight search for Global Context (handles Macs with Spotlight off).
    func appendGlobalDiskMatches(for typed: String) {
        globalFileSearchGeneration &+= 1
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let generation = globalFileSearchGeneration
        let settings = AppSettings.shared
        let roots = FileSearchService.boundedRoots(
            useCustom: settings.useCustomSearchDirectories,
            customDirectories: settings.searchDirectories.map(\.path)
        )
        guard !roots.isEmpty else { return }

        Task.detached(priority: .userInitiated) {
            var options = FileSearchService.Options(roots: roots, includeDirectories: true)
            options.maxResults = 10
            options.maxDepth = 4
            options.maxVisited = 12_000
            options.scanTimeBudget = 0.45
            let outcome = FileSearchService.search(query: trimmed, options: options)
            guard !outcome.paths.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self,
                    self.globalFileSearchGeneration == generation,
                    self.isGlobalScope
                else { return }
                let existingPaths = Set(self.rows.compactMap { row -> String? in
                    if case .file(let url) = row { return url.standardizedFileURL.path }
                    return nil
                })
                let newRows = outcome.paths
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
                    .filter { !existingPaths.contains($0.path) }
                    .prefix(6)
                    .map { AppChatRow.file($0) }
                guard !newRows.isEmpty else { return }

                let focusedID = self.focusedRow?.id
                if let lastFileIdx = self.rows.lastIndex(where: {
                    GlobalResultSection.title(for: $0) == GlobalResultSection.files
                }) {
                    self.rows.insert(contentsOf: newRows, at: lastFileIdx + 1)
                } else if let clipOrFallbackIdx = self.rows.firstIndex(where: {
                    let sec = GlobalResultSection.title(for: $0) ?? ""
                    return sec == "Clipboard" || sec == "Quick Notes" || sec == "Notifications"
                        || sec == GlobalFallbacks.section
                }) {
                    self.rows.insert(contentsOf: newRows, at: clipOrFallbackIdx)
                } else {
                    self.rows.append(contentsOf: newRows)
                }
                self.focusedMenuIndex = focusedID.flatMap { id in
                    self.rows.firstIndex { $0.id == id }
                }
                self.syncListPhase()
            }
        }
    }

    /// Whether `row` resolves to a file or folder preview in the right side panel.
    func hasSidePanelFilePreview(_ row: AppChatRow?) -> Bool {
        guard let preview = CornerBoardLayout.preview(
            for: row, appName: appName, appBundleID: appBundleID,
            cliCommand: cliCommand, lookup: searchDocumentLookup)
        else { return false }
        if case .file = preview { return true }
        return false
    }

    /// Space on a file or folder row opens the full-size in-sheet File Preview (repurposing
    /// the top input bar with `<` Back and the right-end mode dropdown), while keeping Space
    /// as a space character whenever the user is mid-typing a query.
    @discardableResult
    func toggleSidePanelPreview(force: Bool = false) -> Bool {
        if let sub = fileSubmode {
            guard force || sub.query.isEmpty else { return false }
            if sub.kind == .preview {
                return leaveFileSubmode()
            } else {
                switchFileSubmode(.preview)
                return true
            }
        }
        guard phase == .suggesting, !isClipboardScope else { return false }
        if !force {
            guard query.isEmpty || arrowedIntoListSinceLastEdit else { return false }
        }
        guard let url = targetFileSubmodeURL() else { return false }
        return enterFileSubmode(url: url, kind: .preview)
    }
}
