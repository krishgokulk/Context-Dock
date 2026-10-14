import AppKit
import Foundation
import PDFKit
import SwiftUI

struct FinderDesktopSearchRecord: Sendable {
    let pathKey: String
    let normalizedName: String
    let normalizedTerms: [String]
    var isDirectory: Bool = false

    nonisolated func score(for query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let base: Int?
        if normalizedName == query { base = 600 }
        else if (normalizedName as NSString).deletingPathExtension == query { base = 550 }
        else if normalizedName.hasPrefix(query) { base = 500 }
        else if normalizedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.hasPrefix(query) }) { base = 400 }
        else if normalizedName.contains(query) { base = 300 }
        else if normalizedTerms.contains(where: { $0.contains(query) }) { base = 150 }
        else { base = nil }
        guard let base else { return nil }
        // Folders lead their file peers of the same match tier — the Finder/Spotlight
        // convention — so directories no longer scatter to the bottom of the list.
        return isDirectory ? base + 80 : base
    }
}

extension DockCore {
    // MARK: - Unified dock pill list (drives both rendering and keyboard navigation)

    /// A lightweight token for each pill currently visible in the dock.
    struct ClipboardEntry: Identifiable, Codable {
        let id: UUID
        let text: String
        let timestamp: Date
        var filePaths: [String] = []
        /// Full image bytes, held in memory only for the newest clips. Older clips keep
        /// their blob in `ClipboardImageStore` and load it on demand — see `imageFileName`.
        /// Never persisted inside the history JSON (that used to rewrite tens of MB of
        /// base64 on every single copy).
        var imageData: Data? = nil
        /// PNG sidecar name in `ClipboardImageStore`; the durable form of `imageData`.
        var imageFileName: String? = nil
        var ocrText: String = ""
        var sourceAppName: String = ""
        var sourceBundleId: String = ""
        /// Produced by Capture Text / Capture Area / Screenshot rather than a Cmd-C.
        var isScreenCapture: Bool = false
        /// Stable de-duplication key. Persisted because an image clip's bytes are lazy —
        /// hashing `imageData` at compare time stopped working once blobs moved to disk.
        var contentHash: String = ""

        init(
            id: UUID = UUID(),
            text: String,
            timestamp: Date,
            filePaths: [String] = [],
            imageData: Data? = nil,
            imageFileName: String? = nil,
            ocrText: String = "",
            sourceAppName: String = "",
            sourceBundleId: String = "",
            isScreenCapture: Bool = false,
            contentHash: String = ""
        ) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.filePaths = filePaths
            self.imageData = imageData
            self.imageFileName = imageFileName
            self.ocrText = ocrText
            self.sourceAppName = sourceAppName
            self.sourceBundleId = sourceBundleId
            self.isScreenCapture = isScreenCapture
            self.contentHash = contentHash
        }

        enum CodingKeys: String, CodingKey {
            case id, text, timestamp, filePaths, imageData, imageFileName
            case ocrText, sourceAppName, sourceBundleId, isScreenCapture, contentHash
        }

