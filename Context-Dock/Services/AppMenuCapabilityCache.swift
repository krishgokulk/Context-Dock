import AppKit
import Foundation

nonisolated struct AppMenuCapabilityRecord: Codable, Hashable {
    let bundleIdentifier: String
    let appName: String
    let bundleVersion: String
    let localeIdentifier: String
    let title: String
    let path: [String]
    let shortcutChar: String?
    let shortcutModifiers: Int
    let isAppleMenu: Bool
    let lastSeen: Date
    var isEnabled: Bool = true  // Added to track enabled state from store
    var resolvedFilePath: String? = nil

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case appName
        case bundleVersion
        case localeIdentifier
        case title
        case path
        case shortcutChar
        case shortcutModifiers
        case isAppleMenu
        case lastSeen
        case isEnabled
        case resolvedFilePath
    }

    init(
        bundleIdentifier: String,
        appName: String,
        bundleVersion: String,
        localeIdentifier: String,
        title: String,
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int,
        isAppleMenu: Bool,
        lastSeen: Date,
        isEnabled: Bool = true,
        resolvedFilePath: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.bundleVersion = bundleVersion
        self.localeIdentifier = localeIdentifier
        self.title = title
        self.path = path
        self.shortcutChar = shortcutChar
        self.shortcutModifiers = shortcutModifiers
        self.isAppleMenu = isAppleMenu
        self.lastSeen = lastSeen
        self.isEnabled = isEnabled
        self.resolvedFilePath = resolvedFilePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        appName = try container.decode(String.self, forKey: .appName)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        localeIdentifier = try container.decode(String.self, forKey: .localeIdentifier)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode([String].self, forKey: .path)
        shortcutChar = try container.decodeIfPresent(String.self, forKey: .shortcutChar)
        shortcutModifiers = try container.decode(Int.self, forKey: .shortcutModifiers)
        isAppleMenu = try container.decode(Bool.self, forKey: .isAppleMenu)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        resolvedFilePath = try container.decodeIfPresent(String.self, forKey: .resolvedFilePath)
    }

    nonisolated var pathString: String { path.joined(separator: " > ") }
    nonisolated var normalizedPath: String { AppMenuCapabilityCache.normalize(pathString) }
    nonisolated var normalizedTitle: String { AppMenuCapabilityCache.normalize(title) }
    nonisolated var resolvedURL: URL? {
        guard let resolvedFilePath, !resolvedFilePath.isEmpty else { return nil }
        return URL(fileURLWithPath: resolvedFilePath)
    }
}

nonisolated struct AppMenuCapabilitySummary: Identifiable, Hashable {
    let bundleIdentifier: String
    let appName: String
    let updatedAt: Date
    let recordCount: Int
    let samplePaths: [String]

    var id: String { bundleIdentifier }
}

