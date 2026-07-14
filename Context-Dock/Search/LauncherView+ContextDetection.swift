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

extension LauncherView {
    // MARK: - Context Detection & Metadata

    var contextDockIsFrontmostApplication: Bool {
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        guard !ownBundleId.isEmpty else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleId
    }

    func loadShortcutMetadata() {
        // Load shortcuts metadata from JSON file
        guard
            let metadataURL = Bundle.main.url(
                forResource: "shortcuts-metadata", withExtension: "json", subdirectory: ".claude")
        else { return }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            let metadata = try decoder.decode([String: ShortcutMetadataJSON].self, from: data)
            for (name, meta) in metadata {
                shortcutMetadataCache[name] = ShortcutMetadata(
                    acceptsFiles: meta.acceptsFiles,
                    acceptsText: meta.acceptsText,
                    acceptsImages: meta.acceptsImages,
                    acceptsContacts: meta.acceptsContacts,
                    acceptsPDFs: meta.acceptsPDFs,
                    fileExtensions: meta.fileExtensions
                )
            }
        } catch {}
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

        // Priority 0: File selected in folder preview (highest priority!)
        if showFolderPreview, let selectedFile = folderPreviewSelectedFile, !selectedFile.isEmpty {
            let fileURL = URL(fileURLWithPath: selectedFile)
            rememberFinderFollowUpTargets(
                [fileURL],
                folderPath: fileURL.deletingLastPathComponent().path,
                sourceQuery: fileURL.lastPathComponent
            )
            currentContext = .filesSelected([fileURL])
            updateContextSuggestions()
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

    func menuSourceApps() -> [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        var seen = Set<pid_t>()

        func append(_ app: NSRunningApplication?) {
            guard let app, !app.isTerminated else { return }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            guard seen.insert(app.processIdentifier).inserted else { return }
            apps.append(app)
        }

        append(contextTargetApp())
        append(AppDelegate.shared?.previousFrontmostApp)
        append(NSWorkspace.shared.frontmostApplication)

        if !frontmost.bundleID.isEmpty,
            let fallback = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == frontmost.bundleID
            })
        {
            append(fallback)
        }

