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

    /// A tab as a row: its title, its site, and ↩ switches to it.
    @MainActor
    static func pill(for tab: SafariTab, onSwitch: @escaping () -> Void = {}) -> DockPill {
        var pill = DockPill(
            id: "safari-tab:\(tab.id)",
            name: tab.title.isEmpty ? tab.domain : tab.title,
            icon: "safari",
            accentColorName: "blue",
            badge: tab.domain,
            execute: {
                SafariTabManager.shared.switchTo(tab)
                onSwitch()
            }
        )
        pill.sourceBundleId = safariBundleID
        pill.sourceAppName = "Safari"
        pill.menuStatusBadge = "Tab"
        pill.rankingKind = "safariTab"
        if let url = URL(string: tab.url) { pill.resolvedURL = url }
        pill.trackingIdentifier = "safari-tab:\(tab.url)"
        pill.searchTerms = [tab.title, tab.domain, tab.url, "tab"]
        return pill
    }
}
