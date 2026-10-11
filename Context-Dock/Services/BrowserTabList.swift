// BrowserTabList.swift
// Context-Dock
//
// Safari's open tabs as a list both shells show: the Dock's tab strip and the Corner's Safari
// scope (inventory D13). Loading and switching stay in `SafariTabManager`; this is the order,
// the filter, and the row — one copy, where they used to live on `LauncherView`.

import AppKit
import Foundation

enum BrowserTabList {
    static let safariBundleID = "com.apple.Safari"

    /// Whether this browser's tabs can be listed. Only Safari today: the Dock lists no tabs for
    /// Chrome or Arc either, so neither shell claims to.
    static func listsTabs(bundleID: String) -> Bool {
        bundleID == safariBundleID
    }

    /// Pure: a URL as a comparison key — no fragment, lower-cased, no trailing slash.
    static func normalizedURLKey(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw)
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var key = (components?.url ?? url).absoluteString.lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// Pure: the current page's tab first, then window by window, tab by tab.
    static func ordered(_ tabs: [SafariTab], currentURL: String?) -> [SafariTab] {
        let currentKey = normalizedURLKey(currentURL)
        return tabs.sorted { lhs, rhs in
            if let currentKey {
                let lhsIsCurrent = normalizedURLKey(lhs.url) == currentKey
                let rhsIsCurrent = normalizedURLKey(rhs.url) == currentKey
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            }
            if lhs.windowIndex != rhs.windowIndex { return lhs.windowIndex < rhs.windowIndex }
            return lhs.tabIndex < rhs.tabIndex
        }
    }

    /// Pure: the tabs whose title, site or address contain every typed word.
    static func matching(_ tabs: [SafariTab], query: String) -> [SafariTab] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return tabs }
        return tabs.filter { tab in
            let haystack = "\(tab.title) \(tab.domain) \(tab.url)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func iconID(for tab: SafariTab) -> String { "safari-tab:\(tab.id)" }

    /// A tab's site icon — the favicon store the Dock's strip reads, Safari's own icon while it
    /// loads. Asking starts the fetch.
    @MainActor
    static func favicon(for tab: SafariTab) -> NSImage? {
        guard let url = URL(string: tab.url) else { return nil }
        if let icon = FaviconStore.shared.icon(for: url) { return icon }
        FaviconStore.shared.fetchIfNeeded(for: url)
        return nil
    }

    /// A tab as a pill in the field's strip — the same pill the running apps use.
    @MainActor
    static func icon(for tab: SafariTab) -> MatchDockIcon {
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        return MatchDockIcon(
            // The strip and the pill key their icons by bundle id; a tab's is its own id.
            id: iconID(for: tab), bundleID: iconID(for: tab),
            title: tab.title.isEmpty ? tab.domain : tab.title,
            icon: favicon(for: tab) ?? safari,
            isRunning: false, isExpandable: false, score: 0, isExactAppPrefix: false)
    }
}
