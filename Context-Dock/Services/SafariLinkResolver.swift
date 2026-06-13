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

    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var titleToURL: [String: URL] = [:]
    nonisolated(unsafe) private var loadStartedAt: Date = .distantPast
    nonisolated(unsafe) private var isLoading = false

    /// Dictionary lookup only — never blocks. Kicks an async warm when stale.
    nonisolated func url(forTitle title: String) -> URL? {
        warmIfNeeded()
        let key = Self.normalizeTitle(title)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return titleToURL[key]
    }

    nonisolated private func finishLoad(_ mapping: [String: URL]) {
        lock.lock()
        if !mapping.isEmpty {
            titleToURL = mapping
        }
        isLoading = false
        lock.unlock()
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
            let mapping = Self.loadHistoryTitleMap()
            SafariLinkResolver.shared.finishLoad(mapping)
        }
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