nonisolated private struct AppMenuCapabilitySnapshot: Codable {
    var bundleIdentifier: String
    var appName: String
    var bundleVersion: String
    var localeIdentifier: String
    var updatedAt: Date
    var records: [AppMenuCapabilityRecord]

    // Inverted indexes — in-memory only, not persisted, rebuilt when records change.
    // wordIndex:    normalized full word → record indices
    // prefix2Index: 2-char prefix       → record indices
    var wordIndex: [String: [Int]] = [:]
    var prefix2Index: [String: [Int]] = [:]

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier, appName, bundleVersion, localeIdentifier, updatedAt, records
    }

    mutating func rebuildInvertedIndex() {
        var words: [String: [Int]] = [:]
        var prefixes: [String: [Int]] = [:]
        words.reserveCapacity(records.count * 3)
        prefixes.reserveCapacity(records.count * 3)
        for (i, record) in records.enumerated() {
            let title = AppMenuCapabilityCache.normalize(record.title)
            let pathTokens = record.path.flatMap {
                AppMenuCapabilityCache.normalize($0).split(separator: " ").map(String.init)
            }
            let allTokens = title.split(separator: " ").map(String.init) + pathTokens
            for token in allTokens where !token.isEmpty {
                words[token, default: []].append(i)
                let p = String(token.prefix(2))
                if p.count == 2 { prefixes[p, default: []].append(i) }
            }
        }
        wordIndex = words
        prefix2Index = prefixes
    }

    // Fast candidate selection using inverted index.
    // Returns record indices that are likely matches for the query.
    // Over-inclusive by design — rankedRecords() scores and filters precisely.
    func candidateIndices(for normalizedQuery: String) -> Set<Int>? {
        guard !normalizedQuery.isEmpty, !wordIndex.isEmpty else { return nil }
        let tokens = normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var combined: Set<Int>? = nil
        for token in tokens {
            var tokenSet = Set(wordIndex[token] ?? [])
            let p = String(token.prefix(2))
            if p.count == 2 { tokenSet.formUnion(prefix2Index[p] ?? []) }
            if tokenSet.isEmpty { return Set() }  // token has no candidates → zero results
            if let existing = combined {
                combined = existing.intersection(tokenSet)
            } else {
                combined = tokenSet
            }
        }
        return combined
    }
}

final class AppMenuCapabilityCache {
    nonisolated static let shared = AppMenuCapabilityCache()

    nonisolated static func shouldExposeInGlobalContext(title: String, path: [String]) -> Bool {
        let normalizedTitle = normalize(title)
        let normalizedPath = path.map(normalize)
        guard !normalizedTitle.isEmpty, !normalizedPath.isEmpty else { return false }
        if normalizedPath.first == "apple" { return false }
        if normalizedPath.contains("services") { return false }
        if normalizedPath.contains("writing tools") { return false }
        if normalizedPath.contains("autofill") { return false }
        if normalizedTitle == "autofill" { return false }
        if normalizedTitle == "start dictation" { return false }
        if normalizedTitle == "emoji symbols" { return false }
        return true
    }

