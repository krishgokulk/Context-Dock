import AppKit
import Foundation

struct AppMenuCapabilityRecord: Codable, Hashable {
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

    nonisolated var pathString: String { path.joined(separator: " > ") }
    nonisolated var normalizedPath: String { AppMenuCapabilityCache.normalize(pathString) }
    nonisolated var normalizedTitle: String { AppMenuCapabilityCache.normalize(title) }
}

struct AppMenuCapabilitySummary: Identifiable, Hashable {
    let bundleIdentifier: String
    let appName: String
    let updatedAt: Date
    let recordCount: Int
    let samplePaths: [String]

    var id: String { bundleIdentifier }
}

private struct AppMenuCapabilitySnapshot: Codable {
    var bundleIdentifier: String
    var appName: String
    var bundleVersion: String
    var localeIdentifier: String
    var updatedAt: Date
    var records: [AppMenuCapabilityRecord]
}

final class AppMenuCapabilityCache {
    nonisolated static let shared = AppMenuCapabilityCache()

    private struct MenuItemsCacheKey: Hashable {
        let bundleIdentifier: String
        let appName: String
        let processIdentifier: pid_t
        let query: String
        let maxResults: Int
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var snapshots: [String: AppMenuCapabilitySnapshot] = [:]
    nonisolated(unsafe) private var menuItemsCache: [MenuItemsCacheKey: [AXMenuItem]] = [:]
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
            guard shouldPersistMenuCapability(
                title: title,
                path: path,
                bundleIdentifier: bundleIdentifier
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
                isEnabled: true  // Don't persist live AX state — enabled depends on runtime context
            )
        }

        guard !records.isEmpty else { return }

        lock.lock()
        let existingRecords = snapshots[bundleIdentifier]?.records ?? []
        var mergedByPath = [String: AppMenuCapabilityRecord]()
        for record in existingRecords {
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

        let snapshot = AppMenuCapabilitySnapshot(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            bundleVersion: bundleVersion,
            localeIdentifier: localeIdentifier,
            updatedAt: now,
            records: Array(mergedRecords.prefix(maxRecords(for: bundleIdentifier)))
        )

        snapshots[bundleIdentifier] = snapshot
        menuItemsCache = menuItemsCache.filter { $0.key.bundleIdentifier != bundleIdentifier }
        lock.unlock()

        saveToDisk()
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
        let records = snapshots[bundleIdentifier]?.records ?? []
        lock.unlock()

        guard !records.isEmpty else { return [] }

        let ranked = rankedRecords(records, normalizedQuery: normalizedQuery)
        // Cached capability entries are passive metadata for ranking/display.
        // Do not attach a live per-app AX element or consult live AX state here,
        // because this path is called from UI rendering and startup code.
        let placeholderElement = AXUIElementCreateSystemWide()

        let items = ranked.prefix(maxResults).map { record in
            let isAppleMenu = record.isAppleMenu || Self.normalize(record.path.first ?? "") == "apple"
            return AXMenuItem(
                title: record.title,
                path: record.path,
                isEnabled: record.isEnabled,
                element: placeholderElement,
                children: [],
                sourcePID: processIdentifier,
                sourceAppName: appName,
                isAppleMenu: isAppleMenu,
                shortcutChar: record.shortcutChar,
                shortcutModifiers: record.shortcutModifiers
            )
        }

        lock.lock()
        if menuItemsCache.count > maxMenuItemsCacheEntries {
            menuItemsCache.removeAll(keepingCapacity: true)
        }
        menuItemsCache[cacheKey] = items
        lock.unlock()

        return items
    }

    nonisolated func record(path: [String], bundleIdentifier: String) -> AppMenuCapabilityRecord? {
        lock.lock()
        let records = snapshots[bundleIdentifier]?.records ?? []
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

    nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            var score = 0

            if title == q { score += 100 }
            if title.hasPrefix(q) { score += 75 }
            if title.contains(q) { score += 55 }
            if path.contains(q) { score += 35 }

            for token in tokens {
                if title == token { score += 40 }
                if title.hasPrefix(token) { score += 28 }
                if title.contains(token) { score += 18 }
                if path.contains(token) { score += 10 }
            }

            guard score > 0 else { return nil }
            return (record, score)
        }

        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.path.count != $1.0.path.count { return $0.0.path.count < $1.0.path.count }
            return $0.0.lastSeen > $1.0.lastSeen
        }.map(\.0)
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
        bundleIdentifier: String
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
            return false
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
                bundleIdentifier: bundleIdentifier
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
        guard let ch = char?.uppercased(), !ch.isEmpty else { return nil }
        var output = ""
        if modifiers & 4 != 0 { output += "⌃" }
        if modifiers & 2 != 0 { output += "⌥" }
        if modifiers & 1 != 0 { output += "⇧" }
        output += "⌘\(ch)"
        return output
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
            if records.count != snapshot.records.count {
                var copy = snapshot
                copy.records = records
                sanitized[bundleIdentifier] = copy
                changed = true
            }
        }
        snapshots = sanitized
        menuItemsCache.removeAll(keepingCapacity: true)
        if changed {
            saveToDisk()
        }
    }

    nonisolated private func saveToDisk() {
        guard let url = cacheURL else { return }

        lock.lock()
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
            print("AppMenuCapabilityCache save failed: \(error.localizedDescription)")
            #endif
        }
    }

    nonisolated private var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock", isDirectory: true)
            .appendingPathComponent("AppMenuCapabilities.json")
    }
}
