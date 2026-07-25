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

        enum Family { case safari, chromium, firefox, coreData }
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

        // Token match, not literal-phrase match. "github page" was matched as one
        // substring — no URL/title contains "github page", so real github visits were
        // missed. Split into tokens (≥3 chars), match any, and rank by how many tokens
        // an entry hits so the strongest match floats up.
        let tokens = query.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !tokens.isEmpty else {
            return Array(
                snapshot.filter {
                    normalized($0.title).contains(query)
                        || normalized($0.url.absoluteString).contains(query)
                        || normalized($0.domain).contains(query)
                }.prefix(limit))
        }
        struct Match { let entry: BrowserURLLibraryEntry; let score: Int; let order: Int }
        var matches: [Match] = []
        for (index, entry) in snapshot.enumerated() {
            let hay = normalized(entry.title) + " " + normalized(entry.url.absoluteString)
                + " " + normalized(entry.domain)
            var score = 0
            for token in tokens where hay.contains(token) { score += 1 }
            if score > 0 { matches.append(Match(entry: entry, score: score, order: index)) }
        }
        // More matching tokens first; original (date-sorted) order within a score.
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return matches.prefix(limit).map(\.entry)
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
        // Callers use completion to rebuild their index after new data arrives. Calling it
        // for an already-fresh cache recursively schedules another rebuild, because those
        // rebuilds call refreshIfNeeded again.
        guard needsRefresh, !isRefreshing else { return }
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
        if !isRefreshing, Date().timeIntervalSince(refreshedAt) >= freshness {
            refresh {}
        }

        // Browser databases can be locked or slow while their app is running. Chat must
        // never inherit that unbounded wait: use any cache produced within 1.5 seconds,
        // otherwise let the caller report that the local refresh is still in progress.
        for _ in 0..<30 where isRefreshing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return entries(matching: query, bundleId: bundleId, limit: limit)
    }

    @MainActor
    var refreshInProgress: Bool { isRefreshing }

    func refresh(completion: @escaping @MainActor () -> Void) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let task = Task.detached(priority: .utility) { Self.readAll(limitPerProfile: 1200) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let entries = await task.value
            if !entries.isEmpty {
                cached = entries
            }
            // Always advance the freshness stamp, even on an EMPTY read (no browser
            // history, locked DBs, or Full Disk Access not granted). Otherwise the
            // cache never counts as fresh, so every dock rebuild re-refreshes and the
            // completion reschedules another rebuild — an infinite ~100% CPU loop.
            refreshedAt = Date()
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
            case .coreData:
                entries += readCoreDataStore(
                    path: profile.historyPath, preferTable: "HISTORY",
                    requireDate: true, kind: .history, profile: profile, limit: limitPerProfile)
                entries += readCoreDataStore(
                    path: profile.bookmarksPath, preferTable: "BOOKMARK",
                    requireDate: false, kind: .bookmark, profile: profile, limit: 2000)
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

        // DuckDuckGo (macOS) is sandboxed and stores history/bookmarks as Core Data
        // SQLite inside its container. Column names differ from Chromium/Firefox, so
        // these are read by schema introspection (readCoreDataStore). Requires Full
        // Disk Access to read another app's container; fails to empty otherwise.
        let ddgSupport = home
            + "/Library/Containers/com.duckduckgo.macos.browser/Data/Library/Application Support/DuckDuckGo/"
        let ddgHistory = ddgSupport + "Database.sqlite"
        let ddgBookmarks = ddgSupport + "Bookmarks.sqlite"
        if fm.fileExists(atPath: ddgHistory) || fm.fileExists(atPath: ddgBookmarks) {
            profiles.append(
                BrowserProfile(
                    appName: "DuckDuckGo",
                    bundleId: "com.duckduckgo.macos.browser",
                    historyPath: fm.fileExists(atPath: ddgHistory) ? ddgHistory : nil,
                    bookmarksPath: fm.fileExists(atPath: ddgBookmarks) ? ddgBookmarks : nil,
                    family: .coreData))
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

    /// Read a Core Data SQLite store (e.g. DuckDuckGo) without knowing its exact
    /// schema. Introspects the Z* tables, picks the one whose columns look like a URL
    /// list (a *URL* column, a *TITLE* column, and — for history — a visit-date
    /// column), preferring a table named for the kind, then selects recent rows.
    nonisolated private static func readCoreDataStore(
        path: String?,
        preferTable: String,
        requireDate: Bool,
        kind: BrowserURLLibraryEntry.Kind,
        profile: BrowserProfile,
        limit: Int
    ) -> [BrowserURLLibraryEntry] {
        guard let path, FileManager.default.fileExists(atPath: path) else { return [] }
        let tables = sqliteTableNames(path: path).filter { $0.uppercased().hasPrefix("Z") }

        struct Candidate { let table: String; let url: String; let title: String; let date: String? }
        var best: Candidate?
        for table in tables {
            let cols = sqliteColumnNames(path: path, table: table)
            guard let urlCol = cols.first(where: { $0.uppercased().contains("URL") }) else { continue }
            guard let titleCol = cols.first(where: { $0.uppercased().contains("TITLE") }) else { continue }
            let dateCol =
                cols.first(where: { $0.uppercased().contains("LASTVISIT") })
                ?? cols.first(where: { let u = $0.uppercased(); return u.contains("VISIT") && u.contains("DATE") })
                ?? cols.first(where: { $0.uppercased().contains("VISIT") })
                ?? cols.first(where: { $0.uppercased().contains("DATE") })
            if requireDate && dateCol == nil { continue }
            let candidate = Candidate(table: table, url: urlCol, title: titleCol, date: dateCol)
            if best == nil { best = candidate }
            if table.uppercased().contains(preferTable) { best = candidate; break }
        }
        guard let b = best else { return [] }

        let dateSelect = b.date != nil ? ", \"\(b.date!)\"" : ", NULL"
        let orderBy = b.date != nil ? " ORDER BY \"\(b.date!)\" DESC" : ""
        let sql = """
            SELECT "\(b.url)", "\(b.title)"\(dateSelect)
            FROM "\(b.table)"
            WHERE "\(b.url)" IS NOT NULL AND "\(b.url)" != ''\(orderBy)
            LIMIT \(limit)
            """
        return loadSQLiteRows(path: path, sql: sql).compactMap { row in
            makeEntry(
                title: row.title.isEmpty ? row.url : row.title,
                urlString: row.url,
                date: coreDataDate(row.dateValue),
                kind: kind, profile: profile)
        }
    }

    /// Core Data timestamps are seconds since the reference date (2001-01-01).
    nonisolated private static func coreDataDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    nonisolated private static func sqliteTableNames(path: String) -> [String] {
        loadSQLiteScalarColumn(
            path: path,
            sql: "SELECT name FROM sqlite_master WHERE type='table'")
    }

    nonisolated private static func sqliteColumnNames(path: String, table: String) -> [String] {
        // PRAGMA table_info returns name in column index 1.
        loadSQLiteScalarColumn(
            path: path,
            sql: "SELECT name FROM pragma_table_info('\(table.replacingOccurrences(of: "'", with: "''"))')")
    }

    /// Open read-only and return the first text column of every row.
    nonisolated private static func loadSQLiteScalarColumn(path: String, sql: String) -> [String] {
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
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
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
