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

    // MARK: - Public Entry Point

    func performSearch() {
        // NOTE: detectAndUpdateContext() deliberately NOT called here.
        // Synchronous AX calls block the main thread 100–500ms per call.
        // Context is captured once when the launcher shows (showLauncher / onAppear).

        let query = searchState.query.trimmingCharacters(in: .whitespaces)

        if isL2ContextActive {
            enforceL2ContextMode()
        }

        // L3 media layer active — suppress search results entirely
        if showMediaLayer {
            searchState.results = []
            searchState.selectedIndex = nil
            return
        }

        // L2 context dock — pills handle filtering, search runs after debounce only
        if showContextInDock && !showMediaLayer {
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
            if showFolderPreview {
                searchState.results = []
                debounceTask?.cancel()
                return
            }
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
                print("🔄 Exiting smart mode, switching to normal search")
                searchState.isInSmartMode = false
                searchState.lastSmartQuery = ""
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFolderPreview = false
                }
            }
        }

        // Smart exact-match detection for folders, contacts, and photos
        if let smartResult = detectSmartQuery(query: query) {
            print("🎯 Smart query detected: \(smartResult)")
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
        struct Snap {
            let query: String
            let isNewQuery: Bool
            let hasItems: Bool
            let showContextInDock: Bool
            let showMediaLayer: Bool
            let l2ExtensionResults: [SearchResult]
            let candidates: [SearchResult]      // apps + CLI tools + pre-filtered indexed
            let pinnedResults: [SearchResult]
            let pinnedTitle: String?
            let dockAtBottom: Bool
            let metaCache: [String: ShortcutMetadata]
            let context: UserContext
            let selectedIndex: Int?
            let existingResults: [SearchResult]
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

            return Snap(
                query: q,
                isNewQuery: isNew,
                hasItems: !allApplications.isEmpty || !allShortcuts.isEmpty
                    || !indexedFileResults.isEmpty || !searchState.pinnedResults.isEmpty,
                showContextInDock: showContextInDock,
                showMediaLayer: showMediaLayer,
                l2ExtensionResults: l2.extensionResults,
                candidates: candidates,
                pinnedResults: searchState.pinnedResults,
                pinnedTitle: searchState.pinnedTitle,
                dockAtBottom: settings.effectiveDockAtBottom,
                metaCache: shortcutMetadataCache,
                context: currentContext,
                selectedIndex: searchState.selectedIndex,
                existingResults: searchState.results,
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

        // ── 2. Pure scoring — off MainActor ───────────────────────────────────
        let strippedQuery: String = {
            let lower = snap.query.lowercased()
            return lower.hasSuffix(".app")
                ? String(snap.query.dropLast(4)).trimmingCharacters(in: .whitespaces)
                : snap.query
        }()
        let queryLower = strippedQuery.lowercased()
        let firstChar  = queryLower.prefix(1)

        // Pre-filter using cached titleLower — no lowercased() allocation per item
        let preFiltered = snap.candidates.filter { $0.titleLower.contains(firstChar) }

        // Batch usage scores: one serial-queue lock instead of one per item
        let usageScores = UsageTracker.shared.snapshotScores(
            for: preFiltered.map { $0.trackingIdentifier })

        var scoredItems: [(item: SearchResult, score: Double)] = []
        scoredItems.reserveCapacity(preFiltered.count)

        for item in preFiltered {
            // Pass pre-lowercased strings — FuzzyMatcher skips internal lowercasing
            guard let score = FuzzyMatcher.score(
                queryLower, againstLower: item.titleLower, original: item.title
            ) else { continue }

            var scoredItem = item
            scoredItem.score = score

            let usageScore = usageScores[item.trackingIdentifier] ?? 0.0

            let typePriority: Double
            switch item.type {
            case .extensionCommand: typePriority = 20.0
            case .application:      typePriority = 15.0
            case .folder:           typePriority = 14.0
            case .cliTool:          typePriority = 13.0
            case .shortcut:         typePriority = 12.0
            case .calendarEvent, .reminder: typePriority = 10.0
            case .mail, .message:   typePriority = 9.0
            case .document:         typePriority = 7.0
            case .note:             typePriority = 6.0
            case .contact:          typePriority = 5.0
            case .file:             typePriority = 3.0
            case .photo:            typePriority = 2.0
            case .webSearch:        typePriority = 1.0
            }

            var finalScore = score + typePriority + (usageScore * 8.0)

            if item.type == .shortcut,
               let metadata = snap.metaCache[item.title],
               metadata.matches(context: snap.context)
            { finalScore += 500.0 }

            scoredItems.append((item: scoredItem, score: finalScore))
        }

        let sortedResults = scoredItems
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { $0.item }

        var grouped = GroupedResults()
        for result in sortedResults {
            let isSuggested = result.type == .shortcut
                && snap.metaCache[result.title]?.matches(context: snap.context) == true
            grouped.add(result, isSuggested: isSuggested)
        }
        grouped.pinnedResults    = snap.pinnedResults
        grouped.pinnedSectionTitle = snap.pinnedTitle

        let newResults = snap.dockAtBottom
            ? Array(grouped.allResults.reversed()) : grouped.allResults

        let oldSelectedID: UUID? = {
            guard let idx = snap.selectedIndex, idx >= 0, idx < snap.existingResults.count
            else { return nil }
            return snap.existingResults[idx].id
        }()

        // ── 3. Apply on MainActor ─────────────────────────────────────────────
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.15)) {
                searchState.results = newResults
                searchState.grouped = grouped

                if snap.isKeyboardNav && !snap.isNewQuery,
                   let oldID = oldSelectedID,
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
