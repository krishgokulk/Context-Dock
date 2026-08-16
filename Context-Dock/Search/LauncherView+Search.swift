import AppKit
import Foundation
import SwiftUI

// MARK: - Search Engine (LauncherView extension)
// All search-related methods extracted from ContentView.swift for clarity.
// State variables (@State) remain on LauncherView in ContentView.swift.

extension LauncherView {

    // MARK: - Smart Query Types

    enum SmartQueryType {
        case contacts
        case photos
        case notes
        case reminders
        case calendarEvents
        case mail
        case messages
        case application(String)   // Specific app path — show app-related content
        case customApp(String)     // User-added app key — show generic AI panel
    }

    func searchableText(for result: SearchResult) -> String {
        var terms = [result.title, result.subtitle, result.filePath ?? ""]
        if result.subtitle.hasPrefix("cli://") {
            let command = String(result.subtitle.dropFirst("cli://".count))
            if let package = terminalPackageManager.packages.first(where: { $0.command == command }) {
                terms += [package.name, package.command, package.description, package.installedPath ?? ""]
                terms += package.keywords
                terms += package.subcommands
            }
        } else if result.subtitle.hasPrefix("syscmd://") {
            let id = String(result.subtitle.dropFirst("syscmd://".count))
            if let uuid = UUID(uuidString: id),
                let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == uuid })
            {
                terms += [command.name, command.description]
                terms += command.keywords
            }
        }
        return terms.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Public Entry Point

    func performSearch() {
        // NOTE: detectAndUpdateContext() deliberately NOT called here.
        // Synchronous AX calls block the main thread 100–500ms per call.
        // Context is captured once when the launcher shows (showLauncher / onAppear).

        let query = searchState.query.trimmingCharacters(in: .whitespaces)
        let signpostState = SearchPerformanceLog.shared.beginInterval("performSearch", query: query)
        defer { SearchPerformanceLog.shared.endInterval("performSearch", state: signpostState) }

        if isL2ContextActive {
            dismissMediaLayer()
        }

        // L3 media layer active — suppress search results entirely
        if showMediaLayer {
            searchState.results = []
            searchState.selectedIndex = nil
            return
        }

        // L2 frontmost context dock owns its own pill list. Never leave stale L1
        // file/search rows visible while the dock is scoped to the frontmost app.
        if showContextInDock && !showMediaLayer {
            if !isGlobalContextActive {
                debounceTask?.cancel()
                searchState.results = []
                searchState.selectedIndex = nil
                indexedFileResults = []
                return
            }

            // L1 Global Context with no selection is app-control mode; L2 renders
            // the app/app-menu rows, so L1 file search must stay out.
            if !hasSelectionScopeSurface {
                debounceTask?.cancel()
                searchState.results = []
                searchState.selectedIndex = nil
                indexedFileResults = []
                return
            }

            debounceTask?.cancel()
            debounceTask = Task(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: 120_000_000)  // 120 ms
                guard !Task.isCancelled else { return }
                await performSearchAsync()
            }
            return
        }

        // App panel active (calendar/notes/etc.) — panel handles its own display.
        if searchState.activeSmartQueryKey != nil {
            if query.isEmpty {
                searchState.results = []
                debounceTask?.cancel()
            } else {
                searchState.results = []
            }
            return
        }

        guard !query.isEmpty else {
            withAnimation(.easeInOut(duration: 0.2)) {
                searchState.results = []
                searchState.selectedIndex = nil
                indexedFileResults = []
                searchState.isInSmartMode = false
                searchState.lastSmartQuery = ""
                searchState.activeSmartQueryKey = nil
                searchState.contextApp = nil
                clearPinnedResults()
                systemDataResults = []
            }
            debounceTask?.cancel()
            return
        }

        // Exit smart mode if the user edited the query away from its trigger
        if searchState.isInSmartMode && query != searchState.lastSmartQuery {
            if detectSmartQuery(query: query) == nil {
                searchState.isInSmartMode = false
                searchState.lastSmartQuery = ""
            }
        }

        // Smart exact-match detection for folders, contacts, and photos
        if let smartResult = detectSmartQuery(query: query) {
            searchState.isInSmartMode = true
            searchState.lastSmartQuery = query
            let shouldReturn = handleSmartQueryResult(smartResult)
            if shouldReturn { return }
        } else {
            if searchState.isInSmartMode {
                searchState.isInSmartMode = false
                searchState.lastSmartQuery = ""
                clearPinnedResults()
            }
        }

        // L3 media dock: show web suggestions while media dock is active
        if showMediaLayer {
            var browserResults: [SearchResult] = []

            let matchingSearches = settings.recentWebSearches.filter {
                $0.lowercased().contains(query.lowercased())
            }
            let matchingBookmarks = settings.importedBookmarks.filter {
                $0.title.lowercased().contains(query.lowercased())
                    || $0.url.lowercased().contains(query.lowercased())
            }

            for search in matchingSearches.prefix(10) {
                browserResults.append(SearchResult(
                    title: search,
                    subtitle: "Recent Search",
                    icon: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil),
                    action: { searchState.query = search; openInDefaultBrowser() },
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
            }
            for bookmark in matchingBookmarks.prefix(10) {
                browserResults.append(SearchResult(
                    title: bookmark.title,
                    subtitle: bookmark.url,
                    icon: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil),
                    action: { searchState.query = bookmark.url; openInDefaultBrowser() },
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
            }

            withAnimation(.easeInOut(duration: 0.2)) {
                searchState.results = browserResults
                searchState.selectedIndex = browserResults.isEmpty ? nil : 0
                indexedFileResults = []
            }
            return
        }

        // In-memory file search — run immediately for instant results
        if settings.enableSpotlightSearch
            && (settings.enableL1DocumentSearch || settings.enableL1FileSearch)
        {
            searchIndexedFiles(for: query)
        } else {
            indexedFileResults = []
        }

        // Debounce then score on a background task — main thread stays free
        debounceTask?.cancel()
        debounceTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 60_000_000)  // 60 ms
            guard !Task.isCancelled else { return }
            await performSearchAsync()
        }
    }

    // MARK: - Core Scoring + Grouping

    // Thin sync wrapper — keeps existing callers (loadSystemData, etc.) unchanged.
    func performSearchWithoutSpotlight() {
        Task(priority: .userInitiated) { await performSearchAsync() }
    }

    // Async implementation: snapshots MainActor state, scores off-thread, applies on MainActor.
    func performSearchAsync() async {
        // ── 1. Snapshot all @State inputs on MainActor ────────────────────────
        enum SearchCandidateKind: Sendable {
            case application
            case shortcut
            case file
            case folder
            case document
            case contact
            case calendarEvent
            case reminder
            case note
            case mail
            case photo
            case message
            case extensionCommand
            case webSearch
            case cliTool

            init(_ resultType: SearchResult.ResultType) {
                switch resultType {
                case .application: self = .application
                case .shortcut: self = .shortcut
                case .file: self = .file
                case .folder: self = .folder
                case .document: self = .document
                case .contact: self = .contact
                case .calendarEvent: self = .calendarEvent
                case .reminder: self = .reminder
                case .note: self = .note
                case .mail: self = .mail
                case .photo: self = .photo
                case .message: self = .message
                case .extensionCommand: self = .extensionCommand
                case .webSearch: self = .webSearch
                case .cliTool: self = .cliTool
                }
            }

            var priority: Double {
                switch self {
                case .extensionCommand: return 20.0
                case .cliTool:          return 18.0
                case .application:      return 15.0
                case .folder:           return 14.0
                case .shortcut:         return 12.0
                case .calendarEvent, .reminder: return 10.0
                case .mail, .message:   return 9.0
                case .document:         return 7.0
                case .note:             return 6.0
                case .contact:          return 5.0
                case .file:             return 3.0
                case .photo:            return 2.0
                case .webSearch:        return 1.0
                }
            }
        }

        struct SearchCandidate: Sendable {
            let id: String
            let title: String
            let titleLower: String
            let haystackLower: String
            let trackingIdentifier: String
            let priority: Double
            let isSuggestedShortcut: Bool
        }

        struct Snap {
            let query: String
            let isNewQuery: Bool
            let hasItems: Bool
            let showContextInDock: Bool
            let showMediaLayer: Bool
            let l2ExtensionResults: [SearchResult]
            let candidates: [SearchCandidate]      // apps + CLI tools + pre-filtered indexed
            let usageScores: [String: Double]
            let pinnedResults: [SearchResult]
            let pinnedTitle: String?
            let dockAtBottom: Bool
            let oldSelectedID: String?
            let isKeyboardNav: Bool
        }

        let snap = await MainActor.run { () -> Snap in
            let q = searchState.query.trimmingCharacters(in: .whitespaces)
            let isNew = q != lastQuery
            if isNew {
                lastQuery = q
                isKeyboardNavigation = false
            }

            var candidates = allItems.filter { $0.type == .application || $0.type == .cliTool }
            if settings.enableSpotlightSearch {
                candidates += indexedFileResults.filter(includeIndexedSearchResult)
            }
            let scoringCandidates = candidates.map { item in
                SearchCandidate(
                    id: item.id,
                    title: item.title,
                    titleLower: item.titleLower,
                    haystackLower: searchableText(for: item).lowercased(),
                    trackingIdentifier: item.trackingIdentifier,
                    priority: SearchCandidateKind(item.type).priority,
                    isSuggestedShortcut: item.type == .shortcut
                        && shortcutMetadataCache[item.title]?.matches(context: currentContext) == true
                )
            }
            let usageScores = UsageTracker.shared.snapshotScores(
                for: scoringCandidates.map(\.trackingIdentifier))
            let oldSelectedID: String? = {
                guard let idx = searchState.selectedIndex,
                      idx >= 0,
                      idx < searchState.results.count
                else { return nil }
                return searchState.results[idx].id
            }()

            return Snap(
                query: q,
                isNewQuery: isNew,
                hasItems: !allApplications.isEmpty || !allShortcuts.isEmpty
                    || !indexedFileResults.isEmpty || !searchState.pinnedResults.isEmpty,
                showContextInDock: showContextInDock,
                showMediaLayer: showMediaLayer,
                l2ExtensionResults: l2.extensionResults,
                candidates: scoringCandidates,
                usageScores: usageScores,
                pinnedResults: searchState.pinnedResults,
                pinnedTitle: searchState.pinnedTitle,
                dockAtBottom: settings.effectiveDockAtBottom,
                oldSelectedID: oldSelectedID,
                isKeyboardNav: isKeyboardNavigation
            )
        }

        // ── Early exits (no actor needed) ─────────────────────────────────────
        guard snap.hasItems else {
            await MainActor.run { searchState.results = []; searchState.selectedIndex = nil }
            return
        }

        if snap.showContextInDock && !snap.showMediaLayer {
            await MainActor.run { updateL2Results(snap.l2ExtensionResults) }
            return
        }

        struct SearchOutput {
            let scores: [String: Double]
            let sortedIDs: [String]
            let oldSelectedID: String?
        }

        // ── 2. Pure scoring — detached so View/MainActor isolation cannot block typing ──
        let output = await Task.detached(priority: .userInitiated) { () -> SearchOutput in
            SearchPerformanceLog.shared.signpost("search.ranking", query: snap.query) {
            let strippedQuery: String = {
                let lower = snap.query.lowercased()
                return lower.hasSuffix(".app")
                    ? String(snap.query.dropLast(4)).trimmingCharacters(in: .whitespaces)
                    : snap.query
            }()
            let queryLower = strippedQuery.lowercased()
            let firstChar = queryLower.prefix(1)

            let preFiltered = snap.candidates.filter { $0.haystackLower.contains(firstChar) }

            var scoredItems: [(id: String, score: Double)] = []
            scoredItems.reserveCapacity(preFiltered.count)

            for item in preFiltered {
                guard !Task.isCancelled else { break }
                let titleScore = FuzzyMatcher.score(
                    queryLower, againstLower: item.titleLower, original: item.title
                )
                let aliasScore = FuzzyMatcher.score(
                    queryLower, againstLower: item.haystackLower, original: item.title
                )
                guard let score = [titleScore, aliasScore].compactMap({ $0 }).max() else { continue }

                let usageScore = snap.usageScores[item.trackingIdentifier] ?? 0.0
                var finalScore = score + item.priority + (usageScore * 8.0)
                if item.isSuggestedShortcut { finalScore += 500.0 }
                scoredItems.append((id: item.id, score: finalScore))
            }

            let sortedItems = scoredItems
                .sorted { $0.score > $1.score }
                .prefix(20)
            var scores: [String: Double] = [:]
            scores.reserveCapacity(sortedItems.count)
            for item in sortedItems { scores[item.id] = item.score }
            return SearchOutput(
                scores: scores,
                sortedIDs: sortedItems.map(\.id),
                oldSelectedID: snap.oldSelectedID
            )
            }
        }.value

        guard !Task.isCancelled else { return }

        // ── 3. Apply on MainActor ─────────────────────────────────────────────
        await MainActor.run {
            let commitSignpost = SearchPerformanceLog.shared.beginInterval(
                "search.stateCommit",
                query: snap.query
            )
            defer { SearchPerformanceLog.shared.endInterval("search.stateCommit", state: commitSignpost) }

            // Query freshness guard: if query changed while task ran, discard — a newer
            // task is already in flight. Prevents stale results overwriting fresh UI.
            guard searchState.query.trimmingCharacters(in: .whitespaces) == snap.query else { return }

            var resultByID: [String: SearchResult] = [:]
            resultByID.reserveCapacity(output.sortedIDs.count)
            for item in allItems {
                if output.scores[item.id] != nil { resultByID[item.id] = item }
            }
            for item in indexedFileResults {
                if output.scores[item.id] != nil { resultByID[item.id] = item }
            }

            let sortedResults = output.sortedIDs.compactMap { id -> SearchResult? in
                guard var result = resultByID[id] else { return nil }
                result.score = output.scores[id] ?? 0.0
                return result
            }
            let displayResults: [SearchResult] = {
                let presets = systemCommandPresetSearchResults(for: snap.query)
                return presets.isEmpty ? sortedResults : presets
            }()
            let suggestedShortcutIDs = Set(
                snap.candidates.filter(\.isSuggestedShortcut).map(\.id)
            )
            var grouped = GroupedResults()
            for result in displayResults {
                grouped.add(result, isSuggested: suggestedShortcutIDs.contains(result.id))
            }
            grouped.pinnedResults = snap.pinnedResults
            grouped.pinnedSectionTitle = snap.pinnedTitle
            let newResults = snap.dockAtBottom
                ? Array(grouped.allResults.reversed()) : grouped.allResults
            let fingerprint = newResults.map(\.id).joined(separator: "\u{1F}")
            if fingerprint == searchState.resultFingerprint,
                searchState.query.trimmingCharacters(in: .whitespaces) == snap.query
            {
                return
            }
            searchState.resultFingerprint = fingerprint

            withAnimation(.easeInOut(duration: 0.15)) {
                searchState.results = newResults
                searchState.grouped = grouped

                if snap.isKeyboardNav && !snap.isNewQuery,
                   let oldID = output.oldSelectedID,
                   let newIndex = searchState.results.firstIndex(where: { $0.id == oldID })
                {
                    searchState.selectedIndex = newIndex
                } else if !searchState.results.isEmpty {
                    let defaultIndex = settings.effectiveDockAtBottom
                        ? max(searchState.results.count - 1, 0) : 0
                    searchState.selectedIndex = defaultIndex
                    if settings.effectiveDockAtBottom { shouldAutoScroll = true }
                } else {
                    searchState.selectedIndex = nil
                }
            }
            if settings.effectiveDockAtBottom { searchState.revision += 1 }
        }
    }

    // MARK: - Helpers

    func findApplications(matching query: String) -> [SearchResult] {
        allItems.filter { $0.title.lowercased().contains(query) }
    }

    func systemCommandPresetSearchResults(for query: String) -> [SearchResult] {
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return [] }
        guard let command = SystemCommandsRegistry.shared.commands.first(where: { command in
            guard command.isEnabled else { return false }
            let terms = ([command.name] + command.keywords).map(normalizedDockPillText)
            return terms.contains(normalizedQuery)
        }) else { return [] }

        let terms = ([command.name] + command.keywords).map(normalizedDockPillText)
        let isVolume = terms.contains { $0.contains("volume") }
        let dynamicItems = systemCommandDynamicItems(command)
        if !dynamicItems.isEmpty {
            return dynamicItems.enumerated().map { index, item in
                var result = SearchResult(
                    title: "\(command.name) \(item.title)",
                    subtitle: "syscmd://\(command.id.uuidString)",
                    icon: NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name),
                    action: {
                        runSystemCommand(command, originalQuery: item.value)
                        searchState.query = ""
                        searchState.results = []
                        searchState.selectedIndex = nil
                    },
                    score: 10_200 - Double(index),
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

        return presets.enumerated().map { index, value in
            var result = SearchResult(
                title: "\(command.name) \(value)",
                subtitle: "syscmd://\(command.id.uuidString)",
                icon: NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name),
                action: {
                    runSystemCommand(command, originalQuery: value)
                    searchState.query = ""
                    searchState.results = []
                    searchState.selectedIndex = nil
                },
                score: 10_000 - Double(index),
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

    // MARK: - Private Helpers

    private func detectSmartQuery(query: String) -> SmartQueryType? {
        let lowercased = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowercased.isEmpty else { return nil }

        if let entry = AppSettings.shared.customAppEntries.first(where: {
            $0.key == lowercased || $0.label.lowercased() == lowercased
        }) {
            return .customApp(entry.key)
        }
        return nil
    }

    private func findExactApplicationMatch(query: String) -> String? {
        let lowercased = query.lowercased().trimmingCharacters(in: .whitespaces)
        for app in allApplications {
            guard let appPath = app.filePath else { continue }
            let appName = URL(fileURLWithPath: appPath)
                .deletingPathExtension().lastPathComponent.lowercased()
            if appName == lowercased { return appPath }
        }
        return nil
    }

    @discardableResult
    private func handleSmartQueryResult(_ smartQuery: SmartQueryType) -> Bool {
        switch smartQuery {
        case .contacts:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.AddressBook", appName: "Contacts")
            loadAllContactsAsResults()
            return false
        case .photos:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.Photos", appName: "Photos")
            loadPhotosAsResults()
            return false
        case .notes:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.Notes", appName: "Notes")
            loadSystemDataAsPinnedResults(query: "", types: [.note], title: "Notes",
                perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.note])
            return false
        case .reminders:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.reminders", appName: "Reminders")
            loadSystemDataAsPinnedResults(query: "", types: [.reminder], title: "Reminders",
                perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.reminder])
            return false
        case .calendarEvents:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.iCal", appName: "Calendar")
            loadSystemDataAsPinnedResults(query: "", types: [.calendarEvent], title: "Calendar",
                perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.calendarEvent])
            return false
        case .mail:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.mail", appName: "Mail")
            loadSystemDataAsPinnedResults(query: "", types: [.mail], title: "Mail",
                perTypeLimit: 100, allowEmptyQuery: true, excludeTypes: [.mail])
            return false
        case .messages:
            _ = activateInlineDockAppScope(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages")
            clearPinnedResults()
            searchState.appPanelAllItems = []
            return false
        case .customApp(let key):
            let entry = settings.customAppEntries.first(where: { $0.key == key })
            if let path = entry?.appPath, !path.isEmpty,
               let bundleId = Bundle(path: path)?.bundleIdentifier
            {
                _ = activateInlineDockAppScope(
                    bundleIdentifier: bundleId, appName: entry?.label ?? key.capitalized)
            } else {
                searchState.activeSmartQueryKey = key
            }
            var items: [SearchResult] = []
            if let path = entry?.appPath, !path.isEmpty,
               FileManager.default.fileExists(atPath: path)
            {
                items.append(SearchResult(
                    title: "Open \(entry?.label ?? key.capitalized)",
                    subtitle: path,
                    icon: NSWorkspace.shared.icon(forFile: path),
                    action: {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: path), configuration: .init())
                    },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ))
            }
            searchState.appPanelAllItems = items
            injectAppShortcuts(for: key)
            return false
        case .application(let appPath):
            loadApplicationSpecificContent(appPath: appPath)
            return false
        }
    }
}
