// FileIndexManager.swift
// Context Dock
//
// Spotlight-backed file index. NSMetadataQuery feeds a live in-memory name
// index; no manual file walk, no JSON cache, no "Rebuild Index" button.
// Spotlight is always up-to-date — files appear/disappear automatically.

import Foundation
import AppKit
import Combine

// MARK: - Indexed File Model (kept for SearchResult compatibility)

struct IndexedFile: Codable, Identifiable {
    let id: UUID
    let name: String
    let path: String
    let isDirectory: Bool
    let fileExtension: String
    let parentPath: String
    let modificationDate: Date
    let size: Int64

    var displayName: String { name }

    init(url: URL, attributes: [FileAttributeKey: Any] = [:]) {
        self.id = UUID()
        self.name = url.lastPathComponent
        self.path = url.path
        self.fileExtension = url.pathExtension.lowercased()
        self.parentPath = url.deletingLastPathComponent().path
        self.modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
        self.size = (attributes[.size] as? Int64) ?? 0
        if let typeVal = attributes[.type] as? FileAttributeType {
            self.isDirectory = typeVal == .typeDirectory
        } else {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            self.isDirectory = isDir.boolValue
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, isDirectory, fileExtension, parentPath, modificationDate, size
    }
}

struct AdvancedFileSearchQuery {
    var rootPath: String
    var residualQuery: String = ""
    var allowedExtensions: Set<String>? = nil
    var includeDirectories: Bool = true
    var filesOnly: Bool = false
    var minSizeBytes: Int64? = nil
    var maxSizeBytes: Int64? = nil
    var modifiedAfter: Date? = nil
    var modifiedBefore: Date? = nil
    var limit: Int = 50
}

// MARK: - Progress / Metadata stubs (keep UI compatibility)

struct IndexMetadata: Codable {
    var lastFullIndexDate: Date?
    var indexedDirectories: [String] = []
    var totalFilesIndexed: Int = 0
    var indexVersion: Int = 1
    static let currentVersion = 1
    init() {}
}

struct IndexingProgress {
    var isIndexing: Bool = false
    var currentDirectory: String = ""
    var filesIndexed: Int = 0
    var totalDirectories: Int = 0
    var processedDirectories: Int = 0
    var lastError: String? = nil
    var progressPercentage: Double { 0 }
}

// MARK: - File Index Manager

@MainActor
final class FileIndexManager: ObservableObject {
    static let shared = FileIndexManager()

    // MARK: Published (UI uses these)
    @Published private(set) var indexedFiles: [IndexedFile] = []
    @Published private(set) var progress = IndexingProgress()
    @Published private(set) var isReady = false
    @Published private(set) var metadata = IndexMetadata()

    // MARK: In-memory name index for fast O(1) prefix lookup
    private var nameIndex: [String: [IndexedFile]] = [:]   // lowercased name prefix → files

    // MARK: NSMetadataQuery — lives on main thread
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Public API

    /// Call once on app launch. Starts the live Spotlight query — no file walk needed.
    func initialize() async {
        guard AppSettings.shared.enableSpotlightSearch else {
            isReady = true
            return
        }
        startSpotlightQuery()
    }

    /// No-op — Spotlight keeps the index fresh automatically. Kept for UI compatibility.
    func forceReindex() async {
        restartQuery()
    }

    /// No-op — there is no JSON cache to clear. Kept for UI compatibility.
    func clearCache() async {
        indexedFiles = []
        nameIndex = [:]
        isReady = false
        restartQuery()
    }

    // MARK: - Search (same signature as before)

    func search(query: String, limit: Int = 50) -> [SearchResult] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var seen = Set<String>()
        var scored: [(IndexedFile, Double)] = []

        for file in specialFolderMatches(query: q) {
            guard seen.insert(file.path).inserted else { continue }
            scored.append((file, 5_000))
        }

        // 1. Prefix match on indexed names
        let prefix = String(q.prefix(4))
        for (key, files) in nameIndex where key.hasPrefix(prefix) {
            for file in files {
                guard seen.insert(file.path).inserted else { continue }
                if let sc = FuzzyMatcher.score(q, against: file.name.lowercased()) {
                    scored.append((file, sc))
                }
            }
        }

        // 2. Substring fallback for short queries missed by prefix
        if scored.count < limit {
            for (_, files) in nameIndex {
                for file in files {
                    guard seen.insert(file.path).inserted else { continue }
                    let lower = file.name.lowercased()
                    if lower.contains(q) {
                        scored.append((file, 0.4))
                    }
                }
                if scored.count >= limit * 3 { break }
            }
        }

