// FrontmostMenuMatcher.swift
// Context-Dock
//
// Which of an app's menu commands a typed query means, and in what order.
//
// This is the dock's rule, moved out of LauncherView so the corner can use the same one.
// The corner is becoming the frontmost-app surface (plan:
// docs/superpowers/plans/2026-09-08-corner-frontmost-app-surface.md); until the dock's own
// path retires, both call this, so the two cannot rank the same menu differently.
//
// Pure: no view state, no AX calls, no I/O. Reading the menu is the caller's job.

import Foundation

enum FrontmostMenuMatcher {

    /// What a surface will show. The dock and the corner differ here and nowhere else.
    struct Policy {
        /// Apple-menu items (System Settings, Sleep…) — the app's own menus only, by default.
        var allowsAppleMenuItems: Bool
        /// Drops About/Help/Quit/Settings-style rows every app has. Global Context wants this;
        /// an app-scoped surface does not, because there "Preferences" is a real answer.
        var excludesGenericAppMenus: Bool
        /// Window-management rows are suppressed when the user runs a native window manager.
        var suppressesWindowManagement: Bool

        /// The corner's app chat: this app's own menus, generic rows included.
        static let cornerAppChat = Policy(
            allowsAppleMenuItems: false,
            excludesGenericAppMenus: false,
            suppressesWindowManagement: false)
    }

    // MARK: - Matching

    /// Does `item` answer `query`? An empty query matches everything: the list is then simply
    /// the app's menu.
    ///
    /// Four rungs, cheapest first: whole-string equality, prefix or substring, shared word,
    /// then a typo rung — and that last one only for words of four letters or more, because
    /// below that an edit distance of two reaches almost anything.
    static func matches(_ item: AXMenuItem, query: String) -> Bool {
        let normalizedQuery = DockTextMatch.normalized(query)
        guard !normalizedQuery.isEmpty else { return true }

        let corpora = ([item.title] + item.path)
            .map(DockTextMatch.normalized)
            .filter { !$0.isEmpty }

        if corpora.contains(normalizedQuery) { return true }
        if corpora.contains(where: {
            $0.hasPrefix(normalizedQuery) || $0.contains(normalizedQuery)
        }) {
            return true
        }

        let queryTokens = Set(DockTextMatch.tokens(normalizedQuery))
        guard !queryTokens.isEmpty else { return false }
        let corpusTokens = Set(corpora.flatMap(DockTextMatch.tokens))
        if !queryTokens.intersection(corpusTokens).isEmpty { return true }

        for qt in queryTokens where qt.count >= 4 {
            for ct in corpusTokens where ct.count >= 4 {
                if DockTextMatch.editDistance(qt, ct) <= 2 { return true }
            }
        }
        return false
    }

    // MARK: - Dedupe

    /// One row per menu path. The same command arrives from the live menu, the warm cache and
    /// the persistent cache; the path is what makes them the same command.
    ///
    /// A pathless item is dropped rather than kept under an empty key — it cannot be executed
    /// and would swallow every other pathless row.
    static func dedupe(_ items: [AXMenuItem]) -> [AXMenuItem] {
        var seen = Set<String>()
        var deduped: [AXMenuItem] = []
        for item in items {
            let key = item.path.joined(separator: " > ").lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            deduped.append(item)
        }
        return deduped
    }

    // MARK: - Policy

    /// Is this row worth showing at all — enabled, or reachable another way?
    static func isExposable(_ item: AXMenuItem) -> Bool {
        if isAppleRecentItem(item) { return false }
        return item.isEnabled
            || hasNativeShortcut(item)
            || item.resolvedFilePath != nil
            || item.isLeaf
    }

