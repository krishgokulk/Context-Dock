import AppKit
import ApplicationServices
import Foundation
import PDFKit
import SwiftUI

extension LauncherView {
    // MARK: - Finder AI — natural language over current folder

    func handleFinderAIQuery(query: String) {
        guard !query.isEmpty else { return }

        let scope = resolveDockScope(for: query)
        let effectiveQuery =
            scope.scopedBundleId == "com.apple.finder"
                && scope.isExplicitAppScope
                && !scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? scope.scopedSearchQuery
            : query
        let normalized = effectiveQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folderPath = currentFinderFolderPath()
        let finderFrontmostWindowActive = isFinderFrontmostWindowContext()
        let folderSearchAttached = isFinderCurrentWindowSearchAttached(
            currentFolderPath: folderPath)
        guard finderFolderQueryModeActive && folderSearchAttached else {
            clearFinderSemanticState()
            return
        }
        let selectedFileURLs = effectiveFinderSelectedFileURLs(
            for: normalized,
            currentFolderPath: folderPath
        )
        let selectedFiles = selectedFileURLs.map(\.path)

        if let pending = pendingFinderOperation {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            if isAffirmativeResponse(normalized) {
                pendingFinderOperation = nil
                runFinderIntent(pending.intent, folderPath: pending.folderPath, confirmed: true)
                return
            }
            if isNegativeResponse(normalized) {
                pendingFinderOperation = nil
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .assistant, content: "Okay, I won't reorganize that folder."))
                return
            }
        }

        if let intent = parseFinderIntent(query: normalized) {
            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.isLoading = true
            searchState.query = ""
            dismissMediaLayer()
            runFinderIntent(
                intent, folderPath: folderPath, confirmed: false, originalQuery: normalized)
            return
        }

        if isFinderSearchStyleQuery(normalized) {
            let profile = finderSemanticProfile(for: normalized)
            guard folderSearchAttached else {
                l2.chatMessages.append(AIChatMessage(role: .user, content: query))
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content:
                            finderFrontmostWindowActive
                            ? "Add the current Finder folder first, then I’ll search only the files and folders in this frontmost Finder window."
                            : "Bring Finder to the front, add the current folder, then I’ll search only the files and folders in that frontmost Finder window."
                    )
                )
                searchState.query = ""
                dismissMediaLayer()
                clearFinderSemanticState()
                return
            }

            let cachedResults = finderSemanticQuery == normalized ? finderSemanticResults : []
            if !cachedResults.isEmpty {
                l2.chatMessages.append(AIChatMessage(role: .user, content: query))
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content: finderSubmissionSummary(
                            for: effectiveQuery, results: cachedResults)
                    ))
                searchState.query = ""
                dismissMediaLayer()
                updateL2Results(cachedResults)
                return
            }

            l2.chatMessages.append(AIChatMessage(role: .user, content: query))
            l2.isLoading = true
            searchState.query = ""
            dismissMediaLayer()
            l2.currentTask = Task {
                let spotlightEnabled = settings.enableSpotlightSearch
                let advancedMatches = await MainActor.run {
                    buildAdvancedFinderDataMatches(
                        profile: profile,
                        currentFolderPath: folderPath,
                        limit: 24
                    )
                }
                let fastMatches = await buildFastFinderSemanticMatches(
                    query: normalized,
                    currentFolderPath: folderPath
                )
                let spotlightMatches =
                    spotlightEnabled && normalized.count >= 3
                    ? runFinderSpotlightSearch(
                        query: normalized,
                        currentFolderPath: folderPath,
                        limit: 18
                    )
                    : []
                let targetMatches = await buildFinderTargetSemanticMatches(
                    for: normalized,
                    currentFolderPath: folderPath,
                    spotlightEnabled: spotlightEnabled
                )
                let mergedMatches = mergeFinderSemanticMatches(
                    mergeFinderSemanticMatches(
                        mergeFinderSemanticMatches(advancedMatches, with: fastMatches),
                        with: spotlightMatches
                    ),
                    with: targetMatches
                )

                await MainActor.run {
                    let results = makeFinderSemanticSearchResults(from: mergedMatches)
                    finderSemanticQuery = normalized
                    finderSemanticResults = results
                    finderSemanticPills = makeFinderSemanticDockPills(from: mergedMatches)
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: finderSubmissionSummary(for: effectiveQuery, results: results)
                        ))
                    updateL2Results(results)
                    l2.isLoading = false
                    l2.currentTask = nil
                }
            }
            return
        }

        l2.chatMessages.append(AIChatMessage(role: .user, content: query))
        l2.isLoading = true
        searchState.query = ""
        dismissMediaLayer()

        // Snapshot everything we know about Finder right now
        let fallbackFolderPath =
            axContext.currentURL?
            .replacingOccurrences(of: "file://", with: "")
            .removingPercentEncoding
            ?? axContext.windowTitle
            ?? "unknown folder"
        // Set currentContext so on-device AI gets proper file/PDF content via buildContextPrompt
        if !selectedFileURLs.isEmpty {
            currentContext = .filesSelected(selectedFileURLs)
        }

        // Read all visible filenames in the current folder via AppleScript
        l2.currentTask = Task {
            let spotlightEnabled = settings.enableSpotlightSearch && folderSearchAttached
            let finderProfile = finderSemanticProfile(for: normalized)
            let advancedSemanticMatches =
                folderSearchAttached || finderProfile.explicitLocationPath != nil
                    || isFinderFrontmostWindowContext()
                ? await MainActor.run {
                    buildAdvancedFinderDataMatches(
                        profile: finderProfile,
                        currentFolderPath: folderPath,
                        limit: 16
                    )
                }
                : []
            let fastSemanticMatches =
                folderSearchAttached
                ? await buildFastFinderSemanticMatches(
                    query: normalized,
                    currentFolderPath: folderPath
                )
                : []
            let spotlightSemanticMatches =
                spotlightEnabled && normalized.count >= 3
                ? runFinderSpotlightSearch(
                    query: normalized,
                    currentFolderPath: folderPath,
                    limit: 12
                )
                : []
            let targetMatches =
                folderSearchAttached
                ? await buildFinderTargetSemanticMatches(
                    for: normalized,
                    currentFolderPath: folderPath,
                    spotlightEnabled: spotlightEnabled
                )
                : []
            let retrievedMatches = mergeFinderSemanticMatches(
                mergeFinderSemanticMatches(
                    advancedSemanticMatches,
                    with: fastSemanticMatches
                ),
                with: mergeFinderSemanticMatches(spotlightSemanticMatches, with: targetMatches)
            )

            // 1. Get visible files in current Finder window
            let visibleFilesScript = """
                tell application "Finder"
                    try
                        set theItems to every item of (target of front window) as alias
                        set nameList to {}
                        repeat with i in theItems
                            set end of nameList to name of i
                        end repeat
                        return nameList as string
                    end try
                end tell
                """
            var visibleFiles: [String] = []
            if let raw = await runAppleScript(visibleFilesScript), !raw.isEmpty {
                visibleFiles = raw.components(separatedBy: ", ").filter { !$0.isEmpty }
            }

            // 2. Read file content for selected files (text, PDF, code, etc.)
            var fileContentBlock = ""
            for filePath in selectedFiles.prefix(3) {
                let fileURL = URL(fileURLWithPath: filePath)
                let ext = fileURL.pathExtension.lowercased()
                let textExts = Set([
                    "txt", "md", "markdown", "swift", "py", "js", "ts", "jsx", "tsx", "html", "css",
                    "scss", "json", "xml", "yaml", "yml", "csv", "log", "sh", "bash", "zsh", "conf",
                    "config", "ini", "toml", "r", "c", "cpp", "h", "java", "go", "rs", "rb", "php",
                    "sql", "rtf",
                ])
                var content: String? = nil
                if textExts.contains(ext) {
                    content = try? String(contentsOf: fileURL, encoding: .utf8)
                    if content == nil {
                        content = try? String(contentsOf: fileURL, encoding: .isoLatin1)
                    }
                    if let c = content { content = String(c.prefix(4000)) }
                } else if ext == "pdf" {
                    if let pdf = PDFDocument(url: fileURL) {
                        var text = ""
                        for i in 0..<min(pdf.pageCount, 8) {
                            if let pageText = pdf.page(at: i)?.string { text += pageText + "\n" }
                            if text.count > 4000 { break }
                        }
                        if !text.isEmpty { content = String(text.prefix(4000)) }
                    }
                } else if ext == "docx" || ext == "rtfd" {
                    if let attr = try? NSAttributedString(
                        url: fileURL, options: [:], documentAttributes: nil)
                    {
                        content = String(attr.string.prefix(4000))
                    }
                }
                if let content, !content.isEmpty {
                    fileContentBlock +=
                        "\n\n### Content of \(fileURL.lastPathComponent):\n```\n\(content)\n```"
                }
            }

            let retrievedSummaryBlock: String = {
                guard !retrievedMatches.isEmpty else { return "" }
                let lines = retrievedMatches.prefix(8).map { match in
                    "- \(match.title) [\(match.source)] \(finderDisplayPath(match.path))"
                }
                return "\nRETRIEVED FINDER MATCHES:\n" + lines.joined(separator: "\n")
            }()

            let currentFolderCatalogBlock =
                folderSearchAttached
                ? buildFinderFileCatalogBlock(
                    currentFolderPath: folderPath,
                    selectedFilePaths: selectedFiles
                )
                : ""

            let resolvedTargetContext = buildFinderResolvedTargetContext(
                query: normalized,
                selectedFilePaths: selectedFiles,
                retrievedMatches: retrievedMatches
            )

            let retrievedContentBlock: String = {
                let candidateURLs =
                    retrievedMatches
                    .filter { !$0.isDirectory }
                    .prefix(2)
                    .map { URL(fileURLWithPath: $0.path) }
                guard !candidateURLs.isEmpty else { return "" }

                let analyzedFiles = ContextDetector.shared.analyzeFiles(Array(candidateURLs))
                var block = ""
                for file in analyzedFiles.prefix(2) {
                    guard let content = file.content,
                        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    block +=
                        "\n\n### Retrieved content from \(file.url.lastPathComponent):\n```\n\(String(content.prefix(2500)))\n```"
                }
                return block
            }()

            // 3. Build the AI prompt
            let systemPrompt = """
                You are a macOS Finder assistant embedded in Context-Dock.
                You help users with file operations AND answer questions about file contents.

                \(currentDateTimeContextBlock())

                CURRENT STATE:
                - Folder: \(fallbackFolderPath)
                - Selected files: \(selectedFiles.isEmpty ? "none" : selectedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                - Visible files in window: \(visibleFiles.isEmpty ? "unknown" : visibleFiles.prefix(30).joined(separator: ", "))
                - Finder menu actions: disabled in folder query mode
                \(retrievedSummaryBlock)
                \(currentFolderCatalogBlock)
                \(resolvedTargetContext.summaryBlock)
                \(fileContentBlock)
                \(retrievedContentBlock)
                \(resolvedTargetContext.contentBlock)

                RULES:
                1. Respond with EITHER:
                   a) ACTION:APPLESCRIPT:<applescript code on one line using \\n for newlines>
                   b) ACTION:SHELL:<shell command>
                   c) ANSWER:<plain text answer if the user asks about file contents, explanations, summaries, or informational questions>

                2. For questions about what a file contains, what it is, summarize, explain, translate — use ANSWER with the file content above.
                3. For file operations prefer AppleScript (it integrates with Finder natively).
                4. For conversions, compressions, bulk renames prefer SHELL.
                5. Do not use Finder menu actions in folder query mode.
                6. Use the EXACT filenames from the visible files list when referencing files.
                7. For selected files use: \(selectedFiles.map { "\"\($0)\"" }.joined(separator: ", "))
                8. Shell commands run in bash. $HOME = /Users/\(NSUserName()). Current dir = \(fallbackFolderPath)
                9. For ACTION responses, output ONLY the ACTION line. For ANSWER responses, provide a helpful answer.
                10. For file operations, prefer RESOLVED TARGET FILES first. If there are no resolved targets, use SELECTED FILES. If there is still ambiguity, ask a short clarification instead of guessing.
                11. When converting or chaining actions, use the exact file path from RESOLVED TARGET FILES or SELECTED FILES.

                EXAMPLES:
                User: move selected files to desktop
                ACTION:APPLESCRIPT:tell application "Finder" to move selection to (path to desktop)

                User: rename all jpg files to add today's date
                ACTION:SHELL:cd "\(fallbackFolderPath)" && for f in *.jpg; do mv "$f" "$(date +%Y-%m-%d)_$f"; done

                User: what is this file about?
                ANSWER:This file is about [summary based on the file content above].

                User: how many files are here
                ANSWER:There are \(visibleFiles.count) visible items in \(fallbackFolderPath).
                """

            do {
                let context: [[String: String]] = [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": query],
                ]

                if selectedFileURLs.isEmpty && !resolvedTargetContext.targetURLs.isEmpty {
                    await MainActor.run {
                        self.rememberFinderFollowUpTargets(
                            Array(resolvedTargetContext.targetURLs.prefix(3)),
                            folderPath: folderPath,
                            sourceQuery: normalized
                        )
                        self.currentContext = .filesSelected(
                            Array(resolvedTargetContext.targetURLs.prefix(3)))
                    }
                } else if !selectedFileURLs.isEmpty {
                    await MainActor.run {
                        self.rememberFinderFollowUpTargets(
                            Array(selectedFileURLs.prefix(3)),
                            folderPath: folderPath,
                            sourceQuery: normalized
                        )
                    }
                }

                let response = try await self.sendToProvider(query: query, context: context)

                await MainActor.run {
                    self.l2.isLoading = false
                    self.l2.currentTask = nil
                    DispatchQueue.main.async {
                        self.executeFinderAIResponse(response, folderPath: fallbackFolderPath)
                    }
                }
            } catch {
                await MainActor.run {
                    self.l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "❌ \(error.localizedDescription)",
                            isError: true
                        ))
                    self.l2.isLoading = false
                    self.l2.currentTask = nil
                }
            }
        }
    }

    func parseFinderIntent(query: String) -> FinderIntent? {
        if query.contains("organize"),
            query.contains("type") || query.contains("types") || query.contains("category")
        {
            return .organizeByType
        }

        let detectedCategory = FinderFileCategory.detect(in: query)

        if query.contains("recent"),
            detectedCategory == nil,
            !query.contains("today"),
            !query.contains("yesterday"),
            !query.contains("week"),
            !query.contains("large"),
            !query.contains("small")
        {
            return .showRecentFiles(limit: 30)
        }

        return nil
    }

    func runFinderIntent(
        _ intent: FinderIntent, folderPath: String, confirmed: Bool, originalQuery: String = ""
    ) {
        l2.currentTask?.cancel()
        l2.currentTask = Task {
            switch intent {
            case .showRecentFiles(let limit):
                let urls = recentFinderItems(in: folderPath, limit: limit)
                let summary: String
                if urls.isEmpty {
                    summary =
                        "No recent files found in \(URL(fileURLWithPath: folderPath).lastPathComponent)."
                } else {
                    summary =
                        "Found \(urls.count) recent item\(urls.count == 1 ? "" : "s") in \(URL(fileURLWithPath: folderPath).lastPathComponent). Showing newest first."
                }
                let results = buildFinderSearchResults(from: urls, subtitle: "Recent Files")
                await MainActor.run {
                    l2.chatMessages.append(AIChatMessage(role: .assistant, content: summary))
                    updateL2Results(results)
                    l2.isLoading = false
                    l2.currentTask = nil
                }

            case .filterFiles(let category):
                // For archives, further filter by a specific extension if the original query mentions one
                let lowerQuery = originalQuery.lowercased()
                let specificExt: String? = {
                    if category == .archive {
                        if lowerQuery.contains("torrent") { return "torrent" }
                        if lowerQuery.contains("dmg") { return "dmg" }
                        if lowerQuery.contains("zip") { return "zip" }
                    }
                    return nil
                }()
                let all = finderItems(in: folderPath).filter { category.matches($0) }
                let urls =
                    specificExt != nil
                    ? all.filter { $0.pathExtension.lowercased() == specificExt! }
                    : all
                let typeName = specificExt ?? category.displayName
                let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
                let summary: String
                if urls.isEmpty {
                    summary = "No \(typeName) files found in \(folderName)."
                } else {
                    let names = urls.prefix(5).map { $0.lastPathComponent }.joined(
                        separator: "\n• ")
                    summary =
                        "Found \(urls.count) \(typeName) file\(urls.count == 1 ? "" : "s") in \(folderName):\n• \(names)"
                        + (urls.count > 5 ? "\n…and \(urls.count - 5) more." : "")
                }
                let results = buildFinderSearchResults(from: urls, subtitle: category.resultTitle)
                await MainActor.run {
                    l2.chatMessages.append(AIChatMessage(role: .assistant, content: summary))
                    updateL2Results(results)
                    l2.isLoading = false
                    l2.currentTask = nil
                }

            case .organizeByType:
                if !confirmed {
                    let preview = previewOrganizeFinderItems(in: folderPath)
                    await MainActor.run {
                        if preview.moveCount == 0 {
                            l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content:
                                        "Nothing to reorganize in \(URL(fileURLWithPath: folderPath).lastPathComponent)."
                                ))
                        } else {
                            pendingFinderOperation = PendingFinderOperation(
                                intent: intent, folderPath: folderPath)
                            l2.chatMessages.append(
                                AIChatMessage(role: .assistant, content: preview.message))
                        }
                        l2.isLoading = false
                        l2.currentTask = nil
                    }
                    return
                }

                let result = organizeFinderItemsByType(in: folderPath)
                await MainActor.run {
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant, content: result.message, isError: !result.success))
                    if !result.createdFolders.isEmpty {
                        updateL2Results(
                            buildFinderSearchResults(
                                from: result.createdFolders, subtitle: "Organized Folders"))
                    }
                    l2.isLoading = false
                    l2.currentTask = nil
                }
            }
        }
    }

    func currentFinderFolderPath() -> String {
        let cachedPath = cachedFinderCurrentDirectoryPath.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !cachedPath.isEmpty {
            return cachedPath
        }

        let decodedURLPath =
            axContext.currentURL?
            .replacingOccurrences(of: "file://", with: "")
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fallback =
            (decodedURLPath?.isEmpty == false ? decodedURLPath : nil)
            ?? {
                let title = axContext.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                return title?.isEmpty == false ? title : nil
            }()

        return fallback ?? NSHomeDirectory()
    }

    func refreshCachedFinderCurrentDirectory(for bundleID: String) {
        guard bundleID == "com.apple.finder" else {
            if !cachedFinderCurrentDirectoryPath.isEmpty {
                cachedFinderCurrentDirectoryPath = ""
            }
            return
        }

        let now = Date()
        guard now.timeIntervalSince(contextDockViewModel.lastFinderDirectoryRefresh) >= 0.5 else {
            return
        }
        contextDockViewModel.lastFinderDirectoryRefresh = now

        let refreshedPath =
            ContextDetector.shared.getCurrentFinderDirectory()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cachedFinderCurrentDirectoryPath != refreshedPath {
            let hadPreviousFolder = !cachedFinderCurrentDirectoryPath.isEmpty
            cachedFinderCurrentDirectoryPath = refreshedPath
            // Finder's Edit/File menu titles bake the current folder/selection name
            // (e.g. Copy "Pictures" as Pathname, Slideshow "Pictures"). Those titles go stale the
            // moment the user navigates to another folder, but the menu snapshot is keyed only by
            // app — so a query keeps matching the old folder's baked name. Drop the Finder menu
            // snapshot on every folder change so the next query re-reads the live menus.
            if hadPreviousFolder {
                invalidateFinderMenuSnapshot()
            }
        }
    }

    /// Clears every cached Finder menu snapshot so dynamic, folder/selection-dependent menu
    /// titles are re-read live on the next dock query.
    func invalidateFinderMenuSnapshot() {
        let finderBundleId = "com.apple.finder"
        AppMenuCapabilityCache.shared.purge(bundleIdentifiers: [finderBundleId])
        if let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == finderBundleId && !$0.isTerminated
        }) {
            let pid = finder.processIdentifier
            AXMenuReader.shared.invalidateCache(for: pid)
            crossAppMenuItems.removeAll { $0.sourcePID == pid }
        }
        if frontmost.bundleID == finderBundleId || axContext.bundleId == finderBundleId {
            liveMenuItems = []
        }
        cachedDockPills = []
    }

    func isFinderFrontmostWindowContext() -> Bool {
        if frontmost.bundleID == "com.apple.finder" { return true }
        if contextTargetApp()?.bundleIdentifier == "com.apple.finder" { return true }
        return axContext.bundleId == "com.apple.finder"
    }

    /// Returns true when Finder has at least one real folder/browser window visible.
    /// Checks CGWindowList for Finder-owned, layer-0, titled, non-tiny windows.
    /// Does NOT require Finder to be the frontmost app (works while dock is active).
    func finderHasActiveWindow() -> Bool {
        guard
            let finderApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.finder"
            })
        else { return false }

        let pid = Int(finderApp.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for info in list {
            guard let wpid = info[kCGWindowOwnerPID as String] as? Int, wpid == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0
            else { continue }
            // Service/background windows have no title; real folder windows do.
            guard let name = info[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            // Require meaningful size to exclude 0×0 service windows.
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat,
               w > 50 && h > 50 { return true }
        }
        return false
    }

    /// True when Finder is frontmost (or scoped via chip) but only the desktop is visible (no folder window).
    /// In this state the dock behaves like a "no-app" global context.
    var isFinderDesktopOnlyMode: Bool {
        let finderBundleId = "com.apple.finder"
        // An explicit inline app scope (e.g. typing "xcode" in global context) means the user is
        // asking for THAT app's menus — it must win over Finder's desktop file search even though
        // Finder is the frontmost app. Without this guard the desktop-mode early-return in
        // buildDockPills hijacks the scoped query and shows Files & Folders under the wrong chip.
        let hasNonFinderInlineScope =
            (globalInlineAppScope.map { $0.bundleId != finderBundleId } ?? false)
            || additionalGlobalInlineAppScopes.contains { $0.bundleId != finderBundleId }
        // Right-arrow scoping a running app stores it in l2.targetApp — same intent:
        // show THAT app's menus, not Finder's desktop files, even though Finder is the
        // real frontmost app behind the dock.
        let hasNonFinderTargetApp =
            (l2.targetApp?.bundleId).map { $0 != finderBundleId } ?? false
        guard !hasNonFinderInlineScope, !hasNonFinderTargetApp else { return false }
        // Use l2.targetApp for explicit chip pin — avoids resolveDockScope which is
        // query-dependent and returns wrong results when query matches menu items in other apps.
        // Global Context pins the Finder scope in globalInlineAppScope (not l2.targetApp),
        // so honour that too — otherwise the Finder chip in Global Context never enters
        // desktop file-search and shows no files/folders.
        let explicitFinderScope = l2.targetApp?.bundleId == finderBundleId
            || globalInlineAppScope?.bundleId == finderBundleId
        // In Global Context, desktop file-search is ONLY for an explicit Finder
        // chip. Do not fall into it just because Finder is the frontmost app —
        // plain Global Context must stay apps/commands/running, not files.
        if isGlobalContextActive {
            return explicitFinderScope
        }
        let isFinderContext = frontmost.bundleID == finderBundleId
            || axContext.bundleId == finderBundleId
            || explicitFinderScope
        // Explicitly scoping Finder (strip icon / right-arrow) always means "search files" —
        // desktop file-search regardless of whether a Finder window is open.
        return isFinderContext && (explicitFinderScope || !finderHasActiveWindow())
    }

    func isFinderCurrentWindowSearchAttached(currentFolderPath: String? = nil) -> Bool {
        guard isFinderFrontmostWindowContext() else { return false }
        return isFinderFolderSearchAttached(currentFolderPath: currentFolderPath)
    }

    func shouldUseFinderSearchPopover(for query: String) -> Bool {
        // File search popup removed — folder path used as AI context only.
        return false
    }

    func shouldKeepFinderSearchPopoverVisible(for query: String) -> Bool {
        return false
    }

    func isFinderFolderSearchModeEnabled(for query: String) -> Bool {
        // File search results disabled — the attached folder path flows into AI context only.
        return false
    }

    func shouldShowFinderSearchResultsPanel(for query: String) -> Bool {
        // File search results panel removed — folder path is used as AI context only.
        return false
    }

    func applyFinderSemanticPanelResults(_ results: [SearchResult]) {
        // Finder search results are shown as dock pills only (finderSemanticPills).
        // We don't populate the results list above the dock — pills are the UI.
        guard showContextInDock, !showMediaLayer else { return }
        if !isSearchBarExpanded && !results.isEmpty {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isSearchBarExpanded = true
            }
        }
        // Clear any stale results from previous queries rather than showing a list
        searchState.results = []
        searchState.grouped = {
            var grouped = GroupedResults()
            results.forEach { grouped.add($0) }
            return grouped
        }()
        searchState.selectedIndex = nil
    }

    func finderItems(in folderPath: String) -> [URL] {
        let folderURL = URL(fileURLWithPath: folderPath)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .contentModificationDateKey, .localizedNameKey,
        ]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []

        return urls.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    func recentFinderItems(in folderPath: String, limit: Int) -> [URL] {
        finderItems(in: folderPath)
            .sorted {
                let lhs =
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                let rhs =
                    (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .prefix(limit)
            .map { $0 }
    }

    func buildFinderSearchResults(from urls: [URL], subtitle: String) -> [SearchResult] {
        urls.map { url in
            let path = url.path
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let resultType: SearchResult.ResultType = {
                if isDirectory { return .folder }
                let ext = url.pathExtension.lowercased()
                if ["pdf", "txt", "md", "doc", "docx", "pages", "rtf"].contains(ext) {
                    return .document
                }
                return .file
            }()

            return SearchResult(
                title: url.lastPathComponent,
                subtitle: subtitle,
                icon: NSWorkspace.shared.icon(forFile: path),
                action: {
                    rememberFinderFollowUpTargets(
                        [url],
                        folderPath: url.deletingLastPathComponent().path,
                        sourceQuery: url.lastPathComponent
                    )
                    NSWorkspace.shared.open(url)
                },
                score: 0.0,
                type: resultType,
                filePath: path,
                contactData: nil
            )
        }
    }

    func previewOrganizeFinderItems(in folderPath: String) -> (
        moveCount: Int, message: String
    ) {
        let items = finderItems(in: folderPath).filter { !($0.hasDirectoryPath) }
        var bucketCounts: [(FinderFileCategory, Int)] = []
        var examples: [String] = []

        for category in FinderFileCategory.allCases where category != .folder {
            let matches = items.filter { category.matches($0) }
            guard !matches.isEmpty else { continue }
            bucketCounts.append((category, matches.count))
            for url in matches.prefix(2) {
                examples.append("• \(url.lastPathComponent) → \(category.destinationFolderName)/")
            }
        }

        let moveCount = bucketCounts.reduce(0) { $0 + $1.1 }
        guard moveCount > 0 else {
            return (0, "")
        }

        var lines = [
            "I can organize \(URL(fileURLWithPath: folderPath).lastPathComponent) by type:"
        ]
        lines.append(contentsOf: bucketCounts.map { "- \($0.0.destinationFolderName): \($0.1)" })
        if !examples.isEmpty {
            lines.append("")
            lines.append("Preview:")
            lines.append(contentsOf: examples.prefix(6))
        }
        lines.append("")
        lines.append("Shall I proceed?")
        return (moveCount, lines.joined(separator: "\n"))
    }

    func organizeFinderItemsByType(in folderPath: String) -> (
        success: Bool, message: String, createdFolders: [URL]
    ) {
        let items = finderItems(in: folderPath).filter { !($0.hasDirectoryPath) }
        guard !items.isEmpty else {
            return (
                true,
                "No files found to organize in \(URL(fileURLWithPath: folderPath).lastPathComponent).",
                []
            )
        }

        let baseURL = URL(fileURLWithPath: folderPath)
        let fileManager = FileManager.default
        var movedCount = 0
        var createdFolders: [URL] = []
        var failures: [String] = []

        for fileURL in items {
            guard
                let category = FinderFileCategory.allCases.first(where: {
                    $0 != .folder && $0.matches(fileURL)
                })
            else {
                continue
            }

            let destinationFolder = baseURL.appendingPathComponent(
                category.destinationFolderName, isDirectory: true)
            if !fileManager.fileExists(atPath: destinationFolder.path) {
                do {
                    try fileManager.createDirectory(
                        at: destinationFolder, withIntermediateDirectories: true)
                    createdFolders.append(destinationFolder)
                } catch {
                    failures.append("Couldn't create \(category.destinationFolderName)")
                    continue
                }
            }

            let destinationURL = uniqueFinderDestination(for: fileURL, in: destinationFolder)
            do {
                try fileManager.moveItem(at: fileURL, to: destinationURL)
                movedCount += 1
            } catch {
                failures.append("Couldn't move \(fileURL.lastPathComponent)")
            }
        }

        let folderLabel = URL(fileURLWithPath: folderPath).lastPathComponent
        if movedCount == 0 {
            let failureText =
                failures.isEmpty
                ? "No matching files needed organizing." : failures.joined(separator: "\n")
            return (false, failureText, createdFolders)
        }

        var lines = ["Organized \(movedCount) file\(movedCount == 1 ? "" : "s") in \(folderLabel)."]
        if !createdFolders.isEmpty {
            lines.append(
                "Created \(createdFolders.count) folder\(createdFolders.count == 1 ? "" : "s").")
        }
        if !failures.isEmpty {
            lines.append("")
            lines.append("Some items were skipped:")
            lines.append(contentsOf: failures.prefix(5))
        }
        return (failures.isEmpty, lines.joined(separator: "\n"), createdFolders)
    }

    func uniqueFinderDestination(for fileURL: URL, in folderURL: URL) -> URL {
        let fileManager = FileManager.default
        let ext = fileURL.pathExtension
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        var candidate = folderURL.appendingPathComponent(fileURL.lastPathComponent)
        var index = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
            candidate = folderURL.appendingPathComponent(name)
            index += 1
        }

        return candidate
    }

    func executeFinderAIResponse(_ response: String, folderPath: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("ACTION:APPLESCRIPT:") {
            let script = String(trimmed.dropFirst("ACTION:APPLESCRIPT:".count))
                .replacingOccurrences(of: "\\n", with: "\n")
            l2.chatMessages.append(
                AIChatMessage(role: .assistant, content: "```applescript\n\(script)\n```"))
            Task.detached(priority: .userInitiated) {
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                if let err {
                    let message = err["NSAppleScriptErrorMessage"] as? String ?? "Script error"
                    await MainActor.run {
                        self.l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: "⚠️ \(message)",
                                isError: true))
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                await MainActor.run {
                    if let app = NSWorkspace.shared.runningApplications.first(where: {
                        $0.bundleIdentifier == "com.apple.finder"
                    }) {
                        AXMenuReader.shared.invalidateCache(for: app.processIdentifier)
                        self.reloadMenuForApp(app)
                    }
                }
            }

        } else if trimmed.hasPrefix("ACTION:SHELL:") {
            let cmd = String(trimmed.dropFirst("ACTION:SHELL:".count))
            l2.chatMessages.append(AIChatMessage(role: .assistant, content: "```bash\n\(cmd)\n```"))
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.launchPath = "/bin/bash"
                process.arguments = ["-c", cmd]
                process.currentDirectoryPath = folderPath
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try? process.run()
                process.waitUntilExit()
                let output =
                    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? ""
                let createdURL =
                    process.terminationStatus == 0
                    ? await MainActor.run { self.detectCreatedFile(command: cmd, output: output) }
                    : nil
                await MainActor.run {
                    let status =
                        process.terminationStatus == 0
                        ? "✅ Done" : "❌ Failed (exit \(process.terminationStatus))"
                    let msg =
                        output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? status
                        : "\(status)\n```\n\(output.prefix(500))\n```"
                    self.l2.chatMessages.append(AIChatMessage(role: .assistant, content: msg))
                    if let createdURL {
                        self.rememberFinderFollowUpTargets(
                            [createdURL],
                            folderPath: createdURL.deletingLastPathComponent().path,
                            sourceQuery: cmd
                        )
                        self.currentContext = .filesSelected([createdURL])
                    }
                    ILauncherNotificationManager.shared.shellFinished(
                        command: cmd,
                        exitCode: process.terminationStatus
                    )
                }
            }

        } else if trimmed.hasPrefix("ACTION:MENU:") {
            let menuTitle = String(trimmed.dropFirst("ACTION:MENU:".count))
            l2.chatMessages.append(AIChatMessage(role: .assistant, content: "▶ \(menuTitle)"))
            if let item = liveMenuItems.first(where: {
                $0.title.lowercased() == menuTitle.lowercased()
            }),
                let pid = NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == "com.apple.finder" })?.processIdentifier
            {
                executeDockMenuAction(
                    sourcePID: pid,
                    path: item.path,
                    shortcutChar: item.shortcutChar,
                    shortcutModifiers: item.shortcutModifiers
                )
            }

        } else if trimmed.hasPrefix("ANSWER:") {
            let answer = String(trimmed.dropFirst("ANSWER:".count))
            l2.chatMessages.append(AIChatMessage(role: .assistant, content: answer))

        } else {
            // Model didn't follow the format — show the raw response
            l2.chatMessages.append(AIChatMessage(role: .assistant, content: trimmed))
        }
    }

    @discardableResult
    func runAppleScript(_ source: String) async -> String? {
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                guard let s = NSAppleScript(source: source) else {
                    cont.resume(returning: nil)
                    return
                }
                let result = s.executeAndReturnError(&err)
                cont.resume(returning: result.stringValue)
            }
        }
    }

}
