import AppKit
import Foundation

struct SafariRecentURL: Identifiable, Equatable {
    let title: String
    let url: URL

    var id: String { url.absoluteString }
}

/// Cache-first Safari history reader. Search rendering never runs AppleScript;
/// refreshes happen off the main actor and update visible results asynchronously.
final class SafariRecentURLService: @unchecked Sendable {
    static let shared = SafariRecentURLService()

    private var cached: [SafariRecentURL] = []
    private var refreshedAt: Date = .distantPast
    private var isRefreshing = false
    private let freshness: TimeInterval = 60

    private init() {}

    func entries(matching rawQuery: String, limit: Int = 14) -> [SafariRecentURL] {
        let query = normalized(rawQuery)
        let snapshot = cached

        if query.isEmpty || ["recent", "recents", "history", "url", "urls"].contains(query) {
            return Array(snapshot.prefix(limit))
        }
        return Array(snapshot.filter {
            normalized($0.title).contains(query)
                || normalized($0.url.absoluteString).contains(query)
        }.prefix(limit))
    }

    func refreshIfNeeded(completion: @escaping @MainActor () -> Void) {
        let needsRefresh = Date().timeIntervalSince(refreshedAt) >= freshness
        guard needsRefresh, !isRefreshing else { return }
        isRefreshing = true

        let refreshTask = Task.detached(priority: .userInitiated) {
            Self.readSafariHistory(limit: 50)
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

    nonisolated private static func readSafariHistory(limit: Int) -> [SafariRecentURL] {
        let script = """
        tell application "Safari"
            set historyItems to history items
            set result to {}
            set itemCount to 0
            repeat with historyItem in historyItems
                if itemCount >= \(limit) then exit repeat
                try
                    set end of result to (name of historyItem) & "|||" & (URL of historyItem)
                    set itemCount to itemCount + 1
                end try
            end repeat
            return result
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script),
            let output = appleScript.executeAndReturnError(&error).stringValue
        else { return [] }

        var seen = Set<String>()
        return output.components(separatedBy: ", ").compactMap { raw in
            let parts = raw.components(separatedBy: "|||")
            guard parts.count == 2,
                let url = URL(string: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                seen.insert(url.absoluteString).inserted
            else { return nil }
            return SafariRecentURL(
                title: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                url: url)
        }
    }

    nonisolated private func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
