import AppKit
import Foundation

struct SafariRecentURL: Identifiable, Equatable {
    let title: String
    let url: URL
    let visitDate: Date?

    var id: String { url.absoluteString }

    var domain: String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Safari-style date bucket title for grouping in the dock.
    var dateGroupTitle: String { SafariRecentURLService.dateGroupTitle(for: visitDate) }
}

/// Cache-first Safari history reader — DoraX's small, continuously refreshed
/// history cache (Spotlight/Raycast style). Search rendering never runs
/// AppleScript or scans AX menus; refreshes happen off the main actor and update
/// visible results asynchronously. Execution always opens the cached URL in
/// Safari — never an AX click on the dynamic History submenu.
final class SafariRecentURLService: @unchecked Sendable {
    static let shared = SafariRecentURLService()

    private var cached: [SafariRecentURL] = []
    private var refreshedAt: Date = .distantPast
    private var isRefreshing = false
    private let freshness: TimeInterval = 60

    private init() {}

    // MARK: - Search (cache only)

    func entries(matching rawQuery: String, limit: Int = 14) -> [SafariRecentURL] {
        let query = normalized(rawQuery)
        let snapshot = cached

        if query.isEmpty || ["recent", "recents", "history", "url", "urls"].contains(query) {
            return Array(snapshot.prefix(limit))
        }
        return Array(snapshot.filter {
            normalized($0.title).contains(query)
                || normalized($0.url.absoluteString).contains(query)
                || normalized($0.domain).contains(query)
        }.prefix(limit))
    }

    /// Group entries into Safari-style date buckets, preserving recency order of
    /// the groups (Earlier Today → Today → Yesterday → dated).
    func groupBySafariStyleDate(_ entries: [SafariRecentURL]) -> [(title: String, items: [SafariRecentURL])] {
        var order: [String] = []
        var buckets: [String: [SafariRecentURL]] = [:]
        for entry in entries {
            let key = entry.dateGroupTitle
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Open a cached history URL in Safari. Never clicks the History submenu.
    @MainActor
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Refresh

    func refreshIfNeeded(completion: @escaping @MainActor () -> Void) {
        let needsRefresh = Date().timeIntervalSince(refreshedAt) >= freshness
        guard needsRefresh, !isRefreshing else { return }
        refreshRecent(completion: completion)
    }

    /// Force a background refresh of recent history (app launch / Safari activated).
    func refreshRecent(completion: @escaping @MainActor () -> Void) {
        guard !isRefreshing else { return }
        isRefreshing = true

        let refreshTask = Task.detached(priority: .userInitiated) {
            Self.readSafariHistory(limit: 80)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let entries = await refreshTask.value
            if !entries.isEmpty {
                cached = entries
                refreshedAt = Date()
            }
            isRefreshing = false
            completion()
        }
    }

    func quickLookURL(for entry: SafariRecentURL) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Context-Dock/Safari History", isDirectory: true)
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

    // MARK: - Date grouping

    /// Safari-style bucket: "Earlier Today", "Today", "Yesterday", or
    /// "Wednesday, 24 June 2026". Falls back to "Safari History" when no date.
    static func dateGroupTitle(for date: Date?) -> String {
        guard let date else { return "Safari History" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            // Within the last ~3 hours reads as "Earlier Today" in Safari's grouping.
            if Date().timeIntervalSince(date) < 3 * 3600 { return "Earlier Today" }
            return "Today"
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = .autoupdatingCurrent
        fmt.dateFormat = "EEEE, d MMMM yyyy"
        return fmt.string(from: date)
    }

    // MARK: - AppleScript reader (fallback source; execution still opens URL)

    nonisolated private static func readSafariHistory(limit: Int) -> [SafariRecentURL] {
        // Visit date emitted as epoch seconds (locale-independent) for reliable parsing.
        let script = """
        tell application "Safari"
            set epoch to (current date) - (do shell script "date +%s") as integer
            set historyItems to history items
            set output to {}
            set itemCount to 0
            repeat with historyItem in historyItems
                if itemCount >= \(limit) then exit repeat
                try
                    set vd to (visit date of historyItem)
                    set secs to (vd - epoch)
                    set end of output to (name of historyItem) & "|||" & (URL of historyItem) & "|||" & (secs as integer)
                    set itemCount to itemCount + 1
                end try
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script),
            let output = appleScript.executeAndReturnError(&error).stringValue
        else { return [] }

        var seen = Set<String>()
        return output.components(separatedBy: ", ").compactMap { raw in
            let parts = raw.components(separatedBy: "|||")
            guard parts.count >= 2,
                let url = URL(string: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                seen.insert(url.absoluteString).inserted
            else { return nil }
            var visit: Date?
            if parts.count >= 3,
                let secs = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) {
                visit = Date(timeIntervalSince1970: secs)
            }
            return SafariRecentURL(
                title: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                url: url,
                visitDate: visit)
        }
    }

    nonisolated private func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
