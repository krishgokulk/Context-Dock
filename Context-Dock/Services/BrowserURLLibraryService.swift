import AppKit
import Foundation
import SQLite3

struct BrowserURLLibraryEntry: Identifiable, Equatable {
    enum Kind: String {
        case history = "History"
        case bookmark = "Bookmark"
    }

    let title: String
    let url: URL
    let visitDate: Date?
    let kind: Kind
    let browserName: String
    let browserBundleId: String

    var id: String { "\(browserBundleId):\(kind.rawValue):\(url.absoluteString)" }

    var domain: String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var dateGroupTitle: String {
        switch kind {
        case .bookmark:
            return "\(browserName) Bookmarks"
        case .history:
            return BrowserURLLibraryService.dateGroupTitle(for: visitDate)
        }
    }
}

final class BrowserURLLibraryService: @unchecked Sendable {
    static let shared = BrowserURLLibraryService()

    private struct BrowserProfile {
        let appName: String
        let bundleId: String
        let historyPath: String?
        let bookmarksPath: String?
        let family: Family

        enum Family { case safari, chromium, firefox }
    }

    private var cached: [BrowserURLLibraryEntry] = []
    private var refreshedAt: Date = .distantPast
    private var isRefreshing = false
    private let freshness: TimeInterval = 60

    private init() {}

    func entries(
        matching rawQuery: String,
        bundleId: String? = nil,
        limit: Int = 24
    ) -> [BrowserURLLibraryEntry] {
        let query = normalized(rawQuery)
        let sourceFiltered = cached.filter { entry in
            guard let bundleId, !bundleId.isEmpty else { return true }
            return entry.browserBundleId.caseInsensitiveCompare(bundleId) == .orderedSame
        }
        let snapshot = sourceFiltered.sorted(by: Self.entrySort)

        if query.isEmpty || ["recent", "recents", "history", "url", "urls", "bookmark", "bookmarks"].contains(query) {
            return Array(snapshot.prefix(limit))
        }
        return Array(snapshot.filter {
            normalized($0.title).contains(query)
                || normalized($0.url.absoluteString).contains(query)
                || normalized($0.domain).contains(query)
                || normalized($0.kind.rawValue).contains(query)
                || normalized($0.browserName).contains(query)
        }.prefix(limit))
    }

