// SafariLinkResolver.swift
// Context-Dock
//
// Turns Safari History/Bookmarks/Recently-Closed menu titles into real URLs,
// and caches page favicons so browser rows render like true links.
//
// Why History.db and not the web extension: Safari extensions have no
// recently-closed-tabs API, but every recently closed page is in history.
// The database is opened read-only with immutable=1 (safe while Safari holds
// its own locks) and loaded off the main thread; until the map is warm,
// callers fall back to the regular menu-click path.

import AppKit
import Combine
import Foundation
import SQLite3

final class SafariLinkResolver {
    nonisolated static let shared = SafariLinkResolver()
    nonisolated private init() {}

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var titleToURL: [String: URL] = [:]
    nonisolated(unsafe) private var loadStartedAt: Date = .distantPast
    nonisolated(unsafe) private var isLoading = false

    // App Group store shared with the Safari Web Extension. Every page the user
    // visits while the extension is enabled lands here as title→url — a no-Full-
    // Disk-Access source that complements (and works without) History.db.
    nonisolated private static let appGroupSuite = "group.com.krishgokul.ContextDock"
    nonisolated private static let extMapKey = "safariExtension.titleURLMap"

    /// Dictionary lookup only — never blocks. Kicks an async warm when stale.
    nonisolated func url(forTitle title: String) -> URL? {
        warmIfNeeded()
        let key = Self.normalizeTitle(title)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return titleToURL[key]
    }

    /// Record a title→URL pair learned live from the Safari Web Extension (no Full
    /// Disk Access). Updates the in-memory map instantly and persists to the App
    /// Group so it survives relaunch and warms before History.db is ever read.
    nonisolated func record(title: String, url: URL) {
        let key = Self.normalizeTitle(title)
        guard !key.isEmpty, url.scheme == "https" || url.scheme == "http" else { return }
        lock.lock()
        titleToURL[key] = url
        lock.unlock()
        Self.persistExtensionEntry(key: key, url: url)
    }

    nonisolated private func finishLoad(_ mapping: [String: URL]) {
        lock.lock()
        // Merge (don't replace) so live extension records added during the async
        // load aren't wiped; History.db / ext-map entries fill in everything else.
        for (k, v) in mapping { titleToURL[k] = v }
        isLoading = false
        lock.unlock()
    }

    nonisolated private static func persistExtensionEntry(key: String, url: URL) {
        guard let defaults = UserDefaults(suiteName: appGroupSuite) else { return }
        var map = defaults.dictionary(forKey: extMapKey) as? [String: String] ?? [:]
        if map[key] == url.absoluteString { return }
        map[key] = url.absoluteString
        if map.count > 3000 {
            for k in map.keys.prefix(map.count - 3000) { map.removeValue(forKey: k) }
        }
        defaults.set(map, forKey: extMapKey)
    }

    nonisolated private static func loadExtensionTitleMap() -> [String: URL] {
        guard let defaults = UserDefaults(suiteName: appGroupSuite),
            let raw = defaults.dictionary(forKey: extMapKey) as? [String: String]
        else { return [:] }
        var out: [String: URL] = [:]
        for (k, v) in raw where !k.isEmpty {
            if let u = URL(string: v), u.scheme == "https" || u.scheme == "http" {
                out[k] = u
            }
        }
        return out
    }

    nonisolated func warmIfNeeded(maxAge: TimeInterval = 300) {
        lock.lock()
        let shouldLoad = !isLoading && Date().timeIntervalSince(loadStartedAt) > maxAge
        if shouldLoad {
            isLoading = true
            loadStartedAt = Date()
        }
        lock.unlock()
        guard shouldLoad else { return }

        Task.detached(priority: .utility) {
            // Merge every available source. None of these need Full Disk Access except
            // Safari's History.db — Chromium/Firefox history live in the user's own
            // Library and are readable directly (this app is not sandboxed).
            var mapping = Self.loadExtensionTitleMap()
            for (k, v) in Self.loadChromiumTitleMap() where mapping[k] == nil { mapping[k] = v }
            for (k, v) in Self.loadFirefoxTitleMap() where mapping[k] == nil { mapping[k] = v }
            for (k, v) in Self.loadHistoryTitleMap() { mapping[k] = v }  // Safari (FDA) overrides
            SafariLinkResolver.shared.finishLoad(mapping)
        }
    }

    // MARK: - Multi-browser history (no Full Disk Access)

    /// Chromium-family history: Chrome, Edge, Brave, Arc, Vivaldi, Chromium. Each
    /// `History` SQLite has a `urls(url, title, last_visit_time)` table.
    nonisolated private static func loadChromiumTitleMap() -> [String: URL] {
        let sql = """
            SELECT url, title FROM urls
            WHERE title IS NOT NULL AND title != ''
            ORDER BY last_visit_time DESC LIMIT 4000
            """
        var mapping: [String: URL] = [:]
        for path in chromiumHistoryPaths() {
            for (k, v) in loadSQLiteTitleMap(path: path, sql: sql) where mapping[k] == nil {
                mapping[k] = v
            }
        }
        return mapping
    }

