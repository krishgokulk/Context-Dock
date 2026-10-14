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

extension DockCore {
    // MARK: - Context Detection & Metadata

    var contextDockIsFrontmostApplication: Bool {
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        guard !ownBundleId.isEmpty else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleId
    }


    func detectAndUpdateContext() {
        guard settings.enableContextAIExtensions else {
            clearFinderFollowUpTargets()
            currentContext = .none
            return
        }

        if contextDockIsFrontmostApplication {
            switch currentContext {
            case .filesSelected, .textSelected, .url, .contactSelected:
                return
            default:
                setFrontmostAppContextOnly(reason: "own app frontmost")
                return
            }
        }

        if isL2ContextActive {
            // While the dock is open, keep global context live:
            // if the user changed their Finder/AX file/text selection, keep that selection
            // as additive context. Do not switch out of Context Dock.
            let livePaths = axContext.selectedFilePaths
            if !livePaths.isEmpty {
                let urls = livePaths.map { URL(fileURLWithPath: $0) }
                if case .filesSelected(let current) = currentContext,
                    current.map(\.path) == livePaths
                {
                    // already correct — no-op
                } else {
                    currentContext = .filesSelected(urls)
                }
                return
            }
            let liveText =
                axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if liveText.count > 3 {
                currentContext = .textSelected(liveText)
                return
            }
            setFrontmostAppContextOnly(reason: "L2 context dock")
            return
        }

        // Priority 1: Files selected in search results (internal selection)
        if !selectedFiles.isEmpty {
            let selectedURLs =
                searchState.results
                .filter { selectedFiles.contains($0.id) }
                .compactMap { $0.filePath }
                .map { URL(fileURLWithPath: $0) }

            if !selectedURLs.isEmpty {
                rememberFinderFollowUpTargets(
                    selectedURLs,
                    folderPath: selectedURLs.first?.deletingLastPathComponent().path
                        ?? currentFinderFolderPath(),
                    sourceQuery: "search selection"
                )
                currentContext = .filesSelected(selectedURLs)
                updateContextSuggestions()
                return
            }
        }

        // Priority 2: Automatic context detection from frontmost app
        if let frontmostApp = contextTargetApp() {
            let bundleID = frontmostApp.bundleIdentifier ?? ""
            let appName = frontmostApp.localizedName ?? "Unknown"

            guard bundleID != Bundle.main.bundleIdentifier else { return }

            frontmost.name = appName
            frontmost.bundleID = bundleID
            frontmost.icon =
                resolvedApplicationIcon(bundleIdentifier: bundleID, appName: appName)
                ?? preparedDockIcon(frontmostApp.icon)
            refreshCachedFinderCurrentDirectory(for: bundleID)
            if bundleID != "com.apple.finder" {
                clearFinderFollowUpTargets()
            }

            // Fast path: use pre-read AXContext when fresh for this app.
            // Avoids a redundant ContextDetector AX pass (text/URL/Finder already read
            // by the background AXContextReader refresh on the 750ms timer and app-switch paths).
            let freshCtx = AXContextReader.shared.current
            if freshCtx.bundleId == bundleID, !freshCtx.isEmpty {
                if bundleID == "com.apple.finder", !freshCtx.selectedFilePaths.isEmpty {
                    let urls = freshCtx.selectedFilePaths.map { URL(fileURLWithPath: $0) }
                    rememberFinderFollowUpTargets(
                        urls,
                        folderPath: urls.first?.deletingLastPathComponent().path
                            ?? currentFinderFolderPath(),
                        sourceQuery: "finder selection"
                    )
                    currentContext = .filesSelected(urls)
                    updateContextSuggestions()
                    return
                }
                if let text = freshCtx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   text.count > 3
                {
                    currentContext = .textSelected(text)
                    updateContextSuggestions()
                    return
                }
                if let url = freshCtx.currentURL, !url.isEmpty {
                    currentContext = .url(url)
                    updateContextSuggestions()
                    return
                }
                // Notes and Mail need deeper detection (content not captured by AXContextReader)
                let needsDeepDetect = bundleID == "com.apple.Notes" || bundleID == "com.apple.mail"
                if !needsDeepDetect {
                    if bundleID == "com.apple.finder",
                        let stickyURL = finderFollowUpTargetURLs(for: currentFinderFolderPath()).first
                    {
                        currentContext = .filesSelected([stickyURL])
                    } else {
                        currentContext = .appFocused(name: appName, bundleID: bundleID)
                    }
                    updateContextSuggestions()
                    return
                }
            }

            // Deep detection: Notes, Mail, and cases where AXContext is stale or empty
            if let detected = ContextDetector.shared.detectContext(frontmostApp: frontmostApp) {
                switch detected {
                case .files(let urls):
                    rememberFinderFollowUpTargets(
                        urls,
                        folderPath: urls.first?.deletingLastPathComponent().path
                            ?? currentFinderFolderPath(),
                        sourceQuery: "finder selection"
                    )
                    currentContext = .filesSelected(urls)

                case .text(let text):
                    currentContext = .textSelected(text)

                case .browserTab(let url, _):
                    currentContext = .url(url)

                case .browserTabs(let tabs):
                    if let firstTab = tabs.first {
                        currentContext = .url(firstTab.url)
                    }

                case .clipboard(let content):
                    currentContext = .textSelected(content)

                case .music(let title, let artist, _):
                    currentContext = .textSelected("\(title) by \(artist)")

                case .podcast(let title, let show):
                    currentContext = .textSelected("\(title) - \(show)")

                case .note(let content):
                    currentContext = .textSelected(content)

                case .email(let subject, _, _):
                    currentContext = .textSelected(subject)

                case .app(_, let name):
                    if bundleID == "com.apple.finder",
                        let stickyURL = finderFollowUpTargetURLs(for: currentFinderFolderPath()).first
                    {
                        currentContext = .filesSelected([stickyURL])
                    } else {
                        currentContext = .appFocused(name: name, bundleID: bundleID)
                    }
                }

                updateContextSuggestions()
                return
            }
        }

        // Priority 3: Fallback to clipboard — check files, then text
        if let fileURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)
            as? [URL]
        {
            let validFileURLs = fileURLs.filter { $0.isFileURL }
            if !validFileURLs.isEmpty {
                clearFinderFollowUpTargets()
                currentContext = .filesSelected(validFileURLs)
                updateContextSuggestions()
                return
            }
        }

        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            let trimmed = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter {
                !$0.isEmpty
            }
            if words.count >= 2 || (words.count == 1 && trimmed.count >= 10) {
                clearFinderFollowUpTargets()
                currentContext = .textSelected(clipboardText)
                updateContextSuggestions()
                return
            }
        }

        // Priority 4: No context
        clearFinderFollowUpTargets()
        currentContext = .none
        updateContextSuggestions()
    }

    func contextTargetApp() -> NSRunningApplication? {
        if let target = l2.targetApp,
            !target.bundleId.isEmpty,
            !target.bundleId.hasPrefix("scope://"),
            let targetApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == target.bundleId && !$0.isTerminated
            })
        {
            return targetApp
        }

        if !frontmost.bundleID.isEmpty,
            frontmost.bundleID != Bundle.main.bundleIdentifier,
            let resolvedApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == frontmost.bundleID && !$0.isTerminated
            })
        {
            return resolvedApp
        }

        // Fallback: NSWorkspace frontmost, but exclude ourselves
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
            frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            return frontmostApp
        }

        // Fallback to the last captured pre-dock app only if we couldn't resolve
        // the live dock target from current frontmost state.
        if let prev = AppDelegate.shared?.previousFrontmostApp,
            prev.bundleIdentifier != Bundle.main.bundleIdentifier,
            !prev.isTerminated
        {
            return prev
        }

        return nil
    }




    func currentFrontmostMenuCapabilityJSONBlock(maxItems: Int = 40) -> String {
        let items =
            liveMenuItems
            .filter {
                $0.isEnabled && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .prefix(maxItems)

        guard !items.isEmpty else { return "" }

        let payload: [[String: Any]] = items.map { item in
            [
                "title": item.title,
                "path": item.path,
                "shortcut": item.shortcutDisplay ?? "",
            ]
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return "" }

        return """

            ## App Menu Capabilities JSON
            ```json
            \(json)
            ```
            Treat this JSON as executable app commands only. It describes what the app can do, not the app's live content.
            """
    }





    /// After a Quick Look peek closes, keep the list selection on the file that was
    /// being previewed — Spotlight-style — instead of dropping back to the first row.
    /// Restores BOTH the results-list selection (searchState.selectedIndex, which
    /// drives Finder file search) and the dock-pill focus (l2.focusedPillIndex).
    func restoreSelectionAfterQuickLookClose(previewedURL url: URL) {
        // Results-list selection (Finder file search is driven by this, not pills).
        if let resultIdx = searchState.results.firstIndex(where: { $0.filePath == url.path }) {
            searchState.selectedIndex = resultIdx
        }

        guard usesVerticalListDockLayout else { return }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pillQuery = shouldUseFinderSearchPopover(for: q) ? "" : q
        let pills =
            pillQuery.isEmpty
            ? selectionScopedDockPills(cachedDockPills)
            : contextDockViewModel.visiblePills
        if let idx = pills.firstIndex(where: { $0.quickLookURL == url }) {
            l2.focusedPillIndex = idx
            l2.pillNavViaKeyboard = true
            isSearchFieldFocused = false
        } else if l2.focusedPillIndex != nil {
            // Keep whatever pill focus already existed; just stay in list-nav mode.
            l2.pillNavViaKeyboard = true
            isSearchFieldFocused = false
        }
    }


    func quickLookPanelIsVisible() -> Bool {
        PreviewController.shared.isOpen
    }

    func showQuickLookURL(_ url: URL, toggleIfSame: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // The dock's own preview surface, not the system panel: it carries the pin,
        // the Open With menu and the assistant, which QLPreviewPanel's chrome cannot.
        let shown = PreviewController.shared.present(
            url: url,
            siblings: visiblePreviewPaths().map { URL(fileURLWithPath: $0) },
            toggleIfSame: toggleIfSame,
            // The surface can also be closed from its own header or Escape, so restore
            // the previewed selection from the close callback rather than the key path.
            onClose: { [self] in
                restoreSelectionAfterQuickLookClose(previewedURL: url)
            }
        )
        guard shown else { return false }
        // Toggled shut rather than opened: the close callback already restored the
        // selection, so re-taking focus here would fight it.
        guard PreviewController.shared.isOpen else { return true }

        return true
    }


    func refreshQuickLookPreviewForCurrentFocusIfVisible() {
        guard quickLookPanelIsVisible() else { return }

        // Web rows first: a link's preview is the live page, and the pill carries the
        // resolved URL that its file path does not.
        if let pill = currentFocusedDockPillForQuickLook() ?? focusedGlobalGroupedListPill(),
            let url = pill.resolvedURL,
            url.scheme == "https" || url.scheme == "http"
        {
            PreviewController.shared.present(url: url, toggleIfSame: false)
            return
        }

        if let pill = currentFocusedDockPillForQuickLook(),
            let url = pill.quickLookURL
        {
            _ = showQuickLookURL(url, toggleIfSame: false)
            return
        }
        if searchState.activeSmartQueryKey == "clipboard",
            let index = focusedClipboardEntryIndex
        {
            let entries = visibleClipboardEntriesForScope()
            if entries.indices.contains(index), let url = quickLookURL(for: entries[index]) {
                _ = showQuickLookURL(url, toggleIfSame: false)
            }
            return
        }
        guard let index = searchState.selectedIndex,
            searchState.results.indices.contains(index),
            let path = searchState.results[index].filePath
        else { return }
        if searchState.results[index].type == .folder {
            showFolderPreviewInline(path: path, toggleIfSame: false)
            return
        }
        _ = showQuickLookURL(URL(fileURLWithPath: path), toggleIfSame: false)
    }

    func loadApplicationsInBackground() {
        searchState.isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            let apps = findAllApplications()
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    allApplications = apps
                    searchState.isLoadingApps = false
                }
                AppScopeMatchCache.shared.prewarm(
                    appPaths: apps.filter { $0.type == .application }.map(\.subtitle)
                )
                rebuildGlobalSearchIndex()
                if !searchState.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async { performSearch() }
                }
            }
        }
    }

    nonisolated func findAllApplications() -> [SearchResult] {
        // Reads the launch-prewarmed catalog (instant) or enumerates once and
        // caches. See AppCatalogService.
        AppCatalogService.shared.appsNow()
    }





    func searchIndexedFiles(for query: String) {
        guard settings.enableSpotlightSearch,
            settings.enableL1DocumentSearch || settings.enableL1FileSearch
        else {
            indexedFileResults = []
            return
        }

        guard !query.isEmpty else {
            indexedFileResults = []
            return
        }

        guard fileIndexManager.isReady else {
            #if DEBUG
            print("⚠️ File index not ready yet")
            #endif
            indexedFileResults = []
            return
        }

        // Use the pre-built index for instant search
        let results = fileIndexManager.search(query: query, limit: 20)
            .filter(includeIndexedSearchResult)

        indexedFileResults = results
        refreshIndexedFileThumbnails(for: query, filePaths: results.compactMap(\.filePath))
    }

    func refreshIndexedFileThumbnails(for query: String, filePaths: [String]) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        for path in Array(Set(filePaths)).prefix(12) {
            ThumbnailGenerator.shared.getThumbnail(
                for: path,
                size: CGSize(width: 96, height: 96)
            ) { thumbnail in
                guard let thumbnail else { return }
                Task { @MainActor in
                    guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        == trimmedQuery
                    else { return }
                    guard let index = indexedFileResults.firstIndex(where: { $0.filePath == path })
                    else { return }
                    indexedFileResults[index] = indexedFileResults[index].replacingIcon(thumbnail)
                    performSearch()
                }
            }
        }
    }

    func includeIndexedSearchResult(_ result: SearchResult) -> Bool {
        switch result.type {
        case .document:
            return settings.enableL1DocumentSearch
        case .file, .folder:
            return settings.enableL1FileSearch
        default:
            return true
        }
    }




    func hideLauncherAfterResultExecution() {
        suppressAutomaticGlobalContextUntil = Date().addingTimeInterval(1.6)
        suppressedAutomaticFinderSelectionSignature = nil
        dismissedFinderSelectionSignature = nil

        // A global-context launch is morphing into the app's Context Dock — keep the dock
        // visible instead of hiding, regardless of dock mode.
        if Date() < (AppDelegate.shared?.suppressResultHideUntil ?? .distantPast) {
            searchState.query = ""
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            DispatchQueue.main.async { self.reclaimSearchInputFocus() }
            return
        }

        // Always-float (or taskbar mode): keep the dock visible after the action runs;
        // just reset it to idle and refocus the input for the next command.
        if settings.alwaysFloatDock || (settings.effectiveDockAtBottom && showContextInDock) {
            searchState.query = ""
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            DispatchQueue.main.async { self.reclaimSearchInputFocus() }
            return
        }

        isSearchFieldFocused = false
    }

    func forceHideLauncherAfterResultExecution() {
        suppressAutomaticGlobalContextUntil = Date().addingTimeInterval(1.6)
        suppressedAutomaticFinderSelectionSignature = nil
        dismissedFinderSelectionSignature = nil
        searchState.query = ""
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        // A global-context launch is morphing into the app's Context Dock — don't hide.
        if Date() < (AppDelegate.shared?.suppressResultHideUntil ?? .distantPast) {
            DispatchQueue.main.async { self.reclaimSearchInputFocus() }
            return
        }
        isSearchFieldFocused = false
    }

    func hideLauncherAfterFinderAction() {
        guard showContextInDock else { return }
        guard
            frontmost.bundleID == "com.apple.finder"
                || contextTargetApp()?.bundleIdentifier == "com.apple.finder"
                || axContext.bundleId == "com.apple.finder"
        else { return }

        hideLauncherAfterResultExecution()
    }


    func executeL2Extension(_ ext: ILExtension, context: UserContext) async {
        await MainActor.run {
            l2.isLoading = true
        }

        defer {
            Task { @MainActor in
                l2.isLoading = false
            }
        }

        let inputFiles: [URL]
        if case .filesSelected(let urls) = context {
            inputFiles = urls
        } else {
            inputFiles = []
        }

        do {
            if ext.name == "Summarize Webpage",
                frontmost.name.lowercased().contains("safari"),
                let pageText = fetchSafariPageText(),
                !pageText.isEmpty
            {
                let prompt = "Summarize this webpage:\n\n\(pageText)"
                let response = try await sendToAIProvider(query: prompt)
                await MainActor.run {
                    updateL2Results(buildL2OutputResults(title: ext.name, output: response))
                }
                return
            }

            let output = try await LayeredExtensionManager.shared.execute(
                extension: ext, with: inputFiles)
            await MainActor.run {
                updateL2Results(buildL2OutputResults(title: ext.name, output: output))
            }
        } catch {
            #if DEBUG
            print("❌ [L2 Extension] Failed to run \(ext.name): \(error.localizedDescription)")
            #endif
        }
    }

    func fetchSafariPageText() -> String? {
        let script = """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                set currentTab to current tab of front window
                set js to "document.body ? document.body.innerText : ''"
                return (URL of currentTab) & linefeed & (do JavaScript js in currentTab)
            end tell
            """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return nil
        }

        let output = scriptObject.executeSerialized(error: &error)
        if error != nil {
            return nil
        }

        // The first line is the tab's address: a page SensitivePageGuard refuses is not read.
        let raw = output.stringValue ?? ""
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let pageURL = lines.first.map(String.init) ?? ""
        guard SensitivePageGuard.allows(pageURL) else { return nil }
        let text = lines.count > 1 ? String(lines[1]) : ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return String(trimmed.prefix(6000))
    }

    func fetchSafariPageLinks() -> [String] {
        let script = """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                set currentTab to current tab of front window
                set js to "Array.from(document.links).map(a => a.href).filter(Boolean).join('\\\\n')"
                return do JavaScript js in currentTab
            end tell
            """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return []
        }

        let output = scriptObject.executeSerialized(error: &error)
        if error != nil {
            return []
        }

        let text = output.stringValue ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let links =
            trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(NSOrderedSet(array: links)) as? [String] ?? links
    }

    func fetchSafariPageImages() -> [String] {
        let script = """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                set currentTab to current tab of front window
                set js to "Array.from(document.images).map(i => i.src).filter(Boolean).join('\\\\n')"
                return do JavaScript js in currentTab
            end tell
            """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return []
        }

        let output = scriptObject.executeSerialized(error: &error)
        if error != nil {
            return []
        }

        let text = output.stringValue ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let images =
            trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(NSOrderedSet(array: images)) as? [String] ?? images
    }

    func shouldAutoRunL2Extension(query: String, ext: ILExtension) -> Bool {
        let normalized = query.lowercased()
        let name = ext.name.lowercased()

        if normalized.contains(name) {
            return true
        }

        if ext.matchesKeyword(query) {
            return true
        }

        for intent in ext.intents {
            if normalized.contains(intent.action.lowercased()) {
                return true
            }
            if let target = intent.target?.lowercased(), normalized.contains(target) {
                return true
            }
        }

        return false
    }

    func buildL2OutputResults(title: String, output: String) -> [SearchResult] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lines =
            trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let maxItems = 20
        let items = lines.isEmpty ? [trimmed] : Array(lines.prefix(maxItems))

        return items.map { line in
            let url = URL(string: line)
            return SearchResult(
                title: line,
                subtitle: title,
                icon: NSImage(systemSymbolName: "doc.text", accessibilityDescription: title),
                action: {
                    if let url, url.scheme != nil {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    }
                },
                score: 0.0,
                type: .extensionCommand,
                filePath: nil,
                contactData: nil
            )
        }
    }

    /// Returns a stable string identifying WHAT the context is about (file path, text hash, URL, app bundle).
    /// Used to detect when the user switches to a different subject so stale chat can be cleared.
    func contextIdentityKey(_ context: UserContext) -> String {
        switch context {
        case .filesSelected(let urls):
            // Use all paths so selecting a different file in same folder is caught
            return "files:" + urls.map(\.path).sorted().joined(separator: "|")
        case .textSelected(let text):
            return "text:" + String(text.prefix(200))
        case .url(let urlString):
            return "url:" + urlString
        case .appFocused(_, let bundleID):
            return "app:" + bundleID
        case .contactSelected(let name):
            return "contact:" + name
        case .none:
            return "none"
        }
    }

    func updateL2Results(_ results: [SearchResult]) {
        l2.extensionResults = results
        if showContextInDock && !showMediaLayer {
            if !isSearchBarExpanded && !results.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isSearchBarExpanded = true
                }
            }
            searchState.results = results
            searchState.grouped = {
                var grouped = GroupedResults()
                results.forEach { grouped.add($0) }
                return grouped
            }()
            // Never auto-select in L2 — keeps the search bar as a plain text field
            // so the user can immediately type a follow-up query.
            searchState.selectedIndex = nil
        }
    }

}
