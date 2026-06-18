import AppKit
import Foundation
import PDFKit
import SwiftUI

extension LauncherView {
    // MARK: - Unified dock pill list (drives both rendering and keyboard navigation)

    /// A lightweight token for each pill currently visible in the dock.
    struct ClipboardEntry: Identifiable, Codable {
        let id: UUID
        let text: String
        let timestamp: Date
        var filePaths: [String] = []
        var imageData: Data? = nil
        var ocrText: String = ""
        var sourceAppName: String = ""
        var sourceBundleId: String = ""

        init(
            id: UUID = UUID(),
            text: String,
            timestamp: Date,
            filePaths: [String] = [],
            imageData: Data? = nil,
            ocrText: String = "",
            sourceAppName: String = "",
            sourceBundleId: String = ""
        ) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.filePaths = filePaths
            self.imageData = imageData
            self.ocrText = ocrText
            self.sourceAppName = sourceAppName
            self.sourceBundleId = sourceBundleId
        }

        var isImage: Bool { imageData != nil }
        var isURL: Bool {
            filePaths.isEmpty && !isImage && URL(string: text)?.scheme != nil
                && text.contains("://")
        }
        var isFilePath: Bool {
            !isImage && (!filePaths.isEmpty || text.hasPrefix("/") || text.hasPrefix("file://"))
        }
        var fileCount: Int { filePaths.isEmpty ? (isFilePath ? 1 : 0) : filePaths.count }
        var folderCount: Int {
            filePaths.filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }.count
        }
        var icon: String {
            if isImage { return "photo" }
            if folderCount > 0 && folderCount == fileCount {
                return fileCount > 1 ? "folder.fill.badge.plus" : "folder"
            }
            if fileCount > 1 { return "doc.on.doc" }
            if isFilePath { return "doc" }
            if isURL { return "link" }
            return "doc.on.clipboard"
        }
        var preview: String {
            if isImage { return "Image" }
            if !filePaths.isEmpty {
                if filePaths.count == 1 {
                    return URL(fileURLWithPath: filePaths[0]).lastPathComponent
                }
                if folderCount > 0 && folderCount == filePaths.count {
                    return "\(filePaths.count) folders"
                }
                return "\(filePaths.count) items"
            }
            let s = isURL ? (URL(string: text)?.host ?? text) : text
            return String(s.prefix(55))
        }
    }

    struct InstalledAppMenuTarget {
        let appName: String
        let bundleId: String
        let appPath: String
        let actionQuery: String
        let matchedAlias: String
        let aliasStartIndex: Int
    }

    struct GlobalInlineAppScope {
        let appName: String
        let bundleId: String
        let appPath: String
        var matchedAlias: String
        var aliasStartIndex: Int
    }

    struct DockScopeResolution {
        let scopedBundleId: String
        let scopedAppName: String
        let scopedSearchQuery: String
        let isExplicitAppScope: Bool
        let isGlobalScope: Bool
    }

    // MARK: - Finder selected-file context pills

    func finderSelectionSignature(_ paths: [String]) -> String {
        paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
    }

    func finderSelectionSignature(_ urls: [URL]) -> String {
        finderSelectionSignature(urls.map(\.path))
    }

    func isDismissedFinderSelection(_ paths: [String]) -> Bool {
        guard let dismissedFinderSelectionSignature,
            !dismissedFinderSelectionSignature.isEmpty,
            !paths.isEmpty
        else { return false }
        return finderSelectionSignature(paths) == dismissedFinderSelectionSignature
    }

    func isDismissedFinderSelection(_ urls: [URL]) -> Bool {
        isDismissedFinderSelection(urls.map(\.path))
    }

    func isSuppressedAutomaticFinderSelection(_ paths: [String]) -> Bool {
        guard let signature = suppressedAutomaticFinderSelectionSignature,
            !signature.isEmpty,
            !paths.isEmpty
        else { return false }
        return finderSelectionSignature(paths) == signature
    }

    func isSuppressedAutomaticFinderSelection(_ urls: [URL]) -> Bool {
        isSuppressedAutomaticFinderSelection(urls.map(\.path))
    }

    var isAutomaticGlobalContextTemporarilySuppressed: Bool {
        Date() < suppressAutomaticGlobalContextUntil
    }

    func updateSuppressedAutomaticFinderSelectionAfterSelectionChange(_ paths: [String]) {
        guard let signature = suppressedAutomaticFinderSelectionSignature else { return }
        if paths.isEmpty || finderSelectionSignature(paths) != signature {
            suppressedAutomaticFinderSelectionSignature = nil
        }
    }

    func suppressCurrentFinderSelectionBaseline() {
        let paths = canonicalExistingURLs(ContextDetector.shared.getFinderSelectedFiles()).map(\.path)
        suppressedAutomaticFinderSelectionSignature =
            paths.isEmpty ? nil : finderSelectionSignature(paths)
    }

    func updateDismissedFinderSelectionAfterSelectionChange(_ paths: [String]) {
        guard let dismissedFinderSelectionSignature else { return }
        if paths.isEmpty || finderSelectionSignature(paths) != dismissedFinderSelectionSignature {
            self.dismissedFinderSelectionSignature = nil
        }
    }

    func effectiveFinderSelectionURLsForPills() -> [URL] {
        if isAutomaticGlobalContextTemporarilySuppressed { return [] }

        let frozenSelection = frozenSelectionFileURLs
        if !frozenSelection.isEmpty {
            return isDismissedFinderSelection(frozenSelection) ? [] : frozenSelection
        }

        let liveSelection = canonicalExistingURLs(
            axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        )
        if !liveSelection.isEmpty {
            if isSuppressedAutomaticFinderSelection(liveSelection) { return [] }
            return isDismissedFinderSelection(liveSelection) ? [] : liveSelection
        }

        if case .filesSelected(let urls) = currentContext {
            let contextSelection = canonicalExistingURLs(urls)
            if !contextSelection.isEmpty {
                if isSuppressedAutomaticFinderSelection(contextSelection) { return [] }
                return isDismissedFinderSelection(contextSelection) ? [] : contextSelection
            }
        }

        return []
    }

    /// When Finder is frontmost and files are selected, generate instant-action pills
    /// for those files so they appear *before* the generic adapter pills.
    func buildFinderFilePills(query q: String) -> [DockPill] {
        let selectedURLs = effectiveFinderSelectionURLsForPills()
        guard !selectedURLs.isEmpty else { return [] }
        let paths = selectedURLs.map(\.path)
        let count = paths.count
        let first = paths[0]
        let firstName = URL(fileURLWithPath: first).lastPathComponent
        let label = count == 1 ? firstName : "\(count) items selected"
        let ext = URL(fileURLWithPath: first).pathExtension.lowercased()
        let imageExtsForFinderSelection = [
            "jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp", "svg",
        ]

        // Pills that always make sense for any selection
        var pills: [DockPill] = []

        func add(
            _ id: String, _ name: String, _ icon: String, _ color: String,
            _ action: @escaping () -> Void
        ) {
            if !q.isEmpty && !name.lowercased().contains(q) { return }
            pills.append(
                DockPill(
                    id: "finder-ctx-\(id)", name: name, icon: icon,
                    accentColorName: color, badge: label, execute: action))
        }

        add("ql", "Quick Look", "eye", "blue") {
            NSWorkspace.shared.activateFileViewerSelecting(
                paths.compactMap { URL(fileURLWithPath: $0) })
        }
        add("open", "Open", "arrow.up.right.square", "blue") {
            for p in paths { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
        add("reveal", "Show in Finder", "folder", "gray") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
        }
        add("copypath", "Copy Path", "doc.on.clipboard", "teal") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(paths.joined(separator: "\n"), forType: .string)
        }
        add("share", "Share…", "square.and.arrow.up", "blue") {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            presentSharingPicker(items: urls)
        }
        if count > 1 {
            add("new-folder-selection", "New Folder with Selection", "folder.badge.plus", "green") {
                executeFinderSelectionMenuAction(titleContains: "new folder with selection")
            }
        }
        add("compress", count > 1 ? "Compress \(count) Items" : "Compress", "archivebox", "yellow")
        {
            executeFinderSelectionMenuAction(titleContains: "compress")
        }
        if selectedURLs.allSatisfy({
            imageExtsForFinderSelection.contains($0.pathExtension.lowercased())
        }) {
            add("create-pdf", "Create PDF", "doc.richtext", "red") {
                createPDFFromFinderSelectionImages(selectedURLs)
            }
            add("rotate-left", "Rotate Left", "rotate.left", "blue") {
                executeFinderSelectionMenuAction(titleContains: "rotate left")
            }
            add("markup", "Markup", "pencil.tip.crop.circle", "blue") {
                executeFinderSelectionMenuAction(titleContains: "markup")
            }
            add("remove-background", "Remove Background", "person.crop.rectangle", "purple") {
                executeFinderSelectionMenuAction(titleContains: "remove background")
            }
            add("convert-image", "Convert Image", "photo.stack", "purple") {
                executeFinderSelectionMenuAction(titleContains: "convert image")
            }
            add("set-wallpaper", "Set as Wallpaper", "photo.fill", "green") {
                executeFinderSelectionMenuAction(titleContains: "set as wallpaper")
            }
        }
        add("trash", "Move to Bin", "trash", "red") {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            var failures: [String] = []
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if failures.isEmpty {
                AppToast.show(
                    urls.count == 1 ? "Moved to Bin" : "\(urls.count) items moved to Bin",
                    icon: "trash",
                    tint: .red.opacity(0.9)
                )
                axContext.selectedFilePaths.removeAll()
                if case .filesSelected = currentContext {
                    currentContext = .none
                }
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
            } else {
                AppToast.show(
                    "Could not move to Bin: \(failures.prefix(2).joined(separator: ", "))",
                    icon: "exclamationmark.triangle",
                    tint: .orange
                )
            }
        }

        // Extension-aware pills
        let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp", "svg"]
        let videoExts = ["mp4", "mov", "m4v", "avi", "mkv", "wmv"]
        let archiveExts = ["zip", "tar", "gz", "bz2", "xz", "7z", "rar"]
        let textExts = [
            "txt", "md", "markdown", "rtf", "csv", "json", "xml", "yaml", "yml", "toml", "log",
        ]
        let pdfExts = ["pdf"]

        func openInApp(_ fileURL: URL, appName: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", appName, fileURL.path]
            try? proc.run()
        }

        if imageExts.contains(ext) {
            add("preview-img", "Open in Preview", "photo", "purple") {
                openInApp(URL(fileURLWithPath: first), appName: "Preview")
            }
        }
        if videoExts.contains(ext) {
            add("play", "Play in QuickTime", "play.circle", "red") {
                openInApp(URL(fileURLWithPath: first), appName: "QuickTime Player")
            }
        }
        if pdfExts.contains(ext) {
            add("preview-pdf", "Open in Preview", "doc.richtext", "red") {
                openInApp(URL(fileURLWithPath: first), appName: "Preview")
            }
        }
        if archiveExts.contains(ext) {
            add("unzip", "Unarchive", "archivebox.circle", "yellow") {
                let dir = URL(fileURLWithPath: first).deletingLastPathComponent().path
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", first, "-d", dir]
                try? proc.run()
            }
        }
        if textExts.contains(ext) {
            add("texteditor", "Open in TextEdit", "doc.plaintext", "gray") {
                openInApp(URL(fileURLWithPath: first), appName: "TextEdit")
            }
        }
        return pills
    }

    func createPDFFromFinderSelectionImages(_ urls: [URL]) {
        let imageURLs = canonicalExistingURLs(urls).filter { url in
            ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp"]
                .contains(url.pathExtension.lowercased())
        }
        guard !imageURLs.isEmpty else {
            AppToast.show("No images selected", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        let document = PDFDocument()
        for url in imageURLs {
            guard let image = NSImage(contentsOf: url),
                let page = PDFPage(image: image)
            else { continue }
            document.insert(page, at: document.pageCount)
        }

        guard document.pageCount > 0 else {
            AppToast.show("Could not create PDF", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        let baseDirectory = imageURLs[0].deletingLastPathComponent()
        let baseName =
            imageURLs.count == 1
            ? imageURLs[0].deletingPathExtension().lastPathComponent
            : "Selected Images"
        let outputURL = uniqueFinderOutputURL(
            directory: baseDirectory,
            baseName: baseName,
            extensionName: "pdf"
        )

        guard document.write(to: outputURL) else {
            AppToast.show("Could not save PDF", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        AppToast.show("Created \(outputURL.lastPathComponent)", icon: "doc.richtext", tint: .blue)
        rememberFinderFollowUpTargets(
            [outputURL],
            folderPath: baseDirectory.path,
            sourceQuery: "create pdf"
        )
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        searchState.query = ""
        l2.focusedPillIndex = nil
    }

    func uniqueFinderOutputURL(directory: URL, baseName: String, extensionName: String) -> URL {
        let cleanedBaseName =
            baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = directory
            .appendingPathComponent(cleanedBaseName)
            .appendingPathExtension(extensionName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(cleanedBaseName) \(suffix)")
                .appendingPathExtension(extensionName)
            suffix += 1
        }
        return candidate
    }

    func buildFinderHomeFolderPills(query q: String) -> [DockPill] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.hasPrefix("+") else { return [] }
        guard query.count >= 2 else { return [] }
        guard
            frontmost.bundleID == "com.apple.finder"
                || l2.targetApp?.bundleId == "com.apple.finder"
                || axContext.bundleId == "com.apple.finder"
        else { return [] }
        guard effectiveFinderSelectionURLsForPills().isEmpty else { return [] }

        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let currentFolder = URL(fileURLWithPath: currentFinderFolderPath()).standardizedFileURL.path
        // Desktop mode = no Finder window, user is on ~/Desktop which is inside ~.
        // Any Finder context inside the home tree should show home folder pills.
        guard
            isFinderDesktopOnlyMode
                || currentFolder == home
                || currentFolder.hasPrefix(home + "/")
        else { return [] }
        let searchRoot = home
        var seen = Set<String>()
        var candidates: [(url: URL, isDirectory: Bool, score: Double)] = []

        func addCandidate(_ url: URL, isDirectory: Bool, score: Double) {
            let path = url.standardizedFileURL.path
            guard path == searchRoot || path.hasPrefix(searchRoot + "/") else { return }
            guard !url.lastPathComponent.hasPrefix(".") else { return }
            guard seen.insert(path).inserted else { return }
            candidates.append((URL(fileURLWithPath: path), isDirectory, score))
        }

        let indexed = fileIndexManager.advancedSearch(
            AdvancedFileSearchQuery(
                rootPath: searchRoot,
                residualQuery: query,
                includeDirectories: true,
                filesOnly: false,
                limit: 48
            ))
        for file in indexed {
            let url = URL(fileURLWithPath: file.path)
            guard let nameScore = strictFinderHomeSearchScore(query: query, url: url) else {
                continue
            }
            let depthPenalty = max(
                0,
                file.path.replacingOccurrences(of: searchRoot, with: "").split(separator: "/").count
                    - 1)
            addCandidate(
                url,
                isDirectory: file.isDirectory,
                score: nameScore + (file.isDirectory ? 90 : 30) - Double(depthPenalty * 8)
            )
        }

        // Instant fallback before Spotlight finishes: direct Home children and common Home folders.
        let fallbackRoots = [
            searchRoot,
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs",
        ]
        for root in fallbackRoots {
            guard candidates.count < 16,
                let items = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            for url in items {
                guard let score = strictFinderHomeSearchScore(query: query, url: url) else {
                    continue
                }
                let values =
                    (try? url.resourceValues(forKeys: [.isDirectoryKey])) ?? URLResourceValues()
                let isDirectory = values.isDirectory ?? url.hasDirectoryPath
                addCandidate(url, isDirectory: isDirectory, score: score + (isDirectory ? 75 : 20))
            }
        }

        return
            candidates
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.url.lastPathComponent.localizedCaseInsensitiveCompare(
                    $1.url.lastPathComponent)
                    == .orderedAscending
            }
            .prefix(10)
            .map { candidate in
                let url = candidate.url
                let itemPath = url.standardizedFileURL.path
                let displayParent = finderDisplayPath(url.deletingLastPathComponent().path)
                var pill = DockPill(
                    id: "finder-home-search-\(itemPath)",
                    name: url.lastPathComponent,
                    icon: candidate.isDirectory
                        ? "folder.fill"
                        : finderSemanticSymbol(
                            for: FinderSemanticMatch(
                                path: itemPath,
                                title: url.lastPathComponent,
                                subtitle: "",
                                isDirectory: candidate.isDirectory,
                                score: candidate.score,
                                source: "Home",
                                searchTerms: []
                            )),
                    accentColorName: candidate.isDirectory ? "blue" : "teal",
                    badge: displayParent == "~" ? "Home" : displayParent,
                    execute: {
                        UsageTracker.shared.recordAccess(
                            for: finderGoToTrackingIdentifier(for: itemPath))
                        rememberFinderFollowUpTargets(
                            [url],
                            folderPath: candidate.isDirectory
                                ? itemPath : url.deletingLastPathComponent().path,
                            sourceQuery: query
                        )
                        NSWorkspace.shared.open(url)
                        searchState.query = ""
                        l2.focusedPillIndex = nil
                    }
                )
                pill.menuItemImage = NSWorkspace.shared.icon(forFile: itemPath)
                pill.sourceBundleId = "com.apple.finder"
                pill.sourceAppName = "Finder"
                pill.rankingKind = candidate.isDirectory ? "finderGoTo" : "finderSearch"
                pill.quickLookURL = url
                pill.trackingIdentifier =
                    candidate.isDirectory
                    ? finderGoToTrackingIdentifier(for: itemPath)
                    : "finder-home-search:\(itemPath.lowercased())"
                pill.searchTerms = [
                    url.lastPathComponent,
                    itemPath,
                    displayParent,
                    "finder",
                    "home",
                    candidate.isDirectory ? "folder" : "file",
                ]
                pill.rankingScore = candidate.score
                return pill
            }
    }

    func buildFinderDesktopModePills(query: String) -> [DockPill] {
        let selectedURLs = effectiveFinderSelectionURLsForPills()
        if !selectedURLs.isEmpty {
            let combinedSelectionPills = buildMacOSExtensionActionPills(query: query)
            if !combinedSelectionPills.isEmpty {
                return combinedSelectionPills
            }
            if !query.isEmpty {
                return []
            }
        }

        let syncBase: [DockPill]
        if query.isEmpty {
            // finderDesktopRecentPills already contains running apps + recent files
            syncBase = finderDesktopRecentPills
        } else {
            // Instant filter:
            // finderDesktopIndexedPills = all user-folder files (pre-loaded at mode entry)
            // finderDesktopRecentPills  = running apps + recent files
            let q = query.lowercased()
            let runningMatches = finderDesktopRecentApplicationPills(query: query)
            let allCached = finderDesktopIndexedPills + finderDesktopRecentPills
            let fileMatches = allCached.filter { pill in
                pill.rankingKind != "finderRecentApp"
                    && (pill.name.lowercased().contains(q)
                        || pill.searchTerms.contains { $0.lowercased().contains(q) })
            }
            syncBase = runningMatches + fileMatches
        }
        let base =
            finderDesktopSearchQuery == query && !finderDesktopSearchPills.isEmpty
            ? syncBase + finderDesktopSearchPills
            : syncBase
        // Running apps always above files/folders
        let deduped = dedupeFinderDesktopPills(base)
        let apps = deduped.filter { $0.rankingKind == "finderRecentApp" }
        let files = deduped.filter { $0.rankingKind != "finderRecentApp" }
        return apps + files
    }

    func commitFinderDesktopModeSnapshot(query: String, preserveFocus: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        dockPillBuildGeneration &+= 1
        contextDockViewModel.clearPendingPillBuild(cancelBuild: true)

        let ranked = rankDockPills(
            buildFinderDesktopModePills(query: q),
            rawQuery: q,
            rankingQuery: q,
            scopedBundleId: "com.apple.finder",
            scopedAppName: "Finder",
            isExplicitAppScope: false,
            includeNonMatching: q.isEmpty
        )
        replaceCachedDockPills(ranked, preserveFocus: preserveFocus)
        lastPillQuery = q
    }

    func finderDesktopRecentApplicationPills(query: String) -> [DockPill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Running apps only — no Apple recent-items list.
        // Recently-used-but-closed apps clutter the desktop launcher; running apps are immediately actionable.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder" }
        let matching = running.filter { app in
            guard !q.isEmpty else { return true }
            let name = app.localizedName ?? ""
            let bundleId = app.bundleIdentifier ?? ""
            return name.lowercased().contains(q) || bundleId.lowercased().contains(q)
        }
        // Non-empty query → only matching apps; empty → all running.
        let source = q.isEmpty ? running : matching
        return source.prefix(10).compactMap { app -> DockPill? in
            guard let url = app.bundleURL else { return nil }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            var pill = makeDesktopPill(
                path: url.path,
                name: name,
                badge: "Running",
                rankingKind: "finderRecentApp",
                query: nil
            )
            pill.menuItemImage = app.icon
            pill.sourceBundleId = app.bundleIdentifier ?? ""
            pill.sourceAppName = name
            pill.trackingIdentifier = "finder-running-app:\(app.bundleIdentifier ?? url.path)"
            pill.searchTerms = [name, app.bundleIdentifier ?? "", "running", "app"]
            pill.rankingScore = 1_500
            return pill
        }
    }

    func dedupeFinderDesktopPills(_ pills: [DockPill]) -> [DockPill] {
        var seen = Set<String>()
        var deduped: [DockPill] = []
        for pill in pills {
            let key: String = {
                if let path = pill.resolvedURL?.path.lowercased(), !path.isEmpty { return path }
                if !pill.sourceBundleId.isEmpty { return pill.sourceBundleId.lowercased() }
                return pill.trackingIdentifier.lowercased()
            }()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            deduped.append(pill)
        }
        return deduped
    }

    func finderDesktopIndexedCachePills(roots: [String], limit: Int = 2_500) -> [DockPill] {
        guard !roots.isEmpty else { return [] }
        var count = 0
        var pills: [DockPill] = []
        pills.reserveCapacity(min(limit, fileIndexManager.indexedFiles.count))

        for file in fileIndexManager.indexedFiles {
            guard count < limit else { break }
            guard !file.name.hasPrefix(".") else { continue }
            guard roots.contains(where: { root in
                file.path == root || file.path.hasPrefix(root + "/")
            }) else { continue }

            let url = URL(fileURLWithPath: file.path)
            pills.append(
                makeDesktopPill(
                    path: file.path,
                    name: file.name,
                    badge: finderDisplayPath(url.deletingLastPathComponent().path),
                    rankingKind: file.isDirectory ? "finderRecent" : "spotlightSearch",
                    query: nil,
                    loadIcon: false,
                    isDirectoryHint: file.isDirectory
                )
            )
            count += 1
        }
        return pills
    }

    func finderDesktopDirectFallbackPills(roots: [String], limit: Int = 160) -> [DockPill] {
        var pills: [DockPill] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        for root in roots {
            guard pills.count < limit else { break }
            guard
                let items = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }

            for url in items {
                guard pills.count < limit else { break }
                let path = url.standardizedFileURL.path
                let values = try? url.resourceValues(forKeys: keys)
                let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
                pills.append(
                    makeDesktopPill(
                        path: path,
                        name: url.lastPathComponent,
                        badge: finderDisplayPath(url.deletingLastPathComponent().path),
                        rankingKind: isDirectory ? "finderRecent" : "spotlightSearch",
                        query: nil,
                        loadIcon: false,
                        isDirectoryHint: isDirectory
                    )
                )
            }
        }
        return pills
    }

    func primeFinderDesktopModeCache(commitQuery: String? = nil, preserveFocus: Bool = true) {
        let roots = finderDesktopSearchRootPaths()
        let runningAppPills = finderDesktopRecentApplicationPills(query: "")
        let indexedPills = finderDesktopIndexedCachePills(roots: roots)
        let fallbackPills = indexedPills.isEmpty
            ? finderDesktopDirectFallbackPills(roots: roots)
            : []
        let recentFilePills = finderRecentDocumentPaths(limit: 20).map { path -> DockPill in
            let url = URL(fileURLWithPath: path)
            return makeDesktopPill(
                path: path,
                name: url.lastPathComponent,
                badge: finderDisplayPath(url.deletingLastPathComponent().path),
                rankingKind: "finderRecent",
                query: nil
            )
        }

        finderDesktopIndexedPills = dedupeFinderDesktopPills(indexedPills + fallbackPills)
        finderDesktopRecentPills = dedupeFinderDesktopPills(runningAppPills + recentFilePills)

        if let commitQuery, isFinderDesktopOnlyMode {
            commitFinderDesktopModeSnapshot(query: commitQuery, preserveFocus: preserveFocus)
        }
    }

    func finderDesktopSearchRootPaths() -> [String] {
        let fm = FileManager.default
        var roots: [String] = []

        for url in effectiveFinderSelectionURLsForPills() {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                roots.append(path)
            }
        }

        roots.append(contentsOf: settings.searchDirectories.map(\.path).filter { !$0.isEmpty })

        var seen = Set<String>()
        return roots.compactMap { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return seen.insert(path).inserted ? path : nil
        }
    }

    func finderRecentDocumentPaths(limit: Int) -> [String] {
        var seen = Set<String>()
        return NSDocumentController.shared.recentDocumentURLs.compactMap { url in
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            guard !url.lastPathComponent.hasPrefix(".") else { return nil }
            return seen.insert(path).inserted ? path : nil
        }
        .prefix(limit)
        .map { $0 }
    }

    func fileIndexPathsForFinderDesktopSearch(query: String, roots: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        if roots.isEmpty {
            for result in fileIndexManager.search(query: query, limit: limit) {
                guard let path = result.filePath else { continue }
                guard seen.insert(path).inserted else { continue }
                paths.append(path)
            }
            return paths
        }

        for root in roots {
            let matches = fileIndexManager.advancedSearch(
                AdvancedFileSearchQuery(
                    rootPath: root,
                    residualQuery: query,
                    includeDirectories: true,
                    filesOnly: false,
                    limit: max(4, limit / max(1, roots.count))
                ))
            for file in matches where seen.insert(file.path).inserted {
                paths.append(file.path)
                if paths.count >= limit { return paths }
            }
        }

        return paths
    }

    // In-process Spotlight query — no subprocess, directly taps the live index.
    // NSMetadataQuery must start on the main thread; withCheckedContinuation lets callers
    // await the result without blocking any thread.
    @MainActor
    static func spotlightSearchPaths(
        predicate: NSPredicate,
        inDirectories dirs: [String],
        sortByLastUsed: Bool = false,
        limit: Int
    ) async -> [String] {
        await withCheckedContinuation { continuation in
            let q = NSMetadataQuery()
            q.searchScopes = dirs.map { URL(fileURLWithPath: $0) }
            q.predicate = predicate
            if sortByLastUsed {
                q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
            }

            var observers: [NSObjectProtocol] = []
            var delivered = false

            func deliver() {
                guard !delivered else { return }
                delivered = true
                q.disableUpdates()
                let paths = (0..<min(q.resultCount, limit)).compactMap { i in
                    (q.result(at: i) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                }
                q.stop()
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                continuation.resume(returning: paths)
            }

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in deliver() })
            // Also handle update (fires when index refreshes results mid-query)
            observers.append(nc.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: q, queue: .main) { _ in deliver() })

            q.start()

            // 3-second safety timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { deliver() }
        }
    }

    // Spotlight search scoped to the whole computer (for app search across /Applications)
    @MainActor
    static func spotlightSearchPathsComputerScope(
        predicate: NSPredicate,
        sortByLastUsed: Bool = false,
        limit: Int
    ) async -> [String] {
        await withCheckedContinuation { continuation in
            let q = NSMetadataQuery()
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
            q.predicate = predicate
            if sortByLastUsed {
                q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
            }

            var observers: [NSObjectProtocol] = []
            var delivered = false

            func deliver() {
                guard !delivered else { return }
                delivered = true
                q.disableUpdates()
                let paths = (0..<min(q.resultCount, limit)).compactMap { i in
                    (q.result(at: i) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                }
                q.stop()
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                continuation.resume(returning: paths)
            }

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in deliver() })
            observers.append(nc.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: q, queue: .main) { _ in deliver() })

            q.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { deliver() }
        }
    }

    // Async loader for recent pills — call from .task
    func refreshFinderDesktopRecentPills() async {
        let roots = finderDesktopSearchRootPaths()

        // Spotlight: recently-used files from user folders (last 30 days) — enriches idle view
        let cutoff = NSDate(timeIntervalSinceNow: -30 * 24 * 3600)
        let filePaths = roots.isEmpty ? [] : await Self.spotlightSearchPaths(
            predicate: NSPredicate(
                format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree != %@ AND kMDItemContentType != %@",
                cutoff,
                "com.apple.application-bundle" as NSString,
                "public.folder" as NSString
            ),
            inDirectories: roots,
            sortByLastUsed: true,
            limit: 15
        )

        let filePills: [DockPill] = filePaths
            .filter { !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".") }
            .prefix(10)
            .map { path -> DockPill in
                let url = URL(fileURLWithPath: path)
                return makeDesktopPill(path: path, name: url.lastPathComponent,
                    badge: finderDisplayPath(url.deletingLastPathComponent().path),
                    rankingKind: "finderRecent", query: nil, loadIcon: false, isDirectoryHint: false)
        }

        guard isFinderDesktopOnlyMode else { return }
        finderDesktopRecentPills = dedupeFinderDesktopPills(finderDesktopRecentPills + filePills)
    }

    func scheduleFinderDesktopSearchEnrichment(query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        contextDockViewModel.finderDesktopSearchGeneration &+= 1
        let generation = contextDockViewModel.finderDesktopSearchGeneration
        contextDockViewModel.finderDesktopSearchTask?.cancel()

        guard isFinderDesktopOnlyMode, q.count >= 2 else {
            contextDockViewModel.finderDesktopSearchTask = nil
            return
        }

        contextDockViewModel.finderDesktopSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled,
                contextDockViewModel.finderDesktopSearchGeneration == generation,
                searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == q
            else { return }
            await refreshFinderDesktopSearchPills(query: q, generation: generation)
        }
    }

    // Async idle enrichment only. Typing path stays synchronous via finderDesktopIndexedPills.
    func refreshFinderDesktopSearchPills(query: String) async {
        await refreshFinderDesktopSearchPills(query: query, generation: nil)
    }

    func refreshFinderDesktopSearchPills(query: String, generation: Int?) async {
        guard query.count >= 2 else {
            finderDesktopSearchQuery = ""
            finderDesktopSearchPills = []
            return
        }
        let roots = finderDesktopSearchRootPaths()

        let fileSearchPaths = roots.isEmpty ? [] : await Self.spotlightSearchPaths(
            predicate: NSPredicate(
                format: "kMDItemDisplayName LIKE[cd] %@",
                "*\(query)*"
            ),
            inDirectories: roots,
            sortByLastUsed: true,
            limit: 12
        )

        var seen = Set<String>()
        var enriched: [DockPill] = []
        for path in fileSearchPaths {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), seen.insert(path.lowercased()).inserted else { continue }
            enriched.append(makeDesktopPill(path: path, name: name,
                badge: finderDisplayPath(url.deletingLastPathComponent().path),
                rankingKind: "spotlightSearch", query: nil, loadIcon: false, isDirectoryHint: nil))
        }
        guard generation == nil || contextDockViewModel.finderDesktopSearchGeneration == generation else {
            return
        }
        guard isFinderDesktopOnlyMode,
            searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query
        else { return }
        let existingKeys = Set(finderDesktopIndexedPills.map { pill -> String in
            if let path = pill.resolvedURL?.path.lowercased(), !path.isEmpty { return path }
            if !pill.sourceBundleId.isEmpty { return pill.sourceBundleId.lowercased() }
            return pill.trackingIdentifier.lowercased()
        })
        let newEnriched = enriched.filter { pill in
            let key: String = {
                if let path = pill.resolvedURL?.path.lowercased(), !path.isEmpty { return path }
                if !pill.sourceBundleId.isEmpty { return pill.sourceBundleId.lowercased() }
                return pill.trackingIdentifier.lowercased()
            }()
            return !key.isEmpty && !existingKeys.contains(key)
        }
        guard !newEnriched.isEmpty else { return }
        finderDesktopIndexedPills = dedupeFinderDesktopPills(finderDesktopIndexedPills + newEnriched)
        finderDesktopSearchQuery = ""
        finderDesktopSearchPills = []
        commitFinderDesktopModeSnapshot(query: query, preserveFocus: true)
    }

    func makeDesktopPill(
        path: String,
        name: String,
        badge: String,
        rankingKind: String,
        query: String?,
        loadIcon: Bool = true,
        isDirectoryHint: Bool? = nil
    ) -> DockPill {
        let url = URL(fileURLWithPath: path)
        let isApp = path.hasSuffix(".app")
        let isDir = isApp
            || (isDirectoryHint
                ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false))
        let effectiveKind = isApp ? "finderRecentApp" : rankingKind
        // Strip .app suffix from display name — macOS localized name already has no extension,
        // but when built from path the filename includes it.
        let displayName = isApp && name.hasSuffix(".app")
            ? String(name.dropLast(4))
            : name
        let icon: String = {
            if isApp { return "app.badge" }
            if isDir { return "folder.fill" }
            return rankingKind == "finderRecent" ? "clock" : "doc.text.magnifyingglass"
        }()
        var pill = DockPill(
            id: "\(effectiveKind)-\(path)",
            name: displayName,
            icon: icon,
            accentColorName: isApp ? "blue" : (isDir ? "blue" : "teal"),
            badge: badge,
            execute: { NSWorkspace.shared.open(url) }
        )
        if loadIcon {
            pill.menuItemImage = NSWorkspace.shared.icon(forFile: path)
        }
        pill.sourceBundleId = isApp
            ? (Bundle(url: url)?.bundleIdentifier ?? "com.apple.finder")
            : "com.apple.finder"
        pill.sourceAppName = "Finder"
        pill.rankingKind = effectiveKind
        pill.resolvedURL = url
        pill.quickLookURL = isApp ? nil : url
        pill.trackingIdentifier = "\(effectiveKind):\(path.lowercased())"
        // searchTerms: name + badge only. Do NOT include the search query — that would make
        // every result match any query, bypassing dockPillHasQuerySignal.
        pill.searchTerms = [displayName, badge, effectiveKind == "finderRecentApp" ? "app" : (rankingKind == "finderRecent" ? "recent" : "")]
            .filter { !$0.isEmpty }
        return pill
    }

    static func mdfindSync(predicate: String, inDirectory dir: String, limit: Int) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-onlyin", dir, predicate]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        // 4-second timeout — content-search predicates can hang without a bound
        let deadline = DispatchTime.now() + .seconds(4)
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: deadline) == .timedOut { proc.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return Array(out.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(limit))
    }

    // Legacy stub — kept to avoid breaking callers; remove once fully migrated
    func buildAppleRecentItemsPills() -> [DockPill] {
        // Use mdfind sorted by kMDItemLastUsedDate — same source as Spotlight/Apple menu recent items
        let home = NSHomeDirectory()
        let searchRoots = settings.searchDirectories.map { $0.path }.filter { !$0.isEmpty }
        let scope = searchRoots.isEmpty ? [home] : searchRoots

        var paths: [String] = []
        for root in scope {
            let result = runMdfind(
                predicate: "kMDItemLastUsedDate >= $time.today(-30) && kMDItemContentType != 'public.folder'",
                inDirectory: root,
                limit: 20
            )
            paths.append(contentsOf: result)
        }

        // Sort by last-used date (most recent first) via MDItem
        let sorted = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .filter { !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".") }
            .sorted {
                let d1 = (MDItemCreate(nil, $0 as CFString)).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date } ?? .distantPast
                let d2 = (MDItemCreate(nil, $1 as CFString)).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date } ?? .distantPast
                return d1 > d2
            }
            .prefix(10)

        return sorted.map { path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let displayParent = finderDisplayPath(url.deletingLastPathComponent().path)
            var pill = DockPill(
                id: "recent-doc-\(path)",
                name: name,
                icon: "clock",
                accentColorName: "blue",
                badge: displayParent,
                execute: { NSWorkspace.shared.open(url) }
            )
            pill.menuItemImage = NSWorkspace.shared.icon(forFile: path)
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.rankingKind = "finderRecent"
            pill.quickLookURL = url
            pill.trackingIdentifier = "finder-recent:\(path.lowercased())"
            pill.searchTerms = [name, "recent", "recents", displayParent]
            return pill
        }
    }

    @discardableResult
    func runMdfind(predicate: String, inDirectory dir: String, limit: Int = 20) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-onlyin", dir, predicate]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Array(output.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(limit))
    }

    func buildScopedSpotlightPills(query: String) -> [DockPill] {
        guard query.count >= 2 else { return [] }

        let searchRoots: [String] = {
            let dirs = settings.searchDirectories.filter { !$0.path.isEmpty }.map { $0.path }
            return dirs.isEmpty ? [NSHomeDirectory()] : dirs
        }()

        var seen = Set<String>()
        var paths: [String] = []

        for root in searchRoots {
            // mdfind: match filename or content (kMDItemTextContent covers PDF/doc content)
            let results = runMdfind(
                predicate: "kMDItemDisplayName == '*\(query)*'cd || kMDItemTextContent == '*\(query)*'cd",
                inDirectory: root,
                limit: 20
            )
            for p in results {
                guard seen.insert(p).inserted else { continue }
                paths.append(p)
            }
            if paths.count >= 10 { break }
        }

        return paths.prefix(10).compactMap { path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), FileManager.default.fileExists(atPath: path) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let displayParent = finderDisplayPath(url.deletingLastPathComponent().path)
            var pill = DockPill(
                id: "spotlight-\(path)",
                name: name,
                icon: isDir ? "folder.fill" : "doc.text.magnifyingglass",
                accentColorName: isDir ? "blue" : "teal",
                badge: displayParent,
                execute: { NSWorkspace.shared.open(url) }
            )
            pill.menuItemImage = NSWorkspace.shared.icon(forFile: path)
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.rankingKind = "spotlightSearch"
            pill.quickLookURL = url
            pill.trackingIdentifier = "spotlight:\(path.lowercased())"
            pill.searchTerms = [name, query, displayParent, isDir ? "folder" : "file"]
            return pill
        }
    }

    func strictFinderHomeSearchScore(query: String, url: URL) -> Double? {
        let normalizedQuery = normalizedDockPillText(query)
        guard normalizedQuery.count >= 2 else { return nil }

        let name = normalizedDockPillText(url.lastPathComponent)
        let parent = normalizedDockPillText(url.deletingLastPathComponent().lastPathComponent)
        guard !name.isEmpty else { return nil }

        if name == normalizedQuery { return 1200 }
        if name.hasPrefix(normalizedQuery) {
            return 1080 + Double(min(normalizedQuery.count, 12) * 6)
        }
        if name.contains(normalizedQuery) {
            return 960 + Double(min(normalizedQuery.count, 10) * 4)
        }

        let queryTokens = dockPillTokens(normalizedQuery).filter { $0.count >= 2 }
        let nameTokens = dockPillTokens(name)
        if !queryTokens.isEmpty {
            let matched = queryTokens.filter { qToken in
                nameTokens.contains { token in
                    token == qToken || token.hasPrefix(qToken) || token.contains(qToken)
                }
            }
            if !matched.isEmpty {
                return 850 + Double(matched.count * 36)
            }
        }

        // Allow small typo tolerance for real name tokens only, not broad path fuzzy matching.
        if normalizedQuery.count >= 4 {
            let bestDistance =
                nameTokens
                .filter { $0.count >= 4 }
                .map { levenshteinDistance(normalizedQuery, $0) }
                .min()
            if let bestDistance, bestDistance <= 1 {
                return 790 + Double(max(0, normalizedQuery.count - bestDistance) * 18)
            }
        }

        // Parent match is lower priority and only for multi-word queries.
        if normalizedQuery.contains(" "), parent.contains(normalizedQuery) {
            return 420
        }

        return nil
    }

    func executeFinderSelectionMenuAction(titleContains fragment: String) {
        guard
            let finder = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.finder"
            })
        else { return }

        let needle = fragment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }

        let pid = finder.processIdentifier
        let items = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 7)
        let preferredRoots = ["file", "quick actions", "services"]
        let match =
            items
            .filter { $0.isEnabled }
            .first { item in
                let title = normalizedDockPillText(item.title)
                let path = normalizedDockPillText(item.pathString)
                let hasPreferredRoot = item.path.contains { part in
                    preferredRoots.contains { normalizedDockPillText(part).contains($0) }
                }
                return hasPreferredRoot && (title.contains(needle) || path.contains(needle))
            }
            ?? items.first { item in
                item.isEnabled && normalizedDockPillText(item.title).contains(needle)
            }

        guard let match else {
            AppToast.show(
                "Finder action unavailable", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        AXActionResolver.shared.execute(menuPath: match.path, in: finder)
    }

    func buildFinderSelectionMenuPills(
        query q: String,
        excludingTitles: Set<String>,
        allowedRootNames: Set<String>? = nil
    ) -> [DockPill] {
        let selectedURLs = effectiveFinderSelectionURLsForPills()
        guard !selectedURLs.isEmpty else { return [] }

        let openWithFilter = openWithChildFilter(from: q)
        let needsRootFilteredMenu = allowedRootNames?.isEmpty == false
        let menuQuery = needsRootFilteredMenu ? "" : (openWithFilter == nil ? q : "open")
        let limit = needsRootFilteredMenu ? 120 : (q.isEmpty ? 12 : 10)
        let queryNeedle = normalizedDockPillText(q)
        let items = finderSelectionMenuResults(query: menuQuery, limit: limit)
        let sourceItems = items.filter { item in
            let rootAllowed: Bool = {
                guard let allowedRootNames, !allowedRootNames.isEmpty else { return true }
                return item.path.contains { part in
                allowedRootNames.contains(normalizedDockPillText(part))
                }
            }()
            guard rootAllowed else { return false }
            guard needsRootFilteredMenu, !queryNeedle.isEmpty else { return true }
            let haystack = normalizedDockPillText(([item.title] + item.path).joined(separator: " "))
            return haystack.contains(queryNeedle)
                || queryNeedle.contains(normalizedDockPillText(item.title))
            }

        var pills =
            openWithFilter.map {
                buildLaunchServicesOpenWithPills(
                    selectedURLs: selectedURLs,
                    filter: $0
                )
            } ?? []
        for item in sourceItems {
            let normalizedTitle = normalizedDockPillText(item.title)
            guard !excludingTitles.contains(normalizedTitle) else { continue }
            let isOpenWithMenu =
                normalizedTitle == "open with"
                || item.path.contains { normalizedDockPillText($0) == "open with" }
            if openWithFilter != nil, isOpenWithMenu, normalizedTitle != "open with" {
                continue
            }

            let path = item.path
            let sourcePID = item.sourcePID
            let shortcutChar = item.shortcutChar
            let shortcutModifiers = item.shortcutModifiers
            let badge = item.shortcutDisplay  // parent menu name dropped — use shortcut only
            let isShareItem =
                normalizedTitle.hasPrefix("share")
                || item.path.contains { normalizedDockPillText($0) == "share" }

            let menuImg = resolvedMenuIcon(for: item)
            var pill = DockPill(
                id: "finder-menu-\(item.id)",
                name: item.title,
                icon: isShareItem ? "square.and.arrow.up" : menuSymbol(for: item),
                accentColorName: isShareItem ? "blue" : "gray",
                badge: badge,
                execute: {
                    if isShareItem {
                        executeShareMenuDestination(item.title)
                        return
                    }

                    guard sourcePID != 0 else { return }
                    executeDockMenuAction(
                        sourcePID: sourcePID,
                        path: path,
                        shortcutChar: shortcutChar,
                        shortcutModifiers: shortcutModifiers
                    )
                }
            )
            pill.menuItemImage = menuImg
            pill.isShareAction = isShareItem
            pill.menuItemName = item.title
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.menuContext = menuContextLabel(from: item.path)
            pill.rankingKind = "finderMenu"
            pill.isEnabled = isOpenWithMenu && normalizedTitle != "open with" ? true : item.isEnabled
            pill.hasLiveAvailability = isOpenWithMenu && normalizedTitle != "open with"
            pill.trackingIdentifier =
                "finder-menu:\(path.joined(separator: " > ").lowercased())"
            pill.searchTerms = item.path + ["finder", "files", "selection"]
            pills.append(pill)

            if false, let openWithFilter, isOpenWithMenu, !item.children.isEmpty {
                let children = leafOpenWithChildren(for: item, filter: openWithFilter)
                for child in children {
                    let childPath = child.path
                    let childPID = child.sourcePID != 0 ? child.sourcePID : sourcePID
                    let childShortcut = child.shortcutChar
                    let childMods = child.shortcutModifiers
                    var childPill = DockPill(
                        id: "finder-open-with-\(child.id)",
                        name: child.title,
                        icon: "app.badge",
                        accentColorName: "blue",
                        badge: "Open With",
                        execute: {
                            guard childPID != 0 else { return }
                            executeDockMenuAction(
                                sourcePID: childPID,
                                path: childPath,
                                shortcutChar: childShortcut,
                                shortcutModifiers: childMods
                            )
                        }
                    )
                    childPill.menuItemImage = openWithAppIcon(for: child)
                    childPill.menuItemName = child.title
                    childPill.sourceBundleId = "com.apple.finder"
                    childPill.sourceAppName = "Finder"
                    childPill.menuContext = "Open With"
                    childPill.rankingKind = "submenuChild"
                    childPill.trackingIdentifier =
                        "finder-open-with:\(childPath.joined(separator: " > ").lowercased())"
                    childPill.searchTerms = child.path + ["open", "open with", child.title, "app"]
                    childPill.isEnabled = true
                    childPill.hasLiveAvailability = false
                    pills.append(childPill)
                }
            }
        }

        return pills
    }

    func finderSelectionMenuResults(query: String, limit: Int = 8) -> [AXMenuItem] {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else {
            return []
        }

        let pid = finder.processIdentifier
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fileActionTitles = [
            "Open", "Open With", "Open in New Tab", "Get Info", "Rename",
            "Compress", "Duplicate", "Make Alias", "Move to Trash", "Move to Bin",
            "Copy", "Share", "Tags", "Quick Look", "Customize Folder",
            "Customise Folder", "Import from iPhone", "Remove Download",
            "Keep Downloaded",
        ]
        let fileActionPaths = ["File", "Services", "Quick Actions", "Open With", "Tags"]
        let thirdPartyServiceHints = [
            "Terminal", "Ghostty", "Downie", "Bluetooth", "TeamViewer",
            "Hammerspoon", "Tuna", "MEGA", "Upload", "Sync", "Backup",
            "Workflow", "Service",
        ]
        let preferredLimit = trimmedQuery.isEmpty ? max(limit, 12) : limit
        let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
        let items = (liveItems.isEmpty
            ? AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)
            : liveItems)
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item -> AXMenuItem in
                var item = item
                item.sourcePID = pid
                item.sourceAppName = "Finder"
                return item
            }
            .filter { item in
                item.path.contains { part in
                    fileActionPaths.contains { part.localizedCaseInsensitiveContains($0) }
                }
                || fileActionTitles.contains { item.title.localizedCaseInsensitiveContains($0) }
                || thirdPartyServiceHints.contains { item.title.localizedCaseInsensitiveContains($0) }
            }

        let matches: [AXMenuItem]
        if trimmedQuery.isEmpty {
            matches = items.filter { item in
                fileActionTitles.contains { needle in
                    item.title.localizedCaseInsensitiveContains(needle)
                        || item.pathString.localizedCaseInsensitiveContains(needle)
                }
                || item.path.contains { part in
                    fileActionPaths.contains { part.localizedCaseInsensitiveContains($0) }
                }
                || thirdPartyServiceHints.contains { hint in
                    item.title.localizedCaseInsensitiveContains(hint)
                }
            }
        } else {
            matches = items.filter { item in
                item.title.lowercased().contains(trimmedQuery)
                    || item.path.contains { $0.lowercased().contains(trimmedQuery) }
            }
        }

        var seen = Set<String>()
        let deduped = matches.filter { item in
            seen.insert(item.pathString.lowercased()).inserted
        }

        let ordered = deduped.sorted {
            func priority(_ item: AXMenuItem) -> Int {
                let title = item.title.lowercased()
                let pathString = item.pathString.lowercased()
                if !trimmedQuery.isEmpty {
                    if title == trimmedQuery { return 0 }
                    if title.hasPrefix(trimmedQuery) { return 1 }
                    if pathString.contains(trimmedQuery) { return 2 }
                }
                if title == "open" { return 10 }
                if title.contains("open with") { return 11 }
                if title.contains("open in new tab") { return 12 }
                if title.contains("move to bin") || title.contains("move to trash") { return 20 }
                if title.contains("get info") { return 21 }
                if title.contains("rename") { return 22 }
                if title.contains("compress") { return 23 }
                if title.contains("duplicate") { return 24 }
                if title.contains("make alias") { return 25 }
                if title.contains("quick look") { return 26 }
                if title == "copy" { return 30 }
                if title.contains("share") { return 31 }
                if title.contains("tag") { return 32 }
                if title.contains("quick action") || pathString.contains("quick actions") { return 40 }
                if title.contains("service") || pathString.contains("services") { return 41 }
                return 90 + item.path.count
            }

            let aPriority = priority($0)
            let bPriority = priority($1)
            if aPriority != bPriority { return aPriority < bPriority }
            return $0.path.count < $1.path.count
        }

        return Array(ordered.prefix(preferredLimit))
    }

    func buildLaunchServicesOpenWithPills(
        selectedURLs: [URL],
        filter: String
    ) -> [DockPill] {
        let existingURLs = canonicalExistingURLs(selectedURLs)
        guard !existingURLs.isEmpty else { return [] }

        let normalizedFilter = normalizedDockPillText(filter)
        let suggestions = DefaultAppResolver.shared.getOpenWithSuggestions(for: existingURLs)
            .filter { suggestion in
                let title = normalizedDockPillText(suggestion.app.displayName)
                return normalizedFilter.isEmpty
                    || title.contains(normalizedFilter)
                    || title.split(separator: " ").contains { $0.hasPrefix(normalizedFilter) }
            }
            .prefix(12)

        return suggestions.map { suggestion in
            let app = suggestion.app
            var pill = DockPill(
                id:
                    "finder-open-with-ls-\(app.bundleIdentifier)-\(existingURLs.map(\.path).joined(separator: "|"))",
                name: suggestion.displayName,
                icon: "app.badge",
                accentColorName: "blue",
                badge: existingURLs.count == 1 ? "Open With" : "\(existingURLs.count) Items",
                execute: {
                    openSelectedFinderFiles(
                        existingURLs,
                        with: app
                    )
                }
            )
            pill.menuItemImage = preparedDockIcon(app.icon)
            pill.menuItemName = suggestion.displayName
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.menuContext = "Open With"
            pill.rankingKind = "openWith"
            pill.trackingIdentifier = "finder-open-with-ls:\(app.bundleIdentifier)"
            pill.searchTerms = [
                "open", "open with", app.displayName, app.bundleIdentifier,
                existingURLs.first?.lastPathComponent ?? "",
            ]
            pill.isEnabled = true
            pill.hasLiveAvailability = true
            return pill
        }
    }

    func openSelectedFinderFiles(
        _ urls: [URL],
        with app: DefaultAppResolver.DefaultApp
    ) {
        let existingURLs = canonicalExistingURLs(urls)
        guard !existingURLs.isEmpty, FileManager.default.fileExists(atPath: app.path.path) else {
            AppToast.show("Open With unavailable", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        hideLauncherAfterResultExecution()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            existingURLs,
            withApplicationAt: app.path,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    AppToast.show(
                        error.localizedDescription, icon: "exclamationmark.triangle", tint: .orange)
                }
            }
        }
    }

    func leafOpenWithChildren(for parent: AXMenuItem, filter: String) -> [AXMenuItem] {
        var leaves: [AXMenuItem] = []
        for child in parent.children {
            if child.isLeaf {
                leaves.append(child)
            } else {
                leaves.append(contentsOf: child.children.filter(\.isLeaf))
            }
        }

        let normalizedFilter = normalizedDockPillText(filter)
        let filtered = leaves.filter { child in
            guard !isAppleMenuItem(child) else { return false }
            let title = normalizedDockPillText(child.title)
            guard !title.isEmpty else { return false }
            if normalizedFilter.isEmpty { return true }
            return title.contains(normalizedFilter)
                || title.split(separator: " ").contains { $0.hasPrefix(normalizedFilter) }
        }

        return Array(filtered.prefix(12))
    }

    func openWithChildFilter(from query: String) -> String? {
        let normalized = normalizedDockPillText(query)
        if normalized == "open" || normalized == "open with" { return "" }
        if normalized.hasPrefix("open with ") {
            return String(normalized.dropFirst("open with ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.hasPrefix("open ") {
            return String(normalized.dropFirst("open ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func openWithAppIcon(for item: AXMenuItem) -> NSImage? {
        if let image = resolvedMenuIcon(for: item) { return image }

        let title = item.title
            .replacingOccurrences(of: #"\s*\(default\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let appName = title.hasSuffix(".app") ? String(title.dropLast(4)) : title
        let candidates = [title, "\(appName).app", appName]

        for result in allApplications where result.type == .application {
            let resultName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathName = URL(fileURLWithPath: result.subtitle).lastPathComponent
            if candidates.contains(where: {
                $0.compare(resultName, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
                    || $0.compare(pathName, options: [.caseInsensitive, .diacriticInsensitive])
                        == .orderedSame
            }) {
                return preparedDockIcon(result.icon)
            }
        }

        let dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications",
        ]
        for dir in dirs {
            let path = "\(dir)/\(appName).app"
            if FileManager.default.fileExists(atPath: path) {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
            }
        }
        return nil
    }

    // MARK: - Cross-app / clipboard / session pill helpers

    /// Native share sheet entry for active selections in either scope. This is intentionally
    /// cache/context based only; it must not trigger live menu or AX reads while typing.
    func buildGlobalSelectionSharePills(query q: String) -> [DockPill] {
        guard hasActiveDockContextSelection else { return [] }
        let normalizedQuery = normalizedDockPillText(q)
        if !normalizedQuery.isEmpty {
            let shareTerms = ["share", "send", "airdrop", "export", "message", "mail"]
            guard
                shareTerms.contains(where: {
                    $0.hasPrefix(normalizedQuery) || normalizedQuery.contains($0)
                })
            else { return [] }
        }

        let context = effectiveAXContextForConversation()
        guard !ShareIntentRouter.shared.shareableItems(for: context).isEmpty else { return [] }

        let badge: String = {
            switch activeSelection {
            case .files(let urls):
                return urls.count == 1 ? "File" : "\(urls.count) Items"
            case .text:
                return "Text"
            case .url:
                return "URL"
            case .none:
                return "Selection"
            }
        }()
        var pill = DockPill(
            id: "selection-share",
            name: "Share Selection",
            icon: "square.and.arrow.up",
            accentColorName: "blue",
            badge: badge,
            execute: { showShareSheetForContext() }
        )
        pill.rankingKind = "payload"
        pill.trackingIdentifier = "selection-share"
        pill.searchTerms = [
            "share", "send", "airdrop", "export", "selection", "files", "text", "url",
        ]
        return [pill]
    }

    /// Selection is additive in Context Dock: these AI actions sit beside normal app menus.
    func buildContextDockSelectionAIPills(query q: String) -> [DockPill] {
        guard !isGlobalContextActive, !aiMode.isActive else { return [] }
        guard case .text(let selectedText) = activeSelection, !selectedText.isEmpty else { return [] }

        let normalizedQuery = normalizedDockPillText(q)
        let actions: [(name: String, icon: String, prompt: String)] = [
            ("Explain", "text.magnifyingglass", "Explain the selected text"),
            ("Summarize", "text.alignleft", "Summarize the selected text"),
            ("Rewrite", "pencil.line", "Rewrite the selected text clearly"),
            ("Translate", "character.book.closed", "Translate the selected text"),
        ]

        return actions.compactMap { action in
            let searchable = normalizedDockPillText("\(action.name) \(action.prompt)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            var pill = DockPill(
                id: "context-selection-ai-\(action.name.lowercased())",
                name: action.name,
                icon: action.icon,
                accentColorName: "purple",
                badge: "Selected text · \(selectedText.count) chars",
                execute: {
                    aiMode.isActive = true
                    searchState.query = action.prompt
                    DispatchQueue.main.async { submitAIQuery() }
                }
            )
            pill.rankingKind = "selectionAI"
            pill.sourceBundleId = axContext.bundleId
            pill.sourceAppName = axContext.appName
            pill.trackingIdentifier = "context-selection-ai:\(action.name.lowercased())"
            pill.searchTerms = [action.name, action.prompt, "selected text", "ai"]
            return pill
        }
    }

    /// Pills for apps that can receive the current context (URL, text, file).
    /// Delegates to CrossAppRouter for capability-aware, content-type routing.
    func buildCrossAppPills(query q: String) -> [DockPill] {
        guard settings.crossAppPills else { return [] }
        let context = effectiveAXContextForConversation()
        guard
            context.selectedFilePaths.isEmpty == false
                || !(context.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                || !(context.currentURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                || !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        let runningIds = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )
        let routed = CrossAppRouter.shared.buildPills(
            context: context,
            runningBundleIds: runningIds,
            query: q
        )
        let normalizedQuery = normalizedDockPillText(q)
        let shareIntentQuery =
            isGlobalContextActive
            && hasActiveDockContextSelection
            && ["share", "send", "airdrop", "export"].contains { term in
                normalizedQuery.isEmpty || term.hasPrefix(normalizedQuery)
                    || normalizedQuery.contains(term)
            }
        return routed.compactMap { pill in
            let searchable = normalizedDockPillText("\(pill.label) \(pill.appName)")
            if !normalizedQuery.isEmpty && !shareIntentQuery
                && !searchable.contains(normalizedQuery)
            {
                return nil
            }
            var dockPill = DockPill(
                id: "cross-\(pill.bundleId)-\(normalizedDockPillText(pill.label))",
                name: pill.label,
                icon: pill.icon,
                accentColorName: pill.badgeColor,
                badge: isGlobalContextActive && hasActiveDockContextSelection ? pill.appName : nil,
                execute: pill.action
            )
            dockPill.sourceBundleId = pill.bundleId
            dockPill.sourceAppName = pill.appName
            dockPill.rankingKind = "crossApp"
            dockPill.trackingIdentifier =
                "cross:\(pill.bundleId):\(normalizedDockPillText(pill.label))"
            dockPill.searchTerms = [
                pill.appName, pill.label, "share", "send", "selection", "text", "files", "url",
            ]
            return dockPill
        }
    }

    /// Pills derived from the current clipboard content.
    func buildClipboardPills(query q: String) -> [DockPill] {
        guard settings.clipboardAwarePills else { return [] }
        let pb = NSPasteboard.general
        var pills: [DockPill] = []

        // URL on clipboard
        if let urlStr = pb.string(forType: .string),
            let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme?.hasPrefix("http") == true
        {
            let label = "Open Clipboard URL"
            if q.isEmpty || label.lowercased().contains(q) || "clipboard".contains(q) {
                pills.append(
                    DockPill(
                        id: "clip-url", name: label, icon: "link",
                        accentColorName: "blue", badge: "Clipboard",
                        execute: { NSWorkspace.shared.open(url) }))
            }
            let label2 = "Copy Clipboard URL"
            if q.isEmpty || label2.lowercased().contains(q) {
                pills.append(
                    DockPill(
                        id: "clip-copy-url", name: label2, icon: "doc.on.clipboard",
                        accentColorName: "blue", badge: "Clipboard",
                        execute: {
                            let p = NSPasteboard.general
                            p.clearContents()
                            p.setString(urlStr, forType: .string)
                        }))
            }
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            // Plain text on clipboard
            let preview = String(text.prefix(30)).replacingOccurrences(of: "\n", with: " ")
            let label = "Use: \"\(preview)\""
            if q.isEmpty || label.lowercased().contains(q) || "clipboard".contains(q) {
                pills.append(
                    DockPill(
                        id: "clip-text", name: label, icon: "doc.on.clipboard",
                        accentColorName: "yellow", badge: "Clipboard",
                        execute: {
                            // Re-paste into frontmost app
                            if let app = AppDelegate.shared?.previousFrontmostApp {
                                app.activate(options: .activateIgnoringOtherApps)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    let src = CGEventSource(stateID: .hidSystemState)
                                    let vKey: CGKeyCode = 9  // 'v'
                                    CGEvent(
                                        keyboardEventSource: src, virtualKey: vKey, keyDown: true)?
                                        .flags = .maskCommand
                                    CGEvent(
                                        keyboardEventSource: src, virtualKey: vKey, keyDown: true)?
                                        .post(tap: .cgSessionEventTap)
                                    CGEvent(
                                        keyboardEventSource: src, virtualKey: vKey, keyDown: false)?
                                        .post(tap: .cgSessionEventTap)
                                }
                            }
                        }))
            }
        }

        // File URL(s) on clipboard
        if let urls = pb.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            let label =
                "Open \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Files")"
            if q.isEmpty || label.lowercased().contains(q) {
                let captured = urls
                pills.append(
                    DockPill(
                        id: "clip-files", name: label, icon: "doc",
                        accentColorName: "green", badge: "Clipboard",
                        execute: { NSWorkspace.shared.activateFileViewerSelecting(captured) }))
            }
        }
        return pills
    }

    /// Compact pills that surface automatically detected context (files, browser tab, selection text).
    /// Shown when context-awareness is enabled so L2 stays focused on user-selected context.
    func buildAutoDetectedContextPills(query q: String) -> [DockPill] {
        guard settings.enableContextAIExtensions else { return [] }

        let needle = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var pills: [DockPill] = []

        func add(
            _ id: String, _ name: String, _ icon: String, _ color: String, badge: String?,
            action: @escaping () -> Void
        ) {
            if !needle.isEmpty {
                let haystack = "\(name) \(badge ?? "")".lowercased()
                guard haystack.contains(needle) else { return }
            }
            pills.append(
                DockPill(
                    id: "autocx-\(id)",
                    name: name,
                    icon: icon,
                    accentColorName: color,
                    badge: badge,
                    execute: action
                ))
        }

        switch currentContext {
        case .filesSelected(let urls) where !urls.isEmpty:
            let firstName = urls[0].lastPathComponent
            let badge = urls.count == 1 ? firstName : "\(urls.count) selected"
            add("files", "File Context", "folder.badge.person.crop", "blue", badge: badge) {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }

        case .url(let urlString):
            let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmedURL), !trimmedURL.isEmpty {
                let badge = url.host ?? "Browser"
                add("url", "Web Context", "globe", "teal", badge: badge) {
                    NSWorkspace.shared.open(url)
                }
            }

        case .textSelected(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let compact = trimmed.replacingOccurrences(of: "\n", with: " ")
                let preview = String(compact.prefix(28))
                add("text", "Text Context", "text.quote", "orange", badge: preview) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(trimmed, forType: .string)
                }
            }

        default:
            break
        }

        // Fallback for cases where AX captured file selection but currentContext hasn't switched yet.
        if pills.isEmpty && !axContext.selectedFilePaths.isEmpty {
            let urls = axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
            let firstName = urls[0].lastPathComponent
            let badge = urls.count == 1 ? firstName : "\(urls.count) selected"
            add("files-ax", "File Context", "folder", "blue", badge: badge) {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }

        return Array(pills.prefix(2))
    }

    /// Detect current work session from running apps and re-order adapter actions.
    func sessionRankedAdapterActions(base: [AdapterAction]) -> [AdapterAction] {
        guard settings.sessionDetectionPills else { return base }
        let runningIds = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        // Session profiles: bundles that signal a session type, and action keywords to boost
        let devBundles = [
            "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.jetbrains", "io.cursor",
            "com.sublimetext", "com.github.atom", "com.panic.Nova",
        ]
        let browseBundles = [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        ]
        let commsBundles = [
            "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.microsoft.teams",
            "com.discord", "com.apple.mail",
        ]

        let isDev = devBundles.contains { b in runningIds.contains { $0.hasPrefix(b) } }
        let isBrowse = browseBundles.contains { b in runningIds.contains { $0.hasPrefix(b) } }
        let isComms = commsBundles.contains { b in runningIds.contains { $0.hasPrefix(b) } }

        let boostKeywords: [String]
        if isDev {
            boostKeywords = ["build", "run", "debug", "test", "deploy", "commit", "push", "pull"]
        } else if isBrowse {
            boostKeywords = ["open", "browse", "search", "bookmark", "read", "save"]
        } else if isComms {
            boostKeywords = ["send", "share", "copy", "message", "paste", "email"]
        } else {
            return base
        }

        return base.sorted { a, b in
            let aBoost = boostKeywords.contains { a.name.lowercased().contains($0) }
            let bBoost = boostKeywords.contains { b.name.lowercased().contains($0) }
            if aBoost != bBoost { return aBoost }
            return false
        }
    }

    nonisolated func normalizedDockPillText(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                return Character(scalar)
            }
            return " "
        }
        return String(mapped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func dockPillTokens(_ text: String) -> [String] {
        normalizedDockPillText(text).split(separator: " ").flatMap { rawToken -> [String] in
            let token = String(rawToken)
            switch token {
            case "fav", "favs", "favourite", "favourites", "favorite", "favorites", "favourate",
                "favourates":
                return [token, "favorite"]
            default:
                return [token]
            }
        }
    }

    /// Returns a human-readable parent menu label from an AXMenuItem path.
    /// e.g. ["File", "Open Recent", "doc.txt"] → "Open Recent"
    ///      ["Apple", "About This Mac"] → "Apple Menu"
    nonisolated func menuContextLabel(from path: [String]) -> String? {
        guard path.count > 1 else { return nil }
        let parent = path[path.count - 2]
        switch parent {
        case "Apple": return "Apple Menu"
        case "Open Recent": return "Recent Items"
        default: return parent
        }
    }

    nonisolated func isAppleMenuItem(_ item: AXMenuItem) -> Bool {
        item.isAppleMenu
            || menuContextLabel(from: item.path) == "Apple Menu"
            || item.path.first == "Apple"
    }

    nonisolated func isApplicationMenuItem(_ item: AXMenuItem, appName: String) -> Bool {
        let normalizedAppName = normalizedDockPillText(appName)
        guard !normalizedAppName.isEmpty,
            let root = item.path.first.map(normalizedDockPillText),
            !root.isEmpty
        else { return false }
        return root == normalizedAppName
    }

    nonisolated func isRejectedTopMenuItem(_ item: AXMenuItem, appName: String) -> Bool {
        isAppleMenuItem(item)
    }

    nonisolated func isGenericAppMenu(_ item: AXMenuItem) -> Bool {
        let title = normalizedDockPillText(item.title)
        let genericPatterns = [
            "about", "help", "quit", "exit", "close",
            "settings", "preferences", "options",
            "hide", "show", "reveal",
            "services", "documentation",
        ]
        return genericPatterns.contains { title.contains($0) }
    }

    func menuItemsVisibleInActiveDockMode(_ items: [AXMenuItem]) -> [AXMenuItem] {
        items.filter { !isAppleMenuItem($0) }
    }

    /// macOS-style dock magnification scale for a pill at `index`.
    /// Peaked at the hovered/focused index, falls off smoothly with distance.
    func dockMagnificationScale(for index: Int) -> CGFloat {
        let refIdx = l2.focusedPillIndex ?? hoveredDockPillIndex
        guard let ref = refIdx else { return 1.0 }
        let dist = CGFloat(abs(index - ref))
        let peak: CGFloat = 0.30  // +30% at the focal pill
        let falloff: CGFloat = 2.5  // distance at which magnification reaches zero
        return 1.0 + peak * max(0, 1.0 - dist / falloff)
    }

    func dockPillAppAliases(appName: String, bundleId: String) -> [String] {
        var aliases = Set<String>()
        let normalizedName = normalizedDockPillText(appName)
        if !normalizedName.isEmpty {
            aliases.insert(normalizedName)
            if let firstWord = normalizedName.split(separator: " ").first {
                aliases.insert(String(firstWord))
            }
            if normalizedName == "visual studio code" || normalizedName == "vs code" {
                aliases.formUnion(["code", "vscode", "vs code", "visual studio code"])
            }
            if normalizedName.hasSuffix("s"), normalizedName.count > 3 {
                aliases.insert(String(normalizedName.dropLast()))
            }
        }

        if let bundleTail = bundleId.split(separator: ".").last {
            let tail = normalizedDockPillText(String(bundleTail))
            if !tail.isEmpty && tail != "app" {
                aliases.insert(tail)
            }
        }

        switch bundleId {
        case "com.apple.MobileSMS":
            aliases.formUnion(["messages", "message", "imessage", "texts"])
        case "com.apple.mail":
            aliases.formUnion(["mail", "email"])
        case "com.apple.systempreferences":
            aliases.formUnion(["settings", "preferences", "system settings", "system preferences"])
        case "com.apple.Safari":
            aliases.insert("safari")
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders":
            aliases.formUnion(["code", "vscode", "vs code", "visual studio code"])
        default:
            break
        }

        return aliases.filter { !$0.isEmpty }
    }

    func defaultDockPillTrackingIdentifier(_ pill: DockPill) -> String {
        if !pill.trackingIdentifier.isEmpty {
            return pill.trackingIdentifier
        }

        let scope = pill.sourceBundleId.isEmpty ? "global" : pill.sourceBundleId
        let baseName =
            !pill.menuItemName.isEmpty ? pill.menuItemName : pill.name
        let normalizedBase = normalizedDockPillText(baseName)
        if pill.rankingKind == "menu", !normalizedBase.isEmpty {
            return "dock-menu:\(scope):\(normalizedBase)"
        }
        return "dock-pill:\(scope):\(pill.rankingKind):\(normalizedBase)"
    }

    func dockPillKindBaseScore(_ pill: DockPill) -> Double {
        switch pill.rankingKind {
        case "appLaunch": return 136
        case "appSwitch": return 134
        case "nativeWindow": return 132
        case "semanticIntent": return 128
        case "finderCurrent": return 114
        case "finderSearch": return 104
        case "adapter", "appAdapter": return 108
        case "menu": return 98
        case "submenuParent": return 96
        case "payload": return 94
        case "cliTool": return 92
        case "quickAction": return 90
        case "contextExtension": return 86
        case "tool": return 82
        case "crossApp": return 72
        case "finderContext": return 68
        case "context", "clipboard": return 62
        default: return 58
        }
    }

    func scoreDockPill(
        _ pill: DockPill,
        originalIndex: Int,
        query: String,
        rawQuery: String,
        scopedBundleId: String,
        scopedAppName: String,
        isExplicitAppScope: Bool
    ) -> Double {
        var score = dockPillKindBaseScore(pill)
        let trackingIdentifier = defaultDockPillTrackingIdentifier(pill)
        let usageScore = UsageTracker.shared.getScore(for: trackingIdentifier)
        score += usageScore * (query.isEmpty ? 8.5 : 6.5)

        // Boost frequently-used actions from per-app interaction history
        if let bid = pill.sourceBundleId.isEmpty ? nil : Optional(pill.sourceBundleId),
            let aid = trackingIdentifier.components(separatedBy: ":").dropFirst().joined(
                separator: ":") as String?
        {
            let boost = AppInteractionStore.shared.frequencyBoost(bundleId: bid, actionId: aid)
            score += boost * (query.isEmpty ? 55 : 35)
        }

        if pill.isFavourited {
            score += 190
        }

        let frontBundleId =
            frontmost.bundleID.isEmpty ? axContext.bundleId : frontmost.bundleID
        let sourceBundleId = pill.sourceBundleId.isEmpty ? scopedBundleId : pill.sourceBundleId
        let sourceAppName = pill.sourceAppName.isEmpty ? scopedAppName : pill.sourceAppName

        if !sourceBundleId.isEmpty {
            if sourceBundleId == scopedBundleId {
                score += isExplicitAppScope ? 220 : 125
            } else if sourceBundleId == frontBundleId {
                score += isExplicitAppScope ? 28 : 92
            } else if isExplicitAppScope {
                score -= 35
            }
        }

        let appAliases = dockPillAppAliases(appName: sourceAppName, bundleId: sourceBundleId)
        let normalizedName = normalizedDockPillText(pill.name)
        let normalizedBadge = normalizedDockPillText(pill.badge ?? "")
        let corpora =
            ([normalizedName, normalizedBadge] + pill.searchTerms.map(normalizedDockPillText)
            + appAliases)
            .filter { !$0.isEmpty }

        if !rawQuery.isEmpty && appAliases.contains(rawQuery) {
            score += sourceBundleId == scopedBundleId ? 120 : 60
        }

        if query.isEmpty {
            let isPureScopedAppSelection =
                isExplicitAppScope && !rawQuery.isEmpty && appAliases.contains(rawQuery)
            if pill.rankingKind == "adapter" || pill.rankingKind == "appAdapter" {
                score += isPureScopedAppSelection ? 72 : 28
            }
            if pill.rankingKind == "quickAction" {
                score += isPureScopedAppSelection ? 40 : 18
            }
            if pill.rankingKind == "menu" {
                score += isPureScopedAppSelection ? 34 : 18
            }
            if pill.rankingKind == "cliTool" {
                score += isPureScopedAppSelection ? 8 : 24
            }
            if pill.rankingKind == "appLaunch" && isPureScopedAppSelection {
                score -= 84
            }
            if normalizedName.hasPrefix("new ") || normalizedName == "new" {
                score += 22
            }
            return score - (Double(originalIndex) * 0.01)
        }

        if let relevance = rankedTextMatchScore(
            query: query,
            primary: normalizedName,
            aliases: pill.searchTerms,
            contexts: [normalizedBadge] + appAliases
        ) {
            score += relevance / 24.0
        }

        if normalizedName == query {
            score += 280
        } else if corpora.contains(query) {
            score += 220
        }

        if normalizedName.hasPrefix(query) {
            score += 195
        } else if corpora.contains(where: { $0.hasPrefix(query) }) {
            score += 165
        }

        if normalizedName.contains(query) {
            score += 120
        } else if corpora.contains(where: { $0.contains(query) }) {
            score += 82
        }

        let orderedQueryTokens = dockPillTokens(query)
        let queryTokens = Set(orderedQueryTokens)
        if !queryTokens.isEmpty {
            let nameTokens = Set(dockPillTokens(normalizedName))
            let corpusTokens = Set(corpora.flatMap(dockPillTokens))
            let nameOverlap = queryTokens.intersection(nameTokens).count
            let corpusOverlap = queryTokens.intersection(corpusTokens).count

            if nameOverlap > 0 {
                score += Double(nameOverlap) * 54
            }
            if corpusOverlap > nameOverlap {
                score += Double(corpusOverlap - nameOverlap) * 30
            }

            if let firstToken = orderedQueryTokens.first {
                if nameTokens.contains(firstToken) {
                    score += 34
                }
                if normalizedName.hasPrefix(firstToken) {
                    score += 28
                }
            }

            // Typo-tolerance: boost when a query token is within edit distance 1-2 of a corpus token
            // Handles "wallpapper" → "wallpaper", "settngs" → "settings", etc.
            for qt in queryTokens where qt.count >= 4 {
                for ct in corpusTokens where ct.count >= 4 {
                    guard !queryTokens.contains(ct) else { continue }  // already scored exactly
                    let dist = pillEditDistance(qt, ct)
                    let maxLen = max(qt.count, ct.count)
                    if dist == 1 {
                        score += 38 * (1.0 - Double(dist) / Double(maxLen))
                    } else if dist == 2 && maxLen >= 7 {
                        score += 18 * (1.0 - Double(dist) / Double(maxLen))
                    }
                }
            }
        }

        return score - (Double(originalIndex) * 0.01)
    }

    /// Levenshtein edit distance (capped early at 3 for performance).
    func pillEditDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count
        let n = b.count
        if abs(m - n) > 3 { return 4 }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            var rowMin = i
            for j in 1...n {
                curr[j] =
                    a[i - 1] == b[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], curr[j - 1])
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > 3 { return 4 }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    func rankDockPills(
        _ pills: [DockPill],
        rawQuery: String,
        rankingQuery: String,
        scopedBundleId: String,
        scopedAppName: String,
        isExplicitAppScope: Bool,
        includeNonMatching: Bool = false
    ) -> [DockPill] {
        guard !rawQuery.isEmpty else { return pills }

        let normalizedRawQuery = normalizedDockPillText(rawQuery)
        let normalizedRankingQuery = normalizedDockPillText(rankingQuery)

        return pills.enumerated()
            .map { index, pill in
                var enriched = pill
                enriched.trackingIdentifier = defaultDockPillTrackingIdentifier(pill)
                enriched.rankingScore = scoreDockPill(
                    enriched,
                    originalIndex: index,
                    query: normalizedRankingQuery,
                    rawQuery: normalizedRawQuery,
                    scopedBundleId: scopedBundleId,
                    scopedAppName: scopedAppName,
                    isExplicitAppScope: isExplicitAppScope
                )
                return enriched
            }
            .filter { pill in
                includeNonMatching
                    || normalizedRankingQuery.isEmpty
                    || dockPillHasQuerySignal(
                        pill,
                        query: normalizedRankingQuery,
                        rawQuery: normalizedRawQuery,
                        scopedBundleId: scopedBundleId,
                        scopedAppName: scopedAppName
                    )
            }
            .sorted { lhs, rhs in
                if lhs.rankingScore == rhs.rankingScore {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.rankingScore > rhs.rankingScore
            }
    }

    func dedupeRankedDockPills(_ pills: [DockPill]) -> [DockPill] {
        var seen = Set<String>()
        var result: [DockPill] = []

        for pill in pills {
            let key: String = {
                let source = pill.sourceBundleId.isEmpty ? "global" : pill.sourceBundleId
                let name = normalizedDockPillText(
                    pill.menuItemName.isEmpty ? pill.name : pill.menuItemName
                )
                let context = normalizedDockPillText(pill.menuContext ?? pill.badge ?? "")

                switch pill.rankingKind {
                case "menu", "finderMenu", "submenuParent", "submenuChild":
                    return "menu:\(source):\(context):\(name)"
                case "appLaunch":
                    return "app:\(source):\(name)"
                case "quickAction", "adapter", "appAdapter", "cliTool", "tool", "userExtension":
                    return
                        "\(pill.rankingKind):\(source):\(pill.trackingIdentifier.isEmpty ? name : pill.trackingIdentifier)"
                default:
                    return "\(pill.rankingKind):\(source):\(name):\(context)"
                }
            }()

            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                seen.insert(key).inserted
            else { continue }
            result.append(pill)
        }

        return result
    }

    func dockPillHasQuerySignal(
        _ pill: DockPill,
        query: String,
        rawQuery: String,
        scopedBundleId: String,
        scopedAppName: String
    ) -> Bool {
        if query.isEmpty { return true }
        if [
            "payload", "finderSearch", "finderCurrent", "finderGoTo", "submenuChild",
            "submenuParent",
        ].contains(pill.rankingKind) {
            return true
        }

        let sourceBundleId = pill.sourceBundleId.isEmpty ? scopedBundleId : pill.sourceBundleId
        let sourceAppName = pill.sourceAppName.isEmpty ? scopedAppName : pill.sourceAppName
        let appAliases = dockPillAppAliases(appName: sourceAppName, bundleId: sourceBundleId)
        if !rawQuery.isEmpty, appAliases.contains(rawQuery) { return true }

        let normalizedName = normalizedDockPillText(pill.name)
        let normalizedBadge = normalizedDockPillText(pill.badge ?? "")
        let corpora =
            ([normalizedName, normalizedBadge] + pill.searchTerms.map(normalizedDockPillText)
            + appAliases)
            .filter { !$0.isEmpty }

        if corpora.contains(query) { return true }
        if corpora.contains(where: { $0.hasPrefix(query) || $0.contains(query) }) { return true }

        let queryTokens = Set(dockPillTokens(query))
        guard !queryTokens.isEmpty else { return false }
        let corpusTokens = Set(corpora.flatMap(dockPillTokens))
        if !queryTokens.intersection(corpusTokens).isEmpty { return true }

        for qt in queryTokens where qt.count >= 4 {
            for ct in corpusTokens where ct.count >= 4 {
                if pillEditDistance(qt, ct) <= 2 { return true }
            }
        }
        return false
    }

    /// If `q` starts with a known recent/running app name, returns (that app, remainder query).
    /// e.g. "safari tab" → (safariApp, "tab")   "xcode build" → (xcodeApp, "build")

}