    nonisolated private struct MenuItemsCacheKey: Hashable {
        let bundleIdentifier: String
        let appName: String
        let processIdentifier: pid_t
        let query: String
        let maxResults: Int
    }

    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "com.krishgokul.ContextDock.menu-capability-persistence",
        qos: .utility
    )
    nonisolated(unsafe) private var snapshots: [String: AppMenuCapabilitySnapshot] = [:]
    nonisolated(unsafe) private var menuItemsCache: [MenuItemsCacheKey: [AXMenuItem]] = [:]
    nonisolated(unsafe) private var pendingSaveWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var persistenceGeneration = 0
    private let maxRecordsPerApp = 350
    private let maxBrowserRecordsPerApp = 2_000
    private let maxMenuItemsCacheEntries = 256

    private init() {
        loadFromDisk()
    }

    nonisolated func store(items: [AXMenuItem], for app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        let appName = app.localizedName ?? bundleIdentifier
        let bundleVersion = bundleVersion(for: app)
        let localeIdentifier = Locale.current.identifier
        let now = Date()

        var seen = Set<String>()
        let records = items.compactMap { item -> AppMenuCapabilityRecord? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = item.path
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "-" }
            guard !title.isEmpty, path.count > 1 else { return nil }
            let isAppleMenu = item.isAppleMenu || Self.normalize(path.first ?? "") == "apple"

            // Top-level menu containers are discovery nodes, not useful executable capabilities.
            if !item.children.isEmpty { return nil }
            let resolvedFilePath = resolvePersistentMenuFilePath(
                title: title,
                path: path,
                bundleIdentifier: bundleIdentifier
            )
            guard shouldPersistMenuCapability(
                title: title,
                path: path,
                bundleIdentifier: bundleIdentifier,
                resolvedFilePath: resolvedFilePath
            ) else { return nil }

            let key = Self.normalize(path.joined(separator: " > "))
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }

            return AppMenuCapabilityRecord(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                bundleVersion: bundleVersion,
                localeIdentifier: localeIdentifier,
                title: title,
                path: path,
                shortcutChar: item.shortcutChar,
                shortcutModifiers: item.shortcutModifiers,
                isAppleMenu: isAppleMenu,
                lastSeen: now,
                isEnabled: item.isEnabled,
                resolvedFilePath: resolvedFilePath
            )
        }

        guard !records.isEmpty else { return }

        lock.lock()
        let existingRecords = snapshots[bundleIdentifier]?.records ?? []
        var mergedByPath = [String: AppMenuCapabilityRecord]()
        for record in existingRecords {
            if isVolatileMenuPath(record.path) { continue }
            guard shouldPersistMenuCapability(
                title: record.title,
                path: record.path,
                bundleIdentifier: bundleIdentifier,
                resolvedFilePath: record.resolvedFilePath
            ) else { continue }
            mergedByPath[record.normalizedPath] = record
        }
        for record in records {
            mergedByPath[record.normalizedPath] = record
        }

        let mergedRecords = mergedByPath.values.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        var snapshot = AppMenuCapabilitySnapshot(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            bundleVersion: bundleVersion,
            localeIdentifier: localeIdentifier,
            updatedAt: now,
            records: Array(mergedRecords.prefix(maxRecords(for: bundleIdentifier)))
        )
        snapshot.rebuildInvertedIndex()

        snapshots[bundleIdentifier] = snapshot
        menuItemsCache = menuItemsCache.filter { $0.key.bundleIdentifier != bundleIdentifier }
        lock.unlock()

        scheduleSaveToDisk()
        Task { @MainActor in
            RecentItemsService.shared.invalidate()
        }
    }

    nonisolated private func isVolatileMenuPath(_ path: [String]) -> Bool {
        let normalized = path.map(Self.normalize).filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return false }
        let volatileBranches: Set<String> = [
            "history",
            "bookmarks",
            "open recent",
            "recent items",
            "recent documents",
            "recent projects",
            "recent files",
            "recent folders",
            "recently closed",
            "closed tabs",
            "closed windows"
        ]
        if normalized.contains(where: { volatileBranches.contains($0) }) { return true }
        return normalized.first == "window" && normalized.count > 2
    }

    nonisolated func updateAvailability(items: [AXMenuItem], for app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        var enabledByPath: [String: Bool] = [:]
        enabledByPath.reserveCapacity(items.count)
        for item in items {
            let key = Self.normalize(item.path.joined(separator: " > "))
            guard !key.isEmpty else { continue }
            enabledByPath[key] = (enabledByPath[key] ?? false) || item.isEnabled
        }
        guard !enabledByPath.isEmpty else { return }

        lock.lock()
        guard var snapshot = snapshots[bundleIdentifier] else {
            lock.unlock()
            return
        }
        var changed = false
        snapshot.records = snapshot.records.map { record in
            guard let enabled = enabledByPath[record.normalizedPath],
                  enabled != record.isEnabled else { return record }
            var updated = record
            updated.isEnabled = enabled
            changed = true
            return updated
        }
        if changed {
            snapshot.updatedAt = Date()
            snapshots[bundleIdentifier] = snapshot
            menuItemsCache = menuItemsCache.filter { $0.key.bundleIdentifier != bundleIdentifier }
        }
        lock.unlock()
    }

    nonisolated func menuItems(
        for app: NSRunningApplication,
        query: String = "",
        maxResults: Int = 24
    ) -> [AXMenuItem] {
        guard let bundleIdentifier = app.bundleIdentifier else { return [] }
        return menuItems(
            bundleIdentifier: bundleIdentifier,
            appName: app.localizedName ?? bundleIdentifier,
            processIdentifier: app.processIdentifier,
            query: query,
            maxResults: maxResults
        )
    }

    nonisolated func menuItems(
        bundleIdentifier: String,
        appName: String,
        processIdentifier: pid_t = 0,
        query: String = "",
        maxResults: Int = 24
    ) -> [AXMenuItem] {
        guard !bundleIdentifier.isEmpty else { return [] }
        let normalizedQuery = Self.normalize(query)
        let cacheKey = MenuItemsCacheKey(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            processIdentifier: processIdentifier,
            query: normalizedQuery,
            maxResults: maxResults
        )

        lock.lock()
        if let cached = menuItemsCache[cacheKey] {
            lock.unlock()
            return cached
        }
        let snapshot = snapshots[bundleIdentifier]
        lock.unlock()

        let allRawRecords = snapshot?.records ?? []
        guard !allRawRecords.isEmpty else { return [] }

        // Use the inverted index to narrow candidates before filtering and scoring.
        // For a 3-char query against 500 records, index lookup returns ~20-50 candidates
        // instead of scoring all 500 — roughly 10-25× speedup per app.
        let candidateRecords: [AppMenuCapabilityRecord]
        if let indices = snapshot?.candidateIndices(for: normalizedQuery), !indices.isEmpty {
            candidateRecords = indices.compactMap { i -> AppMenuCapabilityRecord? in
                guard i < allRawRecords.count else { return nil }
                let r = allRawRecords[i]
                guard shouldPersistMenuCapability(
                    title: r.title, path: r.path,
                    bundleIdentifier: bundleIdentifier, resolvedFilePath: r.resolvedFilePath
                ) else { return nil }
                return r
            }
        } else {
            // No index available or empty query — fall back to full scan outside the lock.
            candidateRecords = allRawRecords.filter {
                shouldPersistMenuCapability(
                    title: $0.title, path: $0.path,
                    bundleIdentifier: bundleIdentifier, resolvedFilePath: $0.resolvedFilePath
                )
            }
        }

        guard !candidateRecords.isEmpty else { return [] }

        let ranked = rankedRecords(candidateRecords, normalizedQuery: normalizedQuery)
        // Cached capability entries are passive metadata for ranking/display.
        // Do not attach a live per-app AX element or consult live AX state here,
        // because this path is called from UI rendering and startup code.
        let placeholderElement = AXUIElementCreateSystemWide()

        let items = ranked.prefix(maxResults).map { record in
            let isAppleMenu = record.isAppleMenu || Self.normalize(record.path.first ?? "") == "apple"
            var item = AXMenuItem(
                title: record.title,
                path: record.path,
                isEnabled: record.isEnabled,
                element: placeholderElement,
                children: [],
                sourcePID: processIdentifier,
                sourceAppName: appName,
                isAppleMenu: isAppleMenu,
                hasLiveAvailability: false,
                shortcutChar: record.shortcutChar,
                shortcutModifiers: record.shortcutModifiers
            )
            item.resolvedFilePath = record.resolvedFilePath
            return item
        }

        lock.lock()
        if menuItemsCache.count > maxMenuItemsCacheEntries {
            // Evict half to avoid thundering-herd on the next query burst
            let excess = menuItemsCache.count - maxMenuItemsCacheEntries / 2
            for key in menuItemsCache.keys.prefix(excess) {
                menuItemsCache.removeValue(forKey: key)
            }
        }
        menuItemsCache[cacheKey] = items
        lock.unlock()

        return items
    }

    nonisolated func record(path: [String], bundleIdentifier: String) -> AppMenuCapabilityRecord? {
        lock.lock()
        let records = (snapshots[bundleIdentifier]?.records ?? []).filter {
            shouldPersistMenuCapability(
                title: $0.title,
                path: $0.path,
                bundleIdentifier: bundleIdentifier,
                resolvedFilePath: $0.resolvedFilePath
            )
        }
        lock.unlock()
        let target = Self.normalize(path.joined(separator: " > "))
        return records.first { $0.normalizedPath == target }
    }

    nonisolated func hasSnapshot(bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        lock.lock()
        let exists = snapshots[bundleIdentifier]?.records.isEmpty == false
        lock.unlock()
        return exists
    }

    nonisolated func allCachedBundleIdentifiers() -> [String] {
        lock.lock()
        let ids = snapshots.compactMap { k, v in v.records.isEmpty ? nil : k }
        lock.unlock()
        return ids
    }

    /// Drop cached menu snapshots for the given bundle ids (e.g. uninstalled
    /// apps) and persist the trimmed cache.
    nonisolated func purge(bundleIdentifiers ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        var removed = false
        for id in ids where snapshots.removeValue(forKey: id) != nil { removed = true }
        lock.unlock()
        if removed { scheduleSaveToDisk() }
    }

    nonisolated func resolvedRecentDocumentURLs(limit: Int = 120) -> [URL] {
        lock.lock()
        let records = snapshots.values.flatMap(\.records)
        lock.unlock()

        var seen = Set<String>()
        return records
            .filter { $0.resolvedFilePath?.isEmpty == false }
            .sorted { $0.lastSeen > $1.lastSeen }
            .compactMap { record -> URL? in
                guard let path = record.resolvedFilePath else { return nil }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path),
                    url.pathExtension.lowercased() != "app",
                    seen.insert(url.path).inserted
                else { return nil }
                return url
            }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated func snapshotAge(bundleIdentifier: String) -> TimeInterval? {
        guard !bundleIdentifier.isEmpty else { return nil }
        lock.lock()
        let updatedAt = snapshots[bundleIdentifier]?.updatedAt
        lock.unlock()
        guard let updatedAt else { return nil }
        return Date().timeIntervalSince(updatedAt)
    }

    nonisolated func summary(bundleIdentifier: String) -> AppMenuCapabilitySummary? {
        guard !bundleIdentifier.isEmpty else { return nil }
        lock.lock()
        let snapshot = snapshots[bundleIdentifier]
        lock.unlock()
        guard let snapshot, !snapshot.records.isEmpty else { return nil }
        return AppMenuCapabilitySummary(
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: snapshot.appName,
            updatedAt: snapshot.updatedAt,
            recordCount: snapshot.records.count,
            samplePaths: snapshot.records.prefix(6).map(\.pathString)
        )
    }

    nonisolated func summaries() -> [AppMenuCapabilitySummary] {
        lock.lock()
        let snapshotValues = Array(snapshots.values)
        lock.unlock()
        return snapshotValues
            .filter { !$0.records.isEmpty }
            .map { snapshot in
                AppMenuCapabilitySummary(
                    bundleIdentifier: snapshot.bundleIdentifier,
                    appName: snapshot.appName,
                    updatedAt: snapshot.updatedAt,
                    recordCount: snapshot.records.count,
                    samplePaths: snapshot.records.prefix(6).map(\.pathString)
                )
            }
            .sorted {
                let lhs = $0.appName.localizedCaseInsensitiveCompare($1.appName)
                if lhs == .orderedSame { return $0.bundleIdentifier < $1.bundleIdentifier }
                return lhs == .orderedAscending
            }
    }

    nonisolated func contextBlock(for app: NSRunningApplication, query: String, maxResults: Int = 40) -> String {
        guard let bundleIdentifier = app.bundleIdentifier else { return "" }

        lock.lock()
        let records = snapshots[bundleIdentifier]?.records ?? []
        lock.unlock()

        let items = rankedRecords(records, query: query)
            .filter { !$0.isAppleMenu && !$0.pathString.isEmpty }
            .prefix(maxResults)
        guard !items.isEmpty else { return "" }

        var lines = ["## Cached App Menu Capabilities"]
        lines.append("These are previously discovered app menu actions. Validate live state before executing.")
        for item in items {
            let shortcut = shortcutDisplay(
                char: item.shortcutChar,
                modifiers: item.shortcutModifiers
            ).map { " [\($0)]" } ?? ""
            lines.append("- \(item.pathString)\(shortcut)")
        }
        return lines.joined(separator: "\n")
    }

    private static let _nonAlphanum = CharacterSet.alphanumerics.inverted

    nonisolated static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let normalized = folded
            .components(separatedBy: _nonAlphanum)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if normalized == "minimise" { return "minimize" }
        if normalized == "minimise all" { return "minimize all" }
        return normalized
    }

    nonisolated private func rankedRecords(
        _ records: [AppMenuCapabilityRecord],
        query: String
    ) -> [AppMenuCapabilityRecord] {
        rankedRecords(records, normalizedQuery: Self.normalize(query))
    }

    nonisolated private func rankedRecords(
        _ records: [AppMenuCapabilityRecord],
        normalizedQuery q: String
    ) -> [AppMenuCapabilityRecord] {
        SearchPerformanceLog.shared.signpost("menu.ranking", query: q) {
        guard !q.isEmpty else {
            return records.sorted { $0.lastSeen > $1.lastSeen }
        }

        let tokens = q
            .split(separator: " ")
            .map(String.init)
            .filter { !fillerWords.contains($0) }

        let scored = records.compactMap { record -> (AppMenuCapabilityRecord, Int)? in
            let title = record.normalizedTitle
            let path = record.normalizedPath
            let pathParts = record.path.map(Self.normalize).filter { !$0.isEmpty }
            let titleTokens = title.split(separator: " ").map(String.init)
            let pathTokens = pathParts.flatMap { $0.split(separator: " ").map(String.init) }
            var score = 0

            if title == q { score += 1_000 }
            if title.hasPrefix(q) { score += 760 }
            if title.contains(q) { score += 620 }
            if pathParts.contains(q) { score += 540 }
            if path.contains(q) { score += 360 }
            if orderedTokens(tokens, appearIn: titleTokens) { score += 520 + tokens.count * 80 }
            if orderedTokens(tokens, appearIn: pathTokens) { score += 320 + tokens.count * 52 }

            for token in tokens {
                if title == token { score += 160 }
                if title.hasPrefix(token) { score += 110 }
                if title.contains(token) { score += 84 }
                if pathTokens.contains(token) { score += 70 }
                if path.contains(token) { score += 34 }
            }
            if record.shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                score += 28
            }

            guard score > 0 else { return nil }
            return (record, score)
        }

        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.path.count != $1.0.path.count { return $0.0.path.count < $1.0.path.count }
            let lhsPath = $0.0.normalizedPath
            let rhsPath = $1.0.normalizedPath
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            return $0.0.lastSeen > $1.0.lastSeen
        }.map(\.0)
        }
    }

    nonisolated private func orderedTokens(_ needles: [String], appearIn haystack: [String]) -> Bool {
        guard !needles.isEmpty, !haystack.isEmpty else { return false }
        var searchStart = haystack.startIndex
        for needle in needles {
            guard let found = haystack[searchStart...].firstIndex(where: {
                $0 == needle || $0.hasPrefix(needle) || $0.contains(needle)
            }) else { return false }
            searchStart = haystack.index(after: found)
        }
        return true
    }

    nonisolated private var fillerWords: Set<String> {
        [
            "app", "application", "open", "show", "view", "use", "please", "the", "a", "an",
            "to", "in", "on", "for", "with", "using", "usage", "usages", "activity", "monitor"
        ]
    }

    nonisolated private func shouldPersistMenuCapability(
        title: String,
        path: [String],
        bundleIdentifier: String,
        resolvedFilePath: String? = nil
    ) -> Bool {
        let normalizedTitle = Self.normalize(title)
        let normalizedPath = path.map(Self.normalize)
        guard !normalizedTitle.isEmpty, !normalizedPath.isEmpty else { return false }
        let isBrowserHistoryOrBookmarks =
            isBrowserBundle(bundleIdentifier)
            && (normalizedPath.first == "history" || normalizedPath.first == "bookmarks")
        // Apple menu items are universal system actions, not per-app capabilities.
        // Keeping them in the per-app cache makes queries like "messages settings"
        // surface "Apple > System Settings..." instead of "Messages > Settings...".
        if normalizedPath.first == "apple" {
            return false
        }

        // Window menu is live app state: open documents, tabs, restored windows, and
        // workspace-specific entries. Persisting it creates confusing stale rows like
        // "Window > Applications" after the real window list changed.
        if normalizedPath.first == "window" {
            return false
        }

        // Services submenu is system-wide (identical entries in every app) and
        // selection-dependent — persisting it duplicates dozens of mostly-dead
        // actions into every app's snapshot. Context Dock reads Services live
        // from the frontmost app when a selection makes them relevant.
        if !Self.shouldExposeInGlobalContext(title: title, path: path) {
            return false
        }

        // Finder Quick Look rows are selection-specific ("Quick Look \"Pictures\"").
        // Persisting them creates stale cached results after Finder selection changes.
        if bundleIdentifier == "com.apple.finder",
            normalizedTitle.contains("quick look")
                || normalizedPath.contains(where: { $0.contains("quick look") })
        {
            return false
        }

        let privateDynamicBranches: Set<String> = [
            "open recent",
            "recent items",
            "recent documents",
            "recent projects",
            "recent files",
            "recently closed",
            "closed tabs",
            "closed windows"
        ]
        if normalizedPath.contains(where: { privateDynamicBranches.contains($0) })
            && !isBrowserHistoryOrBookmarks
        {
            return resolvedFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }

        if isBrowserHistoryOrBookmarks {
            return true
        }

        // Filter version-specific dynamic items that become stale after app updates
        let dynamicTitlePatterns = ["restart to update", "update to", "check for updates in progress"]
        if dynamicTitlePatterns.contains(where: { normalizedTitle.hasPrefix($0) }) {
            return false
        }

        return true
    }

    nonisolated private func resolvePersistentMenuFilePath(
        title: String,
        path: [String],
        bundleIdentifier: String
    ) -> String? {
        guard isDocumentLikeMenuPath(path, bundleIdentifier: bundleIdentifier) else { return nil }
        let cleaned = cleanCachedMenuFileTitle(title)
        guard cleaned.count >= 3 else { return nil }
        if let literalPath = resolveLiteralMenuFilePath(cleaned) {
            return literalPath
        }
        if let recentPath = resolveRecentDocumentMenuFilePath(cleaned) {
            return recentPath
        }
        return nil
    }

    nonisolated private func resolveRecentDocumentMenuFilePath(_ value: String) -> String? {
        let normalizedValue = Self.normalize(value)
        guard !normalizedValue.isEmpty else { return nil }

        for doc in RecentItemsService.shared.recentDocuments() {
            let names = [
                doc.url.lastPathComponent,
                doc.url.deletingPathExtension().lastPathComponent,
                doc.name
            ].map(Self.normalize)

            guard names.contains(normalizedValue),
                  FileManager.default.fileExists(atPath: doc.url.path)
            else { continue }
            return doc.url.path
        }
        return nil
    }

    nonisolated private func resolveLiteralMenuFilePath(_ value: String) -> String? {
        let candidates = literalMenuPathCandidates(value)
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private func literalMenuPathCandidates(_ value: String) -> [String] {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            raw.removeFirst()
            raw.removeLast()
        }
        guard raw.hasPrefix("/") || raw.hasPrefix("~/") else { return [] }

        var candidates: [String] = []
        let expanded = (raw as NSString).expandingTildeInPath
        candidates.append(expanded)

        // VS Code and several Electron apps append workspace/window labels after " - ".
        if raw.contains(" - ") {
            let prefix = raw.components(separatedBy: " - ").first ?? raw
            candidates.append((prefix as NSString).expandingTildeInPath)
        }

        return Array(Set(candidates)).filter { !$0.isEmpty }
    }

    nonisolated private func isDocumentLikeMenuPath(_ path: [String], bundleIdentifier: String) -> Bool {
        let normalizedPath = path.map(Self.normalize)
        if isBrowserBundle(bundleIdentifier),
           normalizedPath.first == "history" || normalizedPath.first == "bookmarks" {
            return false
        }
        let documentBranches: Set<String> = [
            "open recent",
            "recent items",
            "recent documents",
            "recent projects",
            "recent files",
            "documents"
        ]
        return normalizedPath.contains(where: { documentBranches.contains($0) })
    }

    nonisolated private func cleanCachedMenuFileTitle(_ title: String) -> String {
        var value = title
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: " (Edited)", with: "")
            .replacingOccurrences(of: " — Edited", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(" - ") {
            let ext = URL(fileURLWithPath: value).pathExtension
            if ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = value.components(separatedBy: " - ").first ?? value
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func isBrowserBundle(_ bundleIdentifier: String) -> Bool {
        let browserBundles: Set<String> = [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "org.mozilla.firefox"
        ]
        return browserBundles.contains(bundleIdentifier)
    }

    nonisolated private func maxRecords(for bundleIdentifier: String) -> Int {
        isBrowserBundle(bundleIdentifier) ? maxBrowserRecordsPerApp : maxRecordsPerApp
    }

    nonisolated private func sanitize(
        records: [AppMenuCapabilityRecord],
        bundleIdentifier: String
    ) -> [AppMenuCapabilityRecord] {
        records.filter {
            shouldPersistMenuCapability(
                title: $0.title,
                path: $0.path,
                bundleIdentifier: bundleIdentifier,
                resolvedFilePath: $0.resolvedFilePath
            )
        }
    }

    nonisolated private func bundleVersion(for app: NSRunningApplication) -> String {
        guard let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL) else { return "" }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? bundle.infoDictionary?["CFBundleVersion"] as? String
            ?? ""
    }

    nonisolated private func shortcutDisplay(char: String?, modifiers: Int) -> String? {
        MenuShortcutFormatter.display(char: char, modifiers: modifiers)
    }

    nonisolated private func loadFromDisk() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AppMenuCapabilitySnapshot].self, from: data)
        else { return }
        var sanitized = decoded
        var changed = false
        for (bundleIdentifier, snapshot) in decoded {
            let records = sanitize(records: snapshot.records, bundleIdentifier: bundleIdentifier)
            var copy = snapshot
            if records.count != snapshot.records.count {
                copy.records = records
                changed = true
            }
            copy.rebuildInvertedIndex()
            sanitized[bundleIdentifier] = copy
        }
        snapshots = sanitized
        menuItemsCache.removeAll(keepingCapacity: true)
        if changed {
            scheduleSaveToDisk()
        }
    }

    nonisolated private func scheduleSaveToDisk() {
        lock.lock()
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        lock.unlock()

        let workItem = DispatchWorkItem { [weak self] in
            self?.saveToDisk(ifGeneration: generation)
        }

        lock.lock()
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = workItem
        lock.unlock()

        persistenceQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    nonisolated private func saveToDisk(ifGeneration generation: Int) {
        guard let url = cacheURL else { return }

        lock.lock()
        guard persistenceGeneration == generation else {
            lock.unlock()
            return
        }
        let snapshotCopy = snapshots
        lock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshotCopy)
            try data.write(to: url, options: [.atomic])
        } catch {
            #if DEBUG
            Swift.print("AppMenuCapabilityCache save failed: \(error.localizedDescription)")
            #endif
        }
    }

    nonisolated private var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock", isDirectory: true)
            .appendingPathComponent("AppMenuCapabilities.json")
    }
}
