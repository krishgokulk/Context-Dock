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

extension DockCore {

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
        let isSystemCommandScope = scope.scopedBundleId.hasPrefix("syscmd://")
        let isCLIScope = scope.scopedBundleId.hasPrefix("cli://")
        // A cli:// scope is a command workspace: the typed text is the tool's prompt, not
        // a filter over rows. Its only row was the tool's own pill, so the sheet appeared
        // on an empty query, vanished the moment a typed letter missed the pill's search
        // terms, and flickered back when a later letter hit them — the dock grew and
        // shrank while typing, and again on entering and leaving the scope. A System
        // Command scope keeps its rows because those are real, selectable device/control
        // rows; a CLI tool has none.
        if isCLIScope {
            return emptyGlobalGroupedListNavigationState()
        }
        let pills = globalScopedResultPills(scope: scope)
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

    /// One scoped result pipeline for the dock and corner; order and actions stay intact.
    func globalScopedResultPills(scope: DockScopeResolution) -> [DockPill] {
        let query = scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var pills = cachedGlobalAppScopeDockPills(query: query, scope: scope)
        if isBrowserMenuSource(scope.scopedBundleId), !query.isEmpty {
            if LiveMenuHistoryCache.usesLiveMenuHistory(scope.scopedBundleId) {
                pills += buildLiveMenuHistoryPills(query: query, bundleId: scope.scopedBundleId)
            } else {
                pills += buildBrowserURLLibraryPills(
                    query: query, scopedBrowserBundleId: scope.scopedBundleId,
                    limit: maxListViewDockPills)
            }
        }
        return pills.filter { pill in
            guard !pill.isSeparator else { return false }
            if scope.scopedBundleId.hasPrefix("syscmd://") { return pill.rankingKind == "systemCommand" }
            if scope.scopedBundleId.hasPrefix("cli://") { return pill.rankingKind == "cliTool" }
            return ["menu", "submenuChild", "finderMenu", "adapter", "recentURL", "browserCommand"]
                .contains(pill.rankingKind)
        }
    }