        return apps
    }

    func menuInventory(for app: NSRunningApplication) -> [AXMenuItem] {
        let pid = app.processIdentifier
        var items = AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
        if items.isEmpty {
            items = ContextDockEngine.shared.cachedMenuItems(for: app, maxResults: 120)
        }
        for i in items.indices {
            items[i].sourcePID = pid
            items[i].sourceAppName = app.localizedName ?? ""
        }
        return items
    }

    func filterMenuInventory(_ items: [AXMenuItem], query: String, maxResults: Int = 16)
        -> [AXMenuItem]
    {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches =
            q.isEmpty
            ? items
            : items.filter { item in
                item.title.lowercased().contains(q)
                    || item.path.contains { $0.lowercased().contains(q) }
            }
        return Array(
            matches.sorted {
                let aPrefix = q.isEmpty ? 1 : ($0.title.lowercased().hasPrefix(q) ? 0 : 1)
                let bPrefix = q.isEmpty ? 1 : ($1.title.lowercased().hasPrefix(q) ? 0 : 1)
                if aPrefix != bPrefix { return aPrefix < bPrefix }

                let aTitle = q.isEmpty ? 1 : ($0.title.lowercased().contains(q) ? 0 : 1)
                let bTitle = q.isEmpty ? 1 : ($1.title.lowercased().contains(q) ? 0 : 1)
                if aTitle != bTitle { return aTitle < bTitle }

                return $0.path.count < $1.path.count
            }.prefix(maxResults))
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

    func acceptL2AppCompletion(_ completion: AppCompletion) {
        self.l2.appCompletion = nil
        if completion.bundleId == "scope://clipboard" {
            activateClipboardScope(queryOverride: completion.actionQuery)
            return
        }
        // Activate the scope immediately (explicit Tab action) and clear the app name
        // so the user can type their query into an empty field — Spotlight-style.
        let activated = activateInlineDockAppScope(
            bundleIdentifier: completion.bundleId,
            appName: completion.appName,
            queryOverride: completion.actionQuery,
            preserveGlobalContext: isGlobalContextActive
        )
        if !activated {
            let currentTokens = self.searchState.query.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").map(String.init)
            let afterApp = currentTokens.dropFirst().joined(separator: " ")
            let fullName = (currentTokens.first ?? "") + completion.ghost
            self.searchState.query = afterApp.isEmpty ? fullName + " " : fullName + " " + afterApp
        }
    }

    @discardableResult
    func activateTypedAppScopeIfPossible(for query: String? = nil) -> Bool {
        guard isGlobalContextActive else { return false }

        let rawQuery = query ?? searchState.query
        let rawTrimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawTrimmed.count >= 2 else { return false }

        let normalized =
            rawTrimmed.lowercased().hasSuffix(".app")
            ? String(rawTrimmed.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            : rawTrimmed.lowercased()

        if let completion = l2.appCompletion, !completion.ghost.isEmpty {
            acceptL2AppCompletion(completion)
            return true
        }

        if normalized == "clipboard" {
            activateClipboardScope()
            return true
        }

        if let target = L2AppActionRouter.shared.appScopeTarget(for: normalized) {
            let activated = activateInlineDockAppScope(
                bundleIdentifier: target.bundleId,
                appName: target.appName,
                queryOverride: target.actionQuery,
                preserveGlobalContext: isGlobalContextActive
            )
            if !activated { searchState.query = target.appName + " " }
            return true
        }

        if let target = installedAppMenuTarget(
            for: normalized,
            runningOnly: false,
            includeAppsWithoutMenuSnapshot: true,
            allowPrefixAlias: true
        ) {
            let activated = activateInlineDockAppScope(
                bundleIdentifier: target.bundleId,
                appName: target.appName,
                queryOverride: target.actionQuery,
                preserveGlobalContext: isGlobalContextActive
            )
            if !activated { searchState.query = target.appName + " " }
            return true
        }

        if let completion = bestL2PartialAppCompletion(for: normalized, runningOnly: false),
            !completion.ghost.isEmpty
        {
            acceptL2AppCompletion(completion)
            return true
        }

        return false
    }

    func menuDebugSummary(query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches =
            q.isEmpty
            ? liveMenuItems.count
            : liveMenuItems.filter {
                $0.title.lowercased().contains(q)
                    || $0.path.contains { part in part.lowercased().contains(q) }
            }.count
        return "\(menuDebugText), \(matches) matches"
    }

    func setupQuickLookEventMonitor() {
        // Remove any existing monitor first
        removeQuickLookEventMonitor()

        // Add a local event monitor to intercept Space key for Quick Look
        // This works even when the text field has focus
        quickLookEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [self] event in
            // Only handle Space key (keyCode 49)
            guard event.keyCode == 49 else { return event }

            if showFolderPreview {
                if let index = searchState.selectedIndex,
                    searchState.results.indices.contains(index),
                    let path = searchState.results[index].filePath,
                    searchState.results[index].type == .folder,
                    folderPreviewPath != path
                {
                    showFolderPreviewInline(path: path)
                } else {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        showFolderPreview = false
                        folderPreviewPath = nil
                    }
                }
                return nil
            }

            // Don't intercept if in AI mode (allow typing spaces in AI queries)
            guard !aiMode.isActive else { return event }

            if let pill = currentFocusedDockPillForQuickLook(),
                quickLookDockPill(pill)
            {
                return nil
            }

            // Global grouped list (app-scope sheet): Space peeks web link rows.
            if isGlobalContextActive,
                let pill = focusedGlobalGroupedListPill(),
                pill.resolvedURL != nil,
                quickLookDockPill(pill)
            {
                return nil
            }

            if isGlobalContextActive,
                l2.pillNavViaKeyboard,
                let result = focusedGlobalAppResultForInputPreview(),
                result.type != .application,
                let path = result.filePath,
                showQuickLookURL(URL(fileURLWithPath: path), toggleIfSame: true)
            {
                return nil
            }

            // Only intercept if we have a selected result
            guard let index = searchState.selectedIndex, index < searchState.results.count else {
                return event
            }

            let result = searchState.results[index]

            // Check if the result supports preview (file, folder, or contact)
            let supportsPreview = result.filePath != nil || result.type == .contact
            guard supportsPreview else { return event }

            // Only trigger Quick Look when query is literally empty (user pressed space with nothing typed)
            // or Shift+Space. Never consume space mid-query — user may be typing multi-word searches.
            let isShiftHeld = event.modifierFlags.contains(.shift)
            let searchIsEmpty = searchState.query.isEmpty

            if isShiftHeld || searchIsEmpty {
                DispatchQueue.main.async {
                    self.quickLookSelectedItem()
                }
                return nil  // Consume the event
            }

            return event
        }
    }

    func removeQuickLookEventMonitor() {
        if let monitor = quickLookEventMonitor {
            NSEvent.removeMonitor(monitor)
            quickLookEventMonitor = nil
        }
    }

    func quickLookPanelIsVisible() -> Bool {
        QLPreviewPanel.shared()?.isVisible ?? false
    }

    func showQuickLookURL(_ url: URL, toggleIfSame: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let panel = QLPreviewPanel.shared() else { return false }
        if panel.isVisible,
            let currentDataSource = quickLookDataSource,
            currentDataSource.urls.first == url,
            toggleIfSame
        {
            panel.orderOut(nil)
            quickLookDataSource = nil
            // Spotlight-style: land focus on the result that was being previewed so Down/Up
            // continue from THERE, not from the first result. Use the previewed URL to find
            // its row (the peek may have arrow-navigated to a different file than where it
            // opened), then keep the list focused (not the input field).
            if usesVerticalListDockLayout {
                let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let pillQuery = shouldUseFinderSearchPopover(for: q) ? "" : q
                let pills =
                    pillQuery.isEmpty
                    ? selectionScopedDockPills(cachedDockPills)
                    : contextDockViewModel.visiblePills
                if let idx = pills.firstIndex(where: { $0.quickLookURL == url }) {
                    l2.focusedPillIndex = idx
                } else if l2.focusedPillIndex == nil {
                    l2.focusedPillIndex = listViewHoveredIndex
                }
                l2.pillNavViaKeyboard = true
                isSearchFieldFocused = false
            }
            return true
        }

        let dataSource = QuickLookDataSource(urls: [url])
        quickLookDataSource = dataSource
        panel.dataSource = dataSource
        panel.delegate = dataSource
        panel.reloadData()
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        if let window = AppDelegate.shared?.launcherWindow {
            window.makeKey()
            // List-view (finder desktop) results: keep the RESULT focused, not the input —
            // so when the peek closes (however it closes) the user lands back on the result
            // and can arrow to the next one (Spotlight-style), instead of in the input field.
            if usesVerticalListDockLayout {
                if l2.focusedPillIndex == nil { l2.focusedPillIndex = listViewHoveredIndex }
                l2.pillNavViaKeyboard = true
                isSearchFieldFocused = false
            } else {
                isSearchFieldFocused = true
            }
        }
        return true
    }

    /// Electron/Catalyst apps (VS Code, Slack, Discord…) usually don't expose `selectedText`
    /// via Accessibility, so the AX read returns nothing. Fallback: briefly copy the selection
    /// (synthetic ⌘C to the still-frontmost previous app), read it off the pasteboard, then
    /// RESTORE the previous pasteboard — so the selection chip works in any app. Non-destructive:
    /// the user's clipboard is preserved, and an empty selection just times out to nil.
    func peekSelectionViaClipboard(completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else { completion(nil); return }
        // Target the app that held the selection. The dock panel is key by now, so a generic
        // event post would go to the DOCK, not the selected app — deliver ⌘C to its PID.
        guard let targetPID = AppDelegate.shared?.previousFrontmostApp?.processIdentifier,
            targetPID != 0
        else { completion(nil); return }
        let pb = NSPasteboard.general

        // Snapshot the current pasteboard so we can put it back.
        let saved: [NSPasteboardItem] =
            pb.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            } ?? []
        let beforeCount = pb.changeCount
        suppressClipboardImportUntilChangeCount = beforeCount + 2

        // Synthetic ⌘C posted directly to the selected app's process (postToPid), so it lands
        // there even though the dock window currently has key focus.
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 0x08  // 'c'
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: false)
        up?.flags = .maskCommand
        down?.postToPid(targetPID)
        up?.postToPid(targetPID)

        func restore() {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
            suppressClipboardImportUntilChangeCount = pb.changeCount
            lastCheckedPasteboardCount = pb.changeCount
        }

        func poll(_ attempt: Int) {
            if pb.changeCount != beforeCount {
                let text = pb.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                restore()
                completion((text?.isEmpty == false) ? text : nil)
                return
            }
            if attempt >= 10 {  // ~200ms — copy never landed (no selection)
                suppressClipboardImportUntilChangeCount = nil
                completion(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(attempt + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(1) }
    }

    func refreshQuickLookPreviewForCurrentFocusIfVisible() {
        if showFolderPreview {
            if let index = searchState.selectedIndex,
                searchState.results.indices.contains(index),
                let path = searchState.results[index].filePath,
                path != folderPreviewPath
            {
                if searchState.results[index].type == .folder {
                    showFolderPreviewInline(path: path)
                } else {
                    showFolderPreview = false
                    folderPreviewPath = nil
                    _ = showQuickLookURL(URL(fileURLWithPath: path), toggleIfSame: false)
                }
            }
            return
        }

        if WebQuickLookPanel.shared.isVisible {
            if let pill = currentFocusedDockPillForQuickLook(),
                let url = pill.resolvedURL,
                url.scheme == "https" || url.scheme == "http"
            {
                WebQuickLookPanel.shared.show(url: url)
                return
            }
            if let pill = focusedGlobalGroupedListPill(),
                let url = pill.resolvedURL,
                url.scheme == "https" || url.scheme == "http"
            {
                WebQuickLookPanel.shared.show(url: url)
                return
            }
        }

        guard quickLookPanelIsVisible() else { return }
        if let pill = currentFocusedDockPillForQuickLook(),
            let url = pill.quickLookURL
        {
            _ = showQuickLookURL(url, toggleIfSame: false)
            return
        }
        if searchState.activeSmartQueryKey == "clipboard",
            let index = focusedClipboardEntryIndex
        {
            let entries = filteredClipboardEntriesForScope()
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
            QLPreviewPanel.shared()?.orderOut(nil)
            quickLookDataSource = nil
            showFolderPreviewInline(path: path)
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

    func findAllShortcuts() -> [SearchResult] {
        var shortcuts: [SearchResult] = []

        do {
            let query = ShortcutsLinkQuery()
            let results = try query.shortcuts()

            for shortcut in results {
                let shortcutName = shortcut.name
                let shortcutIcon = NSImage(
                    systemSymbolName: ShortcutsCatalog.iconName(for: shortcutName),
                    accessibilityDescription: shortcutName
                ) ?? ShortcutsCatalog.appIcon ?? NSWorkspace.shared.icon(forFileType: "shortcut")
                shortcuts.append(
                    SearchResult(
                        title: shortcutName,
                        subtitle: "Shortcut",
                        icon: shortcutIcon,
                        action: {
                            if let encodedName = shortcutName.addingPercentEncoding(
                                withAllowedCharacters: .urlPathAllowed),
                                let url = URL(
                                    string: "shortcuts://run-shortcut?name=\(encodedName)")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        },
                        type: .shortcut,
                        filePath: nil,
                        contactData: nil
                    ))
            }
        } catch {}

        return shortcuts.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    func findSystemFolders() -> [SearchResult] {
        var folders: [SearchResult] = []
        let fileManager = FileManager.default

        // Get user's home directory
        let homeURL = fileManager.homeDirectoryForCurrentUser

        // Common system folders with their names and icons
        let systemFolders: [(name: String, path: String, icon: String)] = [
            ("Desktop", "\(homeURL.path)/Desktop", "desktop"),
            ("Documents", "\(homeURL.path)/Documents", "doc.text.fill"),
            ("Downloads", "\(homeURL.path)/Downloads", "arrow.down.circle.fill"),
            ("Pictures", "\(homeURL.path)/Pictures", "photo.fill"),
            ("Music", "\(homeURL.path)/Music", "music.note"),
            ("Movies", "\(homeURL.path)/Movies", "film.fill"),
            ("Applications", "/Applications", "app.fill"),
            ("Library", "\(homeURL.path)/Library", "books.vertical.fill"),
            ("Public", "\(homeURL.path)/Public", "person.2.fill"),
            (
                "iCloud Drive", "\(homeURL.path)/Library/Mobile Documents/com~apple~CloudDocs",
                "icloud.fill"
            ),
        ]

        // Scan home directory for user-created folders (like MEGA, Projects, etc.)
        do {
            let homeContents = try fileManager.contentsOfDirectory(
                at: homeURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            // Get list of system folder names to exclude duplicates
            let systemFolderNames = Set(systemFolders.map { $0.name.lowercased() })

            for url in homeContents {
                // Check if it's a directory
                guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                    resourceValues.isDirectory == true
                else {
                    continue
                }

                let folderName = url.lastPathComponent

                // Skip if it's already in system folders
                guard !systemFolderNames.contains(folderName.lowercased()) else {
                    continue
                }

                // Skip hidden folders (like .ssh, .config, etc.)
                guard !folderName.hasPrefix(".") else {
                    continue
                }

                // Skip known non-interesting folders
                let skipFolders = ["Applications (Parallels)", "Parallels", "VirtualBox VMs"]
                guard !skipFolders.contains(folderName) else {
                    continue
                }

                // Add user folder with inline preview
                let folderPath = url.path
                folders.append(
                    SearchResult(
                        title: folderName,
                        subtitle: url.path,
                        icon: NSWorkspace.shared.icon(forFile: url.path),
                        action: {
                            self.showFolderPreviewInline(path: folderPath)
                        },
                        type: .folder,
                        filePath: url.path,
                        contactData: nil
                    ))

            }
        } catch {}

        // Add predefined system folders
        for folder in systemFolders {
            let folderURL = URL(fileURLWithPath: folder.path)

            // Check if folder exists
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                folders.append(
                    SearchResult(
                        title: folder.name,
                        subtitle: folder.path,
                        icon: NSImage(
                            systemSymbolName: folder.icon, accessibilityDescription: folder.name),
                        action: {
                            // Folder opening is handled in executeResult
                        },
                        type: .folder,
                        filePath: folder.path,
                        contactData: nil
                    ))
            }
        }

        return folders
    }

    func findAllContacts() async -> [SearchResult] {
        var contacts: [SearchResult] = []

        // Check if contacts search is enabled in settings
        if !settings.allowContacts { return [] }

        if !contactManager.hasContactsPermission {
            let granted = await contactManager.requestPermission()
            if !granted { return [] }
        }

        // Get all contacts for searching
        let contactResults = await contactManager.getAllContacts()

        for contactResult in contactResults {
            contacts.append(
                SearchResult(
                    title: contactResult.fullName,
                    subtitle: contactResult.subtitle,
                    icon: contactResult.image,
                    action: { [contactResult] in
                        // Default action: open in Contacts app
                        contactResult.openInContacts()
                    },
                    type: .contact,
                    filePath: nil,
                    contactData: SearchResult.ContactData(
                        primaryEmail: contactResult.primaryEmail,
                        allEmails: contactResult.allEmails,
                        primaryPhone: contactResult.primaryPhone,
                        allPhones: contactResult.allPhones,
                        identifier: contactResult.identifier
                    )
                ))
        }

        return contacts
    }

    func initializeFileIndex() {
        Task {
            await fileIndexManager.initialize()
        }
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

    func searchSystemData(for query: String) async {
        // System data (calendar, reminders, notes, mail) only appears in the
        // dedicated app panel (searchState.activeSmartQueryKey), never in normal search results.
        // This prevents clutter like "call mom" showing under CALENDAR & NOTES when
        // the user types "cal" looking for Calendar.app.
        guard !query.isEmpty else {
            await MainActor.run {
                systemDataResults = []
            }
            return
        }
        // Skip entirely when not in app panel mode
        guard
            await MainActor.run(
                resultType: Bool.self, body: { searchState.activeSmartQueryKey != nil })
        else {
            return
        }

        #if DEBUG
        print("🔍 [SystemSearch] Starting search for: '\(query)'")
        #endif

        // Search all system data types
        let systemResults = await systemDataManager.searchAll(
            query: query,
            types: [.calendarEvent, .reminder, .note, .mail, .photo, .voiceRecording],
            perTypeLimit: 5
        )

        #if DEBUG
        print("✅ [SystemSearch] Found \(systemResults.count) system data results")
        #endif
        if systemResults.isEmpty {
            print(
                "⚠️ [SystemSearch] No results found - this might indicate permission issues or no matching data"
            )
        } else {
            print(
                "📊 [SystemSearch] Result types: \(systemResults.map { "\($0.type)" }.joined(separator: ", "))"
            )
        }

        // Convert SystemSearchResult to SearchResult
        let convertedSearchResults = systemResults.map { systemResult -> SearchResult in
            // Map SystemDataType to ResultType
            let resultType: SearchResult.ResultType
            switch systemResult.type {
            case .calendarEvent:
                resultType = .calendarEvent
            case .reminder:
                resultType = .reminder
            case .note:
                resultType = .note
            case .mail:
                resultType = .mail
            case .photo:
                resultType = .photo
            case .message:
                resultType = .message
            case .voiceRecording, .contact:
                // Map voiceRecording to file type and contact is already handled separately
                resultType = .file
            }

            return SearchResult(
                title: systemResult.title,
                subtitle: systemResult.subtitle,
                icon: systemResult.icon,
                action: { systemResult.open() },
                score: 0.0,
                type: resultType,
                filePath: nil,
                contactData: nil
            )
        }

        #if DEBUG
        print("✅ [SystemSearch] Converted to \(convertedSearchResults.count) SearchResults")
        #endif

        await MainActor.run {
            #if DEBUG
            print("📝 [SystemSearch] Updating systemDataResults on main thread")
            #endif
            systemDataResults = convertedSearchResults
            #if DEBUG
            print("📝 [SystemSearch] Current systemDataResults count: \(systemDataResults.count)")
            #endif
            #if DEBUG
            print("📝 [SystemSearch] Current allItems count: \(allItems.count)")
            #endif
            // Trigger re-search on next run loop to avoid state changes during view updates
            DispatchQueue.main.async {
                performSearchWithoutSpotlight()
            }
        }
    }

    func navigateResults(direction: Int) {
        let results = searchState.results  // Capture current snapshot
        guard !results.isEmpty else {
            searchState.selectedIndex = nil
            return
        }

        // Mark as keyboard navigation for auto-scroll
        isKeyboardNavigation = true

        let movementDirection = direction

        if let currentIndex = searchState.selectedIndex {
            // Validate current index is still valid
            guard currentIndex >= 0 && currentIndex < results.count else {
                searchState.selectedIndex = 0
                return
            }

            let newIndex = currentIndex + movementDirection
            if newIndex >= 0 && newIndex < results.count {
                searchState.selectedIndex = newIndex
            } else if movementDirection < 0 {
                // At the top, stay at top
                searchState.selectedIndex = 0
            } else {
                // At the bottom, stay at bottom
                searchState.selectedIndex = results.count - 1
            }
        } else {
            searchState.selectedIndex = direction > 0 ? 0 : max(results.count - 1, 0)
        }
    }

    func executeSelectedResult() {
        // Cancel any in-flight background search task so its stale result batch
        // cannot overwrite searchState.results after the action has already fired.
        debounceTask?.cancel()
        debounceTask = nil

        // In AI mode, submit to AI provider instead
        if aiMode.isActive {
            if launchTypedAppMatchIfNeeded() {
                return
            }
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.count > 3 {
                submitAIQuery()
            }
            return
        }

        // Validate index bounds before accessing
        if let index = searchState.selectedIndex, index >= 0 && index < searchState.results.count {
            executeResult(searchState.results[index])
        } else if !searchState.results.isEmpty {
            executeResult(searchState.results[0])
        } else {
            // Try to open as URL or perform web search
            handleDirectInput()
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
        AppDelegate.shared?.hideLauncher()
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
        AppDelegate.shared?.hideLauncher(force: true)
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

    func executeResult(_ result: SearchResult) {
        // Track usage for frecency ranking
        UsageTracker.shared.recordAccess(for: result.trackingIdentifier)

        // Contacts → open context panel (contact card)
        if result.type == .contact {
            activateSearchContext(for: result)
            return
        }

        // Files, documents, and folders → Enter always opens them directly
        // (Use Tab or → to open the context panel instead)
        if result.type == .file || result.type == .document || result.type == .folder {
            result.action()
            hideLauncherAfterResultExecution()
            return
        }

        if result.type == .application {
            let bundleId =
                Bundle(url: URL(fileURLWithPath: result.subtitle))?.bundleIdentifier
            _ = launchApplication(
                bundleIdentifier: bundleId,
                appName: result.title,
                path: result.subtitle
            )
            if isGlobalContextActive {
                forceHideLauncherAfterResultExecution()
            } else {
                hideLauncherAfterResultExecution()
            }
            return
        }

        // Special handling for shortcuts with context
        if result.type == .shortcut {
            executeShortcutWithContext(result)
        } else {
            result.action()
        }

        if result.dismissesLauncher {
            hideLauncherAfterResultExecution()
        } else {
            // Stay-open actions (e.g. "Quit App" rows in Global Context):
            // keep the dock up and ready for the next query.
            searchState.query = ""
            searchState.selectedIndex = nil
            DispatchQueue.main.async { self.reclaimSearchInputFocus() }
        }
    }

    func executeL2Extension(_ ext: ILExtension, context: UserContext) async {
        await MainActor.run {
            l2.isLoading = true
            requestWindowSizeUpdate(reason: .contentSettled)
        }

        defer {
            Task { @MainActor in
                l2.isLoading = false
                requestWindowSizeUpdate(reason: .contentSettled)
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
                return do JavaScript js in currentTab
            end tell
            """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return nil
        }

        let output = scriptObject.executeAndReturnError(&error)
        if error != nil {
            return nil
        }

        let text = output.stringValue ?? ""
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

        let output = scriptObject.executeAndReturnError(&error)
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

        let output = scriptObject.executeAndReturnError(&error)
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