    @MainActor
    func open(_ entry: BrowserURLLibraryEntry) {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: entry.browserBundleId)
        {
            NSWorkspace.shared.open(
                [entry.url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func refreshIfNeeded(completion: @escaping @MainActor () -> Void) {
        let needsRefresh = Date().timeIntervalSince(refreshedAt) >= freshness
        guard needsRefresh else {
            Task { @MainActor in completion() }
            return
        }
        guard !isRefreshing else {
            Task { @MainActor in completion() }
            return
        }
        refresh(completion: completion)
    }

    /// Chat-safe cache read. Refreshes the same URL library used by Context Dock rows,
    /// then returns structured local entries without involving an AI provider.
    @MainActor
    func refreshedEntries(
        matching query: String,
        bundleId: String? = nil,
        limit: Int = 24
    ) async -> [BrowserURLLibraryEntry] {
        if isRefreshing {
            for _ in 0..<20 where isRefreshing {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } else if Date().timeIntervalSince(refreshedAt) >= freshness {
            await withCheckedContinuation { continuation in
                refresh { continuation.resume() }
            }
        }
        return entries(matching: query, bundleId: bundleId, limit: limit)
    }

    func refresh(completion: @escaping @MainActor () -> Void) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let task = Task.detached(priority: .utility) { Self.readAll(limitPerProfile: 1200) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let entries = await task.value
            if !entries.isEmpty {
                cached = entries
                refreshedAt = Date()
            }
            isRefreshing = false
            completion()
        }
    }

    func quickLookURL(for entry: BrowserURLLibraryEntry) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Context-Dock/Browser URLs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let digest = String(entry.url.absoluteString.hashValue, radix: 16)
            let file = directory.appendingPathComponent("\(digest).webloc")
            if !FileManager.default.fileExists(atPath: file.path) {
                let payload = ["URL": entry.url.absoluteString]
                let data = try PropertyListSerialization.data(
                    fromPropertyList: payload, format: .xml, options: 0)
                try data.write(to: file, options: .atomic)
            }
            return file
        } catch {
            return nil
        }
    }

    static func dateGroupTitle(for date: Date?) -> String {
        guard let date else { return "Browser History" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            if Date().timeIntervalSince(date) < 3 * 3600 { return "Earlier Today" }
            return "Today"
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = .autoupdatingCurrent
        fmt.dateFormat = "EEEE, d MMMM yyyy"
        return fmt.string(from: date)
    }

    nonisolated private static func entrySort(
        _ lhs: BrowserURLLibraryEntry,
        _ rhs: BrowserURLLibraryEntry
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .history
        }
        return (lhs.visitDate ?? .distantPast) > (rhs.visitDate ?? .distantPast)
    }

    nonisolated private static func readAll(limitPerProfile: Int) -> [BrowserURLLibraryEntry] {
        var entries: [BrowserURLLibraryEntry] = []
        for profile in browserProfiles() {
            switch profile.family {
            case .safari:
                entries += readSafariHistory(profile: profile, limit: limitPerProfile)
                entries += readSafariBookmarks(profile: profile)
            case .chromium:
                entries += readChromiumHistory(profile: profile, limit: limitPerProfile)
                entries += readChromiumBookmarks(profile: profile)
            case .firefox:
                entries += readFirefoxHistory(profile: profile, limit: limitPerProfile)
                entries += readFirefoxBookmarks(profile: profile, limit: limitPerProfile)
            }
        }

        var seen = Set<String>()
        return entries.sorted(by: entrySort).filter { entry in
            let key = "\(entry.browserBundleId):\(entry.kind.rawValue):\(entry.url.absoluteString)"
            return seen.insert(key).inserted
        }
    }

    nonisolated private static func browserProfiles() -> [BrowserProfile] {
        let home = NSHomeDirectory()
        let appSupport = home + "/Library/Application Support/"
        let fm = FileManager.default
        var profiles: [BrowserProfile] = [
            BrowserProfile(
                appName: "Safari",
                bundleId: "com.apple.Safari",
                historyPath: home + "/Library/Safari/History.db",
                bookmarksPath: home + "/Library/Safari/Bookmarks.plist",
                family: .safari)
        ]

        let chromiumRoots: [(String, String, String)] = [
            ("Google/Chrome", "Google Chrome", "com.google.Chrome"),
            ("Google/Chrome Beta", "Google Chrome Beta", "com.google.Chrome.beta"),
            ("Google/Chrome Canary", "Google Chrome Canary", "com.google.Chrome.canary"),
            ("Chromium", "Chromium", "org.chromium.Chromium"),
            ("Microsoft Edge", "Microsoft Edge", "com.microsoft.edgemac"),
            ("BraveSoftware/Brave-Browser", "Brave", "com.brave.Browser"),
            ("Arc/User Data", "Arc", "company.thebrowser.Browser"),
            ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi"),
        ]
        for (root, name, bundle) in chromiumRoots {
            let rootPath = appSupport + root
            let profileNames = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
            let candidates = Set(["Default"] + profileNames.filter { $0.hasPrefix("Profile") })
            for profileName in candidates {
                let history = "\(rootPath)/\(profileName)/History"
                let bookmarks = "\(rootPath)/\(profileName)/Bookmarks"
                guard fm.fileExists(atPath: history) || fm.fileExists(atPath: bookmarks) else {
                    continue
                }
                profiles.append(
                    BrowserProfile(
                        appName: name,
                        bundleId: bundle,
                        historyPath: history,
                        bookmarksPath: bookmarks,
                        family: .chromium))
            }
        }

        let firefoxRoots: [(String, String, String)] = [
            ("Firefox/Profiles", "Firefox", "org.mozilla.firefox"),
            ("zen/Profiles", "Zen", "app.zen-browser.zen"),
        ]
        for (root, name, bundle) in firefoxRoots {
            let rootPath = appSupport + root
            let profileNames = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
            for profileName in profileNames {
                let places = "\(rootPath)/\(profileName)/places.sqlite"
                guard fm.fileExists(atPath: places) else { continue }
                profiles.append(
                    BrowserProfile(
                        appName: name,
                        bundleId: bundle,
                        historyPath: places,
                        bookmarksPath: places,
                        family: .firefox))
            }
        }
        return profiles
    }

    nonisolated private static func readSafariHistory(
        profile: BrowserProfile,
        limit: Int
    ) -> [BrowserURLLibraryEntry] {
        guard let path = profile.historyPath else { return [] }
        let sql = """
            SELECT items.url, visits.title, visits.visit_time
            FROM history_visits visits
            JOIN history_items items ON visits.history_item = items.id
            WHERE visits.title IS NOT NULL AND visits.title != ''
            ORDER BY visits.visit_time DESC
            LIMIT \(limit)
            """
        let rows = loadSQLiteRows(path: path, sql: sql)
        return rows.compactMap { row in
            guard let visitRaw = row.dateValue else { return nil }
            return makeEntry(
                title: row.title, urlString: row.url,
                date: Date(timeIntervalSinceReferenceDate: visitRaw),
                kind: .history, profile: profile)
        }
    }

    nonisolated private static func readSafariBookmarks(profile: BrowserProfile)
        -> [BrowserURLLibraryEntry]
    {
        guard let path = profile.bookmarksPath,
            let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return [] }

        var entries: [BrowserURLLibraryEntry] = []
        scanSafariBookmarkNode(plist, profile: profile, entries: &entries)
        return entries
    }