    func connectGlobalResults() {
        GlobalContextResultSource.shared.windowLayoutResults = { query, bundleID, appName in
            makeNativeWindowManagementPills(
                rawScopedQuery: query, scopedBundleId: bundleID, scopedAppName: appName,
                isGlobalScope: false)
        }
        GlobalContextResultSource.shared.pureGlobalResults = { query in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return [] }
            let state = instantGlobalGroupedListNavigationState(for: q)
            let appRows = state.appResults.map { result in
                globalAppResultDockPill(result)
            }
            return state.menuFirst ? state.menuPills + appRows : appRows + state.menuPills
        }
        GlobalContextResultSource.shared.scopedResults = { query, bundleID, appName in
            let scope: DockScopeResolution
            if let bundleID, !bundleID.isEmpty {
                scope = DockScopeResolution(
                    scopedBundleId: bundleID, scopedAppName: appName ?? "",
                    scopedSearchQuery: query, isExplicitAppScope: true, isGlobalScope: false)
            } else {
                guard let target = indexedGlobalAppMenuTarget(
                    for: query, allowPrefixAlias: false, preserveRemainingQueryTokens: true)
                    ?? installedAppMenuTarget(
                        for: query, runningOnly: false, includeAppsWithoutMenuSnapshot: true,
                        allowPrefixAlias: false, preserveRemainingQueryTokens: true),
                    !target.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !target.bundleId.contains("://")
                else { return nil }
                scope = DockScopeResolution(
                    scopedBundleId: target.bundleId, scopedAppName: target.appName,
                    scopedSearchQuery: target.actionQuery, isExplicitAppScope: true, isGlobalScope: false)
            }
            return globalScopedResultPills(scope: scope)
        }
    }

    func globalAppResultDockPill(_ result: SearchResult) -> DockPill {
        var pill = DockPill(
            id: "global-result-\(result.trackingIdentifier)",
            name: result.title,
            icon: "app",
            badge: result.subtitle,
            execute: { executeGlobalAppSearchResult(result) }
        )
        pill.menuItemImage = result.icon
        pill.menuContext = result.subtitle
        pill.sourceAppName = result.subtitle
        pill.sourceBundleId = bundleIdentifier(forApplicationResult: result) ?? ""
        pill.rankingKind = result.type == .extensionCommand ? "globalCommand" : "application"
        pill.resultSection = GlobalResultSection.title(for: result.type)
        pill.trackingIdentifier = result.trackingIdentifier
        // A Global result's id is its search document's (`stableID: doc.id`).
        pill.searchDocumentID = result.id
        pill.searchTerms = [result.title, result.subtitle]
        pill.rankingScore = result.score
        pill.keyboardShortcutLabel = result.displayBadges.first
        pill.previewPath = result.filePath
        pill.dragProvider = result.dragProvider
        return pill
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

    /// Delegates to the one shared definition. Copies of this predicate drifted apart:
    /// some CLI-suggestion paths filtered on it while others took every enabled package,
    /// so PATH binaries the user never added ("tac", "pdf2ps") ghost-completed as scopes.
    func isUserAddedGlobalCLITool(_ package: TerminalPackage) -> Bool {
        terminalPackageManager.isUserAddedGlobalScope(package)
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
        DockTextMatch.rankedScore(
            query: query, primary: primary, aliases: aliases, contexts: contexts)
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
    func activateGlobalInlineScope(result: SearchResult, bundleID: String) -> Bool {
        if bundleID.hasPrefix("cli://") {
            // Entering a CLI scope is the moment its documentation is about to be used, so
            // it is the right moment to notice the binary was upgraded since it was scanned.
            // Detached and pinned-only: this must never delay the scope opening.
            Task.detached(priority: .utility) {
                await TerminalPackageManager.shared.refreshStaleHelpForPinnedTools()
            }
        }
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
        }
        reclaimSearchInputFocus()
        return true
    }


    func reclaimSearchInputFocus() {
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        l2.pillNavViaKeyboard = false

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


    func moveSearchInsertionPointToEnd(in textView: NSTextView) {
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    func clearSearchFieldEditorText() {
        let keyResponder = NSApp.keyWindow?.firstResponder as? NSTextView
        let textViews = [keyResponder].compactMap { $0 }

        for textView in textViews {
            if !textView.string.isEmpty {
                textView.string = ""
                dockCoreModel.searchInputCaretTick &+= 1
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
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
            globalContextViewModel.stickyLeadingMatchIcon = nil
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
            globalContextViewModel.scopedSheetExpanded = false
            measuredGlobalListContentHeight = 0
            globalContextViewModel.stickyLeadingMatchIcon = nil
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
        // No auto-expansion. The dock's contract is one the user drives: typing shows the
        // ghost match in a compact capsule, ↓ opens the sheet. A timer that opened it 360ms
        // after a typing pause made the surface behave differently depending on how fast you
        // type — compact in a fast burst, expanded the moment you hesitated — and once open
        // the phase stays expanded while refining, so every later keystroke rendered the
        // full sheet.
        globalContextViewModel.autoExpandTask?.cancel()
        globalContextViewModel.autoExpandTask = nil
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
                // Top match owns the leading input icon (Spotlight behaviour). Written
                // on every resolve, so an empty result clears it instead of stranding
                // the previous query's icon.
                self.globalContextViewModel.stickyLeadingMatchIcon = matchDockIcons.first
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
        measuredGlobalListContentHeight = DockMetrics.globalListEstimatedHeight(
            rowCount: min(state.totalCount, 12), maximum: listViewVisibleHeight)

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
            case .userExtension, .plugin:
                icon = doc.icon
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

            case .adapterAction(let bundleId, let appName, let actionId):
                // Actions the user authored in App Adapters, runnable from anywhere rather
                // than only after scoping to the app. Executed through the same
                // AppAdapterManager.execute the dock and scope rows use.
                guard
                    let action = AppAdapterManager.shared
                        .actions(for: bundleId)
                        .first(where: { $0.id == actionId })
                else { continue }
                icon = doc.icon
                let capturedDoc = doc
                let capturedBundleId = bundleId
                let capturedAppName = appName
                var result = SearchResult(
                    title: action.name,
                    subtitle: "\(appName) · \(action.type.displayName)",
                    icon: icon,
                    action: {
                        recordGlobalSearchDocumentUse(capturedDoc, query: query)
                        let capturedContext = effectiveAXContextForConversation()
                        Task {
                            AppInteractionStore.shared.record(
                                bundleId: capturedBundleId,
                                appName: capturedAppName,
                                query: query,
                                kind: action.type == .pageJS ? .pageJS : .adapterAction,
                                actionId: action.id
                            )
                            let outcome = await AppAdapterManager.shared.execute(
                                action,
                                context: capturedContext,
                                targetBundleId: capturedBundleId,
                                query: query
                            )
                            guard !outcome.0 else { return }
                            let detail = outcome.1.trimmingCharacters(in: .whitespacesAndNewlines)
                            await MainActor.run {
                                AppToast.show(
                                    detail.isEmpty ? "Couldn't run \(action.name)" : detail,
                                    icon: "exclamationmark.triangle", tint: .orange, duration: 4)
                            }
                        }
                    },
                    type: .extensionCommand,
                    filePath: nil,
                    contactData: nil,
                    stableID: doc.id
                )
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
        case .userExtension:
            if !trimmedQuery.isEmpty {
                AppUsageLearner.shared.recordQueryIntent(query: trimmedQuery, wasMenu: false)
            }
        case .systemCommandScope, .cliScope, .adapterAction, .plugin:
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
    /// The index is `GlobalSearchIndexBuilder`'s now (#247 4b). The launcher still installs
    /// the Corner's result closures on the way.
    func rebuildGlobalSearchIndex() {
        connectGlobalResults()
        GlobalSearchIndexBuilder.shared.rebuild()
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
                if !trimmed.isEmpty {
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
        if BrowserStableMenuCommand.isStable(title: descriptor.name) { return false }
        return root == "history"
            || root == "bookmarks"
            || pathText.contains("recent")
            || pathText.contains("recently")
            || pathText.contains("tabs")
            || pathText.contains("visited")
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
        pill.menuPath = descriptor.path
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
            // Actions the user authored in App Adapters. They were built only for Context
            // Dock, so an app scope in Global Context showed cached menus and nothing the
            // user had added themselves. Menu-bar actions stay out: AXMenuReader owns menus
            // and would duplicate them. CLI-tool actions stay out too — they attach a
            // terminal to the dock, which is not what a Global Context row does.
            let scopedAdapterActions = adapterManager
                .actions(for: scope.scopedBundleId, query: actionQuery)
                .filter { $0.type != .menubar && $0.type != .cliTool }
            if !scopedAdapterActions.isEmpty {
                pills += adapterActionPills(
                    actions: scopedAdapterActions,
                    scopedBundleId: scope.scopedBundleId,
                    scopedAppName: scope.scopedAppName,
                    scopedSearchQuery: actionQuery)
            }
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
        appName: String, bundleIdentifier: String?, path: String?
    ) -> Bool {
        GlobalSearchIndexBuilder.shouldIgnoreApplicationFromAppSearch(
            appName: appName, bundleIdentifier: bundleIdentifier, path: path)
    }




}