        scored.sort { $0.1 > $1.1 }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return scored.prefix(limit).map { (file, _) in
            let icon = ThumbnailGenerator.shared.getThumbnailSync(for: file.path)
                ?? NSWorkspace.shared.icon(forFile: file.path)
            let displayPath = file.path.replacingOccurrences(of: homeDir, with: "~")
            let resultType: SearchResult.ResultType = file.isDirectory ? .folder :
                (file.fileExtension.isEmpty ? .file : .document)
            let url = URL(fileURLWithPath: file.path)
            return SearchResult(
                title: file.name,
                subtitle: displayPath,
                icon: icon,
                action: { NSWorkspace.shared.open(url) },
                type: resultType,
                filePath: file.path,
                contactData: nil
            )
        }
    }

    private func specialFolderMatches(query q: String) -> [IndexedFile] {
        let aliases = [
            "application", "applications", "apps", "app folder", "application folder",
            "mac applications", "macos applications", "macintosh hd applications"
        ]
        guard aliases.contains(where: { $0.hasPrefix(q) || q.hasPrefix($0) || $0.contains(q) }) else {
            return []
        }

        let candidates: [(title: String, path: String, score: Double)] = [
            ("Applications", "/Applications", 5_000),
            ("System Applications", "/System/Applications", 4_800),
            ("Utilities", "/Applications/Utilities", 4_600),
            ("System Utilities", "/System/Applications/Utilities", 4_500)
        ]

        return candidates.compactMap { candidate in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                isDir.boolValue
            else { return nil }
            var attrs: [FileAttributeKey: Any] = [.type: FileAttributeType.typeDirectory]
            attrs[.modificationDate] = Date.distantPast
            return IndexedFile(url: URL(fileURLWithPath: candidate.path), attributes: attrs)
        }
    }

    func advancedSearch(_ query: AdvancedFileSearchQuery) -> [IndexedFile] {
        let root = URL(fileURLWithPath: query.rootPath).standardizedFileURL.path
        let residual = query.residualQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let residualTerms = residual
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }

        var scored: [(IndexedFile, Double)] = []

        for file in indexedFiles {
            guard file.path == root || file.path.hasPrefix(root + "/") else { continue }
            if query.filesOnly && file.isDirectory { continue }
            if !query.includeDirectories && file.isDirectory { continue }

            if let allowedExtensions = query.allowedExtensions {
                guard !file.isDirectory, allowedExtensions.contains(file.fileExtension) else { continue }
            }

            if let minSizeBytes = query.minSizeBytes, !file.isDirectory {
                guard file.size >= minSizeBytes else { continue }
            }
            if let maxSizeBytes = query.maxSizeBytes, !file.isDirectory {
                guard file.size > 0, file.size <= maxSizeBytes else { continue }
            }
            if let modifiedAfter = query.modifiedAfter {
                guard file.modificationDate >= modifiedAfter else { continue }
            }
            if let modifiedBefore = query.modifiedBefore {
                guard file.modificationDate < modifiedBefore else { continue }
            }

            let searchableText = "\(file.name) \(file.parentPath) \(file.fileExtension)".lowercased()
            var score = 100.0

            if !residual.isEmpty {
                if file.name.lowercased() == residual {
                    score += 900
                } else if file.name.lowercased().hasPrefix(residual) {
                    score += 760
                } else if file.name.lowercased().contains(residual) {
                    score += 650
                } else if !residualTerms.isEmpty {
                    let matchedTerms = residualTerms.filter { searchableText.contains($0) }
                    guard !matchedTerms.isEmpty else { continue }
                    score += Double(matchedTerms.count * 120)
                } else {
                    continue
                }
            }

            if let minSizeBytes = query.minSizeBytes, file.size >= minSizeBytes {
                score += min(350, Double(file.size) / 1_048_576.0)
            }
            if let maxSizeBytes = query.maxSizeBytes, file.size > 0, file.size <= maxSizeBytes {
                score += max(0, 80 - Double(file.size) / 65_536.0)
            }

            let ageHours = max(0, Date().timeIntervalSince(file.modificationDate) / 3600)
            score += max(0, 80 - min(80, ageHours / 12))
            scored.append((file, score))
        }