    /// Firefox-family history: Firefox, Zen. `places.sqlite` has a
    /// `moz_places(url, title, last_visit_date)` table.
    nonisolated private static func loadFirefoxTitleMap() -> [String: URL] {
        let sql = """
            SELECT url, title FROM moz_places
            WHERE title IS NOT NULL AND title != ''
            ORDER BY last_visit_date DESC LIMIT 4000
            """
        var mapping: [String: URL] = [:]
        for path in firefoxPlacesPaths() {
            for (k, v) in loadSQLiteTitleMap(path: path, sql: sql) where mapping[k] == nil {
                mapping[k] = v
            }
        }
        return mapping
    }

    nonisolated private static func chromiumHistoryPaths() -> [String] {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        let roots = [
            "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
            "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Vivaldi",
        ]
        let fm = FileManager.default
        var paths: [String] = []
        for root in roots {
            let rootPath = base + root
            let profiles = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
            let candidates = Set(["Default"] + profiles.filter { $0.hasPrefix("Profile") })
            for profile in candidates {
                let historyPath = "\(rootPath)/\(profile)/History"
                if fm.fileExists(atPath: historyPath) { paths.append(historyPath) }
            }
        }
        return paths
    }

    nonisolated private static func firefoxPlacesPaths() -> [String] {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        let roots = ["Firefox/Profiles", "zen/Profiles"]
        let fm = FileManager.default
        var paths: [String] = []
        for root in roots {
            let rootPath = base + root
            let profiles = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
            for profile in profiles {
                let placesPath = "\(rootPath)/\(profile)/places.sqlite"
                if fm.fileExists(atPath: placesPath) { paths.append(placesPath) }
            }
        }
        return paths
    }

    /// Generic read-only title→URL loader for a SQLite DB whose query yields
    /// (url, title) rows. Opens immutable so it is safe while the browser holds locks.
    nonisolated private static func loadSQLiteTitleMap(path: String, sql: String) -> [String: URL] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard
            var components = URLComponents(
                url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        else { return [:] }
        components.scheme = "file"
        components.queryItems = [
            URLQueryItem(name: "immutable", value: "1"),
            URLQueryItem(name: "mode", value: "ro"),
        ]
        guard let uri = components.url?.absoluteString else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
            let db
        else { return [:] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var mapping: [String: URL] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let urlText = sqlite3_column_text(statement, 0),
                let titleText = sqlite3_column_text(statement, 1)
            else { continue }
            let key = normalizeTitle(String(cString: titleText))
            guard !key.isEmpty, mapping[key] == nil,
                let url = URL(string: String(cString: urlText)),
                url.scheme == "https" || url.scheme == "http"
            else { continue }
            mapping[key] = url
        }
        return mapping
    }

    nonisolated private static func normalizeTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Most-recent-first title → URL map from Safari history. Returns empty
    /// without Full Disk Access — callers keep their menu-click fallback.
    nonisolated private static func loadHistoryTitleMap() -> [String: URL] {
        let path = NSHomeDirectory() + "/Library/Safari/History.db"
        guard FileManager.default.fileExists(atPath: path) else { return [:] }

        guard
            var components = URLComponents(
                url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        else { return [:] }
        components.scheme = "file"
        components.queryItems = [
            URLQueryItem(name: "immutable", value: "1"),
            URLQueryItem(name: "mode", value: "ro"),
        ]
        guard let uri = components.url?.absoluteString else { return [:] }

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, openFlags, nil) == SQLITE_OK, let db else {
            return [:]
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT items.url, visits.title
            FROM history_visits visits
            JOIN history_items items ON visits.history_item = items.id
            WHERE visits.title IS NOT NULL AND visits.title != ''
            ORDER BY visits.visit_time DESC
            LIMIT 4000
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var mapping: [String: URL] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let urlText = sqlite3_column_text(statement, 0),
                let titleText = sqlite3_column_text(statement, 1)
            else { continue }
            let key = normalizeTitle(String(cString: titleText))
            guard !key.isEmpty, mapping[key] == nil,
                let url = URL(string: String(cString: urlText)),
                url.scheme == "https" || url.scheme == "http"
            else { continue }
            mapping[key] = url
        }
        return mapping
    }
}

// MARK: - Favicons

@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    private init() {}

    /// Bumped when a new favicon lands so visible lists can repaint.
    @Published private(set) var revision = 0

    private var icons: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    private var failed: Set<String> = []

    func icon(for url: URL) -> NSImage? {
        url.host.flatMap { icons[$0] }
    }

    func fetchIfNeeded(for url: URL) {
        guard let host = url.host,
            icons[host] == nil,
            !failed.contains(host),
            inflight.insert(host).inserted
        else { return }

        Task.detached(priority: .utility) {
            let image = await Self.loadFavicon(host: host)
            await MainActor.run {
                let store = FaviconStore.shared
                store.inflight.remove(host)
                if let image {
                    store.icons[host] = image
                    store.revision &+= 1
                } else {
                    store.failed.insert(host)
                }
            }
        }
    }

    nonisolated private static func loadFavicon(host: String) async -> NSImage? {
        let candidates = [
            "https://\(host)/favicon.ico",
            "https://www.google.com/s2/favicons?sz=64&domain=\(host)",
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            guard
                let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                !data.isEmpty,
                let image = NSImage(data: data),
                image.isValid
            else { continue }
            image.size = NSSize(width: 28, height: 28)
            return image
        }
        return nil
    }
}
