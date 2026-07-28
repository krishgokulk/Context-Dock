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

/// Coalesces global-search index rebuilds. Extensions can't hold stored state, and the rebuild
/// is main-thread work heavy enough to show up in spin reports, so the clock lives here.
enum GlobalSearchIndexThrottle {
    @MainActor static var lastRebuild: Date = .distantPast
}
import Vision

extension LauncherView {
    /// Final Backspace/Clear is input-critical. Cancel work immediately, but leave the
    /// rendered result snapshot alive for one display frame so AppKit can paint the empty
    /// NSTextField before SwiftUI tears down rows and resizes the translucent NSPanel.
    func beginGlobalContextEmptyQueryTransition() {
        globalContextViewModel.fastMatchTask?.cancel()
        globalContextViewModel.prepareTask?.cancel()
        globalContextViewModel.autoExpandTask?.cancel()
        globalContextViewModel.idleCollapseTask?.cancel()
        globalAppMatchTask?.cancel()
        globalGroupedTask?.cancel()
        queryChangeTask?.cancel()
        globalAppMatchGeneration &+= 1
        globalGroupedGeneration &+= 1
        queryChangeGeneration &+= 1
        globalContextViewModel.isResolvingFastMatches = false
        globalContextViewModel.expandWhenFastMatchesResolve = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            guard self.isGlobalContextActive,
                self.globalInlineAppScope == nil,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                self.globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot()
                self.globalContextViewModel.preparedResults = nil
                self.cachedGlobalAppQuery = ""
                self.cachedGlobalAppMatches = []
                self.cachedGlobalGroupedQuery = ""
                self.cachedGlobalGroupedState = nil
                self.globalContextViewModel.cachedGroupedFingerprint = ""
                self.pendingGlobalAppQuery = nil
                self.pendingGlobalGroupedQuery = nil
                self.focusedAppPillIndex = nil
                self.l2.focusedPillIndex = nil
                self.l2.pillNavViaKeyboard = false
                self.measuredGlobalListContentHeight = 0
            }
            self.globalContextViewModel.fastMatchTask = nil
            self.globalContextViewModel.prepareTask = nil
            self.globalContextViewModel.autoExpandTask = nil
            self.globalContextViewModel.idleCollapseTask = nil
            self.globalAppMatchTask = nil
            self.globalGroupedTask = nil
            self.queryChangeTask = nil
        }
    }

    func currentGlobalAppMatches(for query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        guard cachedGlobalAppQuery == q else { return [] }
        return cachedGlobalAppMatches
    }

    func currentOrImmediateGlobalAppMatches(for query: String) -> [SearchResult] {
        let cached = currentGlobalAppMatches(for: query)
        if !cached.isEmpty { return dedupeGlobalApplicationResults(cached) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, shouldUsePureGlobalAppSearch else { return [] }
        return instantGlobalApplicationMatches(for: q, limit: maxListViewDockPills)
    }

    func matchDockIconRowsForExpandedSheet(query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, shouldUsePureGlobalAppSearch else { return [] }
        let icons =
            globalContextViewModel.typingSnapshot.query == q
            ? globalContextViewModel.typingSnapshot.matchDockIcons
            : GlobalContextSearchCoordinator.shared.resolveFastMatchDockIcons(
                query: q,
                limit: maxListViewDockPills
            )
        return icons.prefix(maxListViewDockPills).enumerated().map { index, item in
            var result = SearchResult(
                title: item.title,
                subtitle: item.isExpandable ? "Menus available" : "Application",
                icon: item.icon,
                action: { executeMatchDockIcon(item) },
                type: .application,
                filePath: nil,
                contactData: nil,
                stableID: "match-dock-icon:\(item.id)"
            )
            result.score = 80_000 - Double(index)
            return result
        }
    }

    func transientGlobalScopedMenuRowCount(for query: String) -> Int {
        visibleGlobalScopedMenuNavigationState(for: query)?.totalCount ?? 0
    }

    func activeVisibleGlobalScopedMenuScope(for query: String) -> DockScopeResolution? {
        guard isGlobalContextActive, !hasSelectionScopeSurface else { return nil }

        let rawActionQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let target = l2.targetApp,
            !target.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return DockScopeResolution(
                scopedBundleId: target.bundleId,
                scopedAppName: target.name,
                scopedSearchQuery: rawActionQuery,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        if let inlineScope = globalInlineAppScope,
            !inlineScope.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return DockScopeResolution(
                scopedBundleId: inlineScope.bundleId,
                scopedAppName: inlineScope.appName,
                scopedSearchQuery: effectiveGlobalInlineActionQuery(query).lowercased(),
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        return activeGlobalInlineDockScope(for: query)
    }

    func visibleGlobalScopedMenuNavigationState(
        for query: String
    ) -> GlobalGroupedListNavigationState? {
        if currentGlobalScopedBundleID == "com.apple.finder", isFinderDesktopOnlyMode {
            return nil
        }
        guard let scope = activeVisibleGlobalScopedMenuScope(for: query),
            scope.isExplicitAppScope
        else { return nil }
        let scopedQuery = scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSystemCommandScope = scope.scopedBundleId.hasPrefix("syscmd://")
        let isCLIScope = scope.scopedBundleId.hasPrefix("cli://")
        let resolvedPills = cachedGlobalAppScopeDockPills(query: scopedQuery, scope: scope)
            .filter { pill in
                guard !pill.isSeparator else { return false }
                if isSystemCommandScope { return pill.rankingKind == "systemCommand" }
                if isCLIScope { return pill.rankingKind == "cliTool" }
                // Running-app capsules are isolated cached-menu scopes. Generic
                // content search, web search, app launch, window management, tools,
                // and Global Context actions belong to other surfaces.
                return ["menu", "submenuChild", "finderMenu"].contains(pill.rankingKind)
            }
        // System-command providers define semantic display order directly:
        // power control, summary, then devices. The shared result shell handles
        // its own dock transform, so keep the provider array unchanged.
        let pills = resolvedPills
        guard !pills.isEmpty else {
            return emptyGlobalGroupedListNavigationState()
        }
        let icon: NSImage? = {
            if isSystemCommandScope {
                let id = String(scope.scopedBundleId.dropFirst("syscmd://".count))
                if let uuid = UUID(uuidString: id),
                    let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == uuid })
                {
                    return NSImage(
                        systemSymbolName: command.icon,
                        accessibilityDescription: command.name
                    )
                }
            }
            if isCLIScope {
                return NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: scope.scopedAppName)
            }
            return resolvedApplicationIcon(
                bundleIdentifier: scope.scopedBundleId,
                appName: scope.scopedAppName
            )
        }()
        return GlobalGroupedListNavigationState(
            appResults: [],
            menuPills: pills,
            menuGroups: [],
            appMenuGroups: [
                AppMenuGroup(
                    id: scope.scopedBundleId,
                    appName: scope.scopedAppName,
                    icon: icon,
                    pills: pills
                )
            ],
            menuFirst: false
        )
    }

    func visibleGlobalGroupedListNavigationState(
        for query: String
    ) -> GlobalGroupedListNavigationState {
        if currentGlobalScopedBundleID == "com.apple.finder", isFinderDesktopOnlyMode {
            return emptyGlobalGroupedListNavigationState()
        }
        if currentGlobalScopedBundleID != nil {
            return visibleGlobalScopedMenuNavigationState(for: query)
                ?? emptyGlobalGroupedListNavigationState()
        }
        return visibleGlobalScopedMenuNavigationState(for: query)
            ?? globalGroupedListNavigationState(for: query)
    }

    func isActiveGlobalRunningAppMenuScope() -> Bool {
        guard isGlobalContextActive, currentGlobalScopedBundleID != nil else { return false }
        return !(currentGlobalScopedBundleID == "com.apple.finder" && isFinderDesktopOnlyMode)
    }

    func globalApplicationIdentityKey(
        for result: SearchResult,
        explicitBundleIdentifier: String? = nil
    ) -> String {
        if let bundleIdentifier =
            explicitBundleIdentifier ?? bundleIdentifier(forApplicationResult: result),
            !bundleIdentifier.isEmpty
        {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        if let path = result.filePath ?? (result.subtitle == "Running" ? nil : result.subtitle),
            !path.isEmpty
        {
            return "path:\(URL(fileURLWithPath: path).standardizedFileURL.path.lowercased())"
        }
        return "name:\(normalizedDockPillText(result.title))"
    }

    func dedupeGlobalApplicationResults(_ results: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        return results.filter { result in
            guard result.type == .application else { return true }
            return seen.insert(globalApplicationIdentityKey(for: result)).inserted
        }
    }

    func indexedGlobalDocuments(
        for query: String,
        limit: Int,
        includeCachedMenus: Bool = true,
        includeRunningCachedMenus: Bool = false
    ) -> [GlobalSearchService.SearchDocument] {
        guard GlobalSearchService.shared.documentCount > 0 else { return [] }
        let snapshot = GlobalContextSearchCoordinator.shared.snapshot(
            query: query,
            limit: limit,
            includeCachedMenus: includeCachedMenus,
            includeRunningCachedMenus: includeRunningCachedMenus
        )
        return snapshot.documents
    }

    func indexedAppDocuments(_ docs: [GlobalSearchService.SearchDocument])
        -> [GlobalSearchService.SearchDocument]
    {
        docs.filter { doc in
            if case .cachedMenu = doc.action { return false }
            if case .browserURL = doc.action { return false }
            return true
        }
    }

    func indexedRunningMenuDocuments(_ docs: [GlobalSearchService.SearchDocument])
        -> [GlobalSearchService.SearchDocument]
    {
        docs.filter { doc in
            if case .cachedMenu = doc.action { return true }
            if case .browserURL = doc.action { return true }
            return false
        }
    }

    func indexedInstalledAppDocuments(_ docs: [GlobalSearchService.SearchDocument])
        -> [GlobalSearchService.SearchDocument]
    {
        docs.filter { doc in
            if case .cachedMenu = doc.action { return false }
            if case .browserURL = doc.action { return false }
            if doc.sourceKind == .running { return false }
            switch doc.sourceKind {
            case .installed, .pinned, .builtIn:
                return true
            default:
                return false
            }
        }
    }

    func indexedRunningAppDocuments(_ docs: [GlobalSearchService.SearchDocument])
        -> [GlobalSearchService.SearchDocument]
    {
        docs.filter { doc in
            if case .cachedMenu = doc.action { return false }
            if case .browserURL = doc.action { return false }
            return doc.sourceKind == .running
        }
    }

    func mergeGlobalCommandRows(
        _ commandRows: [SearchResult],
        with appRows: [SearchResult],
        limit: Int
    ) -> [SearchResult] {
        mergeGlobalRowsPreservingPriority([appRows, commandRows], limit: limit)
    }

    func mergeGlobalRows(
        _ rowGroups: [[SearchResult]],
        limit: Int
    ) -> [SearchResult] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var merged: [SearchResult] = []
        let rows = rowGroups.flatMap { $0 }
        merged.reserveCapacity(min(limit, rows.count))
        for result in rows.sorted(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }) {
            let key = globalApplicationIdentityKey(for: result)
            guard seen.insert(key).inserted else { continue }
            merged.append(result)
            if merged.count >= limit { break }
        }
        return merged
    }

    func mergeGlobalRowsPreservingPriority(
        _ rowGroups: [[SearchResult]],
        limit: Int
    ) -> [SearchResult] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var merged: [SearchResult] = []
        for group in rowGroups {
            for result in group {
                let key = globalApplicationIdentityKey(for: result)
                guard seen.insert(key).inserted else { continue }
                merged.append(result)
                if merged.count >= limit { return merged }
            }
        }
        return merged
    }

    func isGlobalRunningAppTerminationQuery(_ query: String) -> Bool {
        let normalized = normalizedDockPillText(query)
        guard !normalized.isEmpty else { return false }
        return normalized == "quit" || normalized.hasPrefix("quit ")
    }

    func instantGlobalApplicationMatches(for query: String, limit: Int) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        if isGenericApplicationListQuery(q) {
            return groupedGlobalApplicationList(limit: limit)
        }

        let runningQuitRows = globalRunningAppQuitMatches(for: q, limit: max(limit, 12))
        if !runningQuitRows.isEmpty {
            let exactSystemCommandRows = globalSystemCommandPresetRows(
                for: normalizedDockPillText(q),
                limit: max(limit, 12)
            )
            return mergeGlobalRows(
                [runningQuitRows, exactSystemCommandRows],
                limit: limit
            )
        }

        let commandRows = globalSystemCommandScopeMatches(for: q, limit: min(limit, 8))

        // Hot index path: O(N) scan with precomputed strings, no alias-building per item.
        // Falls through to the full scan below only if the index is empty (first launch).
        if GlobalSearchService.shared.documentCount > 0 {
            let docs = GlobalContextSearchCoordinator.shared.snapshot(
                query: q,
                limit: limit * 3,
                includeCachedMenus: false,
                includeRunningCachedMenus: false
            ).appDocuments
            if !docs.isEmpty {
                let runningDocs = Array(indexedRunningAppDocuments(docs).prefix(limit))
                let runningRows =
                    runningDocs.isEmpty
                    ? globalRunningApplicationMatches(for: q, limit: limit)
                    : searchResults(from: runningDocs, query: q)
                let appRows = Array(
                    searchResults(from: indexedInstalledAppDocuments(docs), query: q).prefix(limit)
                )
                return mergeGlobalRowsPreservingPriority(
                    [runningRows, appRows, commandRows],
                    limit: limit
                )
            }
        }

        let exactSystemCommandRows = globalSystemCommandPresetRows(
            for: normalizedDockPillText(q),
            limit: max(limit, 12)
        )
        if !exactSystemCommandRows.isEmpty { return exactSystemCommandRows }

        var candidates: [(result: SearchResult, score: Double, order: Int)] = []
        var seen = Set<String>()
        var order = 0

        func add(_ result: SearchResult, bundleIdentifier explicitBundleId: String? = nil) {
            let title = result.title.lowercased()
            guard title.hasPrefix(q) || title.contains(q) else { return }
            let key = globalApplicationIdentityKey(
                for: result, explicitBundleIdentifier: explicitBundleId)
            guard seen.insert(key).inserted else { return }

            var enriched = result
            let prefixScore = title.hasPrefix(q) ? 9_000.0 : 5_000.0
            let runningBoost = explicitBundleId != nil ? 20_000.0 : 0
            enriched.score = runningBoost + prefixScore - Double(title.count)
            candidates.append((enriched, enriched.score, order))
            order += 1
        }

        // Command scopes are part of Global Actions. Show them before app launch rows
        // so a pinned CLI like `obsidian` is usable without opening Obsidian.app.
        for result in globalCLIScopeMatches(for: q, limit: limit - candidates.count) {
            let key = globalApplicationIdentityKey(
                for: result, explicitBundleIdentifier: result.subtitle)
            guard seen.insert(key).inserted else { continue }
            candidates.append((result, result.score, order))
            order += 1
        }

        for result in globalSystemCommandScopeMatches(for: q, limit: limit - candidates.count) {
            let key = globalApplicationIdentityKey(
                for: result, explicitBundleIdentifier: result.subtitle)
            guard seen.insert(key).inserted else { continue }
            candidates.append((result, result.score, order))
            order += 1
        }

        let runningSource =
            runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        for app in runningSource
        where candidates.count < limit && app.bundleIdentifier != "com.apple.finder" {
            guard let name = app.localizedName else { continue }
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: name,
                    bundleIdentifier: app.bundleIdentifier,
                    path: app.bundleURL?.path
                )
            else { continue }
            add(
                SearchResult(
                    title: name,
                    subtitle: app.bundleURL?.path ?? "Running",
                    icon: resolvedRunningAppIcon(for: app),
                    action: { activateRunningAppFromGlobalContext(app, forceHideLauncher: true) },
                    type: .application,
                    filePath: app.bundleURL?.path,
                    contactData: nil,
                    stableID: app.bundleIdentifier.map { "bundle:\($0)" }
                        ?? app.bundleURL.map { "path:\($0.path)" }
                ), bundleIdentifier: app.bundleIdentifier)
        }

        for app in allApplications where candidates.count < limit && app.type == .application {
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: app.title,
                    bundleIdentifier: nil,
                    path: app.subtitle
                )
            else { continue }
            add(app)
        }

        if isGlobalContextActive, q.count >= 3 {
            for result in recentDocumentGlobalMatches(for: q, limit: limit - candidates.count) {
                let key = globalApplicationIdentityKey(for: result)
                guard seen.insert(key).inserted else { continue }
                candidates.append((result, result.score, order))
                order += 1
            }
        }

        return
            candidates
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.order < $1.order
            }
            .map(\.result)
    }

    func globalRunningApplicationMatches(for query: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return [] }

        let runningSource =
            runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        var seen = Set<String>()
        var rows: [(result: SearchResult, score: Double)] = []
        rows.reserveCapacity(min(limit, runningSource.count))

        for app in runningSource {
            guard let name = app.localizedName, !name.isEmpty,
                app.bundleIdentifier != "com.apple.finder",
                app.bundleIdentifier != Bundle.main.bundleIdentifier,
                !app.isTerminated
            else { continue }
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: name,
                    bundleIdentifier: app.bundleIdentifier,
                    path: app.bundleURL?.path
                )
            else { continue }

            let normalizedName = normalizedDockPillText(name)
            let bundleTail =
                app.bundleIdentifier?
                .split(separator: ".")
                .last
                .map(String.init)
                .map(normalizedDockPillText) ?? ""
            let aliases = [
                normalizedName,
                bundleTail,
                normalizedName.replacingOccurrences(of: " ", with: ""),
            ].filter { !$0.isEmpty }
            guard aliases.contains(where: { $0.hasPrefix(q) || $0.contains(q) }) else {
                continue
            }

            let key =
                app.bundleIdentifier
                ?? app.bundleURL?.standardizedFileURL.path
                ?? "pid:\(app.processIdentifier)"
            guard seen.insert(key).inserted else { continue }

            var result = SearchResult(
                title: name,
                subtitle: "Running",
                icon: resolvedRunningAppIcon(for: app),
                action: { activateRunningAppFromGlobalContext(app, forceHideLauncher: true) },
                type: .application,
                filePath: app.bundleURL?.path,
                contactData: nil,
                stableID: app.bundleIdentifier.map { "bundle:\($0)" }
                    ?? app.bundleURL.map { "path:\($0.path)" }
            )
            let score: Double = {
                if normalizedName == q || bundleTail == q { return 32_000 }
                if normalizedName.hasPrefix(q) || bundleTail.hasPrefix(q) { return 30_000 }
                return 26_000
            }()
            result.score = score - Double(name.count)
            rows.append((result, result.score))
        }

        return rows.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.result.title.localizedCaseInsensitiveCompare($1.result.title)
                == .orderedAscending
        }
        .prefix(limit)
        .map(\.result)
    }

    func globalCLIScopeMatches(for query: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return [] }
        return terminalPackageManager.packages
            .filter(\.isEnabled)
            .filter(isUserAddedGlobalCLITool)
            .compactMap { package -> SearchResult? in
                let aliases = [package.command, package.name] + package.keywords
                guard
                    aliases.contains(where: {
                        let alias = normalizedDockPillText($0)
                        return alias.hasPrefix(q) || alias.contains(q)
                    })
                else { return nil }
                var result = SearchResult(
                    title: package.command,
                    // nil icon → ResultRow renders the green terminal.fill for .cliTool,
                    // matching the scope chip; a generic unix-executable NSImage showed an
                    // ugly grey box instead.
                    subtitle: "cli://\(package.command)",
                    icon: nil,
                    action: {
                        _ = activateInlineDockAppScope(
                            bundleIdentifier: "cli://\(package.command)",
                            appName: package.name.isEmpty ? package.command : package.name,
                            queryOverride: "",
                            preserveGlobalContext: true
                        )
                    },
                    type: .cliTool,
                    filePath: nil,
                    contactData: nil
                )
                result.score =
                    (normalizedDockPillText(package.command).hasPrefix(q) ? 34_000 : 30_000)
                    - Double(package.command.count)
                return result
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func globalRunningAppQuitMatches(for query: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let normalized = normalizedDockPillText(query)
        guard !normalized.isEmpty else { return [] }

        let verb = "quit"
        guard normalized == verb || normalized.hasPrefix("\(verb) ") else { return [] }

        let appQuery =
            normalized
            .dropFirst(verb.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runningSource = currentStoppableRunningApps(for: appQuery)

        var seen = Set<String>()
        return
            runningSource
            .compactMap { app -> (SearchResult, Double)? in
                guard let name = app.localizedName,
                    !name.isEmpty,
                    app.bundleIdentifier != "com.apple.finder",
                    app.bundleIdentifier != Bundle.main.bundleIdentifier,
                    !app.isTerminated
                else { return nil }
                guard
                    !shouldIgnoreApplicationFromAppSearch(
                        appName: name,
                        bundleIdentifier: app.bundleIdentifier,
                        path: app.bundleURL?.path
                    )
                else { return nil }

                let appName = normalizedDockPillText(name)
                let bundleTail =
                    app.bundleIdentifier?
                    .split(separator: ".")
                    .last
                    .map(String.init)
                    .map(normalizedDockPillText) ?? ""
                guard
                    appQuery.isEmpty
                        || appName.hasPrefix(appQuery)
                        || appName.contains(appQuery)
                        || (!bundleTail.isEmpty && bundleTail.contains(appQuery))
                else { return nil }

                let key = app.bundleIdentifier ?? app.bundleURL?.path ?? name
                guard seen.insert(key).inserted else { return nil }

                let capturedApp = app
                let actionTitlePrefix = "Quit"
                var result = SearchResult(
                    title: "\(actionTitlePrefix) \(name)",
                    subtitle: name,
                    icon: resolvedRunningAppIcon(for: app),
                    action: {
                        terminateRunningAppFromDock(capturedApp)
                    },
                    score: 0,
                    type: .extensionCommand,
                    filePath: app.bundleURL?.path,
                    contactData: nil,
                    displayBadges: ["Running App"],
                    showsTypeLabel: false,
                    dismissesLauncher: false,
                    stableID: "\(verb):\(key)"
                )
                let score: Double =
                    appQuery.isEmpty ? 9_400 : (appName.hasPrefix(appQuery) ? 9_800 : 7_200)
                result.score = score - Double(name.count)
                return (result, result.score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    func currentStoppableRunningApps(for appQuery: String) -> [NSRunningApplication] {
        let live = NSWorkspace.shared.runningApplications
        let cached = runningRegularApps
        var seen = Set<String>()
        return (live + cached).filter { app in
            guard !app.isTerminated,
                app.bundleIdentifier != "com.apple.finder",
                app.bundleIdentifier != Bundle.main.bundleIdentifier,
                let name = app.localizedName,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }

            let normalizedName = normalizedDockPillText(name)
            let normalizedBundleTail =
                app.bundleIdentifier?
                .split(separator: ".")
                .last
                .map(String.init)
                .map(normalizedDockPillText) ?? ""
            let matchesQuery =
                appQuery.isEmpty
                || normalizedName.hasPrefix(appQuery)
                || normalizedName.contains(appQuery)
                || (!normalizedBundleTail.isEmpty && normalizedBundleTail.contains(appQuery))

            let executablePath = app.executableURL?.standardizedFileURL.path ?? ""
            let isXcodeProduct =
                executablePath.contains("/DerivedData/")
                || executablePath.contains("/Build/Products/")
                || app.bundleURL?.standardizedFileURL.path.contains("/DerivedData/") == true
                || app.bundleURL?.standardizedFileURL.path.contains("/Build/Products/") == true
            let isUserVisible = app.activationPolicy == .regular
            let isNamedTarget = !appQuery.isEmpty && matchesQuery
            guard isUserVisible || isXcodeProduct || isNamedTarget else { return false }

            let key =
                app.bundleIdentifier
                ?? app.bundleURL?.standardizedFileURL.path
                ?? app.executableURL?.standardizedFileURL.path
                ?? "pid:\(app.processIdentifier)"
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    func isUserAddedGlobalCLITool(_ package: TerminalPackage) -> Bool {
        let command = package.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return false }
        if settings.isCLIToolPinned(command) { return true }
        let commandKey = normalizedDockPillText(command)
        let packageNameKey = normalizedDockPillText(package.name)
        if adapterManager.adapters.contains(where: { adapter in
            let adapterKey = normalizedDockPillText(adapter.bundleId)
            let adapterNameKey = normalizedDockPillText(adapter.appName)
            if adapter.bundleId.lowercased().hasPrefix("cli://") {
                return adapterKey.contains(commandKey)
                    || (!packageNameKey.isEmpty && adapterKey.contains(packageNameKey))
                    || adapterNameKey == commandKey
                    || (!packageNameKey.isEmpty && adapterNameKey == packageNameKey)
            }
            return adapter.actions.contains { action in
                action.type == .cliTool
                    && (action.cliToolCommand ?? "").caseInsensitiveCompare(command) == .orderedSame
            }
        }) {
            return true
        }
        let scopeIds = Set(["cli://\(command)", "cli_\(command)", command])
        return package.contextAppBundleIds.contains { scopeIds.contains($0) }
    }

    func globalSystemCommandScopeMatches(for query: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return [] }
        // Provider-backed commands (Bluetooth/Wi-Fi) remain a single parent row in
        // global search. Enumerating private device data belongs to the explicit scope,
        // not typing or ghost completion.
        let matchesProviderCommand = SystemCommandsRegistry.shared.commands.contains { command in
            command.isEnabled
                && systemCommandProviderName(command) != nil
                && ([command.name] + command.keywords).map(normalizedDockPillText).contains(q)
        }
        let exactPresetRows = matchesProviderCommand
            ? [] : globalSystemCommandPresetRows(for: q, limit: limit)
        if !exactPresetRows.isEmpty { return exactPresetRows }
        return SystemCommandsRegistry.shared.commands
            .filter(\.isEnabled)
            .compactMap { command -> SearchResult? in
                let aliases = [command.name] + command.keywords
                guard
                    aliases.contains(where: {
                        let alias = normalizedDockPillText($0)
                        return alias.hasPrefix(q) || alias.contains(q)
                    })
                else { return nil }
                var result = SearchResult(
                    title: command.name,
                    subtitle: "syscmd://\(command.id.uuidString)",
                    icon: NSImage(
                        systemSymbolName: command.icon, accessibilityDescription: command.name)
                        ?? NSImage(),
                    action: {
                        runSystemCommand(command, originalQuery: query)
                    },
                    type: .extensionCommand,
                    filePath: nil,
                    contactData: nil,
                    displayBadges: [command.actionTypeLabel],
                    showsTypeLabel: false,
                    stableID: "syscmd://\(command.id.uuidString)"
                )
                result.dismissesLauncher = true
                result.score =
                    (normalizedDockPillText(command.name).hasPrefix(q) ? 33_000 : 29_000)
                    - Double(command.name.count)
                return result
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func globalSystemCommandPresetRows(for normalizedQuery: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        guard
            let command = SystemCommandsRegistry.shared.commands.first(where: { command in
                guard command.isEnabled else { return false }
                return ([command.name] + command.keywords)
                    .map(normalizedDockPillText)
                    .contains(normalizedQuery)
            })
        else { return [] }

        let terms = ([command.name] + command.keywords).map(normalizedDockPillText)
        let isVolume = terms.contains { $0.contains("volume") }
        let dynamicItems = systemCommandDynamicItems(command)
        if !dynamicItems.isEmpty {
            return dynamicItems.prefix(limit).enumerated().map { index, item in
                var result = SearchResult(
                    title: "\(command.name) \(item.title)",
                    subtitle: "syscmd://\(command.id.uuidString)",
                    icon: NSImage(
                        systemSymbolName: command.icon, accessibilityDescription: command.name)
                        ?? NSImage(),
                    action: {
                        runSystemCommand(command, originalQuery: item.value)
                    },
                    score: 9_800 - Double(index),
                    type: .extensionCommand,
                    filePath: nil,
                    contactData: nil,
                    displayBadges: [item.subtitle, command.actionTypeLabel],
                    showsTypeLabel: false,
                    stableID: "syscmd:\(command.id.uuidString):dynamic:\(item.value)"
                )
                result.dismissesLauncher = true
                return result
            }
        }
        let presets = systemCommandPresetValues(command, fallbackVolume: isVolume)
        guard !presets.isEmpty else { return [] }

        return presets.prefix(limit).enumerated().map { index, value in
            var result = SearchResult(
                title: "\(command.name) \(value)",
                subtitle: "syscmd://\(command.id.uuidString)",
                icon: NSImage(
                    systemSymbolName: command.icon, accessibilityDescription: command.name)
                    ?? NSImage(),
                action: {
                    runSystemCommand(command, originalQuery: value)
                },
                score: 9_500 - Double(index),
                type: .extensionCommand,
                filePath: nil,
                contactData: nil,
                displayBadges: [command.actionTypeLabel],
                showsTypeLabel: false,
                stableID: "syscmd:\(command.id.uuidString):preset:\(value)"
            )
            result.dismissesLauncher = true
            return result
        }
    }

    func recentDocumentGlobalMatches(for query: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 3 else { return [] }
        let isRecentIntent = [
            "recent", "recents", "recent file", "recent files",
            "recent document", "recent documents",
        ].contains(normalizedDockPillText(q))

        return RecentItemsService.shared.recentDocuments()
            .enumerated()
            .compactMap { index, doc -> SearchResult? in
                let name = doc.name.lowercased()
                guard isRecentIntent || name.contains(q) else { return nil }
                let url = doc.url
                var result = SearchResult(
                    title: doc.name,
                    subtitle: url.deletingLastPathComponent().path,
                    icon: doc.icon,
                    action: { NSWorkspace.shared.open(url) },
                    type: .document,
                    filePath: url.path,
                    contactData: nil,
                    stableID: "recent:\(url.standardizedFileURL.path)"
                )
                result.score =
                    isRecentIntent
                    ? 2_700 - Double(index)
                    : (name.hasPrefix(q) ? 2_500 - Double(name.count) : 1_800)
                return result
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func hasStrongGlobalAppMatch(query: String, appMatches: [SearchResult]) -> Bool {
        let q = normalizedDockPillText(query)
        guard !q.isEmpty, let first = appMatches.first else { return false }
        let title = normalizedDockPillText(first.title)
        if title == q || title.hasPrefix(q) { return true }
        return first.score >= 8_900
    }

    func shouldIncludeFrontmostGlobalMenuResults(
        query: String,
        appMatches: [SearchResult],
        isGenericAppQuery: Bool
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isGenericAppQuery else { return false }
        if frontmost.bundleID == "com.apple.finder" { return false }
        return true
    }

    func shouldIncludeCrossAppGlobalMenuResults(
        query: String,
        appMatches: [SearchResult],
        isGenericAppQuery: Bool
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isGenericAppQuery else { return false }
        guard q.count >= 3 else { return false }
        return true
    }

    var shouldShowGlobalInputLoadingIndicator: Bool {
        guard isGlobalContextActive, shouldUsePureGlobalAppSearch else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let groupedKey = globalGroupedStateCacheKey(for: q)
        guard !q.isEmpty else { return false }
        if globalContextViewModel.isResolvingFastMatches { return true }
        // Committed state for the current query → done, no spinner.
        if cachedGlobalGroupedQuery == groupedKey, cachedGlobalGroupedState != nil {
            return false
        }
        if searchState.isLoadingApps { return q.count >= 3 }
        // Build in flight for this query (coalesced keystroke rebuild) → spinner.
        return pendingGlobalAppQuery == q || pendingGlobalGroupedQuery == q
    }

    var shouldShowContextDockInputLoadingIndicator: Bool {
        guard showContextInDock,
            !isGlobalContextActive,
            !aiMode.isActive,
            !showMediaLayer
        else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pillQuery = shouldUseFinderSearchPopover(for: q) ? "" : q
        return cachedDockPills.isEmpty && pendingDockPillQuery == pillQuery
    }

    func isGenericApplicationListQuery(_ query: String) -> Bool {
        switch normalizedDockPillText(query) {
        case "app", "apps", "application", "applications":
            return true
        default:
            return false
        }
    }

    func isQuestionStyleDockQuery(_ query: String) -> Bool {
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return false }
        if query.contains("?") { return true }

        let prefixes = [
            "what", "which", "who", "when", "where", "why", "how",
            "is", "are", "was", "were", "do", "does", "did",
            "can", "could", "would", "should", "tell", "explain",
            "describe", "summarize", "analyse", "analyze",
        ]
        return prefixes.contains { prefix in
            q == prefix || q.hasPrefix(prefix + " ")
        }
    }

    func bundleIdentifier(forApplicationResult result: SearchResult) -> String? {
        let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if subtitle.hasPrefix("cli://") || subtitle.hasPrefix("syscmd://") {
            return subtitle
        }
        if let path = result.filePath, !path.isEmpty {
            return bundleIdentifierForApplicationPath(path)
        }
        if let running = runningRegularApps.first(where: {
            ($0.localizedName ?? "").caseInsensitiveCompare(result.title) == .orderedSame
        }), let bundleId = running.bundleIdentifier {
            return bundleId
        }
        if let appPath = allApplications.first(where: {
            $0.title.caseInsensitiveCompare(result.title) == .orderedSame
        })?.filePath {
            return bundleIdentifierForApplicationPath(appPath)
        }
        guard !subtitle.isEmpty else { return nil }
        return bundleIdentifierForApplicationPath(subtitle)
    }

    func rankedTextMatchScore(
        query: String,
        primary: String,
        aliases: [String] = [],
        contexts: [String] = []
    ) -> Double? {
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return nil }

        let primaryText = normalizedDockPillText(primary)
        let aliasTexts = aliases.map(normalizedDockPillText).filter {
            !$0.isEmpty && $0 != primaryText
        }
        let contextTexts = contexts.map(normalizedDockPillText).filter { !$0.isEmpty }
        let queryTokens = q.split(separator: " ").map(String.init)

        func wordPrefixScore(_ text: String, base: Double) -> Double? {
            let words = text.split(separator: " ").map(String.init)
            guard let idx = words.firstIndex(where: { $0.hasPrefix(q) }) else { return nil }
            return base - Double(idx * 34) - min(Double(text.count), 42)
        }

        var best: Double?
        func keep(_ score: Double?) {
            guard let score else { return }
            best = max(best ?? -Double.infinity, score)
        }

        if primaryText == q { keep(12_000) }
        if aliasTexts.contains(q) { keep(10_600) }
        if primaryText.hasPrefix(q) {
            keep(9_600 + Double(q.count * 20) - min(Double(primaryText.count), 48))
        }
        keep(wordPrefixScore(primaryText, base: 8_900 + Double(q.count * 12)))

        for alias in aliasTexts {
            if alias.hasPrefix(q) {
                keep(8_250 + Double(q.count * 14) - min(Double(alias.count), 48))
            }
            keep(wordPrefixScore(alias, base: 7_700 + Double(q.count * 10)))
        }

        for context in contextTexts {
            if context == q { keep(6_800) }
            if context.hasPrefix(q) { keep(6_100 - min(Double(context.count), 48)) }
            keep(wordPrefixScore(context, base: 5_700))
        }

        if q.count >= 2 {
            if let range = primaryText.range(of: q) {
                let offset = primaryText.distance(
                    from: primaryText.startIndex, to: range.lowerBound)
                keep(4_900 - Double(offset * 72) - min(Double(primaryText.count), 48))
            }
            for alias in aliasTexts {
                if let range = alias.range(of: q) {
                    let offset = alias.distance(from: alias.startIndex, to: range.lowerBound)
                    keep(4_250 - Double(offset * 58) - min(Double(alias.count), 48))
                }
            }
            for context in contextTexts where context.contains(q) {
                keep(3_400 - min(Double(context.count), 48))
            }
        }

        if queryTokens.count > 1 {
            let primaryTokens = Set(dockPillTokens(primaryText))
            let aliasTokens = Set(aliasTexts.flatMap(dockPillTokens))
            let contextTokens = Set(contextTexts.flatMap(dockPillTokens))
            let qSet = Set(queryTokens)
            keep(Double(qSet.intersection(primaryTokens).count) * 820)
            keep(Double(qSet.intersection(aliasTokens).count) * 680)
            keep(Double(qSet.intersection(contextTokens).count) * 420)
        }

        return best
    }

    func appSearchMatchScore(
        query: String,
        appName: String,
        bundleIdentifier: String?
    ) -> Double? {
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return nil }

        let aliases = dockPillAppAliases(appName: appName, bundleId: bundleIdentifier ?? "")
        guard var score = rankedTextMatchScore(query: q, primary: appName, aliases: aliases) else {
            return nil
        }
        if bundleIdentifier == "com.apple.Photos", q == "photos" {
            score += 2_000
        }
        // Usage-aware ranking (Raycast/Spotlight-style learning): apps the user actually
        // launches climb, and apps they've NEVER opened are demoted — so a perfect name
        // match on an unused app (e.g. QuickTime for "qu") doesn't auto-win the top slot
        // over apps the user uses daily. The boost is sized to break ties within a match
        // tier without overriding a clearly stronger name match.
        let frecency = UsageTracker.shared.getScore(for: "app:\(bundleIdentifier ?? appName)")
        let learned = AppUsageLearner.shared.score(forBundleID: bundleIdentifier ?? "")
        let usageSignal = frecency / 6.0 + learned * 6.0
        if usageSignal > 0 {
            score += min(usageSignal, 1_000)
        } else {
            score -= 500
        }
        return score
    }

    func pureGlobalAppMenuFallbackScope(
        for query: String,
        appMatches: [SearchResult]? = nil
    ) -> DockScopeResolution? {
        guard shouldUsePureGlobalAppSearch else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.split(separator: " ").count >= 2 else { return nil }
        guard (appMatches ?? currentGlobalAppMatches(for: q)).isEmpty else { return nil }

        let scope = resolveDockScope(for: q)
        let actionQuery = scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope.isExplicitAppScope, !actionQuery.isEmpty else { return nil }
        return scope
    }

    func focusedDockPillForInputPreview() -> DockPill? {
        guard usesVerticalListDockLayout,
            let idx = l2.focusedPillIndex
        else { return nil }

        if shouldUsePureGlobalAppSearch {
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let state = visibleGlobalGroupedListNavigationState(for: q)
            let menuIndex = idx - state.appResults.count
            guard menuIndex >= 0,
                menuIndex < state.menuPills.count,
                !state.menuPills[menuIndex].isSeparator
            else { return nil }
            return state.menuPills[menuIndex]
        }

        let q =
            isL2ContextActive
            ? searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : ""
        let pillQuery = shouldUseFinderSearchPopover(for: q) ? "" : q
        let pills = currentVisibleDockPills(for: pillQuery)
        guard idx >= 0, idx < pills.count, !pills[idx].isSeparator else { return nil }
        return pills[idx]
    }

    func focusedGlobalAppResultForInputPreview() -> SearchResult? {
        guard usesVerticalListDockLayout,
            isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            let idx = focusedAppPillIndex
        else { return nil }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = visibleGlobalGroupedListNavigationState(for: q)
        guard idx >= 0, idx < state.appResults.count else { return nil }
        return state.appResults[idx]
    }

    func topGlobalAppResultForInputPreview() -> SearchResult? {
        guard shouldUsePureGlobalAppSearch else { return nil }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let prepared = globalContextViewModel.preparedResults,
            prepared.query == q
        {
            return prepared.navigationState?.appResults.first
        }
        return globalGroupedListNavigationState(for: q).appResults.first
    }

    func moveGlobalAppResultFocus(direction: Int) -> Bool {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = visibleGlobalGroupedListNavigationState(for: q)
        if state.totalCount > 0 || isActiveGlobalRunningAppMenuScope() {
            return moveGlobalGroupedListFocus(direction: direction)
        }
        let matches =
            state.appResults.isEmpty
            ? currentGlobalAppMatches(for: q)
            : state.appResults
        guard !matches.isEmpty else {
            focusedAppPillIndex = nil
            l2.pillNavViaKeyboard = false
            return false
        }

        if direction > 0 {
            // Row 0 is shown pre-selected (render default) while typing even though
            // focusedAppPillIndex is nil — start from it so the first Down goes to the second row.
            let start = focusedAppPillIndex ?? (q.isEmpty ? -1 : 0)
            let next = min(start + 1, matches.count - 1)
            focusedAppPillIndex = next
            l2.pillNavViaKeyboard = true
            return true
        }

        if direction < 0 {
            // At the first row (explicit index 0, or the render-default first where index is nil):
            // Up returns to the input with the query selected, Spotlight-style.
            guard let current = focusedAppPillIndex, current > 0 else {
                DispatchQueue.main.async { self.reclaimSearchInputFocusSelectingAll() }
                return true
            }
            focusedAppPillIndex = current - 1
            l2.pillNavViaKeyboard = true
            return true
        }

        return true
    }

    struct GlobalInputLoadingDots: View {
        @Environment(\.accessibilityReduceMotion) var reduceMotion

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let dotCount = 10
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) * 0.36
                    let dotSize = min(size.width, size.height) * 0.10
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                    for index in 0..<dotCount {
                        let progress = (Double(index) / Double(dotCount) + time * 1.15)
                            .truncatingRemainder(dividingBy: 1)
                        let angle = Double(index) / Double(dotCount) * .pi * 2
                        let x = center.x + CGFloat(cos(angle)) * radius
                        let y = center.y + CGFloat(sin(angle)) * radius
                        let opacity = 0.18 + progress * 0.72
                        let rect = CGRect(
                            x: x - dotSize / 2,
                            y: y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(Color.accentColor.opacity(opacity))
                        )
                    }
                }
            }
            .accessibilityLabel("Loading")
        }
    }

    /// Three-layer intent signal: learned picks → verb heuristic → on-device AI cache.
    func intentFavorsMenu(_ q: String) -> Bool {
        guard !q.isEmpty else { return false }

        // Layer 1: user's own pick history — strongest signal, overrides everything
        if let pref = AppUsageLearner.shared.intentPreference(for: q) {
            return pref > 0
        }

        // Layer 2: static heuristics (cold start)
        if q.contains(" ") { return true }
        let actionVerbs: Set<String> = [
            "close", "quit", "stop", "pause", "play", "resume", "save", "undo", "redo", "copy", "paste", "cut",
            "find", "select", "zoom", "hide", "minimize", "print", "export",
            "import", "share", "delete", "duplicate", "rename", "refresh",
            "reload", "bookmark", "history", "preferences", "settings",
            "help", "fullscreen", "revert", "lock", "sleep", "restart",
            "shutdown", "eject", "connect", "disconnect", "inspect",
        ]
        if actionVerbs.contains(q) { return true }
        if q.count >= 3, actionVerbs.contains(where: { $0.hasPrefix(q) }) { return true }

        // Layer 3: on-device AI cache — async result from previous keystroke
        if let aiPref = QueryIntentCache.shared.cachedIntent(for: q) {
            return aiPref
        }
        // Trigger classification for next keystroke (fire-and-forget)
        QueryIntentCache.shared.classify(q)
        return false
    }

    func emptyGlobalGroupedListNavigationState() -> GlobalGroupedListNavigationState {
        GlobalGroupedListNavigationState(appResults: [], menuPills: [])
    }

    func globalGroupedListNavigationState(for query: String)
        -> GlobalGroupedListNavigationState
    {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheKey = globalGroupedStateCacheKey(for: q)
        guard !q.isEmpty || globalInlineAppScope != nil else {
            return emptyGlobalGroupedListNavigationState()
        }
        if cachedGlobalGroupedQuery == cacheKey, let state = cachedGlobalGroupedState {
            return state
        }
        // While the detached fast matcher is replacing an expanded sheet, retain its
        // already-published lightweight rows. Do not fall back to synchronous index work
        // on the main actor for every keystroke.
        if globalContextViewModel.isResolvingFastMatches {
            return emptyGlobalGroupedListNavigationState()
        }
        // SwiftUI presentation reads this method many times per frame. Never start full
        // indexed/grouped search work from body evaluation; only consume committed state.
        // The detached preparation pipeline publishes the snapshot before expansion.
        return emptyGlobalGroupedListNavigationState()
    }

    func globalGroupedStateCacheKey(for normalizedQuery: String) -> String {
        let scopes =
            allGlobalInlineAppScopes
            .map { $0.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        guard !scopes.isEmpty else { return normalizedQuery }
        return "\(normalizedQuery)#scope:\(scopes)"
    }

    func instantGlobalGroupedListNavigationState(for query: String)
        -> GlobalGroupedListNavigationState
    {
        let started = Date()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func finish(
            _ state: GlobalGroupedListNavigationState,
            label: String = "instantGlobalGroupedListNavigationState"
        ) -> GlobalGroupedListNavigationState {
            let elapsedMS = Date().timeIntervalSince(started) * 1_000
            if elapsedMS >= 8 {
                SearchPerformanceLog.shared.record(
                    label: label,
                    elapsedMS: elapsedMS,
                    query: q,
                    pills: state.appResults.count + state.menuPills.count
                )
            }
            return state
        }
        guard shouldUsePureGlobalAppSearch, !q.isEmpty || globalInlineAppScope != nil else {
            return finish(
                emptyGlobalGroupedListNavigationState(),
                label: "instantGlobalGroupedListNavigationState.empty"
            )
        }
        if let inlineScope = globalInlineAppScope {
            if isFinderDesktopOnlyMode, inlineScope.bundleId == "com.apple.finder" {
                let scopedQuery = effectiveGlobalInlineActionQuery(q)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let finderPills =
                    !scopedQuery.isEmpty && finderSemanticQuery == scopedQuery
                    ? finderSemanticPills
                    : []
                let icon =
                    FileManager.default.fileExists(atPath: inlineScope.appPath)
                    ? NSWorkspace.shared.icon(forFile: inlineScope.appPath)
                    : resolvedApplicationIcon(
                        bundleIdentifier: inlineScope.bundleId,
                        appName: inlineScope.appName
                    )
                let groups =
                    finderPills.isEmpty
                    ? []
                    : [
                        AppMenuGroup(
                            id: "finder-desktop-files-\(inlineScope.bundleId)",
                            appName: inlineScope.appName,
                            icon: icon,
                            pills: finderPills
                        )
                    ]
                return finish(
                    GlobalGroupedListNavigationState(
                        appResults: [],
                        menuPills: finderPills,
                        menuGroups: [],
                        appMenuGroups: groups,
                        menuFirst: false
                    ),
                    label: "instantGlobalGroupedListNavigationState.finderDesktopOnly"
                )
            }
            let groups = cachedGlobalInlineAppScopeGroups(query: q)
            var resolvedGroups = groups
            if isBrowserMenuSource(inlineScope.bundleId) {
                let urlPills = buildBrowserURLLibraryPills(
                    query: q,
                    scopedBrowserBundleId: inlineScope.bundleId,
                    requireExplicitHistoryQuery: false,
                    limit: maxListViewDockPills
                )
                if !urlPills.isEmpty {
                    let icon =
                        resolvedApplicationIcon(
                            bundleIdentifier: inlineScope.bundleId,
                            appName: inlineScope.appName
                        )
                        ?? (FileManager.default.fileExists(atPath: inlineScope.appPath)
                            ? NSWorkspace.shared.icon(forFile: inlineScope.appPath)
                            : nil)
                    resolvedGroups.insert(
                        AppMenuGroup(
                            id: "browser-url-scope-\(inlineScope.bundleId)",
                            appName: inlineScope.appName,
                            icon: icon,
                            pills: urlPills
                        ),
                        at: 0
                    )
                }
            }
            let pills = resolvedGroups.flatMap(\.pills)
            return finish(
                GlobalGroupedListNavigationState(
                    appResults: [],
                    menuPills: pills,
                    menuGroups: [],
                    appMenuGroups: resolvedGroups,
                    menuFirst: false
                ))
        }
        let isTerminationQuery = isGlobalRunningAppTerminationQuery(q)
        let isMenuActionQuery = intentFavorsMenu(q)
        let appRowLimit: Int = {
            if isTerminationQuery { return min(12, maxListViewDockPills) }
            if isMenuActionQuery { return min(4, maxListViewDockPills) }
            return min(maxListViewDockPills, 12)
        }()
        let indexedDocsForQuery =
            q.count >= 2 && GlobalSearchService.shared.documentCount > 0
            ? indexedGlobalDocuments(
                for: q,
                // Match the detached preparation key so auto-expansion consumes its hot
                // cached snapshot instead of repeating the index query on the main actor.
                limit: 48,
                includeCachedMenus: true,
                includeRunningCachedMenus: true
            )
            : []
        let appResults: [SearchResult] = {
            let runningRows =
                isTerminationQuery
                ? globalRunningAppQuitMatches(for: q, limit: appRowLimit)
                : globalRunningApplicationMatches(for: q, limit: appRowLimit)
            let commandRows = globalSystemCommandScopeMatches(
                for: q,
                limit: min(6, appRowLimit)
            )
            let appRows = instantGlobalApplicationMatches(for: q, limit: appRowLimit)
            let indexedRows =
                indexedDocsForQuery.isEmpty
                ? []
                : Array(
                    searchResults(
                        from: indexedDocsForQuery.filter { doc in
                            if case .cachedMenu = doc.action { return false }
                            if case .browserURL = doc.action { return false }
                            return true
                        },
                        query: q
                    )
                    .prefix(appRowLimit)
                )
            if isTerminationQuery {
                return mergeGlobalRowsPreservingPriority(
                    [runningRows, commandRows, appRows],
                    limit: appRowLimit
                )
            }
            let strongCommandMatch = commandRows.first.map {
                normalizedDockPillText($0.title).hasPrefix(q)
            } ?? false
            if !indexedRows.isEmpty {
                return mergeGlobalRowsPreservingPriority(
                    strongCommandMatch
                        ? [commandRows, appRows, runningRows, indexedRows]
                        : [appRows, commandRows, runningRows, indexedRows],
                    limit: appRowLimit
                )
            }
            return mergeGlobalRowsPreservingPriority(
                strongCommandMatch
                    ? [commandRows, appRows, runningRows]
                    : [appRows, commandRows, runningRows],
                limit: appRowLimit
            )
        }()
        // 1-char queries: apps/commands only. From 2 chars onward the hot index can
        // cheaply include running/cached menu hits too, so "sl" is not command-only.
        if q.count < 2, !isTerminationQuery {
            return finish(
                GlobalGroupedListNavigationState(
                    appResults: appResults,
                    menuPills: [],
                    menuGroups: [],
                    appMenuGroups: [],
                    menuFirst: false
                ), label: "instantGlobalGroupedListNavigationState.singleChar")
        }
        let runningMenuGroupCount = max(
            currentRegularRunningApps().count,
            runningRegularApps.count
        )
        let menuGroupLimit = max(
            isMenuActionQuery ? 8 : 4,
            min(16, runningMenuGroupCount)
        )
        let menuBudget =
            isTerminationQuery
            ? max(8, maxListViewDockPills - appResults.count)
            : isMenuActionQuery
                ? max(12, maxListViewDockPills - appResults.count)
                : max(0, maxListViewDockPills - appResults.count)
        let indexedDocs =
            menuBudget > 0 ? indexedDocsForQuery : []
        let indexedMenuDocs = indexedRunningMenuDocuments(indexedDocs)
        let fallbackMenuGroups =
            indexedMenuDocs.isEmpty
            ? runningCachedMenuGroups(
                for: q,
                maxGroups: menuGroupLimit,
                maxPills: menuBudget
            )
            : []
        let remainingMenuBudget = max(0, menuBudget - fallbackMenuGroups.flatMap(\.pills).count)
        let menuGroups = indexedRunningMenuGroups(
            from: indexedMenuDocs,
            maxGroups: menuGroupLimit,
            maxPills: remainingMenuBudget
        )
        let existingMenuBundleIds = Set(
            (menuGroups + fallbackMenuGroups)
                .flatMap { group in
                    [group.id] + group.pills.compactMap(\.sourceBundleId)
                }
                .map(normalizedDockPillText)
        )
        let cachedMenuAppGroups =
            indexedMenuDocs.isEmpty
            ? cachedMenuCapabilityGroups(
                for: q,
                excludingBundleIds: existingMenuBundleIds,
                maxGroups: menuGroupLimit,
                maxPills: menuBudget
            )
            : []
        let resolvedMenuGroups =
            mergeRunningMenuGroups(
                indexed: menuGroups,
                cached: fallbackMenuGroups + cachedMenuAppGroups,
                maxGroups: menuGroupLimit,
                maxPills: menuBudget
            )
        let menuPills = resolvedMenuGroups.flatMap { $0.pills }
        return finish(
            GlobalGroupedListNavigationState(
                appResults: appResults,
                menuPills: menuPills,
                menuGroups: [],
                appMenuGroups: resolvedMenuGroups,
                menuFirst: isMenuActionQuery && !isTerminationQuery
                    && !globalAppRowsBeginWithSystemCommand(appResults)
                    && !globalAppRowsContainStrongApplicationMatch(appResults, query: q)
            ))
    }

    func globalAppRowsBeginWithSystemCommand(_ rows: [SearchResult]) -> Bool {
        rows.first?.id.hasPrefix("syscmd://") == true
    }

    func globalAppRowsContainStrongApplicationMatch(
        _ rows: [SearchResult],
        query: String
    ) -> Bool {
        let q = normalizedDockPillText(query)
        guard !q.isEmpty else { return false }
        let qTokens = q.split(separator: " ").map(String.init)
        return rows.prefix(4).contains { result in
            guard result.type == .application else { return false }
            let title = normalizedDockPillText(result.title)
            guard !title.isEmpty else { return false }
            if title == q || title.hasPrefix(q) || q.hasPrefix(title) { return true }
            let titleTokens = Set(title.split(separator: " ").map(String.init))
            return !qTokens.isEmpty && qTokens.allSatisfy { token in
                titleTokens.contains(token) || title.hasPrefix(token)
            }
        }
    }

    func setCachedGlobalGroupedState(
        query: String,
        state: GlobalGroupedListNavigationState,
        animated: Bool
    ) {
        let cacheKey = globalGroupedStateCacheKey(
            for: query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        let commitState = state.cappedForCommit(maxRows: maxListViewDockPills)
        let fingerprint = commitState.renderFingerprint
        if globalContextViewModel.cachedGroupedFingerprint == fingerprint {
            cachedGlobalGroupedQuery = cacheKey
            return
        }

        let currentQuery = searchState.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard query.isEmpty || currentQuery == query || globalInlineAppScope != nil else { return }
        guard globalContextViewModel.cachedGroupedFingerprint != fingerprint else {
            cachedGlobalGroupedQuery = cacheKey
            return
        }

        if cachedGlobalGroupedQuery != cacheKey
            || globalContextViewModel.cachedGroupedFingerprint != fingerprint
        {
            measuredGlobalListContentHeight = 0
        }

        globalContextViewModel.cachedGroupedFingerprint = fingerprint
        let signpostState = SearchPerformanceLog.shared.beginInterval(
            "global.stateCommit",
            query: query
        )
        defer {
            SearchPerformanceLog.shared.endInterval("global.stateCommit", state: signpostState)
        }

        if animated {
            cachedGlobalGroupedQuery = cacheKey
            cachedGlobalGroupedState = commitState
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                cachedGlobalGroupedQuery = cacheKey
                cachedGlobalGroupedState = commitState
            }
        }
    }

    func scheduleGlobalGroupedListRebuild(
        query: String, delayNanoseconds: UInt64 = 140_000_000
    ) {
        let scheduleStarted = Date()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        globalGroupedGeneration &+= 1
        globalGroupedTask?.cancel()
        guard !q.isEmpty || globalInlineAppScope != nil, !isQuestionStyleDockQuery(q) else {
            cachedGlobalGroupedQuery = ""
            cachedGlobalGroupedState = nil
            globalContextViewModel.cachedGroupedFingerprint = ""
            measuredGlobalListContentHeight = 0
            pendingGlobalGroupedQuery = nil
            return
        }

        guard shouldUsePureGlobalAppSearch, !q.isEmpty || globalInlineAppScope != nil else {
            setCachedGlobalGroupedState(
                query: q,
                state: emptyGlobalGroupedListNavigationState(),
                animated: false
            )
            pendingGlobalGroupedQuery = nil
            globalGroupedTask = nil
            return
        }

        let commit: () -> Void = {
            let state = self.instantGlobalGroupedListNavigationState(for: q)
            self.setCachedGlobalGroupedState(query: q, state: state, animated: false)
            self.pendingGlobalGroupedQuery = nil
            self.globalGroupedTask = nil

            let elapsedMS = Date().timeIntervalSince(scheduleStarted) * 1_000
            if elapsedMS >= 8 {
                SearchPerformanceLog.shared.record(
                    label: "scheduleGlobalGroupedListRebuild.commit",
                    elapsedMS: elapsedMS,
                    query: q,
                    pills: state.appResults.count + state.menuPills.count
                )
            }
        }

        guard delayNanoseconds > 0 else {
            commit()
            return
        }
        // Keystroke path: coalesce — the build runs between keystrokes, never inside
        // the key event, so typing stays fluid. Cancelled by the next keystroke.
        let generation = globalGroupedGeneration
        pendingGlobalGroupedQuery = q
        globalGroupedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, self.globalGroupedGeneration == generation else { return }
            commit()
        }
    }

    func refreshVisibleGlobalContextAfterMenuCacheUpdate(bundleIdentifier: String? = nil) {
        guard isGlobalContextActive else { return }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty || globalInlineAppScope != nil else { return }

        if let bundleIdentifier,
            let scope = globalInlineAppScope,
            scope.bundleId != bundleIdentifier
        {
            return
        }

        scheduleGlobalGroupedListRebuild(query: q, delayNanoseconds: 0)
    }

    func buildGlobalGroupedListNavigationState(for query: String)
        -> GlobalGroupedListNavigationState
    {
        SearchPerformanceLog.shared.signpost("global.buildGroupedState", query: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard shouldUsePureGlobalAppSearch, !q.isEmpty || globalInlineAppScope != nil else {
                return emptyGlobalGroupedListNavigationState()
            }
            return instantGlobalGroupedListNavigationState(for: q)
        }
    }

    func groupMenuPillsByTitle(_ pills: [DockPill]) -> [MenuPillGroup] {
        var seen: [String: Int] = [:]
        var groups: [MenuPillGroup] = []
        for pill in pills {
            let key = normalizedDockPillText(pill.name)
            if let idx = seen[key] {
                let g = groups[idx]
                groups[idx] = MenuPillGroup(
                    id: g.id, primaryPill: g.primaryPill, allPills: g.allPills + [pill])
            } else {
                seen[key] = groups.count
                groups.append(MenuPillGroup(id: key, primaryPill: pill, allPills: [pill]))
            }
        }
        return groups
    }

    func currentGlobalGroupedFocusIndex(
        state: GlobalGroupedListNavigationState
    ) -> Int? {
        if let idx = focusedAppPillIndex, idx >= 0, idx < state.appResults.count {
            return idx
        }
        if let idx = l2.focusedPillIndex,
            idx >= state.appResults.count,
            idx < state.totalCount
        {
            return idx
        }
        return nil
    }

    func globalGroupedVisibleOrder(state: GlobalGroupedListNavigationState) -> [Int] {
        let appIndices = Array(0..<state.appResults.count)
        let menuIndices = Array(state.appResults.count..<state.totalCount)
        return state.menuFirst ? menuIndices + appIndices : appIndices + menuIndices
    }

    func globalGroupedTitle(
        at index: Int,
        state: GlobalGroupedListNavigationState
    ) -> String? {
        guard index >= 0, index < state.totalCount else { return nil }
        let title: String
        if index < state.appResults.count {
            title = state.appResults[index].title
        } else {
            let menuIndex = index - state.appResults.count
            guard menuIndex >= 0, menuIndex < state.menuPills.count else { return nil }
            title = state.menuPills[menuIndex].name
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func setGlobalGroupedFocus(
        _ index: Int?,
        state: GlobalGroupedListNavigationState
    ) {
        guard let index, index >= 0, index < state.totalCount else {
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            DispatchQueue.main.async { self.reclaimSearchInputFocus() }
            return
        }

        // Keyboard navigation is active interaction, not idle time. Once focus enters
        // the result sheet, keep it open until the user explicitly leaves/collapses it.
        globalContextViewModel.idleCollapseTask?.cancel()
        globalContextViewModel.idleCollapseTask = nil
        l2.pillNavViaKeyboard = true
        if index < state.appResults.count {
            focusedAppPillIndex = index
            l2.focusedPillIndex = nil
        } else {
            focusedAppPillIndex = nil
            l2.focusedPillIndex = index
        }
    }

    func moveGlobalGroupedListFocus(direction: Int) -> Bool {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = visibleGlobalGroupedListNavigationState(for: q)
        guard state.totalCount > 0 else {
            setGlobalGroupedFocus(nil, state: state)
            return false
        }

        if direction > 0 {
            let visibleOrder = globalGroupedVisibleOrder(state: state)
            // Row 0 is shown pre-selected (render default) whenever the list renders
            // a default-first row even though the focus index is nil — while typing
            // (q non-empty) OR inside any active global scope (which always shows the
            // first row selected via isRunningAppMenuScopeDefaultFirstRow). Start from
            // that row so the first Down advances to the second instead of re-selecting
            // the first. Mirrors the fallback in moveGlobalAppResultFocus(direction:).
            let showsDefaultFirstRow = !q.isEmpty || isActiveGlobalRunningAppMenuScope()
            let current =
                currentGlobalGroupedFocusIndex(state: state)
                .flatMap { visibleOrder.firstIndex(of: $0) }
                ?? (showsDefaultFirstRow ? 0 : -1)
            setGlobalGroupedFocus(
                visibleOrder[min(current + 1, visibleOrder.count - 1)], state: state)
            return true
        }

        if direction < 0 {
            let visibleOrder = globalGroupedVisibleOrder(state: state)
            guard let focused = currentGlobalGroupedFocusIndex(state: state),
                let current = visibleOrder.firstIndex(of: focused)
            else {
                setGlobalGroupedFocus(nil, state: state)
                DispatchQueue.main.async { self.reclaimSearchInputFocusSelectingAll() }
                return true
            }
            if current <= 0 {
                setGlobalGroupedFocus(nil, state: state)
                DispatchQueue.main.async { self.reclaimSearchInputFocusSelectingAll() }
            } else {
                setGlobalGroupedFocus(visibleOrder[current - 1], state: state)
            }
            return true
        }

        return true
    }

    func executeFocusedGlobalGroupedListRow() -> Bool {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = visibleGlobalGroupedListNavigationState(for: q)
        guard state.totalCount > 0 else { return false }

        let index =
            currentGlobalGroupedFocusIndex(state: state)
            ?? globalGroupedVisibleOrder(state: state).first
            ?? 0
        if index < state.appResults.count {
            executeGlobalAppSearchResult(state.appResults[index])
            return true
        }

        let menuIndex = index - state.appResults.count
        guard menuIndex >= 0, menuIndex < state.menuPills.count else { return false }
        executeDockPill(state.menuPills[menuIndex])
        searchState.query = ""
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        return true
    }

    /// Scopes exactly the row highlighted by the grouped result sheet. This must
    /// use the grouped navigation snapshot—not the app-only match array—because
    /// Global Commands and apps can share the same visible title.
    @discardableResult
    func scopeFocusedGlobalGroupedListRow() -> Bool {
        guard isGlobalContextActive, currentGlobalScopedBundleID == nil else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = visibleGlobalGroupedListNavigationState(for: q)
        guard state.totalCount > 0,
            let index = currentGlobalGroupedFocusIndex(state: state)
                ?? globalGroupedVisibleOrder(state: state).first,
            index >= 0,
            index < state.appResults.count
        else { return false }

        let result = state.appResults[index]
        if result.subtitle.hasPrefix("syscmd://") || result.subtitle.hasPrefix("cli://") {
            return activateGlobalInlineScope(result: result, bundleID: result.subtitle)
        }
        guard result.type == .application,
            let bundleID = bundleIdentifier(forApplicationResult: result),
            !bundleID.isEmpty
        else { return false }
        return activateGlobalInlineScope(result: result, bundleID: bundleID)
    }

    func quitFocusedGlobalAppResultIfPossible(state: GlobalGroupedListNavigationState) -> Bool {
        guard let index = currentGlobalGroupedFocusIndex(state: state),
            index >= 0,
            index < state.appResults.count
        else { return false }
        let result = state.appResults[index]
        let lookup = runningApplicationLookup()
        guard let runningApp = runningApplication(forGlobalResult: result, lookup: lookup) else {
            return false
        }
        let preservedQuery = searchState.query
        terminateRunningAppFromDock(runningApp)
        searchState.query = preservedQuery
        focusedAppPillIndex = nil
        hoveredAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        scheduleGlobalAppMatchRebuild(query: preservedQuery, delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: preservedQuery, delayNanoseconds: 0)
        return true
    }

    func topContextMatchDockTitleForInputPreview() -> String? {
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            globalInlineAppScope == nil
        else { return nil }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        // Ghost must use the same visible order as the result sheet. If first row is
        // a menu command, preview that command, not the first app result.
        if let prepared = globalContextViewModel.preparedResults,
            prepared.query == q.lowercased(),
            let state = prepared.navigationState,
            let index = globalGroupedVisibleOrder(state: state).first,
            let title = globalGroupedTitle(at: index, state: state)
        {
            return title
        }

        let state = globalGroupedListNavigationState(for: q.lowercased())
        if let index = globalGroupedVisibleOrder(state: state).first,
            let title = globalGroupedTitle(at: index, state: state)
        {
            return title
        }

        return currentOrImmediateGlobalAppMatches(for: q).first?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func focusedOrTopGlobalAppResult() -> SearchResult? {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state: GlobalGroupedListNavigationState = {
            if let prepared = globalContextViewModel.preparedResults,
                prepared.query == q,
                let navigationState = prepared.navigationState
            {
                return navigationState
            }
            return globalGroupedListNavigationState(for: q)
        }()
        let matches =
            state.appResults.isEmpty
            ? currentOrImmediateGlobalAppMatches(for: q)
            : state.appResults
        guard !matches.isEmpty else { return nil }
        if let focused = currentGlobalGroupedFocusIndex(state: state),
            focused >= 0,
            focused < matches.count
        {
            return matches[focused]
        }
        return matches[0]
    }

    func executeGlobalAppSearchResult(_ result: SearchResult) {
        // A Global Command with an inline control executes in place and keeps the
        // results sheet open: a toggle flips on Enter/click; a slider is adjusted by
        // the inline control itself, so Enter is a no-op rather than resetting it.
        // Scoping into the device/network list is the explicit scope gesture (→).
        if let command = interactiveSystemCommand(forResult: result) {
            switch command.interactionType {
            case .toggle:
                let current = InteractiveCommandState.shared.value(for: command) ?? 0
                let next = current < 0.5
                InteractiveCommandState.shared.setLocal(next ? 1 : 0, for: command.id)
                SystemCommandInteractiveRunner.run(command, value: next ? "on" : "off")
            case .slider, .none:
                break
            }
            focusedAppPillIndex = nil
            hoveredAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            return
        }
        // A scope-only provider command (a picker with no toggle, e.g. Windows) opens
        // its scope on Enter — its whole purpose IS the scoped list, there is no
        // single action to run. Toggles are handled above; other providers scope here.
        if result.subtitle.hasPrefix("syscmd://"),
            let id = UUID(uuidString: String(result.subtitle.dropFirst("syscmd://".count))),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.interactionType == .none,
            command.keywords.contains(where: { $0.lowercased().hasPrefix("provider:") }),
            activateGlobalInlineScope(result: result, bundleID: result.subtitle)
        {
            focusedAppPillIndex = nil
            hoveredAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            reclaimSearchInputFocus()
            return
        }
        // Enter/click runs the command's action directly — Global Commands no longer
        // auto-scope on Enter. Scoping into a command's live list (Bluetooth devices,
        // Wi-Fi networks, presets) is reserved for the explicit scope gesture (→).
        // Arm the launch morph BEFORE running the action: result.action() may activate a
        // running app and force-hide the dock — this makes those hides no-op so the dock
        // stays and morphs into the launched app's Context Dock.
        AppDelegate.shared?.holdDockThroughAppLaunch()
        result.action()
        searchState.query = ""
        focusedAppPillIndex = nil
        hoveredAppPillIndex = nil
        l2.pillNavViaKeyboard = false
        guard result.type == .application else { return }

        let bundleId = bundleIdentifierForApplicationPath(result.filePath)
        UsageTracker.shared.recordAccess(for: "app:\(result.filePath ?? result.title)")
        if let bid = bundleId {
            AppLaunchTracker.shared.record(bundleId: bid)
            AppUsageLearner.shared.recordApp(bundleID: bid, appName: result.title)
        }
        scheduleContextDockTransition(bundleId: bundleId, appName: result.title)
    }

    @discardableResult
    func focusTopGlobalAppResultIfPossible() -> Bool {
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            globalContextViewModel.typingSnapshot.phase == .expanded,
            searchInputCursorIsAtEnd()
        else { return false }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty || isActiveGlobalRunningAppMenuScope() else { return false }
        let state = visibleGlobalGroupedListNavigationState(for: q)
        if state.totalCount > 0 {
            let first = globalGroupedVisibleOrder(state: state).first ?? 0
            let current = currentGlobalGroupedFocusIndex(state: state) ?? first
            setGlobalGroupedFocus(min(current, state.totalCount - 1), state: state)
            return true
        }
        let matches =
            state.appResults.isEmpty
            ? currentOrImmediateGlobalAppMatches(for: q)
            : state.appResults
        guard !matches.isEmpty else { return false }
        focusedAppPillIndex = min(focusedAppPillIndex ?? 0, matches.count - 1)
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = true
        return true
    }

    @discardableResult
    func activateFocusedGlobalAppScopeIfPossible() -> Bool {
        guard isGlobalContextActive,
            currentGlobalScopedBundleID == nil,
            searchInputCursorIsAtEnd(),
            let result = focusedGlobalAppResultForInputPreview() ?? focusedOrTopGlobalAppResult()
        else { return false }

        if result.subtitle.hasPrefix("syscmd://") {
            let activated = activateGlobalInlineScope(
                result: result,
                bundleID: result.subtitle
            )
            if activated {
                focusedAppPillIndex = nil
                l2.focusedPillIndex = nil
                reclaimSearchInputFocus()
            }
            return activated
        }

        guard shouldUsePureGlobalAppSearch,
            result.type == .application,
            let bundleID = bundleIdentifier(forApplicationResult: result)
        else { return false }

        let activated = activateGlobalInlineScope(
            result: result,
            bundleID: bundleID
        )
        if activated {
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            reclaimSearchInputFocus()
        }
        return activated
    }

    @discardableResult
    func acceptTopGlobalAppGhostCompletionIfPossible() -> Bool {
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            searchInputCursorIsAtEnd()
        else { return false }

        let typed = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = typed.lowercased()

        // Right Arrow always follows the visibly highlighted row. Commands enter
        // their scope immediately; apps first accept their visible completion.
        let state = visibleGlobalGroupedListNavigationState(for: normalizedQuery)
        let selectedIndex =
            currentGlobalGroupedFocusIndex(state: state)
            ?? globalGroupedVisibleOrder(state: state).first
        let selectedResult: SearchResult? = {
            guard let selectedIndex,
                selectedIndex >= 0,
                selectedIndex < state.appResults.count
            else { return nil }
            return state.appResults[selectedIndex]
        }()
        if let selectedResult,
            selectedResult.subtitle.hasPrefix("syscmd://")
                || selectedResult.subtitle.hasPrefix("cli://")
        {
            return activateGlobalInlineScope(
                result: selectedResult,
                bundleID: selectedResult.subtitle
            )
        }

        let completionTitle = selectedResult?.title
            ?? topContextMatchDockTitleForInputPreview()
            ?? focusedOrTopGlobalAppResult()?.title

        guard !typed.isEmpty,
            let completionTitle,
            completionTitle.caseInsensitiveCompare(typed) != .orderedSame
        else { return false }

        suppressGlobalInlineAppScopeDetection = true
        searchState.query = completionTitle + " "
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        scheduleGlobalAppMatchRebuild(query: searchState.query, delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: searchState.query, delayNanoseconds: 0)
        reclaimSearchInputFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            suppressGlobalInlineAppScopeDetection = false
        }
        return true
    }

    @discardableResult
    func activateGlobalInlineScope(result: SearchResult, bundleID: String) -> Bool {
        guard shouldUsePureGlobalAppSearch,
            isGlobalContextActive,
            !hasSelectionScopeSurface,
            l2.targetApp == nil,
            lockedSubmenuParent == nil,
            globalInlineAppScope == nil
        else { return false }

        let alias = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let appPath =
            result.filePath
            ?? (result.subtitle.hasSuffix(".app") ? result.subtitle : "")
        globalInlineAppScope = GlobalInlineAppScope(
            appName: result.title.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleId: bundleID,
            appPath: appPath,
            matchedAlias: alias,
            aliasStartIndex: 0,
            isExplicit: true
        )
        additionalGlobalInlineAppScopes = []
        // Clear any stale hover so the new chip doesn't render in its red "remove"
        // state just because it appeared under the resting cursor.
        hoveredGlobalInlineScopeBundleId = nil
        searchState.query = ""
        clearSearchFieldEditorText()
        if bundleID.hasPrefix("syscmd://") || bundleID.hasPrefix("cli://") {
            globalContextViewModel.idleCollapseTask?.cancel()
            globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot(
                query: "",
                phase: .expanded,
                matchDockIcons: [],
                matchDockOverflowCount: 0,
                preparedResultsVersion: globalContextViewModel.typingSnapshot.preparedResultsVersion
            )
        }
        scheduleGlobalAppMatchRebuild(query: "", delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: "", delayNanoseconds: 0)
        DispatchQueue.main.async {
            guard self.currentGlobalScopedBundleID == bundleID else { return }
            self.globalContextViewModel.typingSnapshot.phase = .expanded
            self.requestWindowSizeUpdate(
                reason: .modeChanged,
                animated: true,
                debounceNanoseconds: 0
            )
        }
        reclaimSearchInputFocus()
        return true
    }

    @discardableResult
    func executeScopedRunningAppIfIdle() -> Bool {
        guard isGlobalContextActive,
            searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let scopedBundleID = currentGlobalScopedBundleID
        else { return false }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == scopedBundleID && !$0.isTerminated
        }) {
            activateRunningAppFromGlobalContext(app)
            return true
        }
        let appName =
            l2.targetApp?.bundleId == scopedBundleID
            ? l2.targetApp?.name
            : globalInlineAppScope?.appName
        guard let url = applicationURL(
            bundleIdentifier: scopedBundleID,
            appName: appName ?? ""
        ) else { return false }
        AppDelegate.shared?.holdDockThroughAppLaunch()
        hideLauncherAfterResultExecution()
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        scheduleContextDockTransition(bundleId: scopedBundleID, appName: appName ?? url.deletingPathExtension().lastPathComponent)
        return true
    }

    func reclaimSearchInputFocus() {
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        l2.pillNavViaKeyboard = false
        if let window = AppDelegate.shared?.launcherWindow {
            window.makeKeyAndOrderFront(nil)
        }

        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            moveSearchInsertionPointToEnd(in: textView)
            isSearchFieldFocused = true
            return
        }

        DispatchQueue.main.async {
            isSearchFieldFocused = true
            DispatchQueue.main.async {
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                    moveSearchInsertionPointToEnd(in: textView)
                }
            }
        }
    }

    /// Robust focus claim for scope switches. The single delayed reclaim used to race the
    /// async scoped-menu load + spring animation: when that re-render stole first responder
    /// AFTER the one attempt — and isSearchFieldFocused was already true, so re-setting it did
    /// nothing — the caret silently vanished ("sometimes ready, sometimes not"). This force-
    /// toggles the FocusState (false→true always re-applies) and retries across a few runloop
    /// turns, stopping as soon as the field genuinely holds first responder.
    func ensureSearchInputFocusReady(attempt: Int = 0) {
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        l2.pillNavViaKeyboard = false
        // The window must be KEY and the app ACTIVE before @FocusState will stick — the proven
        // .focusSearchField path does exactly this. A right-arrow scope switch can leave the
        // launcher non-key (the frontmost app behind it is still active), which silently drops
        // the focus assignment and the caret never appears.
        if let window = AppDelegate.shared?.launcherWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Toggle across runloop turns so SwiftUI re-applies focus even when the binding is
        // already true (a plain re-set of true is a no-op and won't reclaim first responder).
        isSearchFieldFocused = false
        DispatchQueue.main.async {
            self.isSearchFieldFocused = true
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                self.moveSearchInsertionPointToEnd(in: tv)
            }
            guard attempt < 4 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) {
                // Retry only while the field still lacks focus — the launcher has a single text
                // field, so any first-responder NSTextView is ours.
                let hasFocus = NSApp.keyWindow?.firstResponder is NSTextView
                if !hasFocus {
                    self.ensureSearchInputFocusReady(attempt: attempt + 1)
                }
            }
        }
    }

    func moveSearchInsertionPointToEnd(in textView: NSTextView) {
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    func clearSearchFieldEditorText() {
        let keyResponder = NSApp.keyWindow?.firstResponder as? NSTextView
        let launcherResponder = AppDelegate.shared?.launcherWindow?.firstResponder as? NSTextView
        let textViews = [keyResponder, launcherResponder].compactMap { $0 }

        for textView in textViews {
            if !textView.string.isEmpty {
                textView.string = ""
                launcherViewModel.searchInputCaretTick &+= 1
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// Like reclaimSearchInputFocus, but selects the whole query (Spotlight-style) so pressing Up
    /// from the first result lands back on the input with the typed text highlighted.
    func reclaimSearchInputFocusSelectingAll() {
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        l2.pillNavViaKeyboard = false
        // Deliberate select-all (Up-arrow editing) — tell the focus handler not to move
        // the caret to end this time.
        launcherViewModel.pendingSelectAllOnFocus = true
        if let window = AppDelegate.shared?.launcherWindow {
            window.makeKeyAndOrderFront(nil)
        }
        func selectAll(in textView: NSTextView) {
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: 0, length: length))
        }
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            isSearchFieldFocused = true
            selectAll(in: textView)
            return
        }
        DispatchQueue.main.async {
            self.isSearchFieldFocused = true
            DispatchQueue.main.async {
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                    selectAll(in: textView)
                }
            }
        }
    }

    func scheduleGlobalAppMatchRebuild(query: String, delayNanoseconds: UInt64 = 120_000_000) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        globalAppMatchGeneration &+= 1
        globalAppMatchTask?.cancel()
        guard !q.isEmpty, !isQuestionStyleDockQuery(q) else {
            cachedGlobalAppQuery = ""
            cachedGlobalAppMatches = []
            pendingGlobalAppQuery = nil
            cachedGlobalGroupedQuery = ""
            cachedGlobalGroupedState = nil
            globalContextViewModel.cachedGroupedFingerprint = ""
            pendingGlobalGroupedQuery = nil
            globalGroupedTask?.cancel()
            return
        }

        let commit: () -> Void = {
            self.scheduleGlobalGroupedListRebuild(query: q, delayNanoseconds: 0)
            let state = self.globalGroupedListNavigationState(for: q)
            self.cachedGlobalAppMatches = state.appResults
            self.cachedGlobalAppQuery = q
            self.pendingGlobalAppQuery = nil
            self.globalAppMatchTask = nil
        }
        guard delayNanoseconds > 0 else {
            commit()
            return
        }
        // Keystroke path: run between keystrokes so typing never blocks on the build.
        let generation = globalAppMatchGeneration
        pendingGlobalAppQuery = q
        globalAppMatchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, self.globalAppMatchGeneration == generation else { return }
            commit()
        }
    }

    func updateGlobalContextTypingSnapshot(query rawQuery: String) {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wasExpanded = globalContextViewModel.typingSnapshot.phase == .expanded
        globalContextViewModel.fastMatchTask?.cancel()
        globalContextViewModel.expandWhenFastMatchesResolve = false
        globalContextViewModel.autoExpandTask?.cancel()
        guard isGlobalContextActive, shouldUsePureGlobalAppSearch, globalInlineAppScope == nil
        else {
            globalContextViewModel.isResolvingFastMatches = false
            globalContextViewModel.idleCollapseTask?.cancel()
            globalContextViewModel.idleCollapseTask = nil
            globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot()
            globalContextViewModel.preparedResults = nil
            globalContextViewModel.prepareTask?.cancel()
            globalContextViewModel.prepareTask = nil
            return
        }

        if q.isEmpty {
            globalContextViewModel.isResolvingFastMatches = false
            globalContextViewModel.idleCollapseTask?.cancel()
            globalContextViewModel.idleCollapseTask = nil
            globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot()
            globalContextViewModel.preparedResults = nil
            globalContextViewModel.prepareTask?.cancel()
            globalContextViewModel.prepareTask = nil
            return
        }

        if wasExpanded {
            immediatelyPruneExpandedGlobalContextRows(for: q)
        }
        let preparedVersion = globalContextViewModel.typingSnapshot.preparedResultsVersion
        globalContextViewModel.isResolvingFastMatches = true
        globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot(
            query: q,
            phase: wasExpanded ? .expanded : .typing,
            matchDockIcons: wasExpanded
                ? globalContextViewModel.typingSnapshot.matchDockIcons : [],
            matchDockOverflowCount: wasExpanded
                ? globalContextViewModel.typingSnapshot.matchDockOverflowCount : 0,
            preparedResultsVersion: preparedVersion
        )
        scheduleBackgroundGlobalContextPreparation(q)
        scheduleEligibleGlobalContextAutoExpansion(query: q)
        if wasExpanded { scheduleGlobalContextIdleCollapse() }

        // Search the immutable Global Context index away from the main actor. Every
        // keystroke cancels this task, so stale work cannot interrupt typing or publish
        // results over a newer query.
        globalContextViewModel.fastMatchTask = Task.detached(priority: .userInitiated) {
            // Coalesce a rapid typing burst before entering GlobalSearchService. Its query
            // is synchronous once started, so cancellation alone cannot stop several old
            // keystrokes from competing for CPU with the TextField and window compositor.
            try? await Task.sleep(nanoseconds: 24_000_000)
            guard !Task.isCancelled else { return }
            let resolved = GlobalContextSearchCoordinator.shared.resolveFastMatchDockIcons(
                query: q,
                limit: 12
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard
                    self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == q,
                    self.isGlobalContextActive,
                    self.shouldUsePureGlobalAppSearch,
                    self.globalInlineAppScope == nil
                else { return }

                // The search index is intentionally lightweight and can carry a
                // generic executable/app placeholder. Resolve only these bounded,
                // already-matched rows on the main actor before we publish the
                // ready state. This mirrors Spotlight's fast-results → real-icon
                // refinement without doing bundle I/O for every keystroke.
                var matchDockIcons = resolved.map { self.refinedMatchDockIcon($0) }
                if let target = self.transientGlobalInlineAppScopeTarget(for: q),
                    !matchDockIcons.contains(where: { $0.bundleID == target.bundleId })
                {
                    let icon =
                        FileManager.default.fileExists(atPath: target.appPath)
                        ? NSWorkspace.shared.icon(forFile: target.appPath)
                        : (self.resolvedApplicationIcon(
                            bundleIdentifier: target.bundleId, appName: target.appName) ?? NSImage())
                    matchDockIcons.insert(
                        MatchDockIcon(
                            id: "transient-scope:\(target.bundleId)",
                            bundleID: target.bundleId,
                            title: target.appName,
                            icon: icon,
                            isRunning: NSWorkspace.shared.runningApplications.contains {
                                $0.bundleIdentifier == target.bundleId && !$0.isTerminated
                            },
                            isExpandable: true,
                            score: 90_000,
                            isExactAppPrefix: true
                        ),
                        at: 0
                    )
                    matchDockIcons = Array(matchDockIcons.prefix(12))
                }

                let hasExpandableMatch = matchDockIcons.contains { $0.isExpandable }
                self.globalContextViewModel.isResolvingFastMatches = false
                self.globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot(
                    query: q,
                    phase: wasExpanded
                        ? .expanded : (hasExpandableMatch ? .expandable : .matched),
                    topMatch: nil,
                    matchDockIcons: matchDockIcons,
                    matchDockOverflowCount: max(0, matchDockIcons.count - 3),
                    preparedResultsVersion:
                        self.globalContextViewModel.typingSnapshot.preparedResultsVersion
                )
                self.globalContextViewModel.fastMatchTask = nil
                if wasExpanded {
                    // Keep the expanded sheet useful during inline filtering. The hot,
                    // bounded first pass includes lightweight application rows, Global
                    // Commands, and cached-menu hits belonging to currently running apps.
                    // Background preparation can still replace this with richer grouping.
                    let state = self.instantGlobalGroupedListNavigationState(for: q)
                    self.setCachedGlobalGroupedState(
                        query: q, state: state, animated: false)
                    // Do not resize an already-expanded sheet for each filtered result
                    // count. Its shell stays anchored; only rows change inline.
                }
                if self.globalContextViewModel.expandWhenFastMatchesResolve {
                    self.globalContextViewModel.expandWhenFastMatchesResolve = false
                    _ = self.expandGlobalContextTypingMatch(selectFirst: true)
                }
            }
        }
    }

    /// Replaces an indexed fallback image with the real running/bundle icon once a
    /// match is ready to draw. Called for at most 12 results, after the 24 ms input
    /// coalescing pass; it is deliberately not part of the hot index query.
    func refinedMatchDockIcon(_ item: MatchDockIcon) -> MatchDockIcon {
        guard let bundleID = item.bundleID,
              !bundleID.isEmpty,
              !bundleID.hasPrefix("cli://"),
              !bundleID.hasPrefix("syscmd://")
        else { return item }

        let icon: NSImage?
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }) {
            icon = resolvedRunningAppIcon(for: running)
        } else {
            icon = resolvedApplicationIcon(bundleIdentifier: bundleID, appName: item.title)
        }
        guard let icon else { return item }
        return MatchDockIcon(
            id: item.id,
            bundleID: item.bundleID,
            title: item.title,
            icon: icon,
            isRunning: item.isRunning,
            isExpandable: item.isExpandable,
            score: item.score,
            isExactAppPrefix: item.isExactAppPrefix
        )
    }

    /// Stage zero of expanded Global Context search. Spotlight removes stale rows in the
    /// same key event, before its index has produced replacements. Filter only the already-
    /// rendered bounded snapshot here; detached matching remains the authoritative search.
    func immediatelyPruneExpandedGlobalContextRows(for query: String) {
        guard let current = cachedGlobalGroupedState else { return }
        let normalizedQuery = normalizedDockPillText(query)
        let tokens = dockPillTokens(normalizedQuery)
        guard !tokens.isEmpty else { return }

        func containsAllTokens(_ values: [String]) -> Bool {
            let searchable = normalizedDockPillText(values.joined(separator: " "))
            return tokens.allSatisfy { searchable.contains($0) }
        }

        let apps = current.appResults.filter { result in
            containsAllTokens(
                [result.title, result.subtitle, result.trackingIdentifier]
                    + result.displayBadges)
        }
        let pillMatches: (DockPill) -> Bool = { pill in
            containsAllTokens(
                [
                    pill.name,
                    pill.badge ?? "",
                    pill.sourceAppName,
                    pill.menuItemName,
                    pill.menuContext ?? "",
                    pill.rankingKind,
                ] + pill.searchTerms)
        }
        let groups = current.appMenuGroups.compactMap { group -> AppMenuGroup? in
            let pills = group.pills.filter(pillMatches)
            guard !pills.isEmpty else { return nil }
            return AppMenuGroup(
                id: group.id, appName: group.appName, icon: group.icon, pills: pills)
        }
        let menuPills = groups.isEmpty
            ? current.menuPills.filter(pillMatches)
            : groups.flatMap(\.pills)
        let menuGroups = current.menuGroups.compactMap { group -> MenuPillGroup? in
            let pills = group.allPills.filter(pillMatches)
            guard let primary = pills.first else { return nil }
            return MenuPillGroup(id: group.id, primaryPill: primary, allPills: pills)
        }
        let pruned = GlobalGroupedListNavigationState(
            appResults: apps,
            menuPills: menuPills,
            menuGroups: groups.isEmpty ? menuGroups : [],
            appMenuGroups: groups,
            menuFirst: current.menuFirst)
        setCachedGlobalGroupedState(query: query, state: pruned, animated: false)
    }

    func scheduleBackgroundGlobalContextPreparation(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        globalContextViewModel.prepareTask?.cancel()
        guard !q.isEmpty else {
            globalContextViewModel.preparedResults = nil
            return
        }

        globalContextViewModel.prepareTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let prepared = await GlobalContextSearchCoordinator.shared.prepareExpandedResults(
                query: q)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard
                    self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == prepared.query
                else { return }
                self.globalContextViewModel.preparedResults = prepared
                self.globalContextViewModel.typingSnapshot.preparedResultsVersion &+= 1
                if self.globalContextViewModel.typingSnapshot.phase == .expanded,
                    let state = prepared.navigationState,
                    state.totalCount > 0
                {
                    self.setCachedGlobalGroupedState(
                        query: prepared.query, state: state, animated: false)
                    // Richer grouping replaces the lightweight rows in place. Resizing
                    // here would replay the sheet's entrance on every keystroke.
                }
            }
        }
    }

    /// Auto-reveal is limited to Global Context's launcher sources. Frontmost-app actions,
    /// Finder/file results, selection actions, and provider-backed scopes stay compact until ↓.
    func scheduleEligibleGlobalContextAutoExpansion(query: String) {
        globalContextViewModel.autoExpandTask?.cancel()
        globalContextViewModel.autoExpandTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            defer { globalContextViewModel.autoExpandTask = nil }
            guard !Task.isCancelled,
                isGlobalContextActive,
                shouldUsePureGlobalAppSearch,
                globalInlineAppScope == nil,
                currentGlobalScopedBundleID == nil,
                searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == query,
                globalContextViewModel.typingSnapshot.phase != .expanded
            else { return }

            let state = visibleGlobalGroupedListNavigationState(for: query)
            let hasAppsOrRunningApps = !state.appResults.isEmpty
            let hasGlobalCommandsOrCachedMenus =
                !state.menuPills.isEmpty || !state.menuGroups.isEmpty || !state.appMenuGroups.isEmpty
            guard hasAppsOrRunningApps || hasGlobalCommandsOrCachedMenus else { return }
            _ = expandGlobalContextTypingMatch(selectFirst: true)
        }
    }

    /// Spotlight-style lease: active typing keeps the expanded shell alive and only resets
    /// this timer. Collapse after a long idle period, never during an active typing burst.
    func scheduleGlobalContextIdleCollapse() {
        globalContextViewModel.idleCollapseTask?.cancel()
        globalContextViewModel.idleCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 55_000_000_000)
            defer { globalContextViewModel.idleCollapseTask = nil }
            guard !Task.isCancelled,
                isGlobalContextActive,
                globalContextViewModel.typingSnapshot.phase == .expanded,
                currentGlobalScopedBundleID == nil,
                focusedAppPillIndex == nil,
                l2.focusedPillIndex == nil,
                !l2.pillNavViaKeyboard
            else { return }
            let icons = globalContextViewModel.typingSnapshot.matchDockIcons
            globalContextViewModel.typingSnapshot.phase = icons.contains(where: \.isExpandable)
                ? .expandable : (icons.isEmpty ? .typing : .matched)
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            measuredGlobalListContentHeight = 0
            requestWindowSizeUpdate(
                reason: .modeChanged, animated: true, debounceNanoseconds: 0)
        }
    }

    /// THE single entry point for expanding the Global Context result sheet.
    /// Works from ANY pre-expansion phase (including a stale .idle snapshot), so the
    /// FIRST ↓ always expands. Order matters: results are computed BEFORE the phase
    /// flips, so a zero-result query never leaves an expanded-but-empty sheet.
    @discardableResult
    func expandGlobalContextTypingMatch(selectFirst: Bool = true) -> Bool {
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch
        else { return false }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        guard globalContextViewModel.typingSnapshot.phase != .expanded else { return false }

        // Fast matches resolve off the main actor. Remember an early Down Arrow instead of
        // consuming it against an intentionally empty `.typing` snapshot. Publication of
        // the matching snapshot immediately re-enters this function for the same query.
        if globalContextViewModel.isResolvingFastMatches {
            globalContextViewModel.expandWhenFastMatchesResolve = true
            return true
        }

        let started = Date()
        // 1. Results first — zero results never expand (token-word fallback covers
        //    "mail recent notes"-style queries where only individual words match).
        var state: GlobalGroupedListNavigationState = {
            if let scopedState = visibleGlobalScopedMenuNavigationState(for: q) {
                return scopedState
            }
            if let prepared = globalContextViewModel.preparedResults,
                prepared.query == q,
                let navigationState = prepared.navigationState,
                navigationState.totalCount > 0
            {
                return navigationState
            }
            return instantGlobalGroupedListNavigationState(for: q)
        }()
        if state.totalCount == 0 {
            let tokenApps = tokenMatchedAppResults(for: q)
            let iconRows = tokenApps.isEmpty ? matchDockIconRowsForExpandedSheet(query: q) : []
            let fallbackApps = tokenApps.isEmpty ? iconRows : tokenApps
            guard !fallbackApps.isEmpty else { return false }
            state = GlobalGroupedListNavigationState(
                appResults: fallbackApps,
                menuPills: [],
                menuGroups: [],
                appMenuGroups: [],
                menuFirst: false
            )
        }

        // 2. Freeze in-flight rebuilds before publishing the committed sheet payload.
        // The expansion phase MUST remain compact until the rows and height exist; the
        // NSPanel observes that phase transition to choose its target frame.
        globalContextViewModel.prepareTask?.cancel()
        // Generation bumps kill in-flight keystroke rebuilds even if they already
        // passed their sleep — cancel() alone loses the race and lets a stale
        // (often empty) rebuild overwrite this committed state right after ↓.
        globalAppMatchGeneration &+= 1
        globalGroupedGeneration &+= 1
        setCachedGlobalGroupedState(query: q, state: state, animated: false)
        cachedGlobalAppMatches = state.appResults
        cachedGlobalAppQuery = q
        pendingGlobalAppQuery = nil
        pendingGlobalGroupedQuery = nil
        globalAppMatchTask?.cancel()
        globalGroupedTask?.cancel()
        globalAppMatchTask = nil
        globalGroupedTask = nil

        // 4. Selection lands on the first row.
        if selectFirst, state.totalCount > 0 {
            setGlobalGroupedFocus(globalGroupedVisibleOrder(state: state).first, state: state)
        }

        // 5. Prime the height estimate from the committed rows — the real measurement
        //    was suppressed during compact typing, so the stale value would size the
        //    window to the compact bar (the "↓ shrinks the dock" bug). The rendered
        //    list refines this via updateMeasuredGlobalListHeight right after commit.
        let estimatedRows = CGFloat(min(state.totalCount, 12))
        measuredGlobalListContentHeight = min(
            max(estimatedRows * 52 + 36, 86), listViewVisibleHeight)

        // 6. Let SwiftUI reconcile the committed row payload before revealing its shell. The
        // compact dock continues showing its spinner during this single turn; the expanded
        // sheet therefore begins with real rows instead of a header or empty half-card.
        Task { @MainActor in
            await Task.yield()
            guard
                isGlobalContextActive,
                shouldUsePureGlobalAppSearch,
                searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == q,
                visibleGlobalGroupedListNavigationState(for: q).totalCount > 0
                    || !currentGlobalAppMatches(for: q).isEmpty
                    || !matchDockIconRowsForExpandedSheet(query: q).isEmpty
            else { return }
            globalContextViewModel.typingSnapshot.phase = .expanded
            scheduleGlobalContextIdleCollapse()

            // 7. Window follows the ready presentation in one smooth expansion.
            requestWindowSizeUpdate(
                reason: .modeChanged, animated: true, debounceNanoseconds: 0)
        }
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 4 {
            SearchPerformanceLog.shared.record(
                label: "global.expandTypingMatch",
                elapsedMS: elapsedMS,
                query: q,
                pills: state.totalCount
            )
        }
        return true
    }

    // Convert GlobalSearchService docs → SearchResult on @MainActor (needs closures + icons).
    func searchResults(from docs: [GlobalSearchService.SearchDocument], query: String)
        -> [SearchResult]
    {
        var seen = Set<String>()
        var results: [SearchResult] = []
        results.reserveCapacity(docs.count)

        for doc in docs {
            guard seen.insert(doc.id).inserted else { continue }
            // Resolve icon: prefer live running icon, fall back to doc's pre-cached icon
            let icon: NSImage?
            switch doc.action {
            case .activatePID(let pid, let bundleId, let path):
                let app =
                    runningRegularApps.first { $0.processIdentifier == pid }
                    ?? runningRegularApps.first { $0.bundleIdentifier == bundleId }
                icon = app.map { resolvedRunningAppIcon(for: $0) } ?? doc.icon
                let capturedApp = app
                let capturedBundleId = bundleId
                let capturedPath = path
                let capturedDoc = doc
                var result = SearchResult(
                    title: doc.title,
                    subtitle: "Running",
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        if let a = capturedApp {
                            activateRunningAppFromGlobalContext(a, forceHideLauncher: true)
                        } else if let url = capturedPath.map(URL.init(fileURLWithPath:)) {
                            forceHideLauncherAfterResultExecution()
                            NSWorkspace.shared.open(url)
                        } else if let url = applicationURLForBundleIdentifier(capturedBundleId) {
                            forceHideLauncherAfterResultExecution()
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    },
                    type: .application,
                    filePath: doc.filePath,
                    contactData: nil,
                    stableID: doc.id
                )
                result.score = doc.sourceKind.rawValue
                results.append(result)
                continue

            case .launchPath(let path):
                icon =
                    doc.icon
                    ?? resolvedApplicationIcon(
                        bundleIdentifier: doc.bundleId.isEmpty ? nil : doc.bundleId,
                        appName: doc.title)
                let capturedPath = path
                let capturedDoc = doc
                var result = SearchResult(
                    title: doc.title,
                    subtitle: path,
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        forceHideLauncherAfterResultExecution()
                        NSWorkspace.shared.open(URL(fileURLWithPath: capturedPath))
                    },
                    type: .application,
                    filePath: capturedPath,
                    contactData: nil,
                    stableID: doc.id
                )
                result.score = doc.sourceKind.rawValue
                results.append(result)
                continue

            case .launchBundleId(let bundleId, let path):
                icon =
                    doc.icon
                    ?? resolvedApplicationIcon(bundleIdentifier: bundleId, appName: doc.title)
                let capturedBundleId = bundleId
                let capturedPath = path
                let capturedDoc = doc
                var result = SearchResult(
                    title: doc.title,
                    subtitle: path,
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        forceHideLauncherAfterResultExecution()
                        if let url = applicationURLForBundleIdentifier(capturedBundleId) {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        } else {
                            NSWorkspace.shared.open(URL(fileURLWithPath: capturedPath))
                        }
                    },
                    type: .application,
                    filePath: capturedPath,
                    contactData: nil,
                    stableID: doc.id
                )
                result.score = doc.sourceKind.rawValue
                results.append(result)
                continue

            case .cliScope(let command, let displayName):
                icon = doc.icon ?? NSWorkspace.shared.icon(forFileType: "public.unix-executable")
                let capturedCommand = command
                let capturedDisplayName = displayName
                let capturedDoc = doc
                var result = SearchResult(
                    title: command,
                    subtitle: "cli://\(command)",
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        _ = activateInlineDockAppScope(
                            bundleIdentifier: "cli://\(capturedCommand)",
                            appName: capturedDisplayName,
                            queryOverride: "",
                            preserveGlobalContext: true
                        )
                    },
                    type: .cliTool,
                    filePath: nil,
                    contactData: nil,
                    stableID: doc.id
                )
                result.score = doc.sourceKind.rawValue
                results.append(result)
                continue

            case .systemCommandScope(let commandKey):
                icon = doc.icon
                let capturedCommand = UUID(uuidString: commandKey).flatMap { commandID in
                    SystemCommandsRegistry.shared.commands.first { $0.id == commandID }
                }
                let capturedDoc = doc
                var result = SearchResult(
                    title: doc.title,
                    subtitle: doc.subtitle,
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        if let command = capturedCommand {
                            runSystemCommand(command, originalQuery: query)
                        }
                    },
                    type: .extensionCommand,
                    filePath: nil,
                    contactData: nil,
                    displayBadges: capturedCommand.map { [$0.actionTypeLabel] } ?? [],
                    showsTypeLabel: false,
                    stableID: doc.id
                )
                result.dismissesLauncher = true
                result.score = doc.sourceKind.rawValue
                results.append(result)
                continue

            case .cachedMenu:
                continue

            case .browserURL(let url, let browserBundleId, let browserName, let kind, let domain):
                icon =
                    doc.icon
                    ?? resolvedApplicationIcon(
                        bundleIdentifier: browserBundleId,
                        appName: browserName
                    )
                let capturedURL = url
                let capturedBundleId = browserBundleId
                let capturedDoc = doc
                var result = SearchResult(
                    title: doc.title,
                    subtitle: domain,
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        forceHideLauncherAfterResultExecution()
                        if let appURL = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: capturedBundleId)
                        {
                            NSWorkspace.shared.open(
                                [capturedURL],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        } else {
                            NSWorkspace.shared.open(capturedURL)
                        }
                    },
                    type: .file,
                    filePath: nil,
                    contactData: nil,
                    displayBadges: [kind],
                    stableID: doc.id
                )
                result.score = doc.sourceKind.rawValue
                results.append(result)
                continue
            }

        }

        // Blend in usage scores and apply deduplication matching globalApplicationMatches
        return dedupeGlobalApplicationResults(
            results.map {
                var r = $0
                let usageBoost = min(
                    UsageTracker.shared.getScore(for: "app:\(r.filePath ?? r.title)") / 100.0, 45)
                r.score += usageBoost
                return r
            })
    }

    func recordGlobalSearchDocumentUse(
        _ doc: GlobalSearchService.SearchDocument,
        query: String
    ) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleId = doc.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableBundleId =
            bundleId.isEmpty || bundleId.hasPrefix("cli://") || bundleId.hasPrefix("syscmd://")
            ? nil
            : bundleId
        UsageTracker.shared.recordAccess(for: doc.usageTrackingKey)
        if !trimmedQuery.isEmpty {
            AppUsageLearner.shared.recordQuery(trimmedQuery, inBundleID: usableBundleId)
        }
        switch doc.action {
        case .activatePID, .launchPath, .launchBundleId:
            if let bid = usableBundleId {
                AppUsageLearner.shared.recordApp(bundleID: bid, appName: doc.title)
            }
            if !trimmedQuery.isEmpty {
                AppUsageLearner.shared.recordQueryIntent(query: trimmedQuery, wasMenu: false)
            }
        case .systemCommandScope, .cliScope:
            AppUsageLearner.shared.recordAction(doc.usageTrackingKey, inBundleID: usableBundleId)
            AppUsageLearner.shared.recordAction(doc.title, inBundleID: usableBundleId)
        case .cachedMenu(_, _, let path, _, _):
            AppUsageLearner.shared.recordAction(doc.usageTrackingKey, inBundleID: usableBundleId)
            AppUsageLearner.shared.recordAction(path.last ?? doc.title, inBundleID: usableBundleId)
            if !trimmedQuery.isEmpty {
                AppUsageLearner.shared.recordQueryIntent(query: trimmedQuery, wasMenu: true)
            }
        case .browserURL:
            AppUsageLearner.shared.recordAction(doc.usageTrackingKey, inBundleID: usableBundleId)
        }
    }

    // Rebuild GlobalSearchService index from current @State sources.
    // Call after allApplications loads or running apps change.
    func rebuildGlobalSearchIndex() {
        let started = Date()
        guard !allApplications.isEmpty || !runningRegularApps.isEmpty else { return }
        // Rebuilding walks every cached menu snapshot and re-grams it on the main thread —
        // spin reports caught it holding the main queue for ~0.5s. The open path alone asks for
        // two rebuilds (frontmost warm, then the recent-app warm a second later), and every
        // reopen asks again. Coalesce: at most one rebuild per 8s.
        guard Date().timeIntervalSince(GlobalSearchIndexThrottle.lastRebuild) > 8 else { return }
        GlobalSearchIndexThrottle.lastRebuild = Date()
        GlobalSearchIndexStatus.shared.begin(message: "Building Global Context index...")

        var docs: [GlobalSearchService.SearchDocument] = []
        var seenIds = Set<String>()
        let indexedMenuSnapshotLimit = 360

        func addIfNew(_ doc: GlobalSearchService.SearchDocument) {
            guard seenIds.insert(doc.id).inserted else { return }
            docs.append(doc)
        }

        func addCachedMenuDocs(
            bundleId: String,
            appName: String,
            processIdentifier: pid_t = 0,
            icon: NSImage?,
            maxResults: Int = 24,
            sourceKind: GlobalSearchService.SourceKind = .runningMenu
        ) {
            guard !bundleId.isEmpty,
                GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bundleId)
            else { return }
            let cachedMenus = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleId,
                appName: appName,
                processIdentifier: processIdentifier,
                query: "",
                maxResults: maxResults
            )
            for item in cachedMenus {
                if let menuDoc = GlobalSearchService.SearchDocument(
                    menuItem: item,
                    appName: appName,
                    bundleId: bundleId,
                    processIdentifier: processIdentifier,
                    icon: icon,
                    sourceKind: sourceKind
                ) {
                    addIfNew(menuDoc)
                }
            }
        }

        // 1. Running apps (highest priority)
        for app in runningRegularApps {
            guard let name = app.localizedName, !name.isEmpty,
                let bundleId = app.bundleIdentifier,
                bundleId != "com.apple.finder",
                bundleId != Bundle.main.bundleIdentifier
            else { continue }
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: name, bundleIdentifier: bundleId, path: app.bundleURL?.path)
            else { continue }
            let icon = resolvedRunningAppIcon(for: app)
            let usageScore =
                AppUsageLearner.shared.score(forBundleID: bundleId)
                + (UsageTracker.shared.getScore(for: "app:\(app.bundleURL?.path ?? bundleId)")
                    / 100.0)
            addIfNew(.init(runningApp: app, icon: icon, usageScore: usageScore))
            addCachedMenuDocs(
                bundleId: bundleId,
                appName: name,
                processIdentifier: app.processIdentifier,
                icon: icon,
                maxResults: indexedMenuSnapshotLimit,
                sourceKind: .runningMenu
            )
        }

        // 2. Built-in Apple apps (always available, high-value targets)
        let builtIns: [(name: String, bundleId: String, path: String)] = [
            ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
            ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
            ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
            ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
            ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
            ("Reminders", "com.apple.reminders", "/System/Applications/Reminders.app"),
            ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
            ("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
            (
                "System Settings", "com.apple.systempreferences",
                "/System/Applications/System Settings.app"
            ),
            ("FaceTime", "com.apple.FaceTime", "/System/Applications/FaceTime.app"),
            ("Music", "com.apple.Music", "/System/Applications/Music.app"),
        ]
        for app in builtIns {
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: app.name, bundleIdentifier: app.bundleId, path: app.path)
            else { continue }
            let path = applicationURLForBundleIdentifier(app.bundleId)?.path ?? app.path
            let icon = resolvedApplicationIcon(bundleIdentifier: app.bundleId, appName: app.name)
            let usageScore =
                AppUsageLearner.shared.score(forBundleID: app.bundleId)
                + (UsageTracker.shared.getScore(for: "app:\(path)") / 100.0)
            let result = SearchResult(
                title: app.name, subtitle: path, icon: icon,
                action: {}, type: .application, filePath: path, contactData: nil,
                stableID: "bundle:\(app.bundleId)")
            addIfNew(
                .init(
                    installedApp: result, bundleId: app.bundleId, sourceKind: .builtIn,
                    usageScore: usageScore))
        }

        // 4. All installed apps
        for result in allApplications where result.type == .application {
            let path = result.filePath ?? result.subtitle
            let bundleId = bundleIdentifierForApplicationPath(path) ?? ""
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: result.title, bundleIdentifier: bundleId.isEmpty ? nil : bundleId,
                    path: path)
            else { continue }
            let usageScore =
                AppUsageLearner.shared.score(forBundleID: bundleId)
                + (UsageTracker.shared.getScore(for: "app:\(path)") / 100.0)
            addIfNew(.init(installedApp: result, bundleId: bundleId, usageScore: usageScore))
        }
        GlobalSearchIndexStatus.shared.update(
            progress: 0.35,
            message: "Indexed apps and running app menus..."
        )

        // 5. CLI tools
        let cliIcon = NSWorkspace.shared.icon(forFileType: "public.unix-executable")
        for pkg in terminalPackageManager.packages
        where pkg.isEnabled && isUserAddedGlobalCLITool(pkg) {
            addIfNew(.init(cliPackage: pkg, icon: cliIcon))
        }

        // 6. Global system commands
        for command in SystemCommandsRegistry.shared.commands where command.isEnabled {
            let icon = NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name)
            addIfNew(.init(systemCommand: command, icon: icon))
        }
        GlobalSearchIndexStatus.shared.update(
            progress: 0.55,
            message: "Indexed commands and CLI scopes..."
        )

        // 7. Cached menus from all known app snapshots. Running apps above win by ID.
        let runningBundleIds = Set(
            runningRegularApps
                .compactMap(\.bundleIdentifier)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        for summary in AppMenuCapabilityCache.shared.summaries() {
            let bundleId = summary.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleId.isEmpty, !runningBundleIds.contains(bundleId.lowercased()) else {
                continue
            }
            let icon = resolvedApplicationIcon(
                bundleIdentifier: bundleId,
                appName: summary.appName
            )
            addCachedMenuDocs(
                bundleId: bundleId,
                appName: summary.appName,
                icon: icon,
                maxResults: indexedMenuSnapshotLimit,
                sourceKind: .cachedMenu
            )
        }
        BrowserURLLibraryService.shared.refreshIfNeeded { [self] in
            rebuildGlobalSearchIndex()
        }
        for entry in BrowserURLLibraryService.shared.entries(matching: "", limit: 800) {
            let icon = resolvedApplicationIcon(
                bundleIdentifier: entry.browserBundleId,
                appName: entry.browserName
            )
            addIfNew(.init(browserURL: entry, icon: icon))
        }
        GlobalSearchIndexStatus.shared.update(
            progress: 0.9,
            message: "Publishing search index..."
        )

        GlobalSearchService.shared.rebuild(with: docs)
        GlobalSearchIndexStatus.shared.finish(documentCount: docs.count)
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 8 {
            SearchPerformanceLog.shared.record(
                label: "rebuildGlobalSearchIndex docs=\(docs.count)",
                elapsedMS: elapsedMS,
                query: "",
                pills: docs.count
            )
        }
    }

    func clearGlobalContextQuerySmoothly() {
        var transaction = Transaction(animation: .easeOut(duration: 0.12))
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            globalAppMatchTask?.cancel()
            globalGroupedTask?.cancel()
            globalContextViewModel.prepareTask?.cancel()
            pendingGlobalAppQuery = nil
            pendingGlobalGroupedQuery = nil
            globalContextViewModel.typingSnapshot = GlobalContextTypingSnapshot()
            globalContextViewModel.preparedResults = nil
            cachedGlobalAppQuery = ""
            cachedGlobalAppMatches = []
            cachedGlobalGroupedQuery = ""
            cachedGlobalGroupedState = nil
            globalContextViewModel.cachedGroupedFingerprint = ""
            focusedAppPillIndex = nil
            hoveredAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            l2.appCompletion = nil
            l2.showResultsPopover = false
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            suppressGlobalInlineAppScopeDetection = false
            dismissedGlobalInlineAppScopes = [:]
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
        }
    }

    func activeGlobalInlineDockScope(for query: String) -> DockScopeResolution? {
        guard shouldUsePureGlobalAppSearch,
            isGlobalContextActive,
            !hasSelectionScopeSurface
        else { return nil }

        let actionQuery = effectiveGlobalInlineActionQuery(query).lowercased()

        if let target = l2.targetApp,
            !target.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !(target.bundleId == "com.apple.finder" && isFinderDesktopOnlyMode)
        {
            return DockScopeResolution(
                scopedBundleId: target.bundleId,
                scopedAppName: target.name,
                scopedSearchQuery: actionQuery,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        guard l2.targetApp == nil else { return nil }

        if let inlineScope = globalInlineAppScope {
            return DockScopeResolution(
                scopedBundleId: inlineScope.bundleId,
                scopedAppName: inlineScope.appName,
                scopedSearchQuery: actionQuery,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        if let target = transientGlobalInlineAppScopeTarget(for: query) {
            return DockScopeResolution(
                scopedBundleId: target.bundleId,
                scopedAppName: target.appName,
                scopedSearchQuery: target.actionQuery,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        return nil
    }

    func transientGlobalInlineAppScopeTarget(for rawQuery: String) -> InstalledAppMenuTarget? {
        guard shouldUsePureGlobalAppSearch,
            isGlobalContextActive,
            !hasSelectionScopeSurface,
            l2.targetApp == nil,
            lockedSubmenuParent == nil,
            globalInlineAppScope == nil,
            // Never surface a transient app-scope hint while in a CLI/provider scope.
            currentGlobalScopedBundleID?.hasPrefix("cli://") != true,
            currentGlobalScopedBundleID?.hasPrefix("syscmd://") != true
        else { return nil }

        let raw = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 4, !isGenericApplicationListQuery(raw.lowercased()) else { return nil }
        guard let target = indexedGlobalAppMenuTarget(
            for: raw,
            allowPrefixAlias: false,
            preserveRemainingQueryTokens: true,
            excludingBundleIds: Set(dismissedGlobalInlineAppScopes.keys)
        )
            ?? installedAppMenuTarget(
                for: raw,
                runningOnly: false,
                includeAppsWithoutMenuSnapshot: true,
                allowPrefixAlias: false,
                preserveRemainingQueryTokens: true,
                excludingBundleIds: Set(dismissedGlobalInlineAppScopes.keys)
            )
        else { return nil }
        guard !target.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return target
    }

    var allGlobalInlineAppScopes: [GlobalInlineAppScope] {
        // Inline token scopes belong only to typed Global Context queries.
        // A running-app capsule lives in l2.targetApp and already has its own visible
        // chip. Mixing it into token parsing duplicates app identity inside input and
        // corrupts text (for example `atGPTChatGPT`).
        [globalInlineAppScope].compactMap { $0 } + additionalGlobalInlineAppScopes
    }

    enum GlobalInlineQueryPiece: Identifiable {
        case text(String, Int)
        case scope(GlobalInlineAppScope)

        var id: String {
            switch self {
            case .text(let value, let index):
                return "text-\(index)-\(value)"
            case .scope(let scope):
                return "scope-\(scope.bundleId)"
            }
        }
    }

    /// UTF-16 character range of every whitespace-separated token in the query
    /// (matches NSTextView selection offsets).
    func globalInlineQueryTokenRanges() -> [Range<Int>] {
        let query = searchState.query
        var ranges: [Range<Int>] = []
        var offset = 0
        var start: Int? = nil
        for character in query {
            let width = String(character).utf16.count
            if character == " " {
                if let s = start {
                    ranges.append(s..<offset)
                    start = nil
                }
            } else if start == nil {
                start = offset
            }
            offset += width
        }
        if let s = start { ranges.append(s..<offset) }
        return ranges
    }

    func globalInlinePieceSpan(
        _ piece: GlobalInlineQueryPiece,
        tokenRanges: [Range<Int>]
    ) -> Range<Int>? {
        switch piece {
        case .text(_, let tokenIndex):
            guard tokenIndex >= 0, tokenIndex < tokenRanges.count else { return nil }
            return tokenRanges[tokenIndex]
        case .scope(let scope):
            // Explicit extension scopes clear their matched alias from the real
            // NSTextField. Their chip is visual-only and therefore owns no text
            // range once the user starts a scoped filter query.
            if scope.isExplicit, !queryContainsInlineScopeAlias(scope) { return nil }
            let count = max(1, scope.matchedAlias.split(separator: " ").count)
            let end = scope.aliasStartIndex + count - 1
            guard scope.aliasStartIndex >= 0, end < tokenRanges.count else { return nil }
            return tokenRanges[scope.aliasStartIndex].lowerBound..<tokenRanges[end].upperBound
        }
    }

    /// Scope pills with their UTF-16 character spans in the underlying query.
    func globalInlineScopeUTF16Spans() -> [(scope: GlobalInlineAppScope, span: Range<Int>)] {
        let tokenRanges = globalInlineQueryTokenRanges()
        return allGlobalInlineAppScopes.compactMap { scope in
            globalInlinePieceSpan(.scope(scope), tokenRanges: tokenRanges)
                .map { (scope, $0) }
        }
    }

    func splitTokenForCaret(_ value: String, utf16Offset: Int) -> (String, String) {
        let utf16View = value.utf16
        guard utf16Offset > 0 else { return ("", value) }
        guard utf16Offset < utf16View.count else { return (value, "") }
        let uIndex = utf16View.index(utf16View.startIndex, offsetBy: utf16Offset)
        guard let index = String.Index(uIndex, within: value) else { return (value, "") }
        return (String(value[..<index]), String(value[index...]))
    }

    var globalInlineQueryPieces: [GlobalInlineQueryPiece] {
        let tokens = searchState.query
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        if allGlobalInlineAppScopes.count == 1,
            let scope = allGlobalInlineAppScopes.first,
            scope.isExplicit,
            !queryContainsInlineScopeAlias(scope)
        {
            // The scope chip is no longer backed by a token in the query. Keep
            // it as a visual prefix and preserve every typed token after it so
            // device filtering never consumes the first word.
            return [.scope(scope)] + tokens.enumerated().map {
                .text($0.element, $0.offset)
            }
        }
        let scopesByStartIndex = allGlobalInlineAppScopes.reduce(
            into: [Int: GlobalInlineAppScope]()
        ) { scopes, scope in
            if scopes[scope.aliasStartIndex] == nil {
                scopes[scope.aliasStartIndex] = scope
            }
        }
        if tokens.isEmpty {
            return allGlobalInlineAppScopes.map { .scope($0) }
        }
        var pieces: [GlobalInlineQueryPiece] = []
        var index = 0
        while index < tokens.count {
            if let scope = scopesByStartIndex[index] {
                pieces.append(.scope(scope))
                index += max(1, scope.matchedAlias.split(separator: " ").count)
            } else {
                pieces.append(.text(tokens[index], index))
                index += 1
            }
        }
        return pieces
    }

    func queryContainsInlineScopeAlias(_ scope: GlobalInlineAppScope) -> Bool {
        let tokens = searchState.query
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { normalizedDockPillText(String($0)) }
        let alias = scope.matchedAlias
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { normalizedDockPillText(String($0)) }
        let end = scope.aliasStartIndex + alias.count
        return !alias.isEmpty
            && scope.aliasStartIndex >= 0
            && tokens.count >= end
            && Array(tokens[scope.aliasStartIndex..<end]) == alias
    }

    func effectiveGlobalInlineActionQuery(_ query: String) -> String {
        let tokens = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if allGlobalInlineAppScopes.count == 1,
            let scope = allGlobalInlineAppScopes.first
        {
            let aliasTokens = scope.matchedAlias
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            let normalizedTokens = tokens.map(normalizedDockPillText)
            let normalizedAlias = aliasTokens.map(normalizedDockPillText)
            let aliasEnd = scope.aliasStartIndex + normalizedAlias.count
            let queryStillContainsAlias =
                !normalizedAlias.isEmpty
                && normalizedTokens.count >= aliasEnd
                && Array(normalizedTokens[scope.aliasStartIndex..<aliasEnd]) == normalizedAlias
            if !queryStillContainsAlias {
                return query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var scopedTokenIndexes = Set<Int>()
        for scope in allGlobalInlineAppScopes {
            let count = max(1, scope.matchedAlias.split(separator: " ").count)
            scopedTokenIndexes.formUnion(scope.aliasStartIndex..<(scope.aliasStartIndex + count))
        }
        let trimmed = tokens.enumerated()
            .filter { !scopedTokenIndexes.contains($0.offset) }
            .map(\.element)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard allGlobalInlineAppScopes.count > 1 else { return trimmed }
        let relationalTokens = Set(["in", "on", "with", "from", "using"])
        let normalizedTokens = trimmed.lowercased().split(separator: " ").map(String.init)
        return !normalizedTokens.isEmpty && normalizedTokens.allSatisfy(relationalTokens.contains)
            ? "" : trimmed
    }

    func indexedGlobalAppMenuTarget(
        for query: String,
        allowPrefixAlias: Bool,
        preserveRemainingQueryTokens: Bool,
        excludingBundleIds: Set<String> = []
    ) -> InstalledAppMenuTarget? {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GlobalSearchService.shared.documentCount > 0, raw.count >= 2 else { return nil }
        let docs = GlobalSearchService.shared.appScopeCandidates(
            for: raw,
            excludingBundleIds: excludingBundleIds,
            limit: 10
        )
        var best: (InstalledAppMenuTarget, Int)?
        for doc in docs {
            let aliases = ([doc.normalizedTitle] + doc.aliases)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            for alias in Set(aliases) {
                guard
                    let extraction = installedAppActionExtraction(
                        query: raw,
                        alias: alias,
                        allowPrefixAlias: allowPrefixAlias,
                        preserveRemainingQueryTokens: preserveRemainingQueryTokens
                    )
                else { continue }
                let score =
                    (extraction.aliasAtStart ? 2_000 : 1_600)
                    + extraction.aliasTokenCount * 120
                    + alias.count
                    + min(extraction.actionQuery.count, 24)
                    - extraction.aliasStartIndex * 40
                let target = InstalledAppMenuTarget(
                    appName: doc.title,
                    bundleId: doc.bundleId,
                    appPath: doc.filePath ?? doc.subtitle,
                    actionQuery: extraction.actionQuery,
                    matchedAlias: preserveRemainingQueryTokens
                        ? extraction.matchedQueryAlias : alias,
                    aliasStartIndex: extraction.aliasStartIndex
                )
                if best.map({ score > $0.1 }) ?? true {
                    best = (target, score)
                }
            }
        }
        return best?.0
    }

    @discardableResult
    func applyGlobalInlineAppScopeIfNeeded(for rawQuery: String) -> Bool {
        guard shouldUsePureGlobalAppSearch,
            isGlobalContextActive,
            !hasSelectionScopeSurface,
            l2.targetApp == nil,
            lockedSubmenuParent == nil,
            globalInlineAppScope == nil,
            // Inside a CLI tool or System Command provider scope the input is a
            // command/prompt, not a scope-building query — never convert typed words
            // into a second app-scope chip (which flipped the layer + double-scoped).
            currentGlobalScopedBundleID?.hasPrefix("cli://") != true,
            currentGlobalScopedBundleID?.hasPrefix("syscmd://") != true
        else { return false }

        let raw = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isGenericApplicationListQuery(raw.lowercased()) else { return false }
        guard
            let target = indexedGlobalAppMenuTarget(
                for: raw,
                allowPrefixAlias: true,
                preserveRemainingQueryTokens: true,
                excludingBundleIds: Set(dismissedGlobalInlineAppScopes.keys)
            )
                ?? installedAppMenuTarget(
                    for: raw,
                    includeAppsWithoutMenuSnapshot: true,
                    allowPrefixAlias: true,
                    preserveRemainingQueryTokens: true,
                    excludingBundleIds: Set(dismissedGlobalInlineAppScopes.keys)
                )
        else { return false }
        let actionQuery = target.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionQuery.isEmpty else { return false }

        globalInlineAppScope = GlobalInlineAppScope(
            appName: target.appName,
            bundleId: target.bundleId,
            appPath: target.appPath,
            matchedAlias: target.matchedAlias,
            aliasStartIndex: target.aliasStartIndex
        )
        additionalGlobalInlineAppScopes = []
        hoveredGlobalInlineScopeBundleId = nil
        ensureTrailingSpaceAfterInlineScopeIfNeeded(target: target, rawQuery: raw)
        scheduleGlobalGroupedListRebuild(query: actionQuery, delayNanoseconds: 80_000_000)
        return true
    }

    @discardableResult
    func activateRunningGlobalAppScopeIfMentioned(for rawQuery: String) -> Bool {
        guard shouldUsePureGlobalAppSearch,
            isGlobalContextActive,
            !hasSelectionScopeSurface,
            l2.targetApp == nil,
            lockedSubmenuParent == nil,
            lockedFindToken == nil,
            !suppressGlobalInlineAppScopeDetection,
            // Inside a System Command provider scope (Quick Note, Windows, …) or a CLI
            // tool scope the input is a prompt/command, not a scope-building query —
            // never convert typed words like "apple notes app" into app-scope chips.
            currentGlobalScopedBundleID?.hasPrefix("syscmd://") != true,
            currentGlobalScopedBundleID?.hasPrefix("cli://") != true
        else { return false }

        let raw = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        reconcileGlobalInlineAppScopePositions(for: raw)
        guard raw.count >= 4, !isGenericApplicationListQuery(raw.lowercased()) else { return false }
        pruneDismissedGlobalInlineAppScopes(for: raw)
        var excludedBundleIds = Set(dismissedGlobalInlineAppScopes.keys)
            .union(allGlobalInlineAppScopes.map(\.bundleId))
        var occupiedTokenIndexes = Set(
            allGlobalInlineAppScopes.flatMap { scope -> [Int] in
                let count = max(1, scope.matchedAlias.split(separator: " ").count)
                return Array(scope.aliasStartIndex..<(scope.aliasStartIndex + count))
            })
        var addedScopes: [GlobalInlineAppScope] = []
        // Automatic pilling requires the full app name/alias typed out — prefix
        // matches ("saf" → Safari) are reserved for explicit Tab completion.
        while let target = indexedGlobalAppMenuTarget(
            for: raw,
            allowPrefixAlias: false,
            preserveRemainingQueryTokens: true,
            excludingBundleIds: excludedBundleIds
        )
            ?? installedAppMenuTarget(
                for: raw,
                runningOnly: false,
                includeAppsWithoutMenuSnapshot: true,
                allowPrefixAlias: false,
                preserveRemainingQueryTokens: true,
                excludingBundleIds: excludedBundleIds
            )
        {
            let actionQuery = target.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actionQuery.isEmpty else {
                excludedBundleIds.insert(target.bundleId)
                continue
            }
            excludedBundleIds.insert(target.bundleId)
            let count = max(1, target.matchedAlias.split(separator: " ").count)
            let targetIndexes = Set(target.aliasStartIndex..<(target.aliasStartIndex + count))
            guard occupiedTokenIndexes.isDisjoint(with: targetIndexes) else { continue }
            addedScopes.append(
                GlobalInlineAppScope(
                    appName: target.appName,
                    bundleId: target.bundleId,
                    appPath: target.appPath,
                    matchedAlias: target.matchedAlias,
                    aliasStartIndex: target.aliasStartIndex
                ))
            occupiedTokenIndexes.formUnion(targetIndexes)
        }
        let typoScopes = typoTolerantGlobalInlineAppScopes(
            in: raw,
            excludingBundleIds: excludedBundleIds,
            occupiedTokenIndexes: occupiedTokenIndexes
        )
        for scope in typoScopes {
            let count = max(1, scope.matchedAlias.split(separator: " ").count)
            let scopeIndexes = Set(scope.aliasStartIndex..<(scope.aliasStartIndex + count))
            guard occupiedTokenIndexes.isDisjoint(with: scopeIndexes),
                !excludedBundleIds.contains(scope.bundleId)
            else { continue }
            addedScopes.append(scope)
            excludedBundleIds.insert(scope.bundleId)
            occupiedTokenIndexes.formUnion(scopeIndexes)
        }
        guard !addedScopes.isEmpty else { return false }

        if globalInlineAppScope == nil {
            globalInlineAppScope = addedScopes.removeFirst()
        }
        additionalGlobalInlineAppScopes.append(contentsOf: addedScopes)
        if let scope = allGlobalInlineAppScopes.max(by: { $0.aliasStartIndex < $1.aliasStartIndex })
        {
            ensureTrailingSpaceAfterInlineScopeIfNeeded(scope: scope, rawQuery: raw)
        }
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        scheduleGlobalGroupedListRebuild(query: raw, delayNanoseconds: 0)
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                self.reclaimSearchInputFocus()
            }
        }
        return true
    }

    func typoTolerantGlobalInlineAppScopes(
        in rawQuery: String,
        excludingBundleIds: Set<String>,
        occupiedTokenIndexes: Set<Int>
    ) -> [GlobalInlineAppScope] {
        let queryTokens = rawQuery.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let normalizedQueryTokens = queryTokens.map(normalizedDockPillText)
        guard normalizedQueryTokens.count >= 2 else { return [] }

        var candidates: [(name: String, bundleId: String, path: String, baseScore: Int)] = []
        var seenBundleIds = Set<String>()

        func appendCandidate(name: String, bundleId: String, path: String, baseScore: Int) {
            guard !name.isEmpty, !bundleId.isEmpty, !excludingBundleIds.contains(bundleId),
                seenBundleIds.insert(bundleId).inserted
            else { return }
            candidates.append((name, bundleId, path, baseScore))
        }

        for result in allApplications where result.type == .application {
            guard let bundleId = AppScopeMatchCache.shared.bundleId(forAppPath: result.subtitle)
            else { continue }
            appendCandidate(
                name: result.title.trimmingCharacters(in: .whitespacesAndNewlines),
                bundleId: bundleId,
                path: result.subtitle,
                baseScore: 100
            )
        }

        let builtInAppTargets: [(name: String, bundleId: String, path: String)] = [
            ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
            ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
            ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
            ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
            ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
            ("Reminders", "com.apple.reminders", "/System/Applications/Reminders.app"),
            ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
            ("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
            (
                "System Settings", "com.apple.systempreferences",
                "/System/Applications/System Settings.app"
            ),
        ]
        for target in builtInAppTargets {
            appendCandidate(
                name: target.name,
                bundleId: target.bundleId,
                path: target.path,
                baseScore: 108
            )
        }

        var bestByBundleId:
            [String: (scope: GlobalInlineAppScope, tokenRange: Range<Int>, score: Int)] = [:]

        for candidate in candidates {
            let aliases = Set(
                ([candidate.name]
                    + dockPillAppAliases(appName: candidate.name, bundleId: candidate.bundleId))
                    .map(normalizedDockPillText)
                    .filter { $0.count >= 4 }
            )
            for alias in aliases {
                let aliasTokens = alias.split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                guard !aliasTokens.isEmpty, aliasTokens.count <= normalizedQueryTokens.count
                else { continue }
                let maxStart = normalizedQueryTokens.count - aliasTokens.count
                for start in 0...maxStart {
                    let range = start..<(start + aliasTokens.count)
                    guard occupiedTokenIndexes.isDisjoint(with: Set(range)) else { continue }

                    var score = candidate.baseScore + alias.count
                    var usedTypo = false
                    var matched = true
                    for offset in aliasTokens.indices {
                        let queryToken = normalizedQueryTokens[start + offset]
                        let aliasToken = aliasTokens[offset]
                        if queryToken == aliasToken {
                            score += 220
                            continue
                        }
                        guard queryToken.count >= 4,
                            aliasToken.count >= 4,
                            queryToken.first == aliasToken.first
                        else {
                            matched = false
                            break
                        }
                        let distance = levenshteinDistance(queryToken, aliasToken)
                        let allowedDistance = min(2, max(1, min(queryToken.count, aliasToken.count) / 4))
                        guard distance <= allowedDistance else {
                            matched = false
                            break
                        }
                        usedTypo = true
                        score += 150 - (distance * 28)
                    }
                    guard matched, usedTypo else { continue }
                    score -= start * 12
                    let scope = GlobalInlineAppScope(
                        appName: candidate.name,
                        bundleId: candidate.bundleId,
                        appPath: candidate.path,
                        matchedAlias: queryTokens[range].joined(separator: " "),
                        aliasStartIndex: start
                    )
                    if bestByBundleId[candidate.bundleId].map({ score > $0.score }) ?? true {
                        bestByBundleId[candidate.bundleId] = (scope, range, score)
                    }
                }
            }
        }

        var claimedIndexes = occupiedTokenIndexes
        return bestByBundleId.values
            .sorted {
                if $0.tokenRange.lowerBound != $1.tokenRange.lowerBound {
                    return $0.tokenRange.lowerBound < $1.tokenRange.lowerBound
                }
                return $0.score > $1.score
            }
            .compactMap { entry in
                let indexes = Set(entry.tokenRange)
                guard claimedIndexes.isDisjoint(with: indexes) else { return nil }
                claimedIndexes.formUnion(indexes)
                return entry.scope
            }
    }

    func ensureTrailingSpaceAfterInlineScopeIfNeeded(
        target: InstalledAppMenuTarget,
        rawQuery: String
    ) {
        let scope = GlobalInlineAppScope(
            appName: target.appName,
            bundleId: target.bundleId,
            appPath: target.appPath,
            matchedAlias: target.matchedAlias,
            aliasStartIndex: target.aliasStartIndex
        )
        ensureTrailingSpaceAfterInlineScopeIfNeeded(scope: scope, rawQuery: rawQuery)
    }

    func ensureTrailingSpaceAfterInlineScopeIfNeeded(
        scope: GlobalInlineAppScope,
        rawQuery: String
    ) {
        guard searchInputCursorIsAtEnd(),
            let last = searchState.query.last,
            !last.isWhitespace
        else { return }
        let queryTokens = rawQuery.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let aliasTokenCount = max(1, scope.matchedAlias.split(separator: " ").count)
        guard scope.aliasStartIndex + aliasTokenCount == queryTokens.count else { return }
        let normalizedMatchedAlias = normalizedDockPillText(scope.matchedAlias)
        let exactAliases = Set(
            ([scope.appName]
                + GlobalSearchService.SearchDocument.aliases(
                    appName: scope.appName,
                    bundleId: scope.bundleId
                )).map(normalizedDockPillText)
        )
        guard exactAliases.contains(normalizedMatchedAlias) else { return }
        searchState.query += " "
    }

    func globalInlineScopeAliasIsPresent(_ alias: String, in query: String) -> Bool {
        let aliasTokens = alias.split(separator: " ").map(String.init)
        let queryTokens = query.split(separator: " ").map { normalizedDockPillText(String($0)) }
        return firstScopedAliasRange(aliasTokens, in: queryTokens) != nil
    }

    func pruneDismissedGlobalInlineAppScopes(for query: String) {
        dismissedGlobalInlineAppScopes = dismissedGlobalInlineAppScopes.filter {
            globalInlineScopeAliasIsPresent($0.value, in: query)
        }
    }

    func reconcileGlobalInlineAppScopePositions(for query: String) {
        let queryTokens = query.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let normalizedTokens = queryTokens.map(normalizedDockPillText)
        var occupiedIndexes = Set<Int>()
        var reconciledScopes: [GlobalInlineAppScope] = []

        for var scope in allGlobalInlineAppScopes.sorted(by: {
            $0.aliasStartIndex < $1.aliasStartIndex
        }) {
            // Explicit (right-arrow) scopes aren't tied to a typed alias — keep them
            // verbatim so typing an action query doesn't drop the scope.
            if scope.isExplicit {
                reconciledScopes.append(scope)
                continue
            }
            let aliasTokens = scope.matchedAlias.split(separator: " ").map {
                normalizedDockPillText(String($0))
            }
            guard !aliasTokens.isEmpty, normalizedTokens.count >= aliasTokens.count else {
                continue
            }

            let maxStart = normalizedTokens.count - aliasTokens.count
            guard
                let start = (0...maxStart).first(where: { candidateStart in
                    let range = candidateStart..<(candidateStart + aliasTokens.count)
                    return occupiedIndexes.isDisjoint(with: Set(range))
                        && Array(normalizedTokens[range]) == aliasTokens
                })
            else {
                continue
            }

            let range = start..<(start + aliasTokens.count)
            scope.aliasStartIndex = start
            scope.matchedAlias = queryTokens[range].joined(separator: " ")
            reconciledScopes.append(scope)
            occupiedIndexes.formUnion(range)
        }

        globalInlineAppScope = reconciledScopes.first
        additionalGlobalInlineAppScopes = Array(reconciledScopes.dropFirst())
    }

    func clearGlobalInlineAppScope(
        preserveQuery: Bool = true,
        dismissScope: Bool = false
    ) {
        let inlineScope = globalInlineAppScope
        globalInlineAppScope = nil
        additionalGlobalInlineAppScopes = []
        suppressGlobalInlineAppScopeDetection = false
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        if dismissScope, let inlineScope {
            dismissedGlobalInlineAppScopes[inlineScope.bundleId] = inlineScope.matchedAlias
        }
        let q: String
        q = preserveQuery ? searchState.query : ""
        pruneDismissedGlobalInlineAppScopes(for: q)
        if !preserveQuery {
            searchState.query = ""
        } else if q != searchState.query {
            searchState.query = q
        }
        scheduleGlobalAppMatchRebuild(query: q, delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: q, delayNanoseconds: 0)
    }

    /// After quitting an app from its scope, remove that app's pill (and its
    /// leftover query when it was the only scope) so the next keystroke starts
    /// a fresh query without manual cleanup.
    func removeGlobalInlineAppScopesAfterQuit(bundleID: String) {
        guard let scope = allGlobalInlineAppScopes.first(where: { $0.bundleId == bundleID })
        else { return }
        let hasOtherScopes = allGlobalInlineAppScopes.contains { $0.bundleId != bundleID }
        withAnimation(.easeOut(duration: 0.18)) {
            if hasOtherScopes {
                removeGlobalInlineAppScope(scope)
            } else {
                clearGlobalInlineAppScope(preserveQuery: false)
            }
        }
        reclaimSearchInputFocus()
    }

    func removeGlobalInlineAppScope(_ scope: GlobalInlineAppScope) {
        dismissedGlobalInlineAppScopes[scope.bundleId] = scope.matchedAlias
        let remaining = allGlobalInlineAppScopes.filter { $0.bundleId != scope.bundleId }
        globalInlineAppScope = remaining.first
        additionalGlobalInlineAppScopes = Array(remaining.dropFirst())
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        let q = searchState.query
        pruneDismissedGlobalInlineAppScopes(for: q)
        scheduleGlobalAppMatchRebuild(query: q, delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: q, delayNanoseconds: 0)
    }

    func removeGlobalInlineAppScopeFromBackspace(_ scope: GlobalInlineAppScope) {
        dismissedGlobalInlineAppScopes[scope.bundleId] = scope.matchedAlias
        let tokens = searchState.query
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let scopeTokenCount = max(1, scope.matchedAlias.split(separator: " ").count)
        let scopeRange = scope.aliasStartIndex..<(scope.aliasStartIndex + scopeTokenCount)
        var nextTokens: [String] = []
        let replacementTokens = scope.matchedAlias
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        for (index, token) in tokens.enumerated() {
            if index == scope.aliasStartIndex {
                nextTokens.append(contentsOf: replacementTokens)
            }
            if !scopeRange.contains(index) {
                nextTokens.append(token)
            }
        }
        let nextQuery = nextTokens.joined(separator: " ")

        let remaining = allGlobalInlineAppScopes.filter { $0.bundleId != scope.bundleId }
        globalInlineAppScope = remaining.first
        additionalGlobalInlineAppScopes = Array(remaining.dropFirst())
        focusedAppPillIndex = nil
        hoveredAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.appCompletion = nil
        cachedGlobalAppQuery = ""
        cachedGlobalAppMatches = []
        cachedGlobalGroupedQuery = ""
        cachedGlobalGroupedState = nil
        globalContextViewModel.cachedGroupedFingerprint = ""
        searchState.query = nextQuery
        reconcileGlobalInlineAppScopePositions(for: nextQuery)
        pruneDismissedGlobalInlineAppScopes(for: nextQuery)
        scheduleGlobalAppMatchRebuild(query: nextQuery, delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: nextQuery, delayNanoseconds: 0)
    }

    func trailingGlobalInlineAppScopeForBackspace() -> GlobalInlineAppScope? {
        guard searchInputCursorIsAtEnd(),
            let lastCharacter = searchState.query.last,
            !lastCharacter.isWhitespace,
            let piece = globalInlineQueryPieces.last,
            case .scope(let scope) = piece
        else {
            return nil
        }
        return scope
    }

    func appMenuGroups(from descriptorGroups: [GlobalMenuDescriptorGroup]) -> [AppMenuGroup] {
        descriptorGroups.compactMap { group -> AppMenuGroup? in
            let descriptors = group.descriptors.filter { descriptor in
                let root = descriptor.path.first.map(normalizedDockPillText) ?? ""
                guard !root.isEmpty else { return false }
                return root != "apple"
            }
            guard !descriptors.isEmpty else {
                return nil
            }
            return AppMenuGroup(
                id: group.bundleID,
                appName: group.appName,
                icon: group.icon,
                pills: descriptors.map(makeCrossAppMenuDockPill)
            )
        }
    }

    func globalNativeWritingToolGroups(for query: String) -> [AppMenuGroup] {
        let pills = buildNativeWritingToolPills(query: query)
        guard !pills.isEmpty else { return [] }
        let sourceBundleId = pills.first?.sourceBundleId ?? nativeWritingToolContext?.bundleId ?? ""
        let sourceAppName =
            pills.first?.sourceAppName ?? nativeWritingToolContext?.appName ?? "Current App"
        return [
            AppMenuGroup(
                id: "writing-tools-\(sourceBundleId.isEmpty ? sourceAppName : sourceBundleId)",
                appName: sourceAppName,
                icon: resolvedApplicationIcon(
                    bundleIdentifier: sourceBundleId, appName: sourceAppName),
                pills: pills
            )
        ]
    }

    func indexedRunningMenuGroups(
        from docs: [GlobalSearchService.SearchDocument],
        maxGroups: Int,
        maxPills: Int
    ) -> [AppMenuGroup] {
        guard maxGroups > 0, maxPills > 0 else { return [] }
        var grouped: [String: (name: String, icon: NSImage?, pills: [DockPill])] =
            [:]
        var bundleOrder: [String] = []
        var remaining = maxPills
        var seenPaths = Set<String>()
        let perAppPillLimit = max(3, min(6, maxPills))

        for doc in docs {
            guard remaining > 0 else { break }
            if case .browserURL(let url, let browserBundleId, let browserName, let kind, let domain) = doc.action {
                let key = "browser-url:\(browserBundleId):\(url.absoluteString)"
                guard seenPaths.insert(key).inserted else { continue }
                if grouped[browserBundleId] == nil {
                    guard bundleOrder.count < maxGroups else { continue }
                    bundleOrder.append(browserBundleId)
                    grouped[browserBundleId] = (browserName, doc.icon, [])
                }
                guard (grouped[browserBundleId]?.pills.count ?? 0) < perAppPillLimit else {
                    continue
                }
                let descriptor = GlobalMenuDescriptor(
                    id: key,
                    name: doc.title,
                    badge: domain,
                    statusBadge: kind,
                    bundleID: browserBundleId,
                    appName: browserName,
                    appIcon: doc.icon,
                    path: [kind, doc.title],
                    shortcutChar: nil,
                    shortcutModifiers: 0,
                    rankingScore: doc.sourceKind.rawValue
                )
                var pill = makeBrowserURLDockPill(
                    descriptor: descriptor,
                    url: url,
                    kind: kind,
                    domain: domain
                )
                pill.searchTerms += doc.aliases
                grouped[browserBundleId]?.pills.append(pill)
                remaining -= 1
                continue
            }
            guard
                case .cachedMenu(
                    let bundleId,
                    let appName,
                    let path,
                    let shortcutChar,
                    let shortcutModifiers
                ) = doc.action
            else { continue }
            let key = "\(bundleId):\(path.joined(separator: ">"))"
            guard seenPaths.insert(key).inserted else { continue }
            if grouped[bundleId] == nil {
                guard bundleOrder.count < maxGroups else { continue }
                bundleOrder.append(bundleId)
                grouped[bundleId] = (appName, doc.icon, [])
            }
            guard (grouped[bundleId]?.pills.count ?? 0) < perAppPillLimit else { continue }

            let descriptor = GlobalMenuDescriptor(
                id: "indexed-menu-\(bundleId)-\(path.joined(separator: ">"))",
                name: doc.title,
                badge: MenuShortcutFormatter.display(
                    char: shortcutChar,
                    modifiers: shortcutModifiers
                ),
                statusBadge: nil,
                bundleID: bundleId,
                appName: appName,
                appIcon: doc.icon,
                path: path,
                shortcutChar: shortcutChar,
                shortcutModifiers: shortcutModifiers,
                rankingScore: doc.sourceKind.rawValue
            )
            grouped[bundleId]?.pills.append(makeCrossAppMenuDockPill(from: descriptor))
            remaining -= 1
        }

        return bundleOrder.compactMap { bundleId -> AppMenuGroup? in
            guard let group = grouped[bundleId], !group.pills.isEmpty else { return nil }
            return AppMenuGroup(
                id: "indexed-menu-group-\(bundleId)",
                appName: group.name,
                icon: group.icon,
                pills: group.pills
            )
        }
    }

    func makeBrowserURLDockPill(
        descriptor: GlobalMenuDescriptor,
        url: URL,
        kind: String,
        domain: String
    ) -> DockPill {
        var pill = DockPill(
            id: descriptor.id,
            name: descriptor.name,
            icon: kind.lowercased() == "bookmark" ? "bookmark.fill" : "clock.arrow.circlepath",
            accentColorName: "blue",
            badge: domain,
            execute: {
                if let appURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: descriptor.bundleID)
                {
                    NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: appURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                } else {
                    NSWorkspace.shared.open(url)
                }
                AppDelegate.shared?.hideLauncher()
            }
        )
        pill.sourceBundleId = descriptor.bundleID
        pill.sourceAppName = descriptor.appName
        pill.rankingKind = "recentURL"
        pill.rankingScore = descriptor.rankingScore
        pill.menuContext = kind
        pill.menuStatusBadge = domain
        pill.resolvedURL = url
        pill.quickLookURL = BrowserURLLibraryService.shared.quickLookURL(
            for: BrowserURLLibraryEntry(
                title: descriptor.name,
                url: url,
                visitDate: nil,
                kind: kind.lowercased() == "bookmark" ? .bookmark : .history,
                browserName: descriptor.appName,
                browserBundleId: descriptor.bundleID
            )
        )
        pill.trackingIdentifier = descriptor.id
        pill.searchTerms = [
            descriptor.name, url.absoluteString, domain, descriptor.appName,
            kind, "browser", "url", "recent", "history", "bookmark",
        ]
        if let favicon = FaviconStore.shared.icon(for: url) {
            pill.menuItemImage = favicon
        } else {
            FaviconStore.shared.fetchIfNeeded(for: url)
        }
        return pill
    }

    func mergeRunningMenuGroups(
        indexed: [AppMenuGroup],
        cached: [AppMenuGroup],
        maxGroups: Int,
        maxPills: Int
    ) -> [AppMenuGroup] {
        guard maxGroups > 0, maxPills > 0 else { return [] }
        var output: [AppMenuGroup] = []
        var seen = Set<String>()
        var remaining = maxPills
        for group in indexed + cached {
            guard output.count < maxGroups, remaining > 0 else { break }
            let key = normalizedDockPillText(group.appName)
            guard seen.insert(key).inserted else { continue }
            let pills = Array(group.pills.prefix(remaining))
            guard !pills.isEmpty else { continue }
            output.append(
                AppMenuGroup(
                    id: group.id,
                    appName: group.appName,
                    icon: group.icon,
                    pills: pills
                ))
            remaining -= pills.count
        }
        return output
    }

    func runningCachedMenuGroups(
        for query: String,
        maxGroups: Int,
        maxPills: Int
    ) -> [AppMenuGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, maxGroups > 0, maxPills > 0 else { return [] }
        var groups: [AppMenuGroup] = []
        var remaining = maxPills
        var seenPaths = Set<String>()
        let perAppLimit = max(3, min(6, maxPills))
        let appQuery = isGlobalRunningAppTerminationQuery(q) ? "" : normalizedDockPillText(q)
        let runningSource =
            isGlobalRunningAppTerminationQuery(q)
            ? currentStoppableRunningApps(for: appQuery)
            : currentRegularRunningApps() + runningRegularApps
        var seenApps = Set<String>()

        for app in runningSource {
            guard remaining > 0, groups.count < maxGroups else { break }
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
                bundleId != "com.apple.finder",
                bundleId != Bundle.main.bundleIdentifier,
                GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bundleId)
            else { continue }
            let appKey = bundleId.lowercased()
            guard seenApps.insert(appKey).inserted else { continue }
            let appName = app.localizedName ?? bundleId
            let icon = resolvedRunningAppIcon(for: app)
            let items = GlobalContextEngine.shared.cachedMenuItems(
                for: app,
                query: q,
                maxResults: min(perAppLimit, remaining)
            )
            let descriptors = items.compactMap { item -> GlobalMenuDescriptor? in
                let path = item.path
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "-" }
                guard path.count > 1, item.children.isEmpty else { return nil }
                let root = path.first.map(normalizedDockPillText) ?? ""
                guard !root.isEmpty, root != "apple" else { return nil }
                let key = "\(bundleId):\(path.joined(separator: ">"))"
                guard seenPaths.insert(key).inserted else { return nil }
                return GlobalMenuDescriptor(
                    id: "running-cache-\(bundleId)-\(path.joined(separator: ">"))",
                    name: item.title,
                    badge: MenuShortcutFormatter.display(
                        char: item.shortcutChar,
                        modifiers: item.shortcutModifiers
                    ),
                    statusBadge: nil,
                    bundleID: bundleId,
                    appName: appName,
                    appIcon: icon,
                    path: path,
                    shortcutChar: item.shortcutChar,
                    shortcutModifiers: item.shortcutModifiers,
                    rankingScore: GlobalSearchService.SourceKind.runningMenu.rawValue
                )
            }
            guard !descriptors.isEmpty else { continue }
            groups.append(
                AppMenuGroup(
                    id: "running-cache-group-\(bundleId)",
                    appName: appName,
                    icon: icon,
                    pills: descriptors.map(makeCrossAppMenuDockPill)
                ))
            remaining -= descriptors.count
        }

        return groups
    }

    func cachedMenuCapabilityGroups(
        for query: String,
        excludingBundleIds rawExcludedBundleIds: Set<String>,
        maxGroups: Int,
        maxPills: Int
    ) -> [AppMenuGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, maxGroups > 0, maxPills > 0 else { return [] }
        var groups: [AppMenuGroup] = []
        var remaining = maxPills
        var seenPaths = Set<String>()
        var excludedBundleIds = Set(rawExcludedBundleIds.map(normalizedDockPillText))
        let perAppLimit = max(3, min(6, maxPills))
        let runningBundleIds = Set(
            (currentRegularRunningApps() + runningRegularApps)
                .compactMap(\.bundleIdentifier)
                .map(normalizedDockPillText)
        )

        for summary in AppMenuCapabilityCache.shared.summaries() {
            guard remaining > 0, groups.count < maxGroups else { break }
            let bundleId = summary.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleKey = normalizedDockPillText(bundleId)
            guard !bundleId.isEmpty, excludedBundleIds.insert(bundleKey).inserted else { continue }
            guard runningBundleIds.contains(bundleKey) else { continue }

            let items = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleId,
                appName: summary.appName,
                query: q,
                maxResults: min(perAppLimit, remaining)
            )
            let icon = resolvedApplicationIcon(bundleIdentifier: bundleId, appName: summary.appName)
            let descriptors = items.compactMap { item -> GlobalMenuDescriptor? in
                let path = item.path
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "-" }
                guard path.count > 1, item.children.isEmpty else { return nil }
                let root = path.first.map(normalizedDockPillText) ?? ""
                guard !root.isEmpty, root != "apple" else { return nil }
                let key = "\(bundleId):\(path.joined(separator: ">"))"
                guard seenPaths.insert(key).inserted else { return nil }
                return GlobalMenuDescriptor(
                    id: "cached-capability-\(bundleId)-\(path.joined(separator: ">"))",
                    name: item.title,
                    badge: MenuShortcutFormatter.display(
                        char: item.shortcutChar,
                        modifiers: item.shortcutModifiers
                    ),
                    statusBadge: nil,
                    bundleID: bundleId,
                    appName: summary.appName,
                    appIcon: icon,
                    path: path,
                    shortcutChar: item.shortcutChar,
                    shortcutModifiers: item.shortcutModifiers,
                    rankingScore: GlobalSearchService.SourceKind.runningMenu.rawValue - 1
                )
            }
            guard !descriptors.isEmpty else { continue }
            groups.append(
                AppMenuGroup(
                    id: "cached-capability-group-\(bundleId)",
                    appName: summary.appName,
                    icon: icon,
                    pills: descriptors.map(makeCrossAppMenuDockPill)
                ))
            remaining -= descriptors.count
        }

        return groups
    }

    func topGlobalMenuGroupIconForInputPreview(query: String) -> NSImage? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            !hasSelectionScopeSurface,
            globalInlineAppScope == nil,
            !q.isEmpty
        else { return nil }
        return globalGroupedListNavigationState(for: q).appMenuGroups.first?.icon
    }

    func globalAppContentSearchGroups(for query: String) -> [AppMenuGroup] {
        let appGroups = AppContentSearchRouter.shared.intents(for: query).map { intent in
            let icon = resolvedApplicationIcon(
                bundleIdentifier: intent.bundleId,
                appName: intent.appName
            )
            var pill = appContentSearchDockPill(intent)
            pill.menuItemImage = icon
            return AppMenuGroup(
                id: "content-search:\(intent.bundleId)",
                appName: "Search \(intent.appName)",
                icon: icon,
                pills: [pill]
            )
        }
        return appGroups
    }

    func globalRoleExpandedAppGroups(for query: String) -> [AppMenuGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            !hasSelectionScopeSurface,
            globalInlineAppScope == nil,
            !q.isEmpty
        else { return [] }

        let resolution = GlobalContextQueryRoleResolver.shared.resolve(q)
        let roles = ([resolution.scope].compactMap { $0 } + resolution.targets)
            .reduce(into: [GlobalContextResolvedAppRole]()) { output, role in
                guard !output.contains(where: { $0.bundleId == role.bundleId }) else { return }
                output.append(role)
            }
        guard !roles.isEmpty else { return [] }

        return roles.prefix(3).compactMap { scope -> AppMenuGroup? in
            let scopeResolution = DockScopeResolution(
                scopedBundleId: scope.bundleId,
                scopedAppName: scope.appName,
                scopedSearchQuery: scope.actionQuery,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
            let icon = resolvedApplicationIcon(
                bundleIdentifier: scope.bundleId,
                appName: scope.appName
            )

            var pills: [DockPill] = []
            let hasNativeBrowserCommand =
                isBrowserMenuSource(scope.bundleId)
                && !BrowserNativeCommandService.shared
                    .matchingCommands(for: scope.actionQuery)
                    .isEmpty
            if isBrowserMenuSource(scope.bundleId),
                !hasNativeBrowserCommand,
                !scope.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                pills.append(globalBrowserSearchPill(scope: scope, icon: icon))
                pills.append(
                    contentsOf: buildBrowserURLLibraryPills(
                        query: scope.actionQuery,
                        scopedBrowserBundleId: scope.bundleId,
                        limit: 12
                    )
                )
            }

            let cachedPills = cachedGlobalAppScopeDockPills(
                query: scope.actionQuery,
                scope: scopeResolution,
                appPath: scope.appPath
            )
            for pill in cachedPills
            where !pills.contains(where: { $0.trackingIdentifier == pill.trackingIdentifier }) {
                pills.append(pill)
                if pills.count >= 5 { break }
            }
            if !pills.contains(where: {
                $0.rankingKind == "appLaunch"
                    || normalizedDockPillText($0.name)
                        == "open \(normalizedDockPillText(scope.appName))"
            }) {
                pills.append(globalOpenAppPill(scope: scope, icon: icon))
            }

            let visible = Array(pills.prefix(maxListViewDockPills))
            guard !visible.isEmpty else { return nil }
            return AppMenuGroup(
                id: scope.bundleId,
                appName: scope.appName,
                icon: icon,
                pills: visible
            )
        }
    }

    func globalBrowserSearchPill(
        scope: GlobalContextResolvedAppRole,
        icon: NSImage?
    ) -> DockPill {
        let query = scope.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = AppContentSearchIntent(
            bundleId: scope.bundleId,
            appName: scope.appName,
            query: query
        )
        var pill = DockPill(
            id: "global-browser-search:\(scope.bundleId):\(normalizedDockPillText(query))",
            name: "Search web for \"\(query)\"",
            icon: "magnifyingglass",
            accentColorName: "blue",
            badge: "Search",
            execute: {
                let actionId = DockActionFeedback.start(
                    "Searching", subject: scope.appName,
                    icon: "magnifyingglass", tint: .blue.opacity(0.85)
                )
                Task {
                    let output = await AppContentSearchRouter.shared.execute(intent)
                    await MainActor.run {
                        let clean =
                            output
                            .replacingOccurrences(of: "✅ ", with: "")
                            .replacingOccurrences(of: "❌ ", with: "")
                        if output.hasPrefix("❌") {
                            DockActionFeedback.fail(actionId, label: clean)
                        } else {
                            DockActionFeedback.complete(actionId, label: clean)
                        }
                        searchState.query = ""
                        focusedAppPillIndex = nil
                        l2.focusedPillIndex = nil
                    }
                }
            }
        )
        pill.menuItemImage = icon
        pill.sourceBundleId = scope.bundleId
        pill.sourceAppName = scope.appName
        pill.rankingKind = "contentSearch"
        pill.trackingIdentifier =
            "global-browser-search:\(scope.bundleId):\(normalizedDockPillText(query))"
        pill.searchTerms = [query, scope.appName, "search", "web", "find"]
        pill.rankingScore = 10_000
        return pill
    }

    func globalOpenWebsitePill(
        url: URL,
        scope: GlobalContextResolvedAppRole,
        target: GlobalContextResolvedAppRole
    ) -> DockPill {
        var pill = DockPill(
            id:
                "global-open-website:\(scope.bundleId):\(target.bundleId):\(url.host ?? url.absoluteString)",
            name: "Open \(url.host ?? target.appName)",
            icon: "link",
            accentColorName: "blue",
            badge: "Web",
            execute: { [self] in
                openURL(url, inBrowserBundleId: scope.bundleId)
            }
        )
        pill.sourceBundleId = scope.bundleId
        pill.sourceAppName = scope.appName
        pill.rankingKind = "web"
        pill.trackingIdentifier = pill.id
        pill.resolvedURL = url
        pill.searchTerms = [target.appName, url.absoluteString, "open", "download", "web"]
        return pill
    }

    func globalOpenAppPill(
        scope: GlobalContextResolvedAppRole,
        icon: NSImage?
    ) -> DockPill {
        var pill = DockPill(
            id: "global-open-app:\(scope.bundleId)",
            name: "Open \(scope.appName)",
            icon: "app.badge",
            accentColorName: "blue",
            badge: nil,
            execute: { [self] in
                _ = launchApplication(
                    bundleIdentifier: scope.bundleId,
                    appName: scope.appName,
                    path: scope.appPath
                )
            }
        )
        pill.menuItemImage = icon
        pill.sourceBundleId = scope.bundleId
        pill.sourceAppName = scope.appName
        pill.rankingKind = "appLaunch"
        pill.trackingIdentifier = pill.id
        pill.searchTerms = [scope.appName, "open", "launch"]
        return pill
    }

    func globalRoleWebsiteURL(for target: GlobalContextResolvedAppRole) -> URL? {
        let hostBase =
            normalizedDockPillText(target.appName)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        guard hostBase.count >= 3 else { return nil }
        return URL(string: "https://www.\(hostBase).com")
    }

    func openURL(_ url: URL, inBrowserBundleId bundleId: String) {
        hideLauncherAfterResultExecution()
        if let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: browserURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Chat with <App>" action pill — arms the frontmost/scoped app chat. If the user
    /// already typed a query, it sends straight to chat; otherwise it just arms ("Ask <App>
    /// — press Enter to send"). Lives in the ACTIONS group.
    func chatWithFrontmostAppDockPill(appName: String, bundleId: String, query: String) -> DockPill {
        var pill = DockPill(
            id: "chat-with:\(bundleId)",
            name: "Chat with \(appName)",
            icon: "bubble.left.and.text.bubble.right",
            accentColorName: "purple",
            badge: appName,
            execute: { [self] in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                l2.chatDraftAppName = appName
                l2.chatDraftBundleId = bundleId
                l2.chatArmed = true
                l2.chatDismissed = false
                if trimmed.isEmpty {
                    requestWindowSizeUpdate(reason: .panelChanged, animated: true)
                } else {
                    dismissMediaLayer()
                    handleL2QuerySkippingMenuRouter(trimmed)
                }
            }
        )
        pill.sourceBundleId = bundleId
        pill.sourceAppName = appName
        pill.rankingKind = "action"
        pill.trackingIdentifier = "chat-with:\(bundleId)"
        pill.searchTerms = ["chat", "ask", "ai", "talk", appName]
        // Just below the search action so it sits at the bottom of ACTIONS.
        pill.rankingScore = 9_000
        return pill
    }

    func appContentSearchDockPill(_ intent: AppContentSearchIntent) -> DockPill {
        var pill = DockPill(
            id: "content-search:\(intent.id)",
            name: "Search \(intent.appName) for \"\(intent.query)\"",
            icon: "magnifyingglass",
            accentColorName: "blue",
            badge: "Search",
            execute: {
                let actionId = DockActionFeedback.start(
                    "Searching", subject: intent.appName,
                    icon: "magnifyingglass", tint: .blue.opacity(0.85)
                )
                // Hide the dock first so the target app becomes key and receives the
                // injector's Cmd+F / paste keystrokes (otherwise the dock eats them).
                resetDockStateAfterAppAction()
                forceHideLauncherAfterResultExecution()
                Task {
                    let output = await AppContentSearchRouter.shared.execute(intent)
                    await MainActor.run {
                        let clean =
                            output
                            .replacingOccurrences(of: "✅ ", with: "")
                            .replacingOccurrences(of: "❌ ", with: "")
                        if output.hasPrefix("❌") {
                            DockActionFeedback.fail(actionId, label: clean)
                        } else {
                            DockActionFeedback.complete(actionId, label: clean)
                        }
                        searchState.query = ""
                        focusedAppPillIndex = nil
                        l2.focusedPillIndex = nil
                    }
                }
            }
        )
        pill.sourceBundleId = intent.bundleId
        pill.sourceAppName = intent.appName
        pill.rankingKind = "contentSearch"
        pill.trackingIdentifier = "content-search:\(intent.bundleId):\(intent.query.lowercased())"
        pill.searchTerms = [intent.query, intent.appName, "search", "find"]
        pill.rankingScore = 10_000
        return pill
    }

    func browserContentSearchDockPill(_ intent: AppContentSearchIntent) -> DockPill {
        let encoded =
            intent.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? intent.query
        let url = URL(string: "https://www.google.com/search?q=\(encoded)")
        var pill = DockPill(
            id: "browser-search:\(intent.bundleId):\(normalizedDockPillText(intent.query))",
            name: "Search web for \"\(intent.query)\"",
            icon: "magnifyingglass",
            accentColorName: "blue",
            badge: intent.appName,
            execute: { [self] in
                guard let url else { return }
                let actionId = DockActionFeedback.start(
                    "Searching", subject: intent.appName,
                    icon: "magnifyingglass", tint: .blue.opacity(0.85)
                )
                openURL(url, inBrowserBundleId: intent.bundleId)
                DockActionFeedback.complete(actionId, label: "Opened web search")
                searchState.query = ""
                focusedAppPillIndex = nil
                l2.focusedPillIndex = nil
            }
        )
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: intent.bundleId)
        {
            pill.menuItemImage = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        pill.sourceBundleId = intent.bundleId
        pill.sourceAppName = intent.appName
        pill.rankingKind = "webSearch"
        pill.trackingIdentifier =
            "browser-search:\(intent.bundleId):\(normalizedDockPillText(intent.query))"
        // Do not include the raw query here. Matching URL/history/menu rows should win
        // when they contain the same text; this pill is the browser-native fallback.
        pill.searchTerms = [intent.appName, "search", "web", "google", "browser"]
        return pill
    }

    /// Browser History/Bookmarks/Recent rows resolve to the page's real URL when the
    /// title is in local browser history — those rows open in Safari directly instead
    /// of replaying menu clicks against the source app.
    func browserLinkURL(for descriptor: GlobalMenuDescriptor) -> URL? {
        guard isBrowserURLMenuRow(descriptor) else { return nil }
        return SafariLinkResolver.shared.url(forTitle: descriptor.name)
    }

    /// True when a browser menu descriptor is a DYNAMIC URL row (History /
    /// Bookmarks / Recently Closed / recent tabs) rather than a stable command
    /// (Back, Forward, Home, Show Personal History, Clear History…). These rows
    /// must open a URL and must NEVER be AX-clicked — the submenu is scrollable,
    /// position-sensitive and reorders.
    func isBrowserURLMenuRow(_ descriptor: GlobalMenuDescriptor) -> Bool {
        guard descriptor.path.count > 1, isBrowserMenuSource(descriptor.bundleID) else {
            return false
        }
        let root = descriptor.path.first.map(normalizedDockPillText) ?? ""
        let pathText = descriptor.path.map(normalizedDockPillText).joined(separator: " ")
        // Stable commands that live under History/Bookmarks but are NOT URL rows.
        let name = normalizedDockPillText(descriptor.name)
        let stableCommands: Set<String> = [
            "show all history", "show history", "show personal history",
            "clear history", "clear history…", "clear history...",
            "back", "forward", "home", "reopen last closed window",
            "reopen all windows from last session", "show bookmarks",
            "edit bookmarks", "add bookmark", "add bookmark…", "bookmark all tabs",
            "show bookmarks editor", "add to reading list",
        ]
        if stableCommands.contains(name) { return false }
        return root == "history"
            || root == "bookmarks"
            || pathText.contains("recent")
            || pathText.contains("recently")
            || pathText.contains("tabs")
            || pathText.contains("visited")
    }

    /// The frontmost app's installed adapter actions (linked shortcuts, deep
    /// links, etc.) as Global Context rows. Menu-bar/CLI types are excluded —
    /// menus come from the AX cache, CLI is a scoped concept.
    func globalFrontmostAdapterActionRows(for query: String, limit: Int) -> [SearchResult] {
        let bundleId =
            AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier
            ?? frontmost.bundleID
        guard !bundleId.isEmpty else { return [] }
        let actions = adapterManager.actions(for: bundleId, query: query)
            .filter { $0.type != .menubar && $0.type != .cliTool }
        guard !actions.isEmpty else { return [] }
        let capturedContext = axContext
        return actions.prefix(limit).map { action in
            SearchResult(
                title: action.name,
                subtitle: action.type == .shortcut ? "Shortcut" : action.type.displayName,
                icon: NSImage(systemSymbolName: action.icon, accessibilityDescription: nil),
                action: {
                    Task {
                        _ = await AppAdapterManager.shared.execute(
                            action, context: capturedContext, targetBundleId: bundleId)
                    }
                },
                score: 9_500,
                type: action.type == .shortcut ? .shortcut : .extensionCommand,
                filePath: nil,
                contactData: nil,
                stableID: "global-adapter:\(bundleId):\(action.id)")
        }
    }

    func isBrowserMenuSource(_ bundleID: String) -> Bool {
        let normalized = bundleID.lowercased()
        return normalized == "com.apple.safari"
            || normalized == "com.google.chrome"
            || normalized == "com.google.chrome.canary"
            || normalized == "com.microsoft.edgemac"
            || normalized == "com.brave.browser"
            || normalized == "company.thebrowser.browser"
            || normalized == "com.vivaldi.vivaldi"
            || normalized == "org.mozilla.firefox"
            || normalized == "app.zen-browser.zen"
            || normalized.contains("browser")
            || normalized.contains("tutor")
            || normalized.contains("distill")
    }

    func openLinkInSafari(_ url: URL) {
        hideLauncherAfterResultExecution()
        if let safariURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari")
        {
            NSWorkspace.shared.open(
                [url], withApplicationAt: safariURL,
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func makeCrossAppMenuDockPill(from descriptor: GlobalMenuDescriptor) -> DockPill {
        let bundleID = descriptor.bundleID
        let path = descriptor.path
        let shortcutChar = descriptor.shortcutChar
        let shortcutModifiers = descriptor.shortcutModifiers
        let linkURL = browserLinkURL(for: descriptor)
        let documentURL = resolvedRecentDocumentURL(for: descriptor)
        let symbol =
            bundleID == "com.apple.systempreferences"
            ? SFSymbolResolver.systemSettingsPaneSymbol(title: descriptor.name)
            : SFSymbolResolver.menuSymbol(
                title: descriptor.name,
                path: descriptor.path,
                isAppleMenu: descriptor.path.first.map(normalizedDockPillText) == "apple"
            )
        var pill = DockPill(
            id: descriptor.id,
            name: descriptor.name,
            icon: linkURL != nil ? "link" : (documentURL != nil ? "doc.text" : symbol),
            accentColorName: nil,
            badge: documentURL != nil ? "Preview" : descriptor.badge,
            execute: { [self] in
                if let linkURL {
                    openLinkInSafari(linkURL)
                } else if let documentURL {
                    NSWorkspace.shared.open(documentURL)
                } else if let windowCommand = windowCommand(forMenuPath: path) {
                    launchAndApplyWindowCommand(
                        bundleId: bundleID,
                        appName: descriptor.appName,
                        command: windowCommand
                    )
                } else if isBrowserURLMenuRow(descriptor) {
                    // Dynamic Safari history/bookmark URL row whose URL couldn't be
                    // resolved — never AX-click the scrollable submenu.
                    DockActionFeedback.showResult(
                        "Couldn't open — no URL for this history item",
                        icon: "safari", success: false)
                } else {
                    executeLearnedGhostAction(
                        bundleID: bundleID,
                        path: path,
                        shortcutChar: shortcutChar,
                        shortcutModifiers: shortcutModifiers
                    )
                }
            }
        )
        pill.sourceBundleId = bundleID
        pill.sourceAppName = descriptor.appName
        pill.menuContext = menuContextLabel(from: descriptor.path)
        pill.rankingKind = "menu"
        pill.rankingScore = descriptor.rankingScore
        pill.trackingIdentifier =
            "dock-menu:\(bundleID):\(descriptor.path.map(normalizedDockPillText).joined(separator: ">"))"
        pill.menuStatusBadge = descriptor.statusBadge
        pill.keyboardShortcutLabel = descriptor.badge
        if let linkURL {
            pill.resolvedURL = linkURL
            pill.menuStatusBadge = linkURL.host
            if let favicon = FaviconStore.shared.icon(for: linkURL) {
                pill.menuItemImage = favicon
            }
            FaviconStore.shared.fetchIfNeeded(for: linkURL)
        }
        if let documentURL {
            pill.resolvedURL = documentURL
            pill.quickLookURL = documentURL
            pill.menuItemImage =
                ThumbnailGenerator.shared.getThumbnailSync(for: documentURL.path)
                ?? NSWorkspace.shared.icon(forFile: documentURL.path)
            pill.menuStatusBadge = documentURL.deletingLastPathComponent().lastPathComponent
            pill.searchTerms.append(documentURL.path)
        }
        return pill
    }

    func windowCommand(forMenuPath path: [String]) -> WindowManagementService.Command? {
        let normalized = path.map(normalizedDockPillText)
        guard normalized.contains("window"), let title = normalized.last else { return nil }
        if title == "minimize" || title == "minimise" { return .minimize }
        if title == "zoom" { return .zoom }
        if title == "fill" || title.contains("fill") { return .fill }
        if title == "centre" || title == "center" { return .center }
        if title == "left" { return .left }
        if title == "right" { return .right }
        if title == "top" { return .top }
        if title == "bottom" { return .bottom }
        if title == "top left" { return .topLeft }
        if title == "top right" { return .topRight }
        if title == "bottom left" { return .bottomLeft }
        if title == "bottom right" { return .bottomRight }
        if title == "left right" { return .leftAndRight }
        if title == "right left" { return .rightAndLeft }
        if title == "top bottom" { return .topAndBottom }
        if title == "bottom top" { return .bottomAndTop }
        if title == "quarters" { return .quarters }
        if title.contains("previous size") { return .restorePreviousSize }
        if title.contains("full screen") || title.contains("fullscreen") { return .fullScreen }
        if title == "bring all to front" { return .bringAllToFront }
        if title.hasPrefix("switch window") { return .switchWindow }
        return nil
    }

    func resolvedRecentDocumentURL(for descriptor: GlobalMenuDescriptor) -> URL? {
        let normalizedPath = descriptor.path.map(normalizedDockPillText)
        let looksRecent =
            normalizedPath.contains("recent items")
            || normalizedPath.contains("open recent")
            || normalizedPath.contains("recent documents")
            || normalizedPath.contains("recent files")
        guard looksRecent else { return nil }

        let title = normalizedDockPillText(descriptor.name)
        guard !title.isEmpty else { return nil }
        return RecentItemsService.shared.recentDocuments().first { doc in
            let names = [
                doc.url.lastPathComponent,
                doc.url.deletingPathExtension().lastPathComponent,
                doc.name,
            ].map(normalizedDockPillText)
            return names.contains(title)
        }?.url
    }

    func cachedGlobalAppScopeDockPills(
        query: String,
        scope: DockScopeResolution,
        appPath: String? = nil
    ) -> [DockPill] {
        guard scope.isExplicitAppScope else {
            return []
        }
        let actionQuery = scope.scopedSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPseudoExtensionScope =
            scope.scopedBundleId.hasPrefix("cli://") || scope.scopedBundleId.hasPrefix("syscmd://")
        let isSystemCommandScope = scope.scopedBundleId.hasPrefix("syscmd://")
        var pills =
            cachedGlobalCLIScopeDockPills(
                scopedBundleId: scope.scopedBundleId,
                scopedAppName: scope.scopedAppName,
                actionQuery: actionQuery
            )
            + scopedSystemCommandPills(
                scopedBundleId: scope.scopedBundleId,
                scopedSearchQuery: actionQuery
            )

        if !isPseudoExtensionScope {
            pills += makeNativeWindowManagementPills(
                rawScopedQuery: actionQuery,
                scopedBundleId: scope.scopedBundleId,
                scopedAppName: scope.scopedAppName,
                isGlobalScope: false
            )
            let frontmostBundleId =
                AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier ?? ""
            let hasAuthoritativeLiveMenus =
                !liveMenuItems.isEmpty
                && !scope.scopedBundleId.isEmpty
                && scope.scopedBundleId == frontmostBundleId
            if !hasAuthoritativeLiveMenus {
                let scopedMenuFetchLimit =
                    actionQuery.isEmpty
                    ? max(maxListViewDockPills * 10, 96)
                    : maxListViewDockPills
                let indexedPills = indexedScopedAppMenuPills(
                    bundleIdentifier: scope.scopedBundleId,
                    appName: scope.scopedAppName,
                    query: actionQuery,
                    maxResults: scopedMenuFetchLimit
                )
                pills += indexedPills
            }
            pills += scopedSpecialAppPills(
                bundleIdentifier: scope.scopedBundleId,
                appName: scope.scopedAppName,
                query: actionQuery
            )
        }
        let visible =
            pills
            .filter { pill in
                guard !pill.isSeparator else { return false }
                guard pill.rankingKind != "appLaunch" else { return false }
                // The live control is the fixed first row of a System Command
                // scope. Device filtering must never remove or reorder it.
                if isSystemCommandScope,
                    pill.trackingIdentifier.hasSuffix(":interactive")
                {
                    return true
                }
                if !isGlobalContextActive,
                    (pill.menuContext ?? "").caseInsensitiveCompare("Apple Menu") == .orderedSame
                {
                    return false
                }
                guard !actionQuery.isEmpty else { return true }
                // Match name OR menu context path so e.g. "recent" surfaces "Recently Closed" tabs
                // whose pill name is the tab title, not the submenu label.
                let nameLower = pill.name.lowercased()
                let contextLower = (pill.menuContext ?? "").lowercased()
                let termsLower = pill.searchTerms.joined(separator: " ").lowercased()
                if nameLower.contains(actionQuery) || contextLower.contains(actionQuery)
                    || termsLower.contains(actionQuery)
                {
                    return true
                }
                let actionTokens = Set(dockPillTokens(actionQuery))
                let pillTokens = Set(
                    dockPillTokens(nameLower + " " + contextLower + " " + termsLower))
                return !actionTokens.intersection(pillTokens).isEmpty
            }
        // System Command providers already return semantic UI order:
        // interactive control, summary, then provider rows. Usage ranking is
        // appropriate for app menus, but moving a power switch among devices
        // makes the scoped surface unstable and unpredictable.
        var sorted = isSystemCommandScope
            ? visible
            : sortScopedGlobalAppPills(visible, query: actionQuery)
        guard actionQuery.isEmpty else {
            // Content search is a fallback action, not the primary command. Keep real
            // app menus first so "safari new private window" executes Safari's menu,
            // while still offering an in-app search when no command matches.
            if !isPseudoExtensionScope {
                let contentSearch = makeScopedAppContentSearchPill(
                    actionQuery: actionQuery,
                    bundleId: scope.scopedBundleId,
                    appName: scope.scopedAppName,
                    appPath: appPath
                )
                if sorted.isEmpty {
                    sorted = [contentSearch]
                } else if sorted.count < maxListViewDockPills {
                    sorted.append(contentSearch)
                }
            }
            return Array(sorted.prefix(maxListViewDockPills))
        }

        if isSystemCommandScope {
            // Provider scopes already emit their intended semantic order:
            // interactive control first, then the summary and device rows. The
            // low-value partition below is tuned for app menus and would demote
            // the control here — its pill name ("Bluetooth") equals the scope's
            // app name, so it reads as a self/"about" row and sinks beneath the
            // device list. Preserve insertion order instead.
            return Array(sorted.prefix(maxListViewDockPills))
        }
        let useful = sorted.filter {
            !isLowValueScopedGlobalMenuPill($0, appName: scope.scopedAppName)
        }
        let lowValue = sorted.filter {
            isLowValueScopedGlobalMenuPill($0, appName: scope.scopedAppName)
        }
        return Array((useful + lowValue).prefix(maxListViewDockPills))
    }

    func sortScopedGlobalAppPills(_ pills: [DockPill], query: String) -> [DockPill] {
        let q = normalizedDockPillText(query)
        return
            pills
            .enumerated()
            .map { index, pill -> (DockPill, Double, Int) in
                (pill, scopedGlobalAppMenuScore(pill, query: q), index)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.2 < $1.2
            }
            .map(\.0)
    }

    func scopedGlobalAppMenuScore(_ pill: DockPill, query: String) -> Double {
        let title = normalizedDockPillText(pill.name)
        let context = normalizedDockPillText(pill.menuContext ?? "")
        let terms = normalizedDockPillText(pill.searchTerms.joined(separator: " "))
        let id = defaultDockPillTrackingIdentifier(pill)
        let menuName = normalizedDockPillText(
            pill.menuItemName.isEmpty ? pill.name : pill.menuItemName
        )
        let source = pill.sourceBundleId.isEmpty ? "global" : pill.sourceBundleId
        let menuNameId = "dock-menu:\(source):\(menuName)"
        var score = min(
            max(
                UsageTracker.shared.getScore(for: id),
                UsageTracker.shared.getScore(for: menuNameId)
            ),
            240
        )
        score += min(
            AppUsageLearner.shared.blendedActionScore(
                trackingKey: id,
                visibleAction: menuName,
                inBundleID: pill.sourceBundleId.isEmpty ? nil : pill.sourceBundleId
            ) * 85,
            720
        )

        if !query.isEmpty {
            if title == query { score += 900 }
            if title.hasPrefix(query) { score += 620 }
            if title.contains(query) { score += 420 }
            if title != query, title.contains(query), pill.rankingKind != "contentSearch" {
                score += 380
            }
            if context.contains(query) || terms.contains(query) { score += 220 }
            let queryTokens = Set(dockPillTokens(query))
            let titleTokens = Set(dockPillTokens(title))
            if !queryTokens.isEmpty, queryTokens.isSubset(of: titleTokens),
                pill.rankingKind != "contentSearch"
            {
                score += 260
            }
            if title.contains("@"), !title.contains(query), pill.rankingKind != "contentSearch" {
                score -= 140
            }
        } else {
            if pill.keyboardShortcutLabel?.isEmpty == false || pill.badge?.contains("⌘") == true {
                score += 42
            }
            if context == "file" || context == "edit" || context == "view" { score += 30 }
            if title.contains("new") || title.contains("open") || title.contains("save")
                || title.contains("search") || title.contains("find")
                || title.contains("copy") || title.contains("paste")
                || title.contains("accessibility") || title.contains("appearance")
                || title.contains("battery") || title.contains("bluetooth")
                || title.contains("desktop") || title.contains("display")
                || title.contains("keyboard") || title.contains("network")
                || title.contains("privacy") || title.contains("security")
                || title.contains("sound") || title.contains("wi fi") || title.contains("wifi")
            {
                score += 68
            }
            if context == "help" || title.contains("help") || title.contains("feedback") {
                score -= 260
            }
            if title.contains("about ") || title.hasPrefix("about ") {
                score -= 180
            }
            if title.contains("hide ") || title == "hide" || title.contains("quit") {
                score -= 150
            }
            if title.contains("settings") && !title.contains("system settings") {
                score -= 80
            }
        }

        if pill.rankingKind == "contentSearch" { score += query.isEmpty ? -80 : -180 }
        if pill.rankingKind == "browserCommand" { score += query.isEmpty ? 120 : 820 }
        if pill.rankingKind == "nativeWindow" { score += query.isEmpty ? 12 : 80 }
        if query.isEmpty {
            score += scopedGlobalAppMenuUtilityScore(pill, appName: pill.sourceAppName)
        }
        return score
    }

    func scopedGlobalAppMenuUtilityScore(_ pill: DockPill, appName: String) -> Double {
        let title = normalizedDockPillText(pill.name)
        let context = normalizedDockPillText(pill.menuContext ?? "")
        guard !title.isEmpty else { return 0 }

        if isLowValueScopedGlobalMenuPill(pill, appName: appName) {
            return -1_200
        }

        var score: Double = 0
        switch context {
        case "file", "edit", "view", "go", "history", "bookmarks", "store", "account",
            "window", "tools", "developer", "debug", "run":
            score += 220
        case "help":
            score -= 400
        default:
            score += context.isEmpty ? 0 : 80
        }

        let highIntentTokens = [
            "new", "open", "save", "export", "import", "search", "find", "update",
            "download", "install", "play", "pause", "back", "forward", "reload",
            "account", "purchases", "categories", "create", "library", "history",
            "bookmarks", "tabs", "window", "debug", "run", "build", "format",
        ]
        if highIntentTokens.contains(where: { title.contains($0) }) {
            score += 260
        }
        if pill.keyboardShortcutLabel?.isEmpty == false || pill.badge?.contains("⌘") == true {
            score += 90
        }
        return score
    }

    func isLowValueScopedGlobalMenuPill(_ pill: DockPill, appName: String) -> Bool {
        let title = normalizedDockPillText(pill.name)
        let context = normalizedDockPillText(pill.menuContext ?? "")
        let app = normalizedDockPillText(appName)
        guard !title.isEmpty else { return true }

        if context == "help" { return true }
        if title == "help" || title.hasSuffix(" help") || title.contains("feedback") {
            return true
        }
        if title.hasPrefix("about ") || title == "about" || title.contains("privacy") {
            return true
        }
        if title == "hide" || title.hasPrefix("hide ") || title == "hide others" {
            return true
        }
        if title == "quit" || title.hasPrefix("quit ") {
            return true
        }
        if !app.isEmpty {
            if title == app || title == "about \(app)" || title == "\(app) help" {
                return true
            }
            if context == app,
                title.hasPrefix("about ") || title.hasPrefix("hide ") || title.hasPrefix("quit ")
            {
                return true
            }
        }
        return false
    }

    func makeScopedAppContentSearchPill(
        actionQuery: String,
        bundleId: String,
        appName: String,
        appPath: String?
    ) -> DockPill {
        let queryKey =
            actionQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var pill = DockPill(
            id: "scoped-content-search:\(bundleId):\(queryKey)",
            name: "Search \"\(actionQuery)\" in \(appName)",
            icon: "magnifyingglass",
            accentColorName: nil,
            badge: nil,
            execute: { [self] in
                let liveQuery = effectiveGlobalInlineActionQuery(searchState.query)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                executeScopedAppContentSearch(
                    query: liveQuery.isEmpty ? actionQuery : liveQuery,
                    bundleId: bundleId,
                    appName: appName,
                    appPath: appPath
                )
            }
        )
        pill.sourceBundleId = bundleId
        pill.sourceAppName = appName
        pill.rankingKind = "contentSearch"
        pill.trackingIdentifier = "scoped-content-search:\(bundleId):\(queryKey)"
        pill.searchTerms = [actionQuery, "search", appName]
        return pill
    }

    func executeScopedAppContentSearch(
        query: String,
        bundleId: String,
        appName: String,
        appPath: String?
    ) {
        Task.detached(priority: .userInitiated) {
            var app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first(where: { !$0.isTerminated })
            if app == nil {
                let appURL: URL? =
                    appPath.flatMap {
                        FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
                    }
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                if let appURL {
                    _ = try? await NSWorkspace.shared.openApplication(
                        at: appURL, configuration: NSWorkspace.OpenConfiguration())
                }
                for _ in 0..<20 where app == nil {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                        .first(where: { !$0.isTerminated })
                }
            }
            guard let app else {
                await MainActor.run {
                    AppToast.show(
                        "Couldn't launch \(appName)",
                        icon: "exclamationmark.triangle",
                        tint: .orange.opacity(0.9)
                    )
                }
                return
            }
            let message = await AXSearchFieldInjector.shared.inject(query: query, into: app)
            if !message.hasPrefix("✅") {
                await MainActor.run {
                    AppToast.show(
                        "No search field found in \(appName)",
                        icon: "magnifyingglass",
                        tint: .orange.opacity(0.9)
                    )
                }
            }
        }
    }

    func cachedGlobalCLIScopeDockPills(
        scopedBundleId: String,
        scopedAppName: String,
        actionQuery: String
    ) -> [DockPill] {
        guard scopedBundleId.hasPrefix("cli://") else { return [] }
        let command = String(scopedBundleId.dropFirst("cli://".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let package = terminalPackageManager.packages.first(where: {
                $0.isEnabled && $0.command.caseInsensitiveCompare(command) == .orderedSame
            })
        else { return [] }

        let displayName = package.name.isEmpty ? package.command : package.name
        let isTUI = TerminalAIBridge.shared.isTUICommand(package.command)
        let icon = isTUI ? "terminal.fill" : "chevron.left.forwardslash.chevron.right"
        var pills: [DockPill] = []

        var main = DockPill(
            id: "global-cli-\(package.command)",
            name: displayName,
            icon: icon,
            accentColorName: "green",
            badge: "CLI",
            execute: {
                if actionQuery.isEmpty {
                    attachCLIToolToCurrentDock(command: package.command, package: package)
                } else {
                    searchState.query = actionQuery
                    handleRemPanelQuery()
                }
            }
        )
        main.rankingKind = "cliTool"
        main.sourceBundleId = scopedBundleId
        main.sourceAppName = scopedAppName
        main.trackingIdentifier = "global-cli:\(package.command)"
        main.searchTerms =
            [displayName, package.command, package.description] + package.keywords
            + package.subcommands + package.taskCategories
        pills.append(main)

        return pills
    }

    func cachedGlobalInlineAppScopeGroups(query: String) -> [AppMenuGroup] {
        let actionQuery = effectiveGlobalInlineActionQuery(query)
        return allGlobalInlineAppScopes.compactMap { inlineScope in
            let scope = DockScopeResolution(
                scopedBundleId: inlineScope.bundleId,
                scopedAppName: inlineScope.appName,
                scopedSearchQuery: actionQuery,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
            let pills = cachedGlobalAppScopeDockPills(
                query: actionQuery, scope: scope, appPath: inlineScope.appPath)
            guard !pills.isEmpty else { return nil }
            let icon =
                FileManager.default.fileExists(atPath: inlineScope.appPath)
                ? NSWorkspace.shared.icon(forFile: inlineScope.appPath)
                : resolvedApplicationIcon(
                    bundleIdentifier: inlineScope.bundleId, appName: inlineScope.appName)
            return AppMenuGroup(
                id: inlineScope.bundleId,
                appName: inlineScope.appName,
                icon: icon,
                pills: pills
            )
        }
    }

    func indexedScopedAppMenuPills(
        bundleIdentifier: String,
        appName: String,
        query: String,
        maxResults: Int
    ) -> [DockPill] {
        guard maxResults > 0 else { return [] }
        var docs = GlobalSearchService.shared.query(
            query,
            bundleId: bundleIdentifier,
            limit: maxResults
        )
        if docs.isEmpty,
            GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bundleIdentifier)
        {
            let cachedItems = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                query: query,
                maxResults: maxResults
            )
            docs = cachedItems.compactMap {
                GlobalSearchService.SearchDocument(
                    menuItem: $0,
                    appName: appName,
                    bundleId: bundleIdentifier,
                    processIdentifier: 0,
                    icon: resolvedApplicationIcon(
                        bundleIdentifier: bundleIdentifier,
                        appName: appName
                    )
                )
            }
        }
        var seen = Set<String>()
        return docs.compactMap { doc -> DockPill? in
            guard
                case .cachedMenu(
                    let bundleId,
                    let resolvedAppName,
                    let path,
                    let shortcutChar,
                    let shortcutModifiers
                ) = doc.action
            else { return nil }
            let normalizedPath = path.map(normalizedDockPillText)
            guard normalizedPath.first != "window",
                !WindowManagementService.shared.handlesMenuPath(path)
            else { return nil }
            let key = "\(bundleId):\(path.joined(separator: ">"))"
            guard seen.insert(key).inserted else { return nil }
            let descriptor = GlobalMenuDescriptor(
                id: "indexed-scope-\(bundleId)-\(path.joined(separator: ">"))",
                name: doc.title,
                badge: MenuShortcutFormatter.display(
                    char: shortcutChar,
                    modifiers: shortcutModifiers
                ),
                statusBadge: nil,
                bundleID: bundleId,
                appName: resolvedAppName.isEmpty ? appName : resolvedAppName,
                appIcon: doc.icon,
                path: path,
                shortcutChar: shortcutChar,
                shortcutModifiers: shortcutModifiers,
                rankingScore: doc.sourceKind.rawValue
            )
            return makeCrossAppMenuDockPill(from: descriptor)
        }
    }

    func cachedFrontmostGlobalMenuPills(query: String, maxResults: Int) -> [DockPill] {
        let bundleId = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty, !appName.isEmpty else {
            return []
        }
        // Global Context is a read-only fast path: persistent cache only, no live AX snapshot.
        // Context Dock/app-switch warmers are responsible for refreshing this cache.
        let cachedPills = cachedScopedAppMenuPills(
            bundleIdentifier: bundleId,
            appName: appName,
            appPath: nil,
            query: query,
            maxResults: maxResults,
            allowLiveRefresh: false
        ).filter { !isAppleRecentItemsPill($0) }
        return cachedPills.prefix(maxResults).map { $0 }
    }

    /// Apple Recent Items is intentionally excluded from Global Context. Its
    /// volatile contents make the cache-first path noisy and stale.
    func isAppleRecentItemsPill(_ pill: DockPill) -> Bool {
        let normalizedTerms = pill.searchTerms.map(normalizedDockPillText)
        let root = normalizedTerms.first ?? ""
        let belongsToAppleMenu =
            root.isEmpty
            || root == "apple"
            || normalizedDockPillText(pill.sourceAppName ?? "") == "apple menu"

        return belongsToAppleMenu && normalizedTerms.contains("recent items")
    }

    var currentListViewDockRowCount: Int {
        guard showContextInDock,
            !showMediaLayer,
            !aiMode.isActive,
            shouldShowL2UnifiedDockRow
        else { return 0 }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isActiveGlobalRunningAppMenuScope() {
            let resolvedCount = min(
                maxListViewDockPills,
                visibleGlobalScopedMenuNavigationState(for: q)?.totalCount ?? 0
            )
            let isExtensionScope =
                currentGlobalScopedBundleID?.hasPrefix("syscmd://") == true
                || currentGlobalScopedBundleID?.hasPrefix("cli://") == true
            // Reserve one row while a provider-backed extension scope resolves.
            // This keeps the shared result-sheet frame alive instead of snapping
            // back to the capsule between scope activation and row publication.
            return isExtensionScope ? max(1, resolvedCount) : resolvedCount
        }
        if shouldUsePureGlobalAppSearch {
            guard !q.isEmpty || globalInlineAppScope != nil || currentGlobalScopedBundleID != nil
            else { return 0 }
            guard globalContextViewModel.typingSnapshot.phase == .expanded else { return 0 }
            let transientMenuCount =
                currentGlobalScopedBundleID == nil
                ? transientGlobalScopedMenuRowCount(for: q)
                : 0
            if transientMenuCount > 0 {
                return min(maxListViewDockPills, transientMenuCount)
            }
            let state = visibleGlobalGroupedListNavigationState(for: q)
            if state.totalCount > 0 {
                return min(maxListViewDockPills, state.totalCount)
            }
            let immediateAppCount = currentOrImmediateGlobalAppMatches(for: q).count
            if immediateAppCount > 0 {
                return min(maxListViewDockPills, immediateAppCount)
            }
            let iconRowCount = matchDockIconRowsForExpandedSheet(query: q).count
            if iconRowCount > 0 {
                return min(maxListViewDockPills, iconRowCount)
            }
            return 0
        }

        let pillQuery = shouldUseFinderSearchPopover(for: q) ? "" : q
        let visibleDockPills =
            isGlobalContextActive
            ? (
                currentGlobalScopedBundleID != nil
                ? stableVisibleDockPills(for: pillQuery)
                : currentVisibleDockPills(for: pillQuery)
            )
            : contextDockViewModel.visiblePills
        let pillCount = (pillQuery.isEmpty ? [] : visibleDockPills)
            .filter { !$0.isSeparator }
            .count
        if pillCount > 0 { return min(maxListViewDockPills, pillCount) }
        if isGlobalContextActive,
            !pillQuery.isEmpty,
            pendingDockPillQuery == pillQuery || isResolvingDockPills(for: pillQuery)
        {
            return 1
        }
        if showContextInDock,
            !isGlobalContextActive,
            !q.isEmpty
        {
            return 1
        }
        return 0
    }

    var currentListViewDockContentHeight: CGFloat {
        let rowCount = currentListViewDockRowCount
        // `shouldShowSeparateActionList` can become true one render before async app/menu
        // rows publish. Returning zero in that frame keeps the NSPanel capsule-height while
        // the shared list already draws its section header, producing a clipped half-sheet.
        // Once list mode owns the shell, reserve its stable viewport immediately in both
        // Global Context and Context Dock; rows can then populate inside without resizing.
        guard rowCount > 0 else {
            // Custom-list / CLI scopes (syscmd:// · cli://) draw their rows from a
            // background script. With no rows yet — no match, or still loading — collapse
            // to the input bar instead of reserving a tall empty sheet that just looks
            // broken. The Quick Note scope renders its own editor surface (no rows), so
            // it keeps the reserved viewport.
            let bundle = currentGlobalScopedBundleID
            let isExtensionListScope =
                (bundle?.hasPrefix("syscmd://") == true || bundle?.hasPrefix("cli://") == true)
                && activeNotepadScopeCommand == nil
            if isExtensionListScope { return 0 }
            return usesVerticalListDockLayout ? listViewVisibleHeight : 0
        }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A running-app capsule is an isolated menu sheet, not the fixed-height Global
        // Context results surface. Hug its actual rows so the NSPanel ends at the same
        // place as the visible glass; otherwise the old 372pt reservation leaves a clear
        // window tail that intercepts clicks below a short scoped result list.
        if isActiveGlobalRunningAppMenuScope() {
            let isExtensionScope =
                currentGlobalScopedBundleID?.hasPrefix("syscmd://") == true
                || currentGlobalScopedBundleID?.hasPrefix("cli://") == true
            // An extension scope is a stable filtering workspace. Keep its
            // viewport fixed while rows are replaced inline so the panel and
            // input never jump as the match count changes.
            if isExtensionScope { return listViewVisibleHeight }
            let measured = measuredGlobalListContentHeight
            if measured > 1 {
                return min(max(measured, 86), listViewVisibleHeight)
            }
            let rowHeight: CGFloat = 52
            let headerReserve: CGFloat = 24
            let contentPadding: CGFloat = 12
            return min(
                max(CGFloat(rowCount) * rowHeight + headerReserve + contentPadding, 86),
                listViewVisibleHeight
            )
        }
        if shouldUsePureGlobalAppSearch,
            !q.isEmpty || globalInlineAppScope != nil || currentGlobalScopedBundleID != nil
        {
            let groupedKey = globalGroupedStateCacheKey(for: q)
            let state = visibleGlobalGroupedListNavigationState(for: q)
            let hasTransientMenus =
                currentGlobalScopedBundleID == nil && transientGlobalScopedMenuRowCount(for: q) > 0
            let hasImmediateApps = !currentOrImmediateGlobalAppMatches(for: q).isEmpty
            let hasIconRows = !matchDockIconRowsForExpandedSheet(query: q).isEmpty
            let isPending = pendingGlobalGroupedQuery == groupedKey || pendingGlobalAppQuery == q
            if state.totalCount == 0, !hasTransientMenus, !hasImmediateApps, !hasIconRows,
                !isPending
            {
                return 0
            }
            return listViewVisibleHeight
        }
        // Context Dock must stay physically locked while typing. Measuring the rendered
        // rows makes the window chase section/header changes one frame late, which looks
        // like the sheet jumps up/down. Once the list opens, reserve the same fixed list
        // height as Global Context; only row content changes inside the scroll area.
        if showContextInDock, !isGlobalContextActive {
            return listViewVisibleHeight
        }

        // Non-Context scopes can still hug measured content.
        let measured = measuredGlobalListContentHeight
        if measured > 1 {
            return min(max(measured, 86), listViewVisibleHeight)
        }
        // Finder desktop clusters into several type groups (Folders / Documents /
        // Images…), each adding a header the row-count estimate below can't see — so the
        // estimate undercut the height and the sheet rendered as a clipped half. Until
        // the measured height lands, reserve the full viewport (it scrolls internally).
        if isFinderDesktopOnlyMode {
            return listViewVisibleHeight
        }
        let rowHeight: CGFloat = 52
        let headerReserve: CGFloat = rowCount > 0 ? 24 : 0
        let contentPadding: CGFloat = 12
        let dynamicHeight = CGFloat(rowCount) * rowHeight + headerReserve + contentPadding
        return min(max(dynamicHeight, 86), listViewVisibleHeight)
    }

    var isExplicitAppScopeLocked: Bool {
        guard let target = l2.targetApp else { return false }
        guard !isGlobalContextActive else { return false }
        return target.bundleId != "scope://clipboard"
    }

    func runningBundleIdsForContextDock() -> Set<String> {
        Set(
            (runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps)
                .compactMap { $0.bundleIdentifier })
    }

    var implicitContextDockAppScopeBlockedBundleIds: Set<String> {
        [
            "com.apple.news"
        ]
    }

    nonisolated func shouldIgnoreApplicationFromAppSearch(
        appName: String,
        bundleIdentifier: String?,
        path: String?
    ) -> Bool {
        let normalizedName = normalizedDockPillText(appName)
        if normalizedName == "news" { return true }
        if bundleIdentifier == "com.apple.news" { return true }
        if let path {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.bundleIdentifier == "com.apple.news" { return true }
            if normalizedDockPillText(url.deletingPathExtension().lastPathComponent) == "news" {
                return true
            }
        }
        return false
    }

    var resultsPanelLeadingInset: CGFloat {
        floatingClipboardOccupiedWidth + 12
    }

    var resultsPanelWidth: CGFloat {
        max(visibleDockWidth - 24, 280)
    }

    var calculatedDockHeight: CGFloat {
        // Fixed height anchors the NSVisualEffectView sampling surface vertically.
        // Computed from max dockIconSize (72): input row (92) + pill row (88) + gap (20) = 200.
        // The actual content is clipped by the mask — glass stays constant.
        let maxSz: CGFloat = 72
        let inputRow = maxSz + 8 + 12  // inputPillHeight + 2×inputVerticalPadding
        let pillRow = maxSz + 4 + 12  // pinnedRowHeight  + 2×outerVerticalPadding
        return inputRow + pillRow + 20  // 200
    }

    var listViewDockHeight: CGFloat {
        guard showContextInDock,
            !showMediaLayer,
            !aiMode.isActive,
            shouldShowL2UnifiedDockRow
        else { return 0 }

        let contentHeight = currentListViewDockContentHeight
        guard contentHeight > 0 else { return 0 }
        let dockChromeHeight: CGFloat = 68
        return dockChromeHeight + contentHeight + 14
    }

    var listViewResizeToken: String {
        guard usesVerticalListDockLayout else { return "off" }
        if isActiveGlobalRunningAppMenuScope() {
            return "app-scope:\(currentGlobalScopedBundleID ?? ""):\(currentListViewDockRowCount):\(Int(measuredGlobalListContentHeight / 8))"
        }
        // Pure Global Context must feel like Spotlight/Raycast: once results are visible,
        // the window frame stays fixed and only row content changes inside the scroll area.
        // Encoding row/measured height here caused visible jumps while typing.
        if isGlobalContextActive {
            return "global:\(currentListViewDockRowCount > 0 ? "open" : "closed")"
        }
        if showContextInDock {
            return "scoped:\(currentListViewDockRowCount > 0 ? "open" : "closed")"
        }
        // Frontmost Context Dock now also hugs the MEASURED content (section headers vary
        // per app, so row count alone undercounts) — react to the measured height in 8px
        // buckets so the sheet settles to fit the real rows, no clipped last row.
        return "scoped:\(currentListViewDockRowCount):\(Int(measuredGlobalListContentHeight / 8))"
    }

    /// Records the measured intrinsic height of the global/scoped result list. The
    /// sheet sizes to this (via currentListViewDockContentHeight) and the resize token
    /// reacts to it, so the window settles to fit the actual rendered rows.
    func updateMeasuredGlobalListHeight(_ height: CGFloat) {
        let clamped = max(0, height)
        guard abs(measuredGlobalListContentHeight - clamped) > 2 else { return }
        measuredGlobalListContentHeight = clamped
        guard !isGlobalContextActive else { return }
    }

}
