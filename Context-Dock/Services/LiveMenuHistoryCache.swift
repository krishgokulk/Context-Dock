//
//  LiveMenuHistoryCache.swift
//  Context-Dock
//
//  Privacy-preserving browser history for apps whose database we deliberately do NOT
//  read (e.g. DuckDuckGo). Instead of touching a browser's on-disk store, this sources
//  history from the app's own live "History" menu via the Accessibility API — exactly
//  the items the user already sees in that menu — and caches them keyed by URL/title.
//
//  Robustness rule ("follow the live menu"): every refresh reconciles the cache against
//  the current live menu. Items still present keep their first-seen timestamp and get a
//  fresh lastSeen; items that have dropped out of the live menu are pruned from the
//  cache. So the cache never drifts from what the browser actually shows.
//

import AppKit
import ApplicationServices

@MainActor
final class LiveMenuHistoryCache {
    static let shared = LiveMenuHistoryCache()

    struct Item: Identifiable {
        let title: String
        let url: URL?
        let section: String?
        var firstSeen: Date
        var lastSeen: Date
        /// Live element ref for the most recent read — used to AX-press when no URL.
        var element: AXUIElement
        var id: String { url?.absoluteString.lowercased() ?? "title:" + title.lowercased() }
        var domain: String? {
            guard let host = url?.host else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    /// Bundle ids whose history comes from the live menu, not a database.
    static let menuHistoryBundleIds: Set<String> = [
        "com.duckduckgo.macos.browser"
    ]

    static func usesLiveMenuHistory(_ bundleId: String) -> Bool {
        menuHistoryBundleIds.contains(bundleId.lowercased())
    }

    /// Stable History-menu commands that are NOT page entries.
    private static let stableCommands: Set<String> = [
        "reopen last closed tab", "reopen last closed window",
        "reopen all windows from last session", "recently closed",
        "clear all history", "clear all history…", "clear all history...",
        "clear history", "clear history…", "clear history...",
        "show all history", "manage bookmarks", "back", "forward", "home",
        "release notes", "pin tab", "unpin tab",
    ]

    private var byBundle: [String: [String: Item]] = [:]
    private var lastRefresh: [String: Date] = [:]
    private let freshness: TimeInterval = 8

    private init() {}

    /// Recent history entries for a browser, most-recent first, optionally filtered by
    /// a token query. Reads only the cache — call `refreshIfNeeded` to populate it.
    func items(for bundleId: String, matching rawQuery: String = "", limit: Int = 24) -> [Item] {
        let all = (byBundle[bundleId.lowercased()] ?? [:]).values
            .sorted { $0.lastSeen > $1.lastSeen }
        let query = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        let historyKeywords: Set<String> = ["history", "recent", "recents", "url", "urls"]
        if query.isEmpty || historyKeywords.contains(query) {
            return Array(all.prefix(limit))
        }
        let tokens = query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return Array(all.prefix(limit)) }
        let matched = all.filter { item in
            let hay = (item.title + " " + (item.url?.absoluteString ?? "") + " " + (item.domain ?? "")).lowercased()
            return tokens.contains { hay.contains($0) }
        }
        return Array(matched.prefix(limit))
    }

    /// Reconcile the cache against the live History menu if the last read is stale.
    /// The AX read runs on the main thread (AX API is main-affine) but is capped and
    /// passive, so it is cheap. Calls `completion` only when the cache actually changed.
    func refreshIfNeeded(
        bundleId: String, pid: pid_t, completion: @escaping () -> Void
    ) {
        let key = bundleId.lowercased()
        guard pid > 0 else { return }
        if let last = lastRefresh[key], Date().timeIntervalSince(last) < freshness { return }
        lastRefresh[key] = Date()

        let live = AXMenuReader.shared.liveMenuURLItems(for: pid, topMenuTitle: "History")
        // Nothing read (menu not ready / AX blocked): keep the existing cache as-is.
        guard !live.isEmpty else { return }

        let now = Date()
        var current = byBundle[key] ?? [:]
        var liveIDs = Set<String>()
        var changed = false

        for entry in live {
            let name = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.stableCommands.contains(name.lowercased()) else { continue }
            // Skip obvious non-history rows (section headers already handled as sections).
            let item = Item(
                title: name, url: entry.url, section: entry.section,
                firstSeen: now, lastSeen: now, element: entry.element)
            liveIDs.insert(item.id)
            if var existing = current[item.id] {
                existing.lastSeen = now
                existing.element = entry.element  // refresh the live ref
                current[item.id] = existing
            } else {
                current[item.id] = item
                changed = true
            }
        }

        // Prune entries no longer in the live menu — the cache follows the menu.
        let removed = current.keys.filter { !liveIDs.contains($0) }
        if !removed.isEmpty {
            for id in removed { current.removeValue(forKey: id) }
            changed = true
        }

        byBundle[key] = current
        if changed { completion() }
    }

    /// Open a cached entry. Prefer AX-pressing the live menu element (true "click the
    /// menu" behaviour, no URL leaves our process); if it has a resolved URL, open that.
    func open(_ item: Item, bundleId: String) {
        if AXMenuReader.shared.pressMenuElement(item.element) { return }
        if let url = item.url {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.open(
                    [url], withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
