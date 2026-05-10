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

        if showContextInDock && !showMediaLayer {
            // L2 context dock: pills filter in the dock row — don't touch the result sheet.
            return
        }

        // App panel active (calendar/notes/etc.) — panel handles its own display.
        if searchState.activeSmartQueryKey != nil {
            if query.isEmpty {
                searchState.results = []
                searchState.debounceTask?.cancel()
            } else {
                searchState.results = []
            }
            return
        }

        guard !query.isEmpty else {
            if showFolderPreview {
                searchState.results = []
                searchState.debounceTask?.cancel()
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                searchState.results = []
                searchState.selectedIndex = nil
                searchState.indexedFileResults = []
                searchState.isInSmartMode = false
                searchState.lastSmartQuery = ""
                searchState.activeSmartQueryKey = nil
                searchState.contextApp = nil
                clearPinnedResults()
                systemDataResults = []
            }
            searchState.debounceTask?.cancel()
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
                searchState.indexedFileResults = []
            }
            return
        }

        // In-memory file search — run immediately for instant results
        if settings.enableSpotlightSearch
            && (settings.enableL1DocumentSearch || settings.enableL1FileSearch)
        {
            searchIndexedFiles(for: query)
        } else {
            searchState.indexedFileResults = []
        }

        // Debounce scoring onto background thread so keystrokes never block the UI
        searchState.debounceTask?.cancel()
        searchState.debounceTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 60_000_000)  // 60 ms
            guard !Task.isCancelled else { return }
            await MainActor.run { performSearchWithoutSpotlight() }
        }
    }

    // MARK: - Core Scoring + Grouping

    func performSearchWithoutSpotlight() {
        let query = searchState.query.trimmingCharacters(in: .whitespaces)
        let isNewQuery = query != searchState.lastQuery
        if isNewQuery {
            DispatchQueue.main.async {
                self.searchState.lastQuery = query
                self.searchState.isKeyboardNavigation = false
            }
        }

        guard !allApplications.isEmpty || !allShortcuts.isEmpty
                || !searchState.indexedFileResults.isEmpty || !searchState.pinnedResults.isEmpty
        else {
            searchState.results = []
            searchState.selectedIndex = nil
            return
        }

        var scoredItems: [(item: SearchResult, score: Double)] = []

        if showContextInDock && !showMediaLayer {
            updateL2Results(l2.extensionResults)
            return
        }

        let searchableItems: [SearchResult] =
            showMediaLayer ? allItems.filter { $0.type != .shortcut } : allItems

        var filteredItems = searchableItems.filter {
            $0.type == .application || $0.type == .cliTool
        }
        if settings.enableSpotlightSearch {
            filteredItems += searchState.indexedFileResults.filter(includeIndexedSearchResult)
        }

        // Strip .app suffix before matching (e.g. "Clock.app" → "Clock")
        let strippedQuery: String = {
            let lower = query.lowercased()
            return lower.hasSuffix(".app")
                ? String(query.dropLast(4)).trimmingCharacters(in: .whitespaces)
                : query
        }()
        let queryLower = strippedQuery.lowercased()

        // Pre-filter: skip items that don't contain the first query character (~90% elimination)
        let preFiltered = filteredItems.filter {
            $0.title.lowercased().contains(queryLower.prefix(1))
        }

        for item in preFiltered {
            guard let score = FuzzyMatcher.score(strippedQuery, against: item.title) else { continue }
            var scoredItem = item
            scoredItem.score = score

            let usageScore = UsageTracker.shared.getScore(for: item.trackingIdentifier)

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

            // Context boost: shortcuts matching current user context float to the top
            if item.type == .shortcut,
               let metadata = shortcutMetadataCache[item.title],
               metadata.matches(context: currentContext)
            {
                finalScore += 500.0
            }

            scoredItems.append((item: scoredItem, score: finalScore))
        }

        let sortedResults = scoredItems
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { $0.item }

        var grouped = GroupedResults()
        for result in sortedResults {
            let isSuggested =
                result.type == .shortcut
                && shortcutMetadataCache[result.title]?.matches(context: currentContext) == true
            grouped.add(result, isSuggested: isSuggested)
        }

        grouped.pinnedResults = searchState.pinnedResults
        grouped.pinnedSectionTitle = searchState.pinnedTitle

        let newResults = settings.effectiveDockAtBottom
            ? Array(grouped.allResults.reversed())
            : grouped.allResults

        let oldSelectedResultID: UUID? = {
            guard let oldIndex = searchState.selectedIndex,
                  oldIndex >= 0, oldIndex < searchState.results.count
            else { return nil }
            return searchState.results[oldIndex].id
        }()

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.searchState.results = newResults
                self.searchState.grouped = grouped

                if self.searchState.isKeyboardNavigation && !isNewQuery,
                   let oldID = oldSelectedResultID,
                   let newIndex = self.searchState.results.firstIndex(where: { $0.id == oldID })
                {
                    self.searchState.selectedIndex = newIndex
                } else if !self.searchState.results.isEmpty {
                    let defaultIndex = self.settings.effectiveDockAtBottom
                        ? max(self.searchState.results.count - 1, 0) : 0
                    self.searchState.selectedIndex = defaultIndex
                    if self.settings.effectiveDockAtBottom {
                        self.searchState.shouldAutoScroll = true
                    }
                } else {
                    self.searchState.selectedIndex = nil
                }
            }
        }

        if settings.effectiveDockAtBottom {
            searchState.revision += 1
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
