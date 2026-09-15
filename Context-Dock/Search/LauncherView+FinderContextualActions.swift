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
    func canonicalExistingURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !path.isEmpty else { return false }
            guard FileManager.default.fileExists(atPath: path) else { return false }
            return seen.insert(path).inserted
        }
    }

    func clearFinderFollowUpTargets() {
        finderFollowUpTargetPaths = []
        finderFollowUpFolderPath = ""
        finderFollowUpSourceQuery = ""
    }

    func rememberFinderFollowUpTargets(
        _ urls: [URL],
        folderPath: String,
        sourceQuery: String = ""
    ) {
        let canonical = canonicalExistingURLs(urls)
        guard !canonical.isEmpty else { return }
        finderFollowUpTargetPaths = canonical.map(\.path)
        finderFollowUpFolderPath = folderPath
        finderFollowUpSourceQuery = sourceQuery
    }

    func finderFollowUpTargetURLs(for folderPath: String? = nil) -> [URL] {
        guard !finderFollowUpTargetPaths.isEmpty else { return [] }
        if let folderPath,
            !folderPath.isEmpty,
            !finderFollowUpFolderPath.isEmpty,
            finderFollowUpFolderPath != folderPath
        {
            return []
        }
        return canonicalExistingURLs(finderFollowUpTargetPaths.map { URL(fileURLWithPath: $0) })
    }

    func queryNeedsFinderFollowUpTargets(_ query: String) -> Bool {
        let normalized = normalizedDockPillText(query)
        guard !normalized.isEmpty else { return false }

        let tokens = Set(dockPillTokens(normalized))
        let pronounTerms: Set<String> = [
            "it", "them", "this", "that", "these", "those", "same", "again",
            "selected", "selection", "current",
        ]
        if !tokens.isDisjoint(with: pronounTerms) { return true }

        let actionTerms = [
            "share", "send", "mail", "email", "message", "open", "convert", "export",
            "save", "move", "copy", "duplicate", "rename", "compress", "zip", "print",
            "preview", "reveal", "quick look", "attach", "upload", "delete", "trash",
            "remove", "merge", "split", "extract", "encode", "transcode",
        ]
        let hasActionIntent = actionTerms.contains { normalized.contains($0) }
        let hasExplicitTarget = !finderTargetReferenceQuery(from: normalized).isEmpty
        return hasActionIntent && !hasExplicitTarget
    }

    func effectiveFinderSelectedFileURLs(for query: String, currentFolderPath: String)
        -> [URL]
    {
        let liveSelection = canonicalExistingURLs(
            axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        )
        if !liveSelection.isEmpty {
            rememberFinderFollowUpTargets(
                liveSelection,
                folderPath: currentFolderPath,
                sourceQuery: query
            )
            return liveSelection
        }

        if case .filesSelected(let urls) = currentContext {
            let contextURLs = canonicalExistingURLs(urls)
            if !contextURLs.isEmpty {
                let normalizedCurrentFolderPath =
                    URL(fileURLWithPath: currentFolderPath).standardizedFileURL.path
                let isStaleAttachedFolderContext =
                    contextURLs.count == 1
                    && contextURLs[0].hasDirectoryPath
                    && contextURLs[0].standardizedFileURL.path == attachedFinderFolderSearchPath
                    && attachedFinderFolderSearchPath != normalizedCurrentFolderPath
                guard !isStaleAttachedFolderContext else { return [] }

                rememberFinderFollowUpTargets(
                    contextURLs,
                    folderPath: currentFolderPath,
                    sourceQuery: query
                )
                return contextURLs
            }
        }

        guard queryNeedsFinderFollowUpTargets(query) else { return [] }
        return finderFollowUpTargetURLs(for: currentFolderPath)
    }

    func effectiveSelectedFileURLsForConversation() -> [URL] {
        let frozenSelection = frozenSelectionFileURLs
        if !frozenSelection.isEmpty {
            return isDismissedFinderSelection(frozenSelection) ? [] : frozenSelection
        }

        let liveSelection = canonicalExistingURLs(
            axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        )
        if !liveSelection.isEmpty {
            return isDismissedFinderSelection(liveSelection) ? [] : liveSelection
        }

        if case .filesSelected(let urls) = currentContext {
            let contextURLs = canonicalExistingURLs(urls)
            if !contextURLs.isEmpty {
                return isDismissedFinderSelection(contextURLs) ? [] : contextURLs
            }
        }

        guard
            frontmost.bundleID == "com.apple.finder"
                || contextTargetApp()?.bundleIdentifier == "com.apple.finder"
        else { return [] }

        if isFinderFolderSearchAttached(currentFolderPath: currentFinderFolderPath()) {
            let folderURL = URL(fileURLWithPath: attachedFinderFolderSearchPath)
            if FileManager.default.fileExists(atPath: folderURL.path) {
                return [folderURL]
            }
        }

        return finderFollowUpTargetURLs(for: currentFinderFolderPath())
    }

    func effectiveAXContextForConversation() -> AXContext {
        var context = axContext
        if context.selectedFilePaths.isEmpty {
            context.selectedFilePaths = effectiveSelectedFileURLsForConversation().map(\.path)
        }
        if (context.currentURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            case .url(let urlString) = currentContext
        {
            context.currentURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (context.currentURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let browserContext = SafariBrowserBridge.shared.currentContext(),
            !browserContext.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            context.currentURL = browserContext.url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (context.currentURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let liveURL = AXContextReader.shared.current.currentURL?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !liveURL.isEmpty
        {
            context.currentURL = liveURL
        }
        if (context.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .textSelected(let text) = currentContext {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { context.selectedText = trimmed }
            } else if let frozenSelection = frozenSelectionFullText ?? frozenSelectionText {
                let trimmed = frozenSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { context.selectedText = trimmed }
            }
        }
        return context
    }

    func finderTargetReferenceQuery(from query: String) -> String {
        let normalized = normalizedDockPillText(query)
        guard !normalized.isEmpty else { return "" }

        let ignoredWords: Set<String> = [
            "convert", "conversion", "export", "save", "open", "move", "copy", "duplicate",
            "share", "send", "attach", "upload", "rename", "delete", "trash", "remove",
            "reveal", "preview", "print", "merge", "split", "extract", "encode", "compress",
            "zip", "unzip", "transform", "change", "make", "create", "render", "transcode",
            "format", "into", "from", "with", "using", "via", "to", "as", "file", "files",
            "folder", "folders", "document", "documents", "image", "images", "photo", "photos",
            "picture", "pictures", "pdf", "png", "jpg", "jpeg", "webp", "heic", "gif", "tiff",
            "bmp", "selected", "selection", "current", "this", "that", "these", "those",
            "please", "here",
        ]

        let remaining = dockPillTokens(normalized).filter {
            !$0.isEmpty && !ignoredWords.contains($0) && $0.count >= 2
        }
        return remaining.joined(separator: " ")
    }

    func finderMetadataSummary(for url: URL) -> String {
        let resourceValues =
            (try? url.resourceValues(
                forKeys: [
                    .isDirectoryKey, .localizedTypeDescriptionKey, .contentModificationDateKey,
                    .fileSizeKey,
                ])) ?? URLResourceValues()
        let isDirectory = resourceValues.isDirectory ?? url.hasDirectoryPath
        let typeLabel =
            resourceValues.localizedTypeDescription
            ?? (isDirectory
                ? "Folder"
                : (url.pathExtension.isEmpty ? "File" : "\(url.pathExtension.uppercased()) file"))
        let sizeLabel: String = {
            guard !isDirectory else { return "folder" }
            let byteCount = Int64(resourceValues.fileSize ?? 0)
            guard byteCount > 0 else { return "size unknown" }
            return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }()
        let modifiedLabel: String = {
            guard let modified = resourceValues.contentModificationDate else {
                return "modified unknown"
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "modified " + formatter.localizedString(for: modified, relativeTo: Date())
        }()
        return "\(typeLabel) | \(sizeLabel) | \(modifiedLabel) | \(finderDisplayPath(url.path))"
    }

    func buildFinderFileCatalogBlock(
        currentFolderPath: String,
        selectedFilePaths: [String]
    ) -> String {
        let folderURL = URL(fileURLWithPath: currentFolderPath)
        let fileManager = FileManager.default

        var orderedURLs = selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if let currentItems = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            let sortedItems = currentItems.sorted { lhs, rhs in
                let lhsValues =
                    (try? lhs.resourceValues(forKeys: [
                        .isDirectoryKey, .contentModificationDateKey,
                    ]))
                    ?? URLResourceValues()
                let rhsValues =
                    (try? rhs.resourceValues(forKeys: [
                        .isDirectoryKey, .contentModificationDateKey,
                    ]))
                    ?? URLResourceValues()
                let lhsDirectory = lhsValues.isDirectory ?? lhs.hasDirectoryPath
                let rhsDirectory = rhsValues.isDirectory ?? rhs.hasDirectoryPath
                if lhsDirectory != rhsDirectory { return lhsDirectory && !rhsDirectory }
                let lhsDate = lhsValues.contentModificationDate ?? .distantPast
                let rhsDate = rhsValues.contentModificationDate ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent)
                    == .orderedAscending
            }
            orderedURLs.append(contentsOf: sortedItems)
        }

        var seen: Set<String> = []
        let uniqueURLs = orderedURLs.filter { seen.insert($0.path).inserted }
        guard !uniqueURLs.isEmpty else { return "" }

        let limit = min(uniqueURLs.count, 40)
        let lines = uniqueURLs.prefix(limit).map { url in
            "- \(url.lastPathComponent) | \(finderMetadataSummary(for: url))"
        }

        var block = "\nCURRENT FOLDER FILE CATALOG:\n" + lines.joined(separator: "\n")
        if uniqueURLs.count > limit {
            block += "\n- ... and \(uniqueURLs.count - limit) more items in this folder"
        }
        return block
    }

    func buildFinderTargetSemanticMatches(
        for query: String,
        currentFolderPath: String,
        spotlightEnabled: Bool
    ) async -> [FinderSemanticMatch] {
        let targetQuery = finderTargetReferenceQuery(from: query)
        guard !targetQuery.isEmpty, targetQuery != normalizedDockPillText(query) else { return [] }

        let fastMatches = await buildFastFinderSemanticMatches(
            query: targetQuery,
            currentFolderPath: currentFolderPath
        )
        let spotlightMatches =
            spotlightEnabled && targetQuery.count >= 3
            ? runFinderSpotlightSearch(
                query: targetQuery,
                currentFolderPath: currentFolderPath,
                limit: 8
            )
            : []
        return mergeFinderSemanticMatches(fastMatches, with: spotlightMatches)
    }

    func buildFinderResolvedTargetContext(
        query: String,
        selectedFilePaths: [String],
        retrievedMatches: [FinderSemanticMatch]
    ) -> (targetURLs: [URL], summaryBlock: String, contentBlock: String) {
        let selectedURLs = selectedFilePaths.map { URL(fileURLWithPath: $0) }
        let candidateURLs: [URL] =
            !selectedURLs.isEmpty
            ? Array(selectedURLs.prefix(5))
            : Array(retrievedMatches.prefix(5).map { URL(fileURLWithPath: $0.path) })

        guard !candidateURLs.isEmpty else {
            return ([], "", "")
        }

        let summaryLines = candidateURLs.map { url in
            "- \(url.lastPathComponent) | \(finderMetadataSummary(for: url))"
        }
        let summaryBlock =
            "\nRESOLVED TARGET FILES FOR THIS QUERY:\n" + summaryLines.joined(separator: "\n")

        let analyzableURLs = candidateURLs.filter {
            let values =
                (try? $0.resourceValues(forKeys: [.isDirectoryKey])) ?? URLResourceValues()
            return !(values.isDirectory ?? $0.hasDirectoryPath)
        }
        let analyzedFiles = ContextDetector.shared.analyzeFiles(Array(analyzableURLs.prefix(2)))
        var contentBlock = ""
        for file in analyzedFiles {
            guard let content = file.content,
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            contentBlock +=
                "\n\n### Resolved target content from \(file.url.lastPathComponent):\n```\n\(String(content.prefix(2500)))\n```"
        }

        return (candidateURLs, summaryBlock, contentBlock)
    }

    func finderSemanticCategoryTokens(_ category: FinderFileCategory) -> Set<String> {
        switch category {
        case .pdf:
            return ["pdf", "pdfs"]
        case .image:
            return [
                "image", "images", "photo", "photos", "picture", "pictures", "screenshot",
                "screenshots",
            ]
        case .video:
            return ["video", "videos", "movie", "movies"]
        case .audio:
            return ["audio", "music", "song", "songs", "mp3"]
        case .archive:
            return ["archive", "archives", "zip", "zips", "dmg", "dmgs", "torrent", "torrents"]
        case .app:
            return ["app", "apps", "application", "applications"]
        case .folder:
            return ["folder", "folders", "directory", "directories"]
        case .document:
            return ["document", "documents", "doc", "docs", "text"]
        }
    }

    func finderExplicitLocationPath(in normalizedQuery: String) -> (
        path: String, tokens: Set<String>
    )? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations: [(names: [String], path: URL, tokens: [String])] = [
            (
                ["downloads", "download folder", "download directory"],
                home.appendingPathComponent("Downloads"), ["downloads", "download"]
            ),
            (["desktop"], home.appendingPathComponent("Desktop"), ["desktop"]),
            (
                ["documents", "documents folder", "docs folder"],
                home.appendingPathComponent("Documents"), ["documents", "docs"]
            ),
            (
                ["movies", "movies folder", "videos folder"], home.appendingPathComponent("Movies"),
                ["movies"]
            ),
            (
                ["pictures", "pictures folder", "photos folder"],
                home.appendingPathComponent("Pictures"), ["pictures", "photos"]
            ),
            (["music", "music folder"], home.appendingPathComponent("Music"), ["music"]),
            (["home", "home folder"], home, ["home"]),
        ]

        for location in locations {
            let matched = location.names.contains { name in
                normalizedQuery == name
                    || normalizedQuery.contains(" in \(name)")
                    || normalizedQuery.contains(" inside \(name)")
                    || normalizedQuery.contains(" under \(name)")
                    || normalizedQuery.contains(" from \(name)")
                    || normalizedQuery.contains(" at \(name)")
            }
            if matched {
                return (
                    location.path.standardizedFileURL.path,
                    Set(location.tokens + ["in", "inside", "under", "from"])
                )
            }
        }

        if normalizedQuery.contains("here") || normalizedQuery.contains("current folder")
            || normalizedQuery.contains("this folder")
        {
            return nil
        }
        return nil
    }

    func finderExplicitSizeBounds(in normalizedQuery: String) -> (
        min: Int64?, max: Int64?, tokens: Set<String>
    ) {
        var consumed: Set<String> = []

        func bytes(_ value: Double, _ unit: String) -> Int64 {
            let normalizedUnit = unit.lowercased()
            let multiplier: Double
            if normalizedUnit.hasPrefix("g") {
                multiplier = 1_073_741_824
            } else if normalizedUnit.hasPrefix("k") {
                multiplier = 1_024
            } else {
                multiplier = 1_048_576
            }
            return Int64(value * multiplier)
        }

        let patterns: [(pattern: String, isMin: Bool)] = [
            (
                #"(?:over|above|larger than|bigger than|greater than|more than)\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|k|mb|m|gb|g)"#,
                true
            ),
            (
                #"(?:under|below|smaller than|less than)\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|k|mb|m|gb|g)"#,
                false
            ),
            (
                #"([0-9]+(?:\.[0-9]+)?)\s*(kb|k|mb|m|gb|g)\s*(?:or )?(?:larger|bigger|plus|\+)"#,
                true
            ),
            (#"([0-9]+(?:\.[0-9]+)?)\s*(kb|k|mb|m|gb|g)\s*(?:or )?(?:smaller|less|under)"#, false),
        ]

        var minBytes: Int64?
        var maxBytes: Int64?
        for item in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: item.pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(
                normalizedQuery.startIndex..<normalizedQuery.endIndex, in: normalizedQuery)
            guard let match = regex.firstMatch(in: normalizedQuery, range: range),
                match.numberOfRanges >= 3,
                let valueRange = Range(match.range(at: 1), in: normalizedQuery),
                let unitRange = Range(match.range(at: 2), in: normalizedQuery),
                let value = Double(normalizedQuery[valueRange])
            else { continue }
            let size = bytes(value, String(normalizedQuery[unitRange]))
            if item.isMin {
                minBytes = max(minBytes ?? 0, size)
            } else {
                maxBytes = min(maxBytes ?? Int64.max, size)
            }
            if let fullRange = Range(match.range(at: 0), in: normalizedQuery) {
                consumed.formUnion(dockPillTokens(String(normalizedQuery[fullRange])))
            }
        }

        if minBytes == nil {
            let tokens = Set(dockPillTokens(normalizedQuery))
            if !tokens.isDisjoint(with: ["huge", "largest"]) {
                minBytes = 500 * 1_024 * 1_024
            } else if !tokens.isDisjoint(with: ["large", "larger", "big"]) {
                minBytes = 100 * 1_024 * 1_024
            }
        }
        if maxBytes == nil {
            let tokens = Set(dockPillTokens(normalizedQuery))
            if !tokens.isDisjoint(with: ["small", "tiny", "smallest"]) {
                maxBytes = 1 * 1_024 * 1_024
            }
        }

        return (minBytes, maxBytes, consumed)
    }

    func finderSemanticProfile(for query: String) -> FinderSemanticQueryProfile {
        let normalized = normalizedDockPillText(query)
        let tokens = dockPillTokens(normalized)
        let category = FinderFileCategory.detect(in: normalized)
        let explicitLocation = finderExplicitLocationPath(in: normalized)
        let explicitSize = finderExplicitSizeBounds(in: normalized)
        let wantsFoldersOnly =
            category == .folder || tokens.contains("folder") || tokens.contains("folders")
            || tokens.contains("directory") || tokens.contains("directories")
        let wantsFilesOnly =
            !wantsFoldersOnly
            && (tokens.contains("file") || tokens.contains("files")
                || tokens.contains("item") || tokens.contains("items"))
        let wantsRecent =
            tokens.contains("recent") || tokens.contains("latest") || tokens.contains("newest")
        let wantsToday = tokens.contains("today") || tokens.contains("tonight")
        let wantsYesterday = tokens.contains("yesterday")
        let wantsThisWeek = tokens.contains("week") || normalized.contains("this week")
        let wantsLargeFiles =
            tokens.contains("large") || tokens.contains("larger") || tokens.contains("big")
            || tokens.contains("huge") || tokens.contains("largest")
        let wantsSmallFiles =
            tokens.contains("small") || tokens.contains("tiny") || tokens.contains("smallest")

        var semanticTokens: Set<String> = [
            "today", "tonight", "yesterday", "recent", "latest", "newest",
            "this", "week", "here", "current", "folder", "folders", "directory", "directories",
            "file", "files", "item", "items", "modified", "updated", "edited", "changed",
            "large", "larger", "big", "huge", "largest", "small", "tiny", "smallest",
            "any", "all", "show", "list", "find", "search", "display", "check",
            "there", "is", "are", "do", "have", "got", "called", "named", "titled",
            "name", "names", "claled", "with", "matching", "match", "contains",
            "contain", "please", "me", "my", "a", "an", "the", "of", "to", "for",
        ]
        if let category {
            semanticTokens.formUnion(finderSemanticCategoryTokens(category))
        }
        if let explicitLocation {
            semanticTokens.formUnion(explicitLocation.tokens)
        }
        semanticTokens.formUnion(explicitSize.tokens)

        let residualQuery = tokens.filter { !semanticTokens.contains($0) }.joined(separator: " ")
        return FinderSemanticQueryProfile(
            originalQuery: normalized,
            residualQuery: residualQuery,
            category: category,
            wantsFoldersOnly: wantsFoldersOnly,
            wantsFilesOnly: wantsFilesOnly,
            wantsRecent: wantsRecent,
            wantsToday: wantsToday,
            wantsYesterday: wantsYesterday,
            wantsThisWeek: wantsThisWeek,
            wantsLargeFiles: wantsLargeFiles,
            wantsSmallFiles: wantsSmallFiles,
            explicitLocationPath: explicitLocation?.path,
            minSizeBytes: explicitSize.min,
            maxSizeBytes: explicitSize.max
        )
    }

    func finderSemanticDateInterval(for profile: FinderSemanticQueryProfile, now: Date)
        -> DateInterval?
    {
        let calendar = Calendar.current
        if profile.wantsToday {
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        if profile.wantsYesterday {
            let todayStart = calendar.startOfDay(for: now)
            guard
                let start = calendar.date(byAdding: .day, value: -1, to: todayStart)
            else { return nil }
            return DateInterval(start: start, end: todayStart)
        }
        if profile.wantsThisWeek {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            guard
                let start = calendar.date(from: components),
                let end = calendar.date(byAdding: .day, value: 7, to: start)
            else { return nil }
            return DateInterval(start: start, end: end)
        }
        return nil
    }

    func finderAdvancedSearchRoot(
        for profile: FinderSemanticQueryProfile, currentFolderPath: String
    ) -> String {
        if let explicitLocationPath = profile.explicitLocationPath {
            return URL(fileURLWithPath: explicitLocationPath).standardizedFileURL.path
        }
        if !attachedFinderFolderSearchPath.isEmpty {
            return URL(fileURLWithPath: attachedFinderFolderSearchPath).standardizedFileURL.path
        }
        return URL(fileURLWithPath: currentFolderPath).standardizedFileURL.path
    }

    func buildAdvancedFinderDataMatches(
        profile: FinderSemanticQueryProfile,
        currentFolderPath: String,
        limit: Int = 24
    ) -> [FinderSemanticMatch] {
        guard profile.hasAdvancedDataConstraint else { return [] }

        let rootPath = finderAdvancedSearchRoot(for: profile, currentFolderPath: currentFolderPath)
        let now = Date()
        let dateInterval = finderSemanticDateInterval(for: profile, now: now)
        let query = AdvancedFileSearchQuery(
            rootPath: rootPath,
            residualQuery: profile.residualQuery,
            allowedExtensions: profile.category?.fileExtensions,
            includeDirectories: profile.wantsFoldersOnly || profile.category == .folder,
            filesOnly: profile.wantsFilesOnly
                || (profile.category != nil && profile.category != .folder)
                || profile.wantsLargeFiles || profile.wantsSmallFiles,
            minSizeBytes: profile.minSizeBytes,
            maxSizeBytes: profile.maxSizeBytes,
            modifiedAfter: dateInterval?.start,
            modifiedBefore: dateInterval?.end,
            limit: limit
        )

        let indexedMatches = fileIndexManager.advancedSearch(query).filter { file in
            if profile.wantsFoldersOnly || profile.category == .folder {
                return file.isDirectory
            }
            return true
        }
        if !indexedMatches.isEmpty {
            return indexedMatches.map { file in
                let source =
                    profile.explicitLocationPath == nil
                    ? "Current Folder" : URL(fileURLWithPath: rootPath).lastPathComponent
                let sizeLabel =
                    file.size > 0
                    ? ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
                    : "size unknown"
                return FinderSemanticMatch(
                    path: file.path,
                    title: file.name,
                    subtitle: "\(source) • \(sizeLabel) • \(finderDisplayPath(file.path))",
                    isDirectory: file.isDirectory,
                    score: 900 + min(500, Double(file.size) / 1_048_576.0),
                    source: source,
                    searchTerms: [
                        file.name, file.path, source, "finder", "spotlight", "advanced query",
                        profile.originalQuery,
                    ],
                    sizeBytes: file.size
                )
            }
        }

        return buildAdvancedFinderDirectoryFallbackMatches(
            profile: profile,
            rootPath: rootPath,
            limit: limit
        )
    }

    func buildAdvancedFinderDirectoryFallbackMatches(
        profile: FinderSemanticQueryProfile,
        rootPath: String,
        limit: Int
    ) -> [FinderSemanticMatch] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        let now = Date()
        var matches: [FinderSemanticMatch] = []
        for case let url as URL in enumerator {
            guard matches.count < max(limit * 4, 80) else { break }
            let values = (try? url.resourceValues(forKeys: Set(keys))) ?? URLResourceValues()
            guard
                let semanticBoost = finderSemanticConstraintBoost(
                    for: url,
                    profile: profile,
                    resourceValues: values,
                    now: now
                )
            else { continue }
            if !profile.residualQuery.isEmpty,
                finderSemanticScore(query: profile.residualQuery, for: url) == nil
            {
                continue
            }
            let isDirectory = values.isDirectory ?? url.hasDirectoryPath
            let size = Int64(values.fileSize ?? 0)
            let sizeLabel =
                size > 0
                ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                : (isDirectory ? "folder" : "size unknown")
            let source = URL(fileURLWithPath: rootPath).lastPathComponent
            matches.append(
                FinderSemanticMatch(
                    path: url.standardizedFileURL.path,
                    title: url.lastPathComponent,
                    subtitle: "\(source) • \(sizeLabel) • \(finderDisplayPath(url.path))",
                    isDirectory: isDirectory,
                    score: semanticBoost + min(400, Double(size) / 1_048_576.0),
                    source: source,
                    searchTerms: [
                        url.lastPathComponent, url.path, source, "finder", "advanced query",
                    ],
                    sizeBytes: size
                )
            )
        }

        return
            matches
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0)
            }
            .prefix(limit)
            .map { $0 }
    }

    func finderSemanticConstraintBoost(
        for url: URL,
        profile: FinderSemanticQueryProfile,
        resourceValues: URLResourceValues,
        now: Date
    ) -> Double? {
        let isDirectory = resourceValues.isDirectory ?? url.hasDirectoryPath

        if profile.wantsFoldersOnly && !isDirectory { return nil }
        if profile.wantsFilesOnly && isDirectory { return nil }
        if let category = profile.category {
            if category == .folder {
                guard isDirectory else { return nil }
            } else if !category.matches(url) {
                return nil
            }
        }

        var score = 0.0
        var matchedAnyConstraint = false

        if profile.wantsFoldersOnly && isDirectory {
            matchedAnyConstraint = true
            score += 140
        }
        if profile.wantsFilesOnly && !isDirectory {
            matchedAnyConstraint = true
            score += 110
        }
        if let category = profile.category {
            matchedAnyConstraint = true
            score += category == .folder ? 150 : 125
        }

        if let interval = finderSemanticDateInterval(for: profile, now: now) {
            guard let modified = resourceValues.contentModificationDate,
                interval.contains(modified)
            else { return nil }
            matchedAnyConstraint = true
            score += profile.wantsToday ? 240 : 220
            let ageHours = max(0, now.timeIntervalSince(modified) / 3600)
            score += max(0, 36 - min(36, ageHours))
        } else if profile.wantsRecent {
            guard let modified = resourceValues.contentModificationDate else { return nil }
            matchedAnyConstraint = true
            let ageHours = max(0, now.timeIntervalSince(modified) / 3600)
            score += max(80, 240 - min(180, ageHours * 4))
        }

        let size = Int64(resourceValues.fileSize ?? 0)
        if profile.wantsLargeFiles {
            guard !isDirectory, size >= 5 * 1_024 * 1_024 else { return nil }
            matchedAnyConstraint = true
            score += 150 + min(180, Double(size) / 1_048_576.0)
        }
        if profile.wantsSmallFiles {
            guard !isDirectory, size > 0, size <= 1 * 1_024 * 1_024 else { return nil }
            matchedAnyConstraint = true
            score += 130 + max(0, 24 - Double(size) / 65_536.0)
        }

        return matchedAnyConstraint ? score : nil
    }

    func finderSemanticScore(query: String, for url: URL) -> Double? {
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let name = normalizedDockPillText(url.lastPathComponent)
        let path = normalizedDockPillText(url.path)
        guard !name.isEmpty || !path.isEmpty else { return nil }

        var bestScore: Double? = nil

        if name == normalizedQuery {
            bestScore = 1100
        } else if name.hasPrefix(normalizedQuery) {
            bestScore = 980 + Double(min(normalizedQuery.count, 12) * 6)
        } else if name.contains(normalizedQuery) {
            bestScore = 900 + Double(min(normalizedQuery.count, 10) * 4)
        }

        if path.contains(normalizedQuery) {
            bestScore = max(bestScore ?? 0, 820 + Double(min(normalizedQuery.count, 12) * 3))
        }

        let queryTerms = dockPillTokens(normalizedQuery).filter { $0.count >= 2 }
        if !queryTerms.isEmpty {
            let matchedTerms = queryTerms.filter { name.contains($0) || path.contains($0) }
            if !matchedTerms.isEmpty {
                bestScore = max(
                    bestScore ?? 0,
                    780 + Double(matchedTerms.count * 42)
                )
            }
        }

        if let fuzzyName = FuzzyMatcher.score(normalizedQuery, against: name) {
            bestScore = max(bestScore ?? 0, fuzzyName)
        }
        if let typoName = finderNameTypoScore(query: normalizedQuery, target: name) {
            bestScore = max(bestScore ?? 0, typoName)
        }
        if bestScore == nil,
            let fuzzyPath = FuzzyMatcher.score(normalizedQuery, against: path)
        {
            bestScore = max(bestScore ?? 0, fuzzyPath * 0.78)
        }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            bestScore = (bestScore ?? 0) + 18
        }

        return bestScore
    }

    func finderNameTypoScore(query: String, target: String) -> Double? {
        let queryTerms = dockPillTokens(query).filter { $0.count >= 3 }
        let targetTerms = dockPillTokens(target).filter { $0.count >= 3 }
        guard !queryTerms.isEmpty, !targetTerms.isEmpty else { return nil }

        var matched = 0
        var score = 0.0
        for q in queryTerms {
            guard let best = targetTerms.map({ levenshteinDistance(q, $0) }).min() else { continue }
            let allowed = max(1, min(3, q.count / 3))
            if best <= allowed {
                matched += 1
                score += 720 + Double(max(0, q.count - best) * 24)
            }
        }
        guard matched > 0 else { return nil }
        return score / Double(queryTerms.count)
    }

    func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }

    func mergeFinderSemanticMatches(
        _ base: [FinderSemanticMatch],
        with additional: [FinderSemanticMatch]
    ) -> [FinderSemanticMatch] {
        var merged: [String: FinderSemanticMatch] = [:]
        for match in base + additional {
            if let existing = merged[match.path], existing.score >= match.score {
                continue
            }
            merged[match.path] = match
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func buildFastFinderSemanticMatches(query: String, currentFolderPath: String) async
        -> [FinderSemanticMatch]
    {
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let profile = finderSemanticProfile(for: normalizedQuery)
        let textQuery =
            !profile.residualQuery.isEmpty
            ? profile.residualQuery
            : (profile.hasSemanticConstraint ? "" : normalizedQuery)
        let now = Date()

        var matches: [FinderSemanticMatch] = []
        let fileManager = FileManager.default

        func addMatch(_ url: URL, baseScore: Double, source: String, extraTerms: [String] = []) {
            let resourceValues =
                (try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
                ]))
                ?? URLResourceValues()
            let textScore =
                !textQuery.isEmpty ? finderSemanticScore(query: textQuery, for: url) : nil
            let semanticBoost = finderSemanticConstraintBoost(
                for: url,
                profile: profile,
                resourceValues: resourceValues,
                now: now
            )

            if !profile.residualQuery.isEmpty, textScore == nil { return }
            if profile.hasSemanticConstraint, semanticBoost == nil { return }
            guard textScore != nil || semanticBoost != nil else { return }

            let isDirectory = resourceValues.isDirectory ?? url.hasDirectoryPath
            matches.append(
                FinderSemanticMatch(
                    path: url.path,
                    title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                    subtitle: "\(source) • \(finderDisplayPath(url.path))",
                    isDirectory: isDirectory,
                    score: (textScore ?? 0) + (semanticBoost ?? 0) + baseScore,
                    source: source,
                    searchTerms: extraTerms + [source, url.lastPathComponent, url.path]
                ))
        }

        let folderURL = URL(fileURLWithPath: currentFolderPath)
        let isTemporalOrSizeQuery =
            profile.wantsRecent || profile.wantsToday || profile.wantsYesterday
            || profile.wantsThisWeek || profile.wantsLargeFiles || profile.wantsSmallFiles
        if !isTemporalOrSizeQuery,
            !profile.hasSemanticConstraint || profile.wantsFoldersOnly
                || !profile.residualQuery.isEmpty
        {
            addMatch(
                folderURL, baseScore: 180, source: "Current Folder",
                extraTerms: ["finder", "current directory"])
        }

        let selectedURLs = axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        for url in selectedURLs {
            addMatch(
                url, baseScore: 165, source: "Selected Item", extraTerms: ["finder", "selection"])
        }

        if let currentItems = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for url in currentItems {
                addMatch(url, baseScore: 140, source: "Current Folder", extraTerms: ["finder"])
            }
        }

        // Deep matches from the prebuilt home-folder Spotlight index — the
        // listing above only covers the current folder's immediate children,
        // so without this, files in subfolders never surface.
        if !textQuery.isEmpty, FileIndexManager.shared.isReady {
            let indexed = FileIndexManager.shared.search(query: textQuery, limit: 24)
            for result in indexed {
                guard let path = result.filePath,
                    !matches.contains(where: { $0.path == path })
                else { continue }
                addMatch(
                    URL(fileURLWithPath: path),
                    baseScore: 90,
                    source: "All Files",
                    extraTerms: ["finder", "spotlight", "all files"]
                )
            }
        }

        return mergeFinderSemanticMatches([], with: matches)
    }

    func runFinderSpotlightSearch(query: String, currentFolderPath: String, limit: Int)
        -> [FinderSemanticMatch]
    {
        let normalizedQuery = normalizedDockPillText(query)
        guard normalizedQuery.count >= 3 else { return [] }
        let profile = finderSemanticProfile(for: normalizedQuery)
        let contentQuery = profile.residualQuery
        guard !contentQuery.isEmpty else { return [] }
        let now = Date()
        let normalizedFolderPath = URL(fileURLWithPath: currentFolderPath).standardizedFileURL.path

        func executeMDFind(arguments: [String], source: String, boost: Double)
            -> [FinderSemanticMatch]
        {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            task.arguments = arguments
            task.standardOutput = pipe
            task.standardError = Pipe()

            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                    return []
                }

                var results: [FinderSemanticMatch] = []
                for path in output.components(separatedBy: .newlines)
                    .filter({ !$0.isEmpty })
                    .prefix(limit)
                {
                    let url = URL(fileURLWithPath: path)
                    let normalizedPath = url.standardizedFileURL.path
                    guard normalizedPath == normalizedFolderPath
                        || normalizedPath.hasPrefix(normalizedFolderPath + "/")
                    else { continue }
                    let resourceValues =
                        (try? url.resourceValues(forKeys: [
                            .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
                        ]))
                        ?? URLResourceValues()
                    let isDirectory = resourceValues.isDirectory ?? url.hasDirectoryPath
                    let textScore = finderSemanticScore(query: contentQuery, for: url) ?? 720
                    let semanticBoost = finderSemanticConstraintBoost(
                        for: url,
                        profile: profile,
                        resourceValues: resourceValues,
                        now: now
                    )
                    if profile.hasSemanticConstraint && semanticBoost == nil { continue }
                    results.append(
                        FinderSemanticMatch(
                            path: normalizedPath,
                            title: url.lastPathComponent.isEmpty
                                ? normalizedPath : url.lastPathComponent,
                            subtitle: "\(source) • \(finderDisplayPath(normalizedPath))",
                            isDirectory: isDirectory,
                            score: textScore + (semanticBoost ?? 0) + boost,
                            source: source,
                            searchTerms: [
                                url.lastPathComponent, normalizedPath, source, "content", "finder",
                            ]
                        ))
                }
                return results
            } catch {
                return []
            }
        }

        let currentFolderMatches = executeMDFind(
            arguments: ["-onlyin", currentFolderPath, contentQuery],
            source: "Current Folder Content",
            boost: 150
        )
        return currentFolderMatches
    }

    func finderResultType(for path: String, isDirectory: Bool) -> SearchResult.ResultType {
        if isDirectory { return .folder }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if [
            "pdf", "txt", "md", "rtf", "doc", "docx", "pages", "json", "csv", "xml", "yaml", "yml",
            "swift", "js", "ts", "py", "sh",
        ].contains(ext) {
            return .document
        }
        return .file
    }

    func finderSemanticSymbol(for match: FinderSemanticMatch) -> String {
        if match.isDirectory { return "folder" }
        switch URL(fileURLWithPath: match.path).pathExtension.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            return "photo"
        case "zip", "rar", "7z", "gz", "tar":
            return "archivebox"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "film"
        case "mp3", "wav", "m4a", "flac":
            return "music.note"
        default:
            return "doc"
        }
    }

    func finderPreviewIcon(for path: String) -> NSImage {
        if let thumbnail = ThumbnailGenerator.shared.cachedThumbnail(for: path) {
            thumbnail.size = NSSize(width: 32, height: 32)
            return thumbnail
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    func requestFinderPreviewThumbnail(for path: String, query: String) {
        guard ThumbnailGenerator.shared.cachedThumbnail(for: path) == nil else { return }
        ThumbnailGenerator.shared.getThumbnail(for: path, size: CGSize(width: 160, height: 160)) {
            image in
            guard image != nil else { return }
            Task { @MainActor in
                let latestScope = resolveDockScope(for: searchState.query)
                let latestQuery =
                    latestScope.scopedBundleId == "com.apple.finder"
                    ? latestScope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    : ""
                guard latestQuery == query.lowercased() else { return }
                if !finderSemanticResults.isEmpty {
                    applyFinderSemanticPanelResults(
                        finderSemanticResults.map { result in
                            guard let path = result.filePath else { return result }
                            return result.replacingIcon(finderPreviewIcon(for: path))
                        }
                    )
                }
                scheduleDockPillRebuild(
                    query: searchState.query,
                    delayNanoseconds: 0,
                    refreshContext: false
                )
            }
        }
    }

    func finderSemanticAction(for path: String, isDirectory: Bool) -> () -> Void {
        {
            let url = URL(fileURLWithPath: path)
            let folderPath =
                isDirectory
                ? url.deletingLastPathComponent().path : url.deletingLastPathComponent().path
            if isFinderCurrentWindowSearchAttached(currentFolderPath: folderPath) {
                recordFinderCurrentFolderLaunch(itemPath: url.path, folderPath: folderPath)
            }
            rememberFinderFollowUpTargets(
                [url],
                folderPath: isDirectory ? url.path : url.deletingLastPathComponent().path,
                sourceQuery: url.lastPathComponent
            )
            // Folders navigate the existing front Finder window (same window, like Go menu)
            // instead of spawning a new one; files open normally.
            openFinderFolderPreferringTab(url, isDirectory: isDirectory)
            searchState.query = ""
            l2.focusedPillIndex = nil
        }
    }

    func makeFinderSemanticSearchResults(from matches: [FinderSemanticMatch])
        -> [SearchResult]
    {
        matches.prefix(24).map { match in
            let icon = finderPreviewIcon(for: match.path)
            requestFinderPreviewThumbnail(for: match.path, query: finderSemanticQuery)
            return SearchResult(
                title: match.title,
                subtitle: match.subtitle,
                icon: icon,
                action: finderSemanticAction(for: match.path, isDirectory: match.isDirectory),
                score: match.score,
                type: finderResultType(for: match.path, isDirectory: match.isDirectory),
                filePath: match.path,
                contactData: nil
            )
        }
    }

    func makeFinderSemanticDockPills(from matches: [FinderSemanticMatch]) -> [DockPill] {
        matches.prefix(8).map { match in
            var pill = DockPill(
                id: "finder-search-\(match.path)",
                name: match.title,
                icon: finderSemanticSymbol(for: match),
                accentColorName: match.isDirectory ? "blue" : "teal",
                badge: match.source,
                execute: finderSemanticAction(for: match.path, isDirectory: match.isDirectory)
            )
            // Real document/folder icon, like Spotlight — the SF symbol stays as fallback.
            pill.menuItemImage = finderPreviewIcon(for: match.path)
            requestFinderPreviewThumbnail(for: match.path, query: finderSemanticQuery)
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.rankingKind = match.source == "Current Folder" ? "finderCurrent" : "finderSearch"
            pill.quickLookURL = URL(fileURLWithPath: match.path)
            pill.trackingIdentifier = "finder-search:\(match.path.lowercased())"
            pill.searchTerms = match.searchTerms
            pill.rankingScore = match.score
            return pill
        }
    }

    func finderSemanticActionTargetURLs() -> [URL] {
        finderSemanticResults
            .compactMap { result -> URL? in
                guard let path = result.filePath, FileManager.default.fileExists(atPath: path)
                else { return nil }
                return URL(fileURLWithPath: path)
            }
            .prefix(8)
            .map { $0 }
    }

    func makeFinderSemanticQuickActionPills(query: String) -> [DockPill] {
        let urls = finderSemanticActionTargetURLs()
        guard !urls.isEmpty else { return [] }
        let normalized = normalizedDockPillText(query)
        let firstURL = urls[0]
        let targetLabel = urls.count == 1 ? firstURL.lastPathComponent : "\(urls.count) results"

        var pills: [DockPill] = []

        var preview = DockPill(
            id: "finder-search-preview-\(firstURL.path)",
            name: "Preview \(firstURL.lastPathComponent)",
            icon: "eye",
            accentColorName: "blue",
            badge: "Quick Look",
            execute: {
                PreviewController.shared.present(
                    url: firstURL, siblings: urls, toggleIfSame: true)
                searchState.query = ""
                l2.focusedPillIndex = nil
            }
        )
        preview.sourceBundleId = "com.apple.finder"
        preview.sourceAppName = "Finder"
        preview.rankingKind = "finderContext"
        preview.quickLookURL = firstURL
        preview.trackingIdentifier = "finder-preview:\(firstURL.path.lowercased())"
        preview.searchTerms = [
            "preview", "quick look", "finder", firstURL.lastPathComponent, normalized,
        ]
        pills.append(preview)

        var reveal = DockPill(
            id: "finder-search-reveal-\(firstURL.path)",
            name: "Reveal \(firstURL.lastPathComponent)",
            icon: "folder",
            accentColorName: "gray",
            badge: "Finder",
            execute: {
                NSWorkspace.shared.activateFileViewerSelecting([firstURL])
                searchState.query = ""
                l2.focusedPillIndex = nil
            }
        )
        reveal.sourceBundleId = "com.apple.finder"
        reveal.sourceAppName = "Finder"
        reveal.rankingKind = "finderContext"
        reveal.trackingIdentifier = "finder-reveal:\(firstURL.path.lowercased())"
        reveal.searchTerms = ["reveal", "show", "finder", firstURL.lastPathComponent, normalized]
        pills.append(reveal)

        if normalized.contains("compress") || normalized.contains("zip")
            || normalized.contains("archive") || normalized.contains("large")
        {
            var compress = DockPill(
                id: "finder-search-compress-\(urls.map(\.path).joined(separator: "|").hashValue)",
                name: "Compress \(targetLabel)",
                icon: "archivebox",
                accentColorName: "orange",
                badge: "ZIP",
                execute: {
                    compressFinderSearchResults(urls)
                    searchState.query = ""
                    l2.focusedPillIndex = nil
                }
            )
            compress.sourceBundleId = "com.apple.finder"
            compress.sourceAppName = "Finder"
            compress.rankingKind = "finderContext"
            compress.trackingIdentifier = "finder-compress:\(normalized)"
            compress.searchTerms = [
                "compress", "zip", "archive", "finder", targetLabel, normalized,
            ]
            pills.append(compress)
        }

        if normalized.contains("move") || normalized.contains("organize") {
            var move = DockPill(
                id: "finder-search-move-\(urls.map(\.path).joined(separator: "|").hashValue)",
                name: "Move \(targetLabel)",
                icon: "folder.badge.plus",
                accentColorName: "teal",
                badge: "Choose",
                execute: {
                    moveFinderSearchResultsWithPanel(urls)
                    searchState.query = ""
                    l2.focusedPillIndex = nil
                }
            )
            move.sourceBundleId = "com.apple.finder"
            move.sourceAppName = "Finder"
            move.rankingKind = "finderContext"
            move.trackingIdentifier = "finder-move:\(normalized)"
            move.searchTerms = ["move", "organize", "finder", targetLabel, normalized]
            pills.append(move)
        }

        return pills
    }

    func compressFinderSearchResults(_ urls: [URL]) {
        let existingURLs = canonicalExistingURLs(urls).filter { !$0.hasDirectoryPath }
        guard !existingURLs.isEmpty else {
            AppToast.show("No files to compress", icon: "exclamationmark.triangle", tint: .orange)
            return
        }
        let parentURL = existingURLs[0].deletingLastPathComponent()
        let archiveBase =
            existingURLs.count == 1
            ? existingURLs[0].deletingPathExtension().lastPathComponent
            : "Context-Dock Selection"
        let archiveURL = uniqueFinderDestination(
            for: parentURL.appendingPathComponent("\(archiveBase).zip"),
            in: parentURL
        )

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            if existingURLs.count == 1 {
                process.arguments = [
                    "-c", "-k", "--sequesterRsrc", "--keepParent",
                    existingURLs[0].path,
                    archiveURL.path,
                ]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = parentURL
                process.arguments = ["-r", archiveURL.path] + existingURLs.map(\.lastPathComponent)
            }
            try? process.run()
            process.waitUntilExit()
            await MainActor.run {
                if process.terminationStatus == 0 {
                    AppToast.show(
                        "Created \(archiveURL.lastPathComponent)", icon: "archivebox", tint: .green)
                    rememberFinderFollowUpTargets(
                        [archiveURL], folderPath: parentURL.path, sourceQuery: "compress")
                } else {
                    AppToast.show(
                        "Compression failed", icon: "exclamationmark.triangle", tint: .orange)
                }
            }
        }
    }

    func moveFinderSearchResultsWithPanel(_ urls: [URL]) {
        let existingURLs = canonicalExistingURLs(urls)
        guard !existingURLs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        let moveLabel =
            existingURLs.count == 1
            ? existingURLs[0].lastPathComponent
            : "\(existingURLs.count) Finder results"
        panel.message = "Choose a destination folder for \(moveLabel)."
        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

        var moved: [URL] = []
        var failures = 0
        for url in existingURLs {
            let destination = uniqueFinderDestination(
                for: url,
                in: destinationFolder
            )
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                moved.append(destination)
            } catch {
                failures += 1
            }
        }

        if !moved.isEmpty {
            rememberFinderFollowUpTargets(
                moved, folderPath: destinationFolder.path, sourceQuery: "move")
            AppToast.show(
                "Moved \(moved.count) item\(moved.count == 1 ? "" : "s")",
                icon: "folder.badge.plus", tint: .green)
        }
        if failures > 0 {
            AppToast.show(
                "Skipped \(failures) item\(failures == 1 ? "" : "s")",
                icon: "exclamationmark.triangle", tint: .orange)
        }
    }

    func buildAttachedFinderFolderPills(query: String) -> [DockPill] {
        let semanticQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !semanticQuery.isEmpty, !semanticQuery.hasPrefix("+") else { return [] }
        guard semanticQuery.count >= 2 else { return [] }
        guard isFinderCurrentWindowSearchAttached() else { return [] }

        let folderPath = URL(fileURLWithPath: attachedFinderFolderSearchPath).standardizedFileURL
            .path
        let folderURL = URL(fileURLWithPath: folderPath)
        let folderName =
            folderURL.lastPathComponent.isEmpty ? "Current Folder" : folderURL.lastPathComponent

        if attachedFinderFolderSnapshotPath != folderPath
            || attachedFinderFolderSnapshotItems.isEmpty
            || Date().timeIntervalSince(attachedFinderFolderSnapshotDate) > 2.0
        {
            refreshAttachedFinderFolderSnapshot(path: folderPath, force: false)
        }

        let scored = Array(
            attachedFinderFolderSnapshotItems
            .compactMap { item -> (item: FinderFolderSnapshotItem, score: Double)? in
                // Search the whole attached-folder tree (recursive), not just direct children.
                guard let score = finderSemanticScore(query: semanticQuery, for: item.url),
                    score >= 120
                else { return nil }
                let recencyBoost: Double = {
                    guard let modifiedDate = item.modifiedDate else { return 0 }
                    let age = Date().timeIntervalSince(modifiedDate)
                    guard age >= 0, age < 7 * 24 * 60 * 60 else { return 0 }
                    return max(0, 80 - (age / 10_800))
                }()
                return (item, score + recencyBoost + (item.isDirectory ? 20 : 0))
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.item.isDirectory != $1.item.isDirectory {
                    return $0.item.isDirectory && !$1.item.isDirectory
                }
                return $0.item.displayName.localizedCaseInsensitiveCompare($1.item.displayName)
                    == .orderedAscending
            }
            .prefix(10))
        let basePills =
            scored
            .map { match in
                let item = match.item
                let itemPath = item.path
                let icon = finderPreviewIcon(for: itemPath)
                requestFinderPreviewThumbnail(for: itemPath, query: semanticQuery)
                var pill = DockPill(
                    id: "finder-attached-\(itemPath)",
                    name: item.displayName,
                    icon: item.isDirectory
                        ? "folder.fill"
                        : finderSemanticSymbol(
                            for: FinderSemanticMatch(
                                path: itemPath,
                                title: item.displayName,
                                subtitle: "",
                                isDirectory: item.isDirectory,
                                score: match.score,
                                source: "Current Folder",
                                searchTerms: []
                            )),
                    accentColorName: item.isDirectory ? "blue" : "teal",
                    badge: folderName,
                    execute: {
                        recordFinderCurrentFolderLaunch(itemPath: itemPath, folderPath: folderPath)
                        openFinderFolderPreferringTab(item.url, isDirectory: item.isDirectory)
                        searchState.query = ""
                        l2.focusedPillIndex = nil
                        hideLauncherAfterFinderAction()
                    }
                )
                pill.sourceBundleId = "com.apple.finder"
                pill.sourceAppName = "Finder"
                pill.rankingKind = "finderCurrent"
                pill.menuItemImage = icon
                pill.quickLookURL = item.url
                pill.trackingIdentifier = finderCurrentFolderTrackingIdentifier(
                    folderPath: folderPath,
                    itemPath: itemPath
                )
                pill.searchTerms = [
                    item.displayName, itemPath, folderPath, "finder", "current folder",
                ]
                pill.rankingScore = match.score
                return pill
            }

        // Drill-in: if a matched item is a folder whose name matches the query, list its
        // contents right below it (e.g. searching "skill" → the Skill folder's files).
        let childPills = finderMatchedFolderChildPills(scored: scored, query: semanticQuery)
        return basePills + childPills
    }

    /// Navigate the EXISTING front Finder window to a folder (same window, like the Go menu)
    /// instead of spawning a new window. Files and the no-window case fall back to the normal
    /// open. Keeps the user's Finder tidy — no window pile-up.
    func openFinderFolderPreferringTab(_ url: URL, isDirectory: Bool) {
        guard isDirectory, finderHasActiveWindow() else {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Finder"
                activate
                if (count of Finder windows) > 0 then
                    set target of front Finder window to (POSIX file "\(path)" as alias)
                else
                    open (POSIX file "\(path)" as alias)
                end if
            end tell
            """
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
    }

    /// Immediate contents of the best matching subfolder, as Finder pills. Lets the user
    /// drill into a folder match without leaving the dock.
    func finderMatchedFolderChildPills(
        scored: [(item: FinderFolderSnapshotItem, score: Double)],
        query: String
    ) -> [DockPill] {
        guard
            let dir = scored.first(where: {
                $0.item.isDirectory
                    && normalizedDockPillText($0.item.displayName).hasPrefix(query)
            })
        else { return [] }

        let dirURL = dir.item.url
        let folderName = dir.item.displayName
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        guard !contents.isEmpty else { return [] }

        return
            contents
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            .prefix(8)
            .enumerated()
            .map { index, childURL in
                let isDir =
                    (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                var pill = DockPill(
                    id: "finder-folder-child-\(childURL.path)",
                    name: childURL.lastPathComponent,
                    icon: isDir ? "folder.fill" : "doc",
                    accentColorName: isDir ? "blue" : "teal",
                    badge: folderName,
                    execute: {
                        openFinderFolderPreferringTab(childURL, isDirectory: isDir)
                        searchState.query = ""
                        l2.focusedPillIndex = nil
                        hideLauncherAfterFinderAction()
                    }
                )
                pill.sourceBundleId = "com.apple.finder"
                pill.sourceAppName = "Finder"
                pill.rankingKind = "finderCurrent"
                pill.menuContext = folderName
                pill.menuItemImage = preparedDockIcon(NSWorkspace.shared.icon(forFile: childURL.path))
                pill.quickLookURL = childURL
                pill.trackingIdentifier = "finder-folder-child:\(childURL.path.lowercased())"
                pill.searchTerms = [childURL.lastPathComponent, folderName, "finder"]
                pill.rankingScore = dir.score - Double(index + 1)
                return pill
            }
    }

    func applyFinderSemanticMatches(_ matches: [FinderSemanticMatch], query: String) {
        let latestScope = resolveDockScope(for: searchState.query)
        let latestQuery =
            latestScope.scopedBundleId == "com.apple.finder"
            ? latestScope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            : ""
        guard latestQuery == query else { return }

        finderSemanticQuery = query
        let results = makeFinderSemanticSearchResults(from: matches)
        finderSemanticResults = results
        finderSemanticPills = makeFinderSemanticDockPills(from: matches)
        applyFinderSemanticPanelResults(results)
    }

    func clearFinderSemanticState() {
        let shouldClearPanelResults =
            !finderSemanticQuery.isEmpty || !finderSemanticResults.isEmpty
            || isFinderSemanticLoading
        finderSemanticTask?.cancel()
        finderSemanticTask = nil
        isFinderSemanticLoading = false
        finderSemanticQuery = ""
        finderSemanticResults = []
        finderSemanticPills = []
        l2.showResultsPopover = false
        if shouldClearPanelResults {
            applyFinderSemanticPanelResults([])
        }
    }

    // MARK: - Finder Go-To-Folder ("+prefix" mode)

    func isFinderGoToMode(query: String) -> Bool {
        guard query.hasPrefix("+") else { return false }
        return frontmost.bundleID == "com.apple.finder"
            || l2.targetApp?.bundleId == "com.apple.finder"
            || axContext.bundleId == "com.apple.finder"
    }

    func updateFinderGoToPills(for query: String) {
        guard isFinderGoToMode(query: query) else {
            if !finderGoToPills.isEmpty { finderGoToPills = [] }
            return
        }
        let pathQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        finderGoToPills = buildFinderGoToPills(pathQuery: pathQuery)
        scheduleDockPillRebuild(query: query, delayNanoseconds: 0)
    }

    func buildFinderGoToPills(pathQuery: String) -> [DockPill] {
        let query = pathQuery.lowercased()
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let desktopOnlyMode = isFinderDesktopOnlyMode

        // Direct absolute-path completion
        if query.hasPrefix("/") {
            if fm.fileExists(atPath: pathQuery) {
                return [makeFinderGoToPill(path: pathQuery)]
            }
            let parent = (pathQuery as NSString).deletingLastPathComponent
            let stem = (pathQuery as NSString).lastPathComponent.lowercased()
            if let items = try? fm.contentsOfDirectory(atPath: parent) {
                return
                    items
                    .filter { !$0.hasPrefix(".") && $0.lowercased().hasPrefix(stem) }
                    .compactMap { item -> DockPill? in
                        let full = (parent as NSString).appendingPathComponent(item)
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue
                        else { return nil }
                        return makeFinderGoToPill(path: full)
                    }
                    .prefix(8).map { $0 }
            }
            return []
        }

        // Common quick-access locations
        let quickAccess: [(path: String, alias: String?)] = [
            ("\(home)/Desktop", "desktop"),
            ("\(home)/Documents", "documents"),
            ("\(home)/Downloads", "downloads"),
            ("\(home)/Pictures", "pictures"),
            ("\(home)/Movies", "movies"),
            ("\(home)/Music", "music"),
            ("\(home)/Library/Mobile Documents/com~apple~CloudDocs", "icloud"),
            (home, "home"),
        ]

        var results: [DockPill] = []
        var seen = Set<String>()

        for entry in quickAccess {
            guard fm.fileExists(atPath: entry.path) else { continue }
            let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
            let alias = entry.alias ?? name
            let matches =
                query.isEmpty
                || name.hasPrefix(query) || name.contains(query)
                || alias.hasPrefix(query) || alias.contains(query)
            if matches, seen.insert(entry.path).inserted {
                results.append(makeFinderGoToPill(path: entry.path))
            }
        }

        guard !desktopOnlyMode else {
            return Array(results.prefix(8))
        }

        // Current Finder folder's subdirectories
        let finderFolder = currentFinderFolderPath()
        if !finderFolder.isEmpty, let items = try? fm.contentsOfDirectory(atPath: finderFolder) {
            for item in items.sorted() where !item.hasPrefix(".") && results.count < 8 {
                let full = (finderFolder as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let itemLower = item.lowercased()
                guard query.isEmpty || itemLower.hasPrefix(query) || itemLower.contains(query)
                else { continue }
                if seen.insert(full).inserted { results.append(makeFinderGoToPill(path: full)) }
            }
        }

        // One level deep inside Desktop + Documents
        for root in ["\(home)/Desktop", "\(home)/Documents"] where results.count < 8 {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() where !item.hasPrefix(".") && results.count < 8 {
                let full = (root as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let itemLower = item.lowercased()
                guard query.isEmpty || itemLower.hasPrefix(query) || itemLower.contains(query)
                else { continue }
                if seen.insert(full).inserted { results.append(makeFinderGoToPill(path: full)) }
            }
        }

        return Array(results.prefix(8))
    }

    func makeFinderGoToPill(path: String) -> DockPill {
        let name = URL(fileURLWithPath: path).lastPathComponent
        var pill = DockPill(
            id: "finder-goto-\(path)",
            name: name.isEmpty ? path : name,
            icon: "folder.fill",
            accentColorName: "blue",
            badge: nil,
            execute: { [self] in navigateFinderToPath(path) }
        )
        pill.menuItemImage = preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        pill.sourceBundleId = "com.apple.finder"
        pill.rankingKind = "finderGoTo"
        pill.trackingIdentifier = finderGoToTrackingIdentifier(for: path)
        return pill
    }

    func finderGoToTrackingIdentifier(for path: String) -> String {
        "finder-goto:\(URL(fileURLWithPath: path).standardizedFileURL.path.lowercased())"
    }

    func finderCurrentFolderTrackingIdentifier(folderPath: String, itemPath: String)
        -> String
    {
        let folder = URL(fileURLWithPath: folderPath).standardizedFileURL.path.lowercased()
        let item = URL(fileURLWithPath: itemPath).standardizedFileURL.path.lowercased()
        return "finder-current:\(folder):\(item)"
    }

    func recordFinderCurrentFolderLaunch(itemPath: String, folderPath: String) {
        UsageTracker.shared.recordAccess(
            for: finderCurrentFolderTrackingIdentifier(folderPath: folderPath, itemPath: itemPath)
        )
    }

    var frequentFinderHomeFolderGhostText: String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Desktop",
        ]

        let mostUsedPath =
            candidates
            .filter { FileManager.default.fileExists(atPath: $0) }
            .max(by: {
                UsageTracker.shared.getAccessCount(for: finderGoToTrackingIdentifier(for: $0))
                    < UsageTracker.shared.getAccessCount(for: finderGoToTrackingIdentifier(for: $1))
            })
        guard let path = mostUsedPath else { return nil }

        guard UsageTracker.shared.getAccessCount(for: finderGoToTrackingIdentifier(for: path)) > 3
        else {
            return nil
        }

        return
            "~/\(URL(fileURLWithPath: path).lastPathComponent)  — type to ask about this folder..."
    }

    var frequentAttachedFinderItemGhostText: String? {
        guard !attachedFinderFolderSearchPath.isEmpty else { return nil }
        let folderPath = URL(fileURLWithPath: attachedFinderFolderSearchPath).standardizedFileURL
            .path
        let prefix = "finder-current:\(folderPath.lowercased()):"
        guard
            let item = UsageTracker.shared.getTopItems(limit: 80)
                .first(where: { entry in
                    entry.identifier.hasPrefix(prefix)
                        && UsageTracker.shared.getAccessCount(for: entry.identifier) > 2
                })
        else { return nil }

        let itemPath = String(item.identifier.dropFirst(prefix.count))
        guard FileManager.default.fileExists(atPath: itemPath) else { return nil }
        return
            "\(URL(fileURLWithPath: itemPath).lastPathComponent)  — type to search this folder..."
    }

    func navigateFinderToPath(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        DispatchQueue.main.async {
            self.searchState.query = ""
            self.finderGoToPills = []
            self.replaceCachedDockPills(self.buildDockPills(query: ""), preserveFocus: true)
        }
    }

    func scheduleFinderSemanticSearchIfNeeded(for query: String) {
        finderSemanticTask?.cancel()

        guard isL2ContextActive, showContextInDock, !isGlobalContextActive, !showMediaLayer else {
            clearFinderSemanticState()
            return
        }

        let scope = resolveDockScope(for: query)
        let currentFolderPath = currentFinderFolderPath()
        guard finderFolderQueryModeActive,
            isFinderFolderSearchAttached(currentFolderPath: currentFolderPath)
        else {
            clearFinderSemanticState()
            return
        }
        let semanticQuery =
            scope.scopedBundleId == "com.apple.finder"
            ? scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : ""
        let profile = finderSemanticProfile(for: semanticQuery)
        guard scope.scopedBundleId == "com.apple.finder" else {
            clearFinderSemanticState()
            return
        }

        guard !semanticQuery.isEmpty else {
            isFinderSemanticLoading = false
            finderSemanticQuery = ""
            finderSemanticResults = []
            finderSemanticPills = []
            l2.showResultsPopover = shouldKeepFinderSearchPopoverVisible(for: query)
            applyFinderSemanticPanelResults([])
            return
        }

        guard semanticQuery.count >= 2 else {
            isFinderSemanticLoading = false
            finderSemanticQuery = ""
            finderSemanticResults = []
            finderSemanticPills = []
            l2.showResultsPopover = shouldKeepFinderSearchPopoverVisible(for: query)
            applyFinderSemanticPanelResults([])
            return
        }

        finderSemanticQuery = semanticQuery
        isFinderSemanticLoading = false
        finderSemanticTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isFinderSemanticLoading = true
            }

            let advancedMatches = await MainActor.run {
                buildAdvancedFinderDataMatches(
                    profile: profile,
                    currentFolderPath: currentFolderPath,
                    limit: 24
                )
            }
            let fastMatches = await buildFastFinderSemanticMatches(
                query: semanticQuery,
                currentFolderPath: currentFolderPath
            )
            let initialMatches = mergeFinderSemanticMatches(advancedMatches, with: fastMatches)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard finderSemanticQuery == semanticQuery else { return }
                applyFinderSemanticMatches(initialMatches, query: semanticQuery)
                isFinderSemanticLoading = false
            }

            let spotlightEnabled = await MainActor.run { settings.enableSpotlightSearch }
            guard spotlightEnabled, semanticQuery.count >= 3 else { return }

            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }

            let spotlightMatches = runFinderSpotlightSearch(
                query: semanticQuery,
                currentFolderPath: currentFolderPath,
                limit: 18
            )
            let merged = mergeFinderSemanticMatches(initialMatches, with: spotlightMatches)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard finderSemanticQuery == semanticQuery else { return }
                applyFinderSemanticMatches(merged, query: semanticQuery)
                isFinderSemanticLoading = false
            }
        }
    }

    func isFinderSearchStyleQuery(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let analyticalTerms = [
            "summarize", "summary", "explain", "review", "translate", "compare",
            "analyze", "analyse", "why", "how", "read", "rewrite", "draft", "prepare",
            "rename", "organize", "sort", "clean up", "compress", "zip",
            "convert", "export", "save", "open", "move", "copy", "share", "send",
            "attach", "upload", "delete", "trash", "remove", "duplicate",
            "reveal", "preview", "quick look", "print", "merge", "split", "combine",
            "package", "email",
            "extract", "encode", "transcode",
        ]
        return !analyticalTerms.contains(where: normalized.contains)
    }

    func finderSubmissionSummary(for query: String, results: [SearchResult]) -> String {
        if results.isEmpty {
            return "No Finder matches for “\(query)”."
        }

        let folderCount = results.filter { $0.type == .folder }.count
        let fileCount = results.count - folderCount
        if folderCount > 0 && fileCount > 0 {
            return "Found \(results.count) Finder matches for “\(query)” across folders and files."
        }
        if folderCount > 0 {
            return
                "Found \(folderCount) Finder folder match\(folderCount == 1 ? "" : "es") for “\(query)”."
        }
        return "Found \(fileCount) Finder file match\(fileCount == 1 ? "" : "es") for “\(query)”."
    }

}