        /// Decoding still reads `imageData` so histories written by older builds keep
        /// their images (they get migrated to a sidecar blob on the next save); encoding
        /// deliberately drops it. Every optional-with-default key decodes leniently so a
        /// history written by an older build never fails to load as a whole.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
            filePaths = try container.decodeIfPresent([String].self, forKey: .filePaths) ?? []
            imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
            imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
            ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
            sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName) ?? ""
            sourceBundleId =
                try container.decodeIfPresent(String.self, forKey: .sourceBundleId) ?? ""
            isScreenCapture =
                try container.decodeIfPresent(Bool.self, forKey: .isScreenCapture) ?? false
            contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(filePaths, forKey: .filePaths)
            try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
            try container.encode(ocrText, forKey: .ocrText)
            try container.encode(sourceAppName, forKey: .sourceAppName)
            try container.encode(sourceBundleId, forKey: .sourceBundleId)
            try container.encode(isScreenCapture, forKey: .isScreenCapture)
            try container.encode(contentHash, forKey: .contentHash)
        }

        var isImage: Bool { imageData != nil || imageFileName != nil }
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
        /// True for scopes entered explicitly (right-arrow on a running app) rather
        /// than by typing the app's name. Explicit scopes are sticky — they survive
        /// alias reconciliation so the user can type an action query without the scope
        /// (whose alias isn't in the query) being dropped.
        var isExplicit: Bool = false
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
        // A corner build or run: the captured selection is the whole truth, never the live one.
        if SelectionActions.isScopedToCapturedSelection { return [] }

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

        let normalizedQuery = normalizedDockPillText(q)

        func add(
            _ id: String,
            _ name: String,
            _ icon: String,
            _ color: String,
            aliases: [String] = [],
            _ action: @escaping () -> Void
        ) {
            let searchTerms = [name, id, ext, label, firstName, "finder", "selection"] + aliases
            if !normalizedQuery.isEmpty {
                let haystacks = searchTerms.map(normalizedDockPillText)
                let tokens = Set(haystacks.flatMap(dockPillTokens))
                let queryTokens = Set(dockPillTokens(normalizedQuery))
                let matches =
                    haystacks.contains { term in
                        term.contains(normalizedQuery) || normalizedQuery.contains(term)
                    }
                    || !queryTokens.intersection(tokens).isEmpty
                    || queryTokens.contains(ext)
                guard matches else { return }
            }

            var pill = DockPill(
                id: "finder-ctx-\(id)", name: name, icon: icon,
                accentColorName: color, badge: label, execute: action)
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.rankingKind = "finderSelection"
            pill.trackingIdentifier = "finder-selection:\(id)"
            pill.searchTerms = searchTerms
            pill.isEnabled = true
            pill.hasLiveAvailability = true
            pills.append(pill)
        }

        add("ql", "Quick Look", "eye", "blue", aliases: ["preview", "view", "space"]) {
            NSWorkspace.shared.activateFileViewerSelecting(
                paths.compactMap { URL(fileURLWithPath: $0) })
        }
        add("open", "Open", "arrow.up.right.square", "blue", aliases: ["launch"]) {
            for p in paths { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
        add("reveal", "Show in Finder", "folder", "gray", aliases: ["reveal", "locate"]) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
        }
        add("copypath", "Copy Path", "doc.on.clipboard", "teal", aliases: ["copy", "path"]) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(paths.joined(separator: "\n"), forType: .string)
        }
        add("share", "Share…", "square.and.arrow.up", "blue", aliases: ["airdrop", "send"]) {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            presentSharingPicker(items: urls)
        }
        let convertibleFiles = selectedURLs.filter(MarkItDownService.supports)
        if !convertibleFiles.isEmpty, MarkItDownService.isAvailable {
            add(
                "markitdown",
                convertibleFiles.count == 1 ? "Convert to Markdown" : "Convert to Markdown",
                "doc.text",
                "purple",
                aliases: ["markdown", "extract", "document", "text", "markitdown"]
            ) {
                convertFilesToMarkdown(convertibleFiles)
            }
        }
        if count > 1 {
            add(
                "new-folder-selection",
                "New Folder with Selection",
                "folder.badge.plus",
                "green",
                aliases: ["folder", "group"]
            ) {
                executeFinderSelectionMenuAction(titleContains: "new folder with selection")
            }
        }
        add(
            "compress",
            count > 1 ? "Compress \(count) Items" : "Compress",
            "archivebox",
            "yellow",
            aliases: ["zip", "archive"]
        )
        {
            executeFinderSelectionMenuAction(titleContains: "compress")
        }
        if selectedURLs.allSatisfy({
            imageExtsForFinderSelection.contains($0.pathExtension.lowercased())
        }) {
            add("create-pdf", "Create PDF", "doc.richtext", "red", aliases: ["pdf", "make pdf"]) {
                createPDFFromFinderSelectionImages(selectedURLs)
            }
            add("rotate-left", "Rotate Left", "rotate.left", "blue", aliases: ["rotate"]) {
                executeFinderSelectionMenuAction(titleContains: "rotate left")
            }
            add("markup", "Markup", "pencil.tip.crop.circle", "blue", aliases: ["edit", "annotate"]) {
                executeFinderSelectionMenuAction(titleContains: "markup")
            }
            add(
                "remove-background",
                "Remove Background",
                "person.crop.rectangle",
                "purple",
                aliases: ["background", "cutout"]
            ) {
                executeFinderSelectionMenuAction(titleContains: "remove background")
            }
            add("convert-image", "Convert Image", "photo.stack", "purple", aliases: ["convert"]) {
                executeFinderSelectionMenuAction(titleContains: "convert image")
            }
            add("set-wallpaper", "Set as Wallpaper", "photo.fill", "green", aliases: ["wallpaper"]) {
                executeFinderSelectionMenuAction(titleContains: "set as wallpaper")
            }
        }
        add("trash", "Move to Bin", "trash", "red", aliases: ["delete", "remove", "bin"]) {
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
            add("preview-img", "Open in Preview", "photo", "purple", aliases: ["preview", "image"]) {
                openInApp(URL(fileURLWithPath: first), appName: "Preview")
            }
        }
        if videoExts.contains(ext) {
            add("play", "Play in QuickTime", "play.circle", "red", aliases: ["video", "quicktime"]) {
                openInApp(URL(fileURLWithPath: first), appName: "QuickTime Player")
            }
        }
        if pdfExts.contains(ext) {
            add("preview-pdf", "Open in Preview", "doc.richtext", "red", aliases: ["pdf", "preview"]) {
                openInApp(URL(fileURLWithPath: first), appName: "Preview")
            }
        }
        if archiveExts.contains(ext) {
            add("unzip", "Unarchive", "archivebox.circle", "yellow", aliases: ["unzip", "extract"]) {
                let dir = URL(fileURLWithPath: first).deletingLastPathComponent().path
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", first, "-d", dir]
                try? proc.run()
            }
        }
        if textExts.contains(ext) {
            add("texteditor", "Open in TextEdit", "doc.plaintext", "gray", aliases: ["text", "edit"]) {
                openInApp(URL(fileURLWithPath: first), appName: "TextEdit")
            }
        }
        return pills
    }

    func convertFilesToMarkdown(_ urls: [URL]) {
        let jobs = urls.map { input -> (URL, URL) in
            let output = uniqueFinderOutputURL(
                directory: input.deletingLastPathComponent(),
                baseName: input.deletingPathExtension().lastPathComponent,
                extensionName: "md"
            )
            return (input, output)
        }
        Task.detached(priority: .userInitiated) {
            var created: [URL] = []
            for (input, output) in jobs {
                guard let converted = MarkItDownService.convert(
                    input,
                    characterBudget: 500_000
                ) else { continue }
                do {
                    try converted.markdown.write(to: output, atomically: true, encoding: .utf8)
                    created.append(output)
                } catch { continue }
            }
            let completed = created
            await MainActor.run {
                if completed.isEmpty {
                    AppToast.show(
                        "MarkItDown could not convert the selection",
                        icon: "exclamationmark.triangle",
                        tint: .orange)
                } else {
                    AppToast.show(
                        completed.count == 1
                            ? "Created \(completed[0].lastPathComponent)"
                            : "Created \(completed.count) Markdown files",
                        icon: "doc.text",
                        tint: .purple)
                    NSWorkspace.shared.activateFileViewerSelecting(completed)
                }
            }
        }
    }

    func buildMarkItDownPagePills(query q: String) -> [DockPill] {
        guard MarkItDownService.isAvailable else { return [] }
        let bundleId = axContext.bundleId.isEmpty ? frontmost.bundleID : axContext.bundleId
        guard bundleId.hasPrefix("com.apple.Safari")
                || bundleId.lowercased().contains("chrome")
                || bundleId.lowercased().contains("browser"),
            let rawURL = axContext.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url,
            let url = URL(string: rawURL),
            MarkItDownService.supports(url)
        else { return [] }

        let normalized = normalizedDockPillText(q)
        let terms = ["convert page to markdown", "markdown page", "extract page", "markitdown"]
        if !normalized.isEmpty,
            !terms.map(normalizedDockPillText).contains(where: {
                $0.contains(normalized) || normalized.contains($0)
                    || !Set(dockPillTokens($0)).intersection(dockPillTokens(normalized)).isEmpty
            })
        { return [] }

        var pill = DockPill(
            id: "markitdown-current-page",
            name: "Convert Page to Markdown",
            icon: "doc.text",
            accentColorName: "purple",
            badge: URL(string: rawURL)?.host,
            execute: { convertPageToMarkdown(url) }
        )
        pill.rankingKind = "browser"
        pill.sourceBundleId = bundleId
        pill.sourceAppName = axContext.appName
        pill.trackingIdentifier = "markitdown:page"
        pill.searchTerms = terms
        return [pill]
    }

    func convertPageToMarkdown(_ url: URL) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let output = uniqueFinderOutputURL(
            directory: downloads,
            baseName: url.host ?? "Web Page",
            extensionName: "md")
        Task.detached(priority: .userInitiated) {
            let converted = MarkItDownService.convert(url, characterBudget: 500_000)
            let saved: Bool
            if let markdown = converted?.markdown {
                do {
                    try markdown.write(to: output, atomically: true, encoding: .utf8)
                    saved = true
                } catch {
                    saved = false
                }
            } else {
                saved = false
            }
            await MainActor.run {
                guard converted != nil, saved else {
                    AppToast.show("Could not convert this page", icon: "exclamationmark.triangle", tint: .orange)
                    return
                }
                AppToast.show("Saved \(output.lastPathComponent)", icon: "doc.text", tint: .purple)
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
        }
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


    func buildFinderDesktopModePills(query: String) -> [DockPill] {
        // Browsing INTO a folder: show its contents (filtered by the typed query),
        // not the search results.
        if isBrowsingFinderFolder {
            return finderBrowseContentsPills(query: query)
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

        // Finder desktop has its own ranker: match-quality first (exact/prefix name > contains >
        // content-only), then clustered into type groups. rankDockPills would re-score by the
        // generic menu heuristics and lose that, so bypass it here.
        var ranked = rankedFinderDesktopPills(
            buildFinderDesktopModePills(query: q), query: q)
        // No user folders configured and nothing selected in Finder → there is
        // nothing to search. Surface a one-tap hint (appended after ranking so it
        // survives even when the query matches nothing) that opens Settings →
        // Data & Storage where search directories are added.
        if finderDesktopHasNoSearchScope {
            ranked.append(finderAddSearchDirectorySuggestionPill())
        } else if ranked.isEmpty, !q.isEmpty {
            ranked.append(finderDesktopNoResultsPill(query: q))
        }
        replaceCachedDockPills(ranked, preserveFocus: preserveFocus)
        lastPillQuery = q
    }



    /// Match-quality score for a Finder desktop file/folder against the query. Higher = better.
    /// Exact/prefix NAME beats a mid-name contains, which beats a content-only hit — so the top
    /// row is always the best name match, Spotlight/Raycast style (not just most-recent).
    func finderDesktopMatchScore(name: String, searchTerms: [String], query: String) -> Int {
        let n = name.lowercased()
        let q = query.lowercased()
        guard !q.isEmpty else { return 0 }
        if n == q { return 600 }
        let base = (n as NSString).deletingPathExtension
        if base == q { return 550 }
        if n.hasPrefix(q) { return 500 }
        // Word-boundary prefix: "career" matches "Albo Careers".
        let words = n.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 400 }
        if n.contains(q) { return 300 }
        // Name doesn't match at all → this is a content-only hit (Spotlight text index).
        if searchTerms.contains(where: { $0.lowercased().contains(q) }) { return 150 }
        return 100
    }

    /// Type bucket for grouping Finder desktop results (Folders / Images / Documents / Media / Files).
    func finderDesktopTypeGroup(_ pill: DockPill) -> String {
        if pill.icon.localizedCaseInsensitiveContains("folder") { return "Folders" }
        let ext = (pill.name as NSString).pathExtension.lowercased()
        let images: Set<String> = [
            "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp", "svg", "raw",
        ]
        let docs: Set<String> = [
            "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers", "xls", "xlsx",
            "ppt", "pptx", "csv",
        ]
        let media: Set<String> = [
            "mp4", "mov", "m4v", "mp3", "wav", "aac", "flac", "mkv", "avi", "m4a",
        ]
        if images.contains(ext) { return "Images" }
        if docs.contains(ext) { return "Documents" }
        if media.contains(ext) { return "Media" }
        return "Files"
    }

    /// Rank Finder desktop file pills by match quality, then cluster into type groups ordered by
    /// their best member — so the group holding the top match leads and each type appears once.
    func rankedFinderDesktopPills(_ pills: [DockPill], query: String) -> [DockPill] {
        // Frequency of past opens, so the user's most-launched items surface first.
        func openCount(_ pill: DockPill) -> Int {
            guard let path = pill.resolvedURL?.path else { return 0 }
            return FinderOpenFrequencyStore.shared.count(forPath: path)
        }

        // Empty query = the default Finder desktop list. Group by type (Folders /
        // Applications / Documents / Images / …) and, within each group, order by how
        // often the user opens each item (most-launched first). Groups are ordered by
        // their hottest member so the most-used type leads. The dock list adds the
        // section headers from the same type grouping.
        guard !query.isEmpty else {
            let indexed = pills.enumerated().map { (order: $0.offset, pill: $0.element) }
            let groups = Dictionary(grouping: indexed) { finderDesktopTypeGroup($0.pill) }
            let groupOrder = groups.keys.sorted { a, b in
                if a == "Folders" || b == "Folders" { return a == "Folders" }
                let fa = groups[a]?.map { openCount($0.pill) }.max() ?? 0
                let fb = groups[b]?.map { openCount($0.pill) }.max() ?? 0
                if fa != fb { return fa > fb }
                return a < b
            }
            return groupOrder.flatMap { key -> [DockPill] in
                (groups[key] ?? [])
                    .sorted { l, r in
                        let fl = openCount(l.pill), fr = openCount(r.pill)
                        return fl != fr ? fl > fr : l.order < r.order
                    }
                    .map(\.pill)
            }
        }

        struct Scored { var pill: DockPill; var score: Int; var freq: Int; var order: Int }
        let scored = pills.enumerated().map { idx, pill -> Scored in
            var p = pill
            let s = finderDesktopMatchScore(
                name: p.name, searchTerms: p.searchTerms, query: query)
            p.rankingScore = Double(s)
            return Scored(pill: p, score: s, freq: openCount(pill), order: idx)
        }
        let groups = Dictionary(grouping: scored) { finderDesktopTypeGroup($0.pill) }
        let groupOrder = groups.keys.sorted { a, b in
            // Place-first Finder behavior: a matching directory is more useful than an
            // individual file because it can be drilled into and scopes what follows.
            if a == "Folders" || b == "Folders" { return a == "Folders" }
            let ma = groups[a]?.map(\.score).max() ?? 0
            let mb = groups[b]?.map(\.score).max() ?? 0
            if ma != mb { return ma > mb }
            return a < b
        }
        return groupOrder.flatMap { key -> [DockPill] in
            (groups[key] ?? [])
                // Match quality first, then most-opened, then stable input order — so
                // frequency only breaks ties between equally-good name matches and can
                // never override a better textual match.
                .sorted { l, r in
                    if l.score != r.score { return l.score > r.score }
                    if l.freq != r.freq { return l.freq > r.freq }
                    return l.order < r.order
                }
                .map(\.pill)
        }
    }

    /// True when the Finder desktop scope has no folders to search: the user has
    /// added no search directories and no Finder selection is active.
    var finderDesktopHasNoSearchScope: Bool {
        settings.searchDirectories.filter { !$0.path.isEmpty }.isEmpty
            && effectiveFinderSelectionURLsForPills().isEmpty
    }

    /// Hint row shown when no search scope exists — opens Settings → Data &
    /// Storage so the user can add a folder to search.
    func finderAddSearchDirectorySuggestionPill() -> DockPill {
        var pill = DockPill(
            id: "finder-add-search-dir",
            name: "Add a folder to search files & folders",
            icon: "folder.badge.plus",
            accentColorName: "blue",
            badge: "Settings › Data & Storage",
            execute: {
                AppDelegate.shared?.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(
                        name: .openSettingsPage,
                        object: nil,
                        userInfo: ["page": SettingsPage.dataStorage.rawValue]
                    )
                }
            }
        )
        pill.rankingKind = "setupHint"
        pill.trackingIdentifier = "finder-setup-hint"
        pill.searchTerms = ["add", "folder", "search", "directory", "settings"]
        pill.rankingScore = -1  // keep at the very end of the list
        return pill
    }

    func finderDesktopNoResultsPill(query: String) -> DockPill {
        var pill = DockPill(
            id: "finder-no-results-\(query)",
            name: "No files or folders found",
            icon: "magnifyingglass",
            accentColorName: "gray",
            badge: query,
            execute: {}
        )
        pill.rankingKind = "emptyState"
        pill.trackingIdentifier = "finder-no-results"
        pill.isEnabled = false
        return pill
    }

    func finderDesktopRecentApplicationPills(query: String) -> [DockPill] {
        // Finder desktop mode is file/folder search only. Running apps belong to
        // Global Context app search, not this surface; mixing them made Enter/click
        // launch apps while user expected Desktop/Finder results.
        []
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
            execute: {
                // Record the open so most-launched items (Downloads, Screenshots,
                // Applications, hot files) rank to the top next time.
                FinderOpenFrequencyStore.shared.recordOpen(path: path)
                NSWorkspace.shared.open(url)
            }
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
            let isContextualSelectionMenu =
                item.path.contains { part in
                    ["file", "quick actions", "services", "open with", "tags"]
                        .contains(normalizedDockPillText(part))
                }
            if openWithFilter != nil, isOpenWithMenu, normalizedTitle != "open with" {
                continue
            }

            let path = item.path
            let sourcePID = item.sourcePID
            let shortcutChar = item.shortcutChar
            let shortcutModifiers = item.shortcutModifiers
            let badge = item.shortcutDisplay  // parent menu name dropped — use shortcut only
            // Bare "Share"/"Share…" ONLY — never path.contains("share"), which would
            // mis-mark real children (Mail/AirDrop) as the share trigger and click the
            // wrong destination. Children fall through and execute their exact path.
            let isShareItem = isShareSheetTitle(item.title)

            let menuImg = resolvedMenuIcon(for: item)
            let shareItem = item
            var pill = DockPill(
                id: "finder-menu-\(item.id)",
                name: item.title,
                icon: isShareItem ? "square.and.arrow.up" : menuSymbol(for: item),
                accentColorName: isShareItem ? "blue" : "gray",
                badge: badge,
                execute: {
                    if isShareItem {
                        executeShareAction(item: shareItem)
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
            pill.isEnabled =
                (isOpenWithMenu && normalizedTitle != "open with")
                || isContextualSelectionMenu
                || item.isEnabled
            pill.hasLiveAvailability =
                (isOpenWithMenu && normalizedTitle != "open with")
                || isContextualSelectionMenu
                || item.hasLiveAvailability
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
        // Selection-gated, no AppleScript/enumeration here — keep typing instant.
        // Browser-page sharing is reached via the app's "Share…" menu item instead.
        guard hasSelectionScopeSurface else { return [] }
        let normalizedQuery = normalizedDockPillText(q)
        if !normalizedQuery.isEmpty {
            let shareTerms = ["share", "send", "airdrop", "export", "message", "mail"]
            guard
                shareTerms.contains(where: {
                    $0.hasPrefix(normalizedQuery) || normalizedQuery.contains($0)
                })
            else { return [] }
        }

        let badge: String = {
            switch effectiveSelectionForScope {
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
        // Single "Share Selection" pill. Activating it reveals the native destinations
        // inline — DoraX never bounces to the system NSSharingServicePicker.
        var pill = DockPill(
            id: "selection-share",
            name: "Share Selection",
            icon: "square.and.arrow.up",
            accentColorName: "blue",
            badge: badge,
            execute: { revealShareDestinations() }
        )
        pill.rankingKind = "payload"
        pill.trackingIdentifier = "selection-share"
        pill.searchTerms = [
            "share", "send", "airdrop", "export", "selection", "files", "text", "url",
        ]
        return [pill]
    }

    /// True only for the share-SHEET menu title ("Share", "Share…") — NOT incidental
    /// names like "Share My Screen" / "Shared with You", which are ordinary actions.
    func isShareSheetTitle(_ title: String) -> Bool {
        let t = normalizedDockPillText(title)
        return t == "share" || t == "share…" || t == "share..."
    }

    /// True when the scoped/frontmost app actually exposes a Share SHEET menu. Used to
    /// gate DoraX's share destinations so we never invent a Share for apps (e.g.
    /// Messages) whose menus contain no real Share item.
    func frontmostAppHasShareMenu() -> Bool {
        func scan(_ items: [AXMenuItem]) -> Bool {
            for item in items {
                if isShareSheetTitle(item.title) { return true }
                if item.path.map(normalizedDockPillText).contains("share") { return true }
                if !item.children.isEmpty, scan(item.children) { return true }
            }
            return false
        }
        return scan(liveMenuItems)
    }


    /// Activate DoraX's inline Share Sheet — the dock then shows ONLY the live
    /// native share destinations for the current content. Works in any app.
    func revealShareDestinations() {
        searchState.query = ""
        inlineShareActive = true
        scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: false)
    }

    /// Live native macOS share destinations (AirDrop, Mail, Messages, Notes, every
    /// installed share-extension) for the current page/selection, as DoraX pills.
    /// This is the inline replacement for NSSharingServicePicker.
    ///
    /// Listing uses the cached context (fast, no AppleScript). The real share runs at
    /// tap time via `liveShareItems()`, which resolves the live browser URL then.
    func buildInlineShareDestinationPills(query q: String) -> [DockPill] {
        let listingItems = ShareIntentRouter.shared.shareableItems(
            for: effectiveAXContextForConversation())
        guard !listingItems.isEmpty else {
            var pill = DockPill(
                id: "share-empty",
                name: "Nothing to share here",
                icon: "square.and.arrow.up",
                accentColorName: "gray",
                badge: nil,
                execute: { inlineShareActive = false }
            )
            pill.rankingKind = "payload"
            pill.isEnabled = false
            return [pill]
        }

        return shareDestinationPills(listingItems: listingItems, filter: normalizedDockPillText(q))
    }

    /// Typing "share"/"send"/"airdrop"/… directly surfaces the app's share children —
    /// the live NSSharingService destinations — for ANY app, no drill-in and without
    /// depending on AX having captured a lazy Share submenu. Gated to share-term queries
    /// so the enumeration never runs on ordinary typing. Listing uses cached context
    /// (no AppleScript); the real share resolves the live URL at tap.
    func buildShareQueryDestinationPills(query q: String) -> [DockPill] {
        let nq = normalizedDockPillText(q)
        guard nq.count >= 2 else { return [] }
        // Only when the app truly has a Share menu, or there's a selection to share.
        guard hasSelectionScopeSurface || frontmostAppHasShareMenu() else { return [] }
        // Share is ALWAYS sourced from NSSharingService.sharingServices(forItems:) — every
        // installed Share Extension (LocalSend, Downie, Bridges, Photomator, …), exactly like
        // the system Share Sheet. We never AX-click an app's Share children (avoids the
        // first-child-opens-AirDrop bug and AX timing). AX is only used to DETECT that a
        // Share menu exists; the payload + execution are pure macOS.
        let genericVerbs = ["share", "send", "export"]
        let destinationVerbs = ["airdrop", "mail", "message", "messages", "notes", "reminders"]
        let isGeneric = genericVerbs.contains { $0.hasPrefix(nq) }
        let isDestination = destinationVerbs.contains { $0.hasPrefix(nq) }
        guard isGeneric || isDestination else { return [] }

        let listingItems = ShareIntentRouter.shared.shareableItems(
            for: effectiveAXContextForConversation())
        guard !listingItems.isEmpty else { return [] }
        // Generic verb → show all destinations; a destination-name query → filter to it.
        let filter = isGeneric ? "" : nq
        return shareDestinationPills(listingItems: listingItems, filter: filter)
    }

    /// Shared builder: one DoraX pill per native share destination. `filter` matches
    /// destination titles ("" = all). Listing items drive enumeration; the live URL is
    /// resolved at tap so the correct page/file is shared.
    func shareDestinationPills(listingItems: [Any], filter normalizedQuery: String) -> [DockPill] {
        let destinations = ShareActionCoordinator.shared.shareDestinations(items: listingItems)
        return destinations.enumerated().compactMap { index, dest in
            let normalizedTitle = normalizedDockPillText(dest.title)
            guard ShareActionCoordinator.destinationMatches(
                normalizedTitle: normalizedTitle, normalizedQuery: normalizedQuery)
            else { return nil }
            var pill = DockPill(
                id: ShareActionCoordinator.destinationRowID(normalizedTitle: normalizedTitle),
                name: dest.title,
                icon: "square.and.arrow.up",
                accentColorName: "blue",
                badge: "Share",
                execute: {
                    inlineShareActive = false
                    // Learn the user's preferred destinations — ranks them higher next time.
                    ShareActionCoordinator.recordUse(normalizedTitle: normalizedTitle)
                    // Resolve the live payload BEFORE hiding (needs the source app context),
                    // then dismiss the launcher panel and run the service once the previous
                    // app is frontmost — NSSharingService can't present its UI (Mail/Messages
                    // compose, AirDrop sheet) from our background accessory panel.
                    let live = liveShareItems()
                    let items = live.isEmpty ? listingItems : live
                    self.forceHideLauncherAfterResultExecution()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        dest.perform(withItems: items)
                    }
                }
            )
            pill.menuItemImage = dest.image ?? shareDestinationIcon(forTitle: dest.title)
            pill.isShareAction = true
            pill.menuItemName = dest.title
            pill.menuContext = "Share"
            pill.rankingKind = "submenuChild"
            pill.hasLiveAvailability = true
            // Frecency-ranked: destinations you use most float to the top, with the system
            // order as the tiebreaker.
            pill.rankingScore = ShareActionCoordinator.rankingScore(
                normalizedTitle: normalizedTitle, systemIndex: index)
            pill.trackingIdentifier = ShareActionCoordinator.usageKey(normalizedTitle: normalizedTitle)
            pill.searchTerms = [dest.title, "share", "send", "airdrop", "export"]
            return pill
        }
    }

    /// Enter an AI chat grounded in the current selection (text / files / page URL). Every
    /// message in this session carries the selection, so the AI always answers about the
    /// user's current work — webpage, document, files. Submits `initialQuery` if given,
    /// otherwise greets with an open prompt.
    /// The selection the Dock's selection chat is about, in the shared form. A frozen Selection
    /// Scope payload is the whole truth; the live context fills in only when there is none.
    var dockSelectionSnapshot: SelectionSnapshot {
        let ctx = effectiveAXContextForConversation()
        if let payload = selectionScopePayload {
            return SelectionSnapshot.fromFrozen(
                payload, appName: ctx.appName, bundleID: ctx.bundleId)
        }
        let text: String = {
            if case .text(let t) = effectiveSelectionForScope, !t.isEmpty { return t }
            return ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()
        return SelectionSnapshot(
            text: text, filePaths: effectiveSelectedFileURLsForConversation().map(\.path),
            appName: ctx.appName, bundleID: ctx.bundleId)
    }

    func enterSelectionChat(initialQuery: String) {
        let ctx = effectiveAXContextForConversation()
        // The same request the corner's ask path builds for this selection and prompt.
        let request = SelectionAskRequest.make(prompt: initialQuery, snapshot: dockSelectionSnapshot)
        aiMode.selectionText = request.selectedText
        aiMode.selectionFiles = request.filePaths.map { URL(fileURLWithPath: $0) }
        aiMode.selectionURL = ctx.currentURL?.isEmpty == false ? ctx.currentURL : nil

        globalContextActivation = nil
        aiMode.isActive = true
        hasUserSentMessageInCurrentSession = true
        searchState.query = ""

        let q = request.prompt
        if q.isEmpty {
            aiMode.messages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "What would you like to do with this? I can summarize or explain it, send it to Notes, Reminders, Mail or Messages, or anything else — just ask."))
            persistGeneralAIConversation()
        } else {
            // Submit synchronously: the Enter caller clears searchState.query right after this
            // returns, so an async submit would read an empty query and do nothing.
            searchState.query = q
            submitAIQuery()
        }
    }

    /// Always-first Selection Scope suggestion — keeps the result sheet stable (never empty)
    /// and is the entry point to selection-grounded chat. Adapts to the typed query.
    func selectionScopeAskAIPill(query q: String) -> DockPill {
        let typed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? "Ask AI — what would you like to do?" : "Ask AI: \(typed)"
        var pill = DockPill(
            id: "selection-ask-ai",
            name: title,
            icon: "sparkles",
            accentColorName: "purple",
            badge: "Selection",
            execute: { enterSelectionChat(initialQuery: typed) }
        )
        pill.selectionAIPrompt = typed
        pill.rankingKind = "selectionAI"
        pill.rankingScore = 100_000  // always first
        pill.trackingIdentifier = "selection-ask-ai"
        pill.searchTerms = ["ask", "ai", "chat", "selection", "what", "do"]
        return pill
    }

    func selectionScopeCopyPill(query q: String) -> [DockPill] {
        guard let selection = effectiveSelectionForScope else { return [] }
        let normalizedQuery = normalizedDockPillText(q)
        let searchable = normalizedDockPillText("copy selection clipboard path")
        guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return [] }

        let title: String
        let icon: String
        switch selection {
        case .files(let urls):
            title = urls.count == 1 ? "Copy File" : "Copy Files"
            icon = "doc.on.clipboard"
        case .text:
            title = "Copy Text"
            icon = "doc.on.doc"
        case .url:
            title = "Copy Link"
            icon = "link"
        }

        var pill = DockPill(
            id: "selection-copy",
            name: title,
            icon: icon,
            accentColorName: "teal",
            badge: "Selection",
            execute: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                switch selection {
                case .files(let urls):
                    pasteboard.writeObjects(urls as [NSURL])
                    showSelectionCopyFeedback("Copied \(urls.count == 1 ? "file" : "\(urls.count) files")")
                case .text(let text):
                    pasteboard.setString(text, forType: .string)
                    showSelectionCopyFeedback("Copied selected text")
                case .url(let url):
                    pasteboard.setString(url, forType: .string)
                    showSelectionCopyFeedback("Copied link")
                }
            }
        )
        pill.rankingKind = "payload"
        pill.rankingScore = 95_000
        pill.trackingIdentifier = "selection-copy"
        pill.searchTerms = ["copy", "clipboard", "selection", "text", "file", "files", "link"]
        return [pill]
    }

    func selectionScopeBuiltInWorkflowPills(query q: String) -> [DockPill] {
        guard let selection = effectiveSelectionForScope else { return [] }
        switch selection {
        case .text:
            return selectionScopeTextWorkflowPills(query: q)
        case .url:
            return selectionScopeURLWorkflowPills(query: q)
        case .files(let urls):
            return selectionScopeFileWorkflowPills(query: q, urls: urls)
        }
    }

    func selectionScopeTextWorkflowPills(query q: String) -> [DockPill] {
        let actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = [
            ("rewrite", "Rewrite", "pencil.and.scribble", "Rewrite this clearly. Return only the replacement text.", "rewrite improve clear professional"),
            ("bullets", "Make bullets", "list.bullet", "Convert this into concise bullet points. Return only the replacement text.", "bullet list key points"),
            ("fix", "Fix grammar", "checkmark.seal", "Fix grammar, spelling, and clarity. Return only the corrected replacement text.", "grammar spelling correct fix"),
            ("shorten", "Shorten", "text.badge.minus", "Shorten this while preserving meaning. Return only the replacement text.", "shorten concise trim"),
            ("table", "Make table", "tablecells", "Convert this into a clean Markdown table if possible. Return only the replacement text.", "table markdown format"),
        ]
        return actions.compactMap { selectionScopeAIPill($0, query: q, badge: "Text") }
    }

    func selectionScopeURLWorkflowPills(query q: String) -> [DockPill] {
        let actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = [
            ("summarize-url", "Summarize Link", "link.badge.plus", "Summarize this URL and list why it may be useful.", "url link summarize"),
            ("extract-tasks-url", "Extract Tasks", "checklist", "Extract actionable tasks or follow-ups from this URL context.", "tasks todo follow up"),
            ("save-note-url", "Note Summary", "note.text", "Create a short note summary for this URL.", "note summary save"),
        ]
        return actions.compactMap { selectionScopeAIPill($0, query: q, badge: "Link") }
    }

    func selectionScopeFileWorkflowPills(query q: String, urls: [URL]) -> [DockPill] {
        guard !urls.isEmpty else { return [] }
        var pills: [DockPill] = []
        pills.append(contentsOf: selectionScopeFileUtilityPills(query: q, urls: urls))
        pills.append(contentsOf: selectionScopeDocumentAIPills(query: q, urls: urls))
        pills.append(contentsOf: selectionScopeMediaAIPills(query: q, urls: urls))
        pills.append(contentsOf: selectionScopeImageTransformPills(query: q, urls: urls))
        pills.append(contentsOf: selectionScopeArchivePills(query: q, urls: urls))
        return pills
    }

    func selectionScopeAIPill(
        _ action: (id: String, name: String, icon: String, prompt: String, terms: String),
        query q: String,
        badge: String
    ) -> DockPill? {
        let normalizedQuery = normalizedDockPillText(q)
        let searchable = normalizedDockPillText("\(action.name) \(action.prompt) \(action.terms)")
        guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
        let prompt = action.prompt
        var pill = DockPill(
            id: "selection-workflow-ai-\(action.id)",
            name: action.name,
            icon: action.icon,
            accentColorName: "purple",
            badge: badge,
            execute: { enterSelectionChat(initialQuery: prompt) }
        )
        pill.selectionAIPrompt = prompt
        pill.rankingKind = "selectionWorkflow"
        pill.rankingScore = 94_000
        pill.trackingIdentifier = "selection-workflow-ai:\(action.id)"
        pill.searchTerms = [action.name, action.prompt, action.terms, "selection", "ai"]
        return pill
    }

    func selectionScopeFileUtilityPills(query q: String, urls: [URL]) -> [DockPill] {
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let actions: [(id: String, name: String, icon: String, terms: String, run: () -> Void)] = [
            ("open", "Open", "arrow.up.forward.app", "open launch file", {
                urls.forEach { NSWorkspace.shared.open($0) }
            }),
            ("reveal", "Reveal in Finder", "folder", "reveal finder show enclosing", {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }),
            ("copy-path", "Copy Path", "point.topleft.down.curvedto.point.bottomright.up", "copy path pathname filepath", {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                showSelectionCopyFeedback("Copied path for \(label)")
            }),
        ]
        return actions.compactMap { action in
            let normalizedQuery = normalizedDockPillText(q)
            let searchable = normalizedDockPillText("\(action.name) \(action.terms)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            var pill = DockPill(
                id: "selection-file-\(action.id)",
                name: action.name,
                icon: action.icon,
                accentColorName: "blue",
                badge: label,
                execute: action.run
            )
            pill.rankingKind = "selectionWorkflow"
            pill.rankingScore = 93_000
            pill.trackingIdentifier = "selection-file:\(action.id)"
            pill.searchTerms = [action.name, action.terms, "selection", "file"]
            return pill
        }
    }

    func selectionScopeDocumentAIPills(query q: String, urls: [URL]) -> [DockPill] {
        let documentExts: Set<String> = ["pdf", "txt", "md", "rtf", "doc", "docx", "pages", "csv", "json", "xml", "html"]
        guard urls.contains(where: { documentExts.contains($0.pathExtension.lowercased()) }) else { return [] }
        let actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = [
            ("extract-text", "Extract Text", "doc.text.viewfinder", "Extract all readable text from this document. Preserve headings and important structure.", "ocr extract text document pdf"),
            ("make-summary", "Document Brief", "doc.richtext", "Create a concise document brief with summary, key points, and action items.", "brief summarize document"),
            ("find-actions", "Find Action Items", "checklist", "Extract action items, owners, dates, and follow-ups from this document.", "tasks action items todo"),
        ]
        return actions.compactMap { selectionScopeAIPill($0, query: q, badge: "Document") }
    }

    func selectionScopeMediaAIPills(query q: String, urls: [URL]) -> [DockPill] {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"]
        let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
        let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac", "aac"]
        let hasImage = urls.contains { imageExts.contains($0.pathExtension.lowercased()) }
        let hasVideo = urls.contains { videoExts.contains($0.pathExtension.lowercased()) }
        let hasAudio = urls.contains { audioExts.contains($0.pathExtension.lowercased()) }
        var actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = []
        if hasImage {
            actions += [
                ("describe-image", "Describe Image", "photo", "Describe this image precisely. Include visible text, objects, layout, and likely purpose.", "image photo describe"),
                ("ocr-image", "OCR Image", "text.viewfinder", "Extract all readable text from this image. Return only the extracted text.", "ocr image text extract"),
                ("alt-text", "Write Alt Text", "accessibility", "Write concise accessibility alt text for this image.", "alt accessibility image"),
            ]
        }
        if hasVideo {
            actions += [
                ("video-brief", "Video Brief", "film", "Analyze this selected video file context and create a short brief: likely content, metadata, and useful next actions.", "video summarize media"),
            ]
            if selectionScopeExecutableExists("ffmpeg") {
                actions += [
                    ("extract-audio", "Extract Audio Plan", "waveform", "Give the exact safe extraction plan for this selected video using ffmpeg, including output filename.", "extract audio ffmpeg video"),
                ]
            }
        }
        if hasAudio {
            actions += [
                ("audio-brief", "Audio Brief", "waveform", "Analyze this selected audio file context and create a short brief with metadata and likely next actions.", "audio summarize media"),
            ]
        }
        return actions.compactMap { selectionScopeAIPill($0, query: q, badge: "Media") }
    }

    func selectionScopeImageTransformPills(query q: String, urls: [URL]) -> [DockPill] {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        let imageURLs = urls.filter { imageExts.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else { return [] }
        let actions: [(id: String, name: String, icon: String, terms: String, run: () -> Void)] = [
            ("to-jpeg", "Convert to JPEG", "photo.badge.arrow.down", "convert jpg jpeg image", {
                runSipsImageTransform(imageURLs, format: "jpeg", suffix: "jpeg", quality: nil)
            }),
            ("to-png", "Convert to PNG", "photo.badge.arrow.down", "convert png image", {
                runSipsImageTransform(imageURLs, format: "png", suffix: "png", quality: nil)
            }),
            ("compress", "Compress Image", "arrow.down.right.and.arrow.up.left", "compress reduce size image", {
                runSipsImageTransform(imageURLs, format: "jpeg", suffix: "compressed.jpg", quality: "72")
            }),
        ]
        return actions.compactMap { action in
            let normalizedQuery = normalizedDockPillText(q)
            let searchable = normalizedDockPillText("\(action.name) \(action.terms)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            var pill = DockPill(
                id: "selection-image-\(action.id)",
                name: action.name,
                icon: action.icon,
                accentColorName: "pink",
                badge: imageURLs.count == 1 ? imageURLs[0].lastPathComponent : "\(imageURLs.count) images",
                execute: action.run
            )
            pill.rankingKind = "selectionMedia"
            pill.rankingScore = 92_000
            pill.trackingIdentifier = "selection-image:\(action.id)"
            pill.searchTerms = [action.name, action.terms, "selection", "media", "image"]
            return pill
        }
    }

    func selectionScopeArchivePills(query q: String, urls: [URL]) -> [DockPill] {
        guard !urls.isEmpty else { return [] }
        let normalizedQuery = normalizedDockPillText(q)
        let searchable = normalizedDockPillText("compress zip archive files folder")
        guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return [] }
        var pill = DockPill(
            id: "selection-archive-zip",
            name: urls.count == 1 ? "Compress to ZIP" : "Compress Items to ZIP",
            icon: "archivebox",
            accentColorName: "yellow",
            badge: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
            execute: { runSelectionZip(urls) }
        )
        pill.rankingKind = "selectionWorkflow"
        pill.rankingScore = 91_000
        pill.trackingIdentifier = "selection-archive:zip"
        pill.searchTerms = ["compress", "zip", "archive", "selection", "file", "folder"]
        return [pill]
    }

    func showSelectionCopyFeedback(_ title: String) {
        let id = "selection-copy-\(UUID().uuidString)"
        dockCoreModel.inlineDockFeedback = DockInlineFeedback(
            id: id,
            title: title,
            icon: "doc.on.clipboard",
            phase: .success,
            subject: "Selection",
            bundleID: nil
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if dockCoreModel.inlineDockFeedback?.id == id {
                dockCoreModel.inlineDockFeedback = nil
            }
        }
    }

    func selectionScopeExecutableExists(_ name: String) -> Bool {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func selectionScopeExecutableURL(_ name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    func runSipsImageTransform(_ urls: [URL], format: String, suffix: String, quality: String?) {
        guard let sips = selectionScopeExecutableURL("sips") else {
            DockActionFeedback.showResult("sips not available", icon: "exclamationmark.triangle", success: false)
            return
        }
        DockActionFeedback.showResult("Processing images…", icon: "photo", success: true)
        Task.detached {
            var outputs: [URL] = []
            var failed = 0
            for url in urls {
                let base = url.deletingPathExtension()
                let output: URL
                if suffix.contains(".") {
                    output = base.deletingLastPathComponent()
                        .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
                } else {
                    output = base.deletingLastPathComponent()
                        .appendingPathComponent("\(base.lastPathComponent).\(suffix)")
                }
                let process = Process()
                process.executableURL = sips
                var args = ["-s", "format", format]
                if let quality {
                    args += ["-s", "formatOptions", quality]
                }
                args += [url.path, "--out", output.path]
                process.arguments = args
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        outputs.append(output)
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                }
            }
            let completedOutputs = outputs
            let failedCount = failed
            await MainActor.run {
                if !completedOutputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(completedOutputs)
                    DockActionFeedback.showResult(
                        completedOutputs.count == 1 ? "Created \(completedOutputs[0].lastPathComponent)" : "Created \(completedOutputs.count) images",
                        icon: "checkmark.circle",
                        success: true
                    )
                } else {
                    DockActionFeedback.showResult(
                        failedCount > 0 ? "Image transform failed" : "No images transformed",
                        icon: "exclamationmark.triangle",
                        success: false
                    )
                }
            }
        }
    }

    func runSelectionZip(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let parent = urls[0].deletingLastPathComponent()
        let baseName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "Selection-\(Date().timeIntervalSince1970.rounded())"
        let output = parent.appendingPathComponent("\(baseName).zip")
        let toolName = urls.count == 1 ? "ditto" : "zip"
        guard let tool = selectionScopeExecutableURL(toolName) else {
            DockActionFeedback.showResult("\(toolName) not available", icon: "exclamationmark.triangle", success: false)
            return
        }
        DockActionFeedback.showResult("Creating ZIP…", icon: "archivebox", success: true)
        Task.detached {
            let process = Process()
            process.executableURL = tool
            process.currentDirectoryURL = parent
            process.arguments =
                urls.count == 1
                ? ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].lastPathComponent, output.path]
                : ["-r", output.path] + urls.map(\.lastPathComponent)
            do {
                try process.run()
                process.waitUntilExit()
                await MainActor.run {
                    if process.terminationStatus == 0 {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                        DockActionFeedback.showResult("Created \(output.lastPathComponent)", icon: "archivebox", success: true)
                    } else {
                        DockActionFeedback.showResult("ZIP failed", icon: "exclamationmark.triangle", success: false)
                    }
                }
            } catch {
                await MainActor.run {
                    DockActionFeedback.showResult(error.localizedDescription, icon: "exclamationmark.triangle", success: false)
                }
            }
        }
    }

    /// Selection is additive in Context Dock: these AI actions sit beside normal app menus.
    /// Works for BOTH text and file selections (e.g. "summarize this PDF") — the selection
    /// chat injects the file content, so the same actions apply.
    func buildContextDockSelectionAIPills(query q: String) -> [DockPill] {
        guard !aiMode.isActive else { return [] }

        let badge: String
        let isText: Bool
        switch effectiveSelectionForScope {
        case .text(let t) where !t.isEmpty:
            badge = "Selection · \(t.count) chars"
            isText = true
        case .files(let urls) where !urls.isEmpty:
            badge = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            isText = false
        default:
            return []
        }

        let normalizedQuery = normalizedDockPillText(q)
        let textActions: [(name: String, icon: String, prompt: String)] = [
            ("Summarize", "text.alignleft", "Summarize this"),
            ("Explain", "text.magnifyingglass", "Explain this"),
            ("Key points", "list.bullet", "List the key points"),
            ("Translate", "character.book.closed", "Translate this"),
        ]
        let fileActions: [(name: String, icon: String, prompt: String)] = [
            ("Summarize", "doc.text.magnifyingglass", "Summarize this document"),
            ("Explain", "text.magnifyingglass", "Explain what this file is about"),
            ("Key points", "list.bullet", "List the key points of this document"),
        ]
        let nativeWritingTools = isText ? buildNativeSelectionWritingToolPills(query: q) : []
        let actions = isText ? textActions : fileActions

        let chatPills = actions.compactMap { action -> DockPill? in
            let searchable = normalizedDockPillText("\(action.name) \(action.prompt)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            let prompt = action.prompt
            var pill = DockPill(
                id: "context-selection-ai-\(action.name.lowercased())",
                name: action.name,
                icon: action.icon,
                accentColorName: "purple",
                badge: badge,
                // Enter selection-grounded chat with this instruction — the session keeps the
                // selection (text or files), so follow-ups ("now send it to mail") still work.
                execute: { enterSelectionChat(initialQuery: prompt) }
            )
            pill.selectionAIPrompt = prompt
            pill.rankingKind = "selectionAI"
            pill.sourceBundleId = axContext.bundleId
            pill.sourceAppName = axContext.appName
            pill.trackingIdentifier = "context-selection-ai:\(action.name.lowercased())"
            pill.searchTerms = [action.name, action.prompt, "selection", "ai"]
            return pill
        }
        return nativeWritingTools + chatPills
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
            hasSelectionScopeSurface
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
                badge: hasSelectionScopeSurface ? pill.appName : nil,
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




    nonisolated func normalizedDockPillText(_ text: String) -> String {
        DockTextMatch.normalized(text)
    }

    func dockPillTokens(_ text: String) -> [String] {
        DockTextMatch.tokens(text)
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

    /// Apple-menu "Recent Items" submenu (recent apps/documents/servers + Clear Menu).
    /// Excluded even when the live Apple menu is allowed — these are noise, not actions.
    nonisolated func isAppleRecentItemsMenuItem(_ item: AXMenuItem) -> Bool {
        guard isAppleMenuItem(item) else { return false }
        return item.path.contains { normalizedDockPillText($0).contains("recent") }
            || normalizedDockPillText(item.title).contains("recent")
    }


    nonisolated func isRejectedTopMenuItem(_ item: AXMenuItem, appName: String) -> Bool {
        isAppleMenuItem(item)
    }

    nonisolated func isGenericAppMenu(_ item: AXMenuItem) -> Bool {
        FrontmostMenuMatcher.isGenericAppMenu(item)
    }

    func menuItemsVisibleInActiveDockMode(_ items: [AXMenuItem]) -> [AXMenuItem] {
        items.filter { !isAppleMenuItem($0) }
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
        case "writingTool": return 146
        case "browserCommand": return 142
        case "appLaunch": return 136
        case "appSwitch": return 134
        case "nativeWindow": return 132
        case "semanticIntent": return 128
        case "finderCurrent": return 114
        case "finderSearch": return 104
        case "recentURL": return 116
        case "adapter", "appAdapter": return 108
        case "menu": return 98
        case "submenuParent": return 96
        case "payload": return 94
        case "cliTool": return 92
        case "quickAction": return 90
        case "contextExtension": return 86
        case "tool": return 82
        case "webSearch": return 76
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
        DockTextMatch.editDistance(a, b)
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
                if pill.isShareAction {
                    return "share:\(name)"
                }

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