    /// A shortcut the app itself declares. An empty string is not one.
    static func hasNativeShortcut(_ item: AXMenuItem) -> Bool {
        item.shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The Apple menu, however the path expresses it: the flag, a parent segment of "Apple"
    /// (which is what `menuContextLabel` reads), or "Apple" at the root.
    static func isAppleMenuItem(_ item: AXMenuItem) -> Bool {
        if item.isAppleMenu { return true }
        if item.path.count > 1, item.path[item.path.count - 2] == "Apple" { return true }
        return item.path.first == "Apple"
    }

    /// Apple-menu Recent Items: noise, not actions — out even when the Apple menu is allowed.
    static func isAppleRecentItem(_ item: AXMenuItem) -> Bool {
        guard isAppleMenuItem(item) else { return false }
        return item.path.contains { DockTextMatch.normalized($0).contains("recent") }
            || DockTextMatch.normalized(item.title).contains("recent")
    }

    /// Rows every app has, which say nothing about what *this* app does.
    static func isGenericAppMenu(_ item: AXMenuItem) -> Bool {
        let title = DockTextMatch.normalized(item.title)
        let genericPatterns = [
            "about", "help", "quit", "exit", "close",
            "settings", "preferences", "options",
            "hide", "show", "reveal",
            "services", "documentation",
        ]
        return genericPatterns.contains { title.contains($0) }
    }

    static func allowed(_ items: [AXMenuItem], policy: Policy) -> [AXMenuItem] {
        items.filter { item in
            guard isExposable(item) else { return false }
            if !policy.allowsAppleMenuItems && isAppleMenuItem(item) { return false }
            if policy.excludesGenericAppMenus && isGenericAppMenu(item) { return false }
            return true
        }
    }

    // MARK: - Ordering

    /// With no query, spread across the app's menus rather than draining the first one —
    /// a resting list that is all File commands tells the user nothing about the app.
    static func distributed(_ items: [AXMenuItem], limit: Int) -> [AXMenuItem] {
        guard limit > 0, !items.isEmpty else { return [] }

        var buckets: [String: [AXMenuItem]] = [:]
        var rootOrder: [String] = []

        for item in items {
            let root = item.path.first ?? item.title
            if buckets[root] == nil {
                buckets[root] = []
                rootOrder.append(root)
            }
            buckets[root, default: []].append(item)
        }

        for root in rootOrder {
            buckets[root]?.sort {
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        var distributed: [AXMenuItem] = []
        var didAppend = true
        while distributed.count < limit && didAppend {
            didAppend = false
            for root in rootOrder where distributed.count < limit {
                guard var bucket = buckets[root], !bucket.isEmpty else { continue }
                distributed.append(bucket.removeFirst())
                buckets[root] = bucket
                didAppend = true
            }
        }

        return distributed
    }

    /// Best match first. Ties go to the shallower menu path, then to the title.
    static func ordered(_ items: [AXMenuItem], filterQuery: String, limit: Int) -> [AXMenuItem] {
        guard !items.isEmpty else { return [] }
        let normalizedFilter = DockTextMatch.normalized(filterQuery)
        if normalizedFilter.isEmpty {
            return distributed(items, limit: limit)
        }

        func score(_ item: AXMenuItem) -> Double {
            DockTextMatch.rankedScore(
                query: normalizedFilter,
                primary: item.title,
                contexts: [
                    item.path.dropLast().last ?? "",
                    item.path.joined(separator: " "),
                ]
            ) ?? 0
        }

        return Array(
            items.sorted {
                let aScore = score($0)
                let bScore = score($1)
                if aScore != bScore { return aScore > bScore }
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
        )
    }

    // MARK: - The whole rule

    /// Menu items in, the rows a surface should show out: matched, deduped, filtered, ordered.
    static func ranked(
        _ items: [AXMenuItem],
        query: String,
        limit: Int,
        policy: Policy
    ) -> [AXMenuItem] {
        let matched = items.filter { matches($0, query: query) }
        return ordered(
            allowed(dedupe(matched), policy: policy),
            filterQuery: query,
            limit: limit)
    }
}