        return scored
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.size != $1.0.size { return $0.0.size > $1.0.size }
                return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
            }
            .prefix(query.limit)
            .map(\.0)
    }

    // MARK: - Spotlight query lifecycle

    private func startSpotlightQuery() {
        let q = NSMetadataQuery()

        // Scope: user home + removable/network volumes
        q.searchScopes = spotlightScopes()

        // Predicate: exclude hidden files and known build/cache dirs
        q.predicate = NSPredicate(
            format: "NOT kMDItemDisplayName BEGINSWITH '.' AND NOT kMDItemPath CONTAINS '/node_modules/' AND NOT kMDItemPath CONTAINS '/DerivedData/' AND NOT kMDItemPath CONTAINS '/Library/Caches/' AND NOT kMDItemPath CONTAINS '/.git/' AND NOT kMDItemPath CONTAINS '/Pods/' AND NOT kMDItemPath CONTAINS '/.build/' AND NOT kMDItemPath CONTAINS '/build/'"
        )

        // Sort by last-used date — most relevant files float up
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]

        // Cap at 60k items — enough for any user's home folder
        q.operationQueue = .main

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] notification in
                guard let query = notification.object as? NSMetadataQuery else { return }
                MainActor.assumeIsolated {
                    self?.ingestResults(from: query)
                }
            }
        )
        observers.append(
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] notification in
                guard let query = notification.object as? NSMetadataQuery else { return }
                MainActor.assumeIsolated {
                    self?.ingestResults(from: query)
                }
            }
        )

        progress.isIndexing = true
        q.start()
        metadataQuery = q
    }

    private func restartQuery() {
        metadataQuery?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        metadataQuery = nil
        startSpotlightQuery()
    }

    /// Cancels a stale chunked ingest when a newer query result arrives.
    private var ingestGeneration = 0

    private func ingestResults(from q: NSMetadataQuery) {
        // Pause live updates while we walk the current result set, and process it in
        // small batches spread across runloop turns. Building 60k IndexedFile structs
        // (each with Spotlight attribute reads) in one synchronous pass froze the main
        // thread on "Add Directory" (esp. the whole home folder); chunking keeps the UI
        // responsive and lets partial results appear as they index.
        q.disableUpdates()
        ingestGeneration &+= 1
        let generation = ingestGeneration
        let maxIngest = 60_000
        let total = min(q.resultCount, maxIngest)
        progress.isIndexing = true
        processIngestBatch(query: q, total: total, from: 0, files: [], generation: generation)
    }

    private func processIngestBatch(
        query q: NSMetadataQuery, total: Int, from start: Int,
        files accumulator: [IndexedFile], generation: Int
    ) {
        // A newer query result superseded this walk — abandon it and re-enable updates.
        guard generation == ingestGeneration else {
            q.enableUpdates()
            return
        }

        let settings = AppSettings.shared
        let showDocs = settings.enableL1DocumentSearch
        let showFiles = settings.enableL1FileSearch
        let allowedDirs = settings.useCustomSearchDirectories
            ? settings.searchDirectories.map { $0.path } : []

        // ~2 ms of Spotlight attribute work per batch — small enough that the runloop
        // stays smooth between batches.
        let batchSize = 2_500
        let end = min(start + batchSize, total)
        var files = accumulator
        files.reserveCapacity(total)

        for i in start ..< end {
            guard let item = q.result(at: i) as? NSMetadataItem else { continue }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()

            let isDoc = documentExtensions.contains(ext)
            if isDoc && !showDocs { continue }
            if !isDoc && !showFiles { continue }

            if settings.useCustomSearchDirectories {
                guard !allowedDirs.isEmpty,
                    allowedDirs.contains(where: { path.hasPrefix($0) })
                else { continue }
            }

            var attrs: [FileAttributeKey: Any] = [:]
            if let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? Int64 {
                attrs[.size] = size
            }
            if let mod = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date {
                attrs[.modificationDate] = mod
            }
            let contentType = item.value(forAttribute: "kMDItemContentType") as? String ?? ""
            let isDir = contentType == "public.folder"
            attrs[.type] = isDir ? FileAttributeType.typeDirectory : FileAttributeType.typeRegular
            files.append(IndexedFile(url: url, attributes: attrs))
        }

        // Publish progressively so search works while the rest indexes.
        indexedFiles = files
        buildNameIndex(from: files)
        progress.filesIndexed = files.count
        isReady = true

        if end < total {
            DispatchQueue.main.async { [weak self] in
                self?.processIngestBatch(
                    query: q, total: total, from: end, files: files, generation: generation)
            }
        } else {
            metadata.lastFullIndexDate = Date()
            metadata.totalFilesIndexed = files.count
            progress.isIndexing = false
            q.enableUpdates()
        }
    }

    private func buildNameIndex(from files: [IndexedFile]) {
        var idx: [String: [IndexedFile]] = [:]
        for file in files {
            let key = String(file.name.lowercased().prefix(4))
            idx[key, default: []].append(file)
        }
        nameIndex = idx
    }

    private func spotlightScopes() -> [Any] {
        let settings = AppSettings.shared
        let custom = settings.searchDirectories.map { URL(fileURLWithPath: $0.path) }

        // Restrict mode: only the user-chosen directories.
        if settings.useCustomSearchDirectories, !custom.isEmpty {
            return custom
        }

        // Additive mode: home scope PLUS any extra directories. The home scope
        // (NSMetadataQueryUserHomeScope) excludes ~/Library, so paths like iCloud Drive
        // (~/Library/Mobile Documents/com~apple~CloudDocs) never appear unless added as
        // their own explicit scope here.
        if !custom.isEmpty {
            return [NSMetadataQueryUserHomeScope] + custom
        }
        return [NSMetadataQueryUserHomeScope]
    }

    private let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "txt", "rtf", "md",
        "csv", "json", "xml", "html", "htm", "css", "js",
        "swift", "py", "rb", "go", "java", "c", "cpp", "h"
    ]
}