    nonisolated private static func scanSafariBookmarkNode(
        _ node: [String: Any],
        profile: BrowserProfile,
        entries: inout [BrowserURLLibraryEntry]
    ) {
        if let urlString = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                ?? node["Title"] as? String
                ?? urlString
            if let entry = makeEntry(
                title: title,
                urlString: urlString,
                date: nil,
                kind: .bookmark,
                profile: profile)
            {
                entries.append(entry)
            }
        }
        for child in (node["Children"] as? [[String: Any]]) ?? [] {
            scanSafariBookmarkNode(child, profile: profile, entries: &entries)
        }
    }

    nonisolated private static func readChromiumHistory(
        profile: BrowserProfile,
        limit: Int
    ) -> [BrowserURLLibraryEntry] {
        guard let path = profile.historyPath else { return [] }
        let sql = """
            SELECT url, title, last_visit_time FROM urls
            WHERE title IS NOT NULL AND title != ''
            ORDER BY last_visit_time DESC LIMIT \(limit)
            """
        return loadSQLiteRows(path: path, sql: sql).compactMap { row in
            makeEntry(
                title: row.title, urlString: row.url,
                date: chromiumDate(row.dateValue),
                kind: .history, profile: profile)
        }
    }

    nonisolated private static func readChromiumBookmarks(profile: BrowserProfile)
        -> [BrowserURLLibraryEntry]
    {
        guard let path = profile.bookmarksPath,
            let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let roots = object["roots"] as? [String: Any]
        else { return [] }

        var entries: [BrowserURLLibraryEntry] = []
        for value in roots.values {
            if let node = value as? [String: Any] {
                scanChromiumBookmarkNode(node, profile: profile, entries: &entries)
            }
        }
        return entries
    }

    nonisolated private static func scanChromiumBookmarkNode(
        _ node: [String: Any],
        profile: BrowserProfile,
        entries: inout [BrowserURLLibraryEntry]
    ) {
        if let urlString = node["url"] as? String {
            let title = node["name"] as? String ?? urlString
            let date = chromiumDate(Double(node["date_added"] as? String ?? ""))
            if let entry = makeEntry(
                title: title,
                urlString: urlString,
                date: date,
                kind: .bookmark,
                profile: profile)
            {
                entries.append(entry)
            }
        }
        for child in (node["children"] as? [[String: Any]]) ?? [] {
            scanChromiumBookmarkNode(child, profile: profile, entries: &entries)
        }
    }

    nonisolated private static func readFirefoxHistory(
        profile: BrowserProfile,
        limit: Int
    ) -> [BrowserURLLibraryEntry] {
        guard let path = profile.historyPath else { return [] }
        let sql = """
            SELECT url, title, last_visit_date FROM moz_places
            WHERE title IS NOT NULL AND title != ''
            ORDER BY last_visit_date DESC LIMIT \(limit)
            """
        return loadSQLiteRows(path: path, sql: sql).compactMap { row in
            makeEntry(
                title: row.title, urlString: row.url,
                date: unixMicrosecondsDate(row.dateValue),
                kind: .history, profile: profile)
        }
    }

    nonisolated private static func readFirefoxBookmarks(
        profile: BrowserProfile,
        limit: Int
    ) -> [BrowserURLLibraryEntry] {
        guard let path = profile.bookmarksPath else { return [] }
        let sql = """
            SELECT places.url, bookmarks.title, bookmarks.dateAdded
            FROM moz_bookmarks bookmarks
            JOIN moz_places places ON bookmarks.fk = places.id
            WHERE bookmarks.title IS NOT NULL AND bookmarks.title != ''
            ORDER BY bookmarks.dateAdded DESC LIMIT \(limit)
            """
        return loadSQLiteRows(path: path, sql: sql).compactMap { row in
            makeEntry(
                title: row.title, urlString: row.url,
                date: unixMicrosecondsDate(row.dateValue),
                kind: .bookmark, profile: profile)
        }
    }

    private struct SQLiteRow {
        let url: String
        let title: String
        let dateValue: Double?
    }

    nonisolated private static func loadSQLiteRows(path: String, sql: String) -> [SQLiteRow] {
        guard FileManager.default.fileExists(atPath: path),
            var components = URLComponents(
                url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        else { return [] }
        components.scheme = "file"
        components.queryItems = [
            URLQueryItem(name: "immutable", value: "1"),
            URLQueryItem(name: "mode", value: "ro"),
        ]
        guard let uri = components.url?.absoluteString else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
            let db
        else { return [] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [SQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0),
                let titleText = sqlite3_column_text(statement, 1)
            else { continue }
            var dateValue: Double?
            if sqlite3_column_count(statement) > 2,
                sqlite3_column_type(statement, 2) != SQLITE_NULL
            {
                dateValue = sqlite3_column_double(statement, 2)
            }
            rows.append(
                SQLiteRow(
                    url: String(cString: urlText),
                    title: String(cString: titleText),
                    dateValue: dateValue))
        }
        return rows
    }

    nonisolated private static func makeEntry(
        title: String,
        urlString: String,
        date: Date?,
        kind: BrowserURLLibraryEntry.Kind,
        profile: BrowserProfile
    ) -> BrowserURLLibraryEntry? {
        guard let url = URL(string: urlString),
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return BrowserURLLibraryEntry(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url,
            visitDate: date,
            kind: kind,
            browserName: profile.appName,
            browserBundleId: profile.bundleId)
    }

    nonisolated private static func chromiumDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: (raw / 1_000_000) - 11_644_473_600)
    }

    nonisolated private static func unixMicrosecondsDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw / 1_000_000)
    }

    nonisolated private func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
