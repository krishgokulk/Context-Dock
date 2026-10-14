import AppKit
import SwiftUI

extension DockCore {
    func buildSafariRecentURLPills(query rawQuery: String) -> [DockPill] {
        let query = normalizedDockPillText(rawQuery)
        guard !query.isEmpty else { return [] }

        let scope = resolveDockScope(for: rawQuery)
        let scopedBrowserBundleId: String? = {
            if isBrowserMenuSource(scope.scopedBundleId) { return scope.scopedBundleId }
            if isBrowserMenuSource(frontmost.bundleID) { return frontmost.bundleID }
            if isBrowserMenuSource(axContext.bundleId) { return axContext.bundleId }
            return nil
        }()
        let explicitlyRequestsHistory =
            ["recent", "recents", "history", "url", "urls", "bookmark", "bookmarks"].contains(query)
        guard isGlobalContextActive || scopedBrowserBundleId != nil else { return [] }

        // Privacy browsers (DuckDuckGo): source history from their live History menu,
        // never their database. Only within that browser's own scope.
        if let bundle = scopedBrowserBundleId,
            LiveMenuHistoryCache.usesLiveMenuHistory(bundle)
        {
            return buildLiveMenuHistoryPills(query: rawQuery, bundleId: bundle)
        }

        return buildBrowserURLLibraryPills(
            query: query,
            scopedBrowserBundleId: isGlobalContextActive ? nil : scopedBrowserBundleId,
            requireExplicitHistoryQuery: explicitlyRequestsHistory
        )
    }

    /// History pills sourced from a browser's live History menu (see LiveMenuHistoryCache).
    func buildLiveMenuHistoryPills(query rawQuery: String, bundleId: String) -> [DockPill] {
        let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .first?.processIdentifier ?? 0
        guard pid > 0 else { return [] }

        LiveMenuHistoryCache.shared.refreshIfNeeded(bundleId: bundleId, pid: pid) {
            GlobalContextResultSource.shared.refresh()
            scheduleDockPillRebuild(
                query: searchState.query, delayNanoseconds: 0, refreshContext: false)
        }

        let items = LiveMenuHistoryCache.shared.items(for: bundleId, matching: rawQuery, limit: 24)
        return items.map { item in
            let subtitle = item.section ?? item.domain ?? "History"
            var pill = DockPill(
                id: "live-menu-history:\(bundleId):\(item.id)",
                name: item.title,
                icon: "clock.arrow.circlepath",
                accentColorName: "blue",
                badge: subtitle,
                execute: {
                    LiveMenuHistoryCache.shared.open(item, bundleId: bundleId)
                }
            )
            pill.sourceBundleId = bundleId
            pill.rankingKind = "recentURL"
            pill.menuItemName = item.title
            pill.menuStatusBadge = "History"
            if let url = item.url { pill.resolvedURL = url }
            pill.trackingIdentifier = "live-menu-history:\(item.id)"
            pill.searchTerms = [item.title, item.domain ?? "", "history", "recent", "menu"]
            return pill
        }
    }

    func buildBrowserURLLibraryPills(
        query: String,
        scopedBrowserBundleId: String?,
        requireExplicitHistoryQuery: Bool = false,
        limit: Int = 24
    ) -> [DockPill] {
        BrowserURLLibraryService.shared.refreshIfNeeded {
            scheduleDockPillRebuild(
                query: searchState.query, delayNanoseconds: 0, refreshContext: false)
        }

        let entries = BrowserURLLibraryService.shared.entries(
            matching: query,
            bundleId: scopedBrowserBundleId,
            limit: limit
        )
        guard requireExplicitHistoryQuery || !entries.isEmpty else { return [] }
        return entries.map { entry in
            var pill = DockPill(
                id: "browser-url:\(entry.id)",
                name: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                icon: entry.kind == .bookmark ? "bookmark.fill" : "clock.arrow.circlepath",
                accentColorName: "blue",
                badge: entry.domain,
                execute: {
                    // Always open cached URL in source browser; never AX-click dynamic
                    // History/Bookmarks menus.
                    BrowserURLLibraryService.shared.open(entry)
                }
            )
            pill.sourceBundleId = entry.browserBundleId
            pill.sourceAppName = entry.browserName
            pill.rankingKind = "recentURL"
            pill.menuItemName = entry.title
            pill.menuStatusBadge = entry.kind.rawValue
            pill.menuContext = entry.dateGroupTitle
            pill.resolvedURL = entry.url
            pill.quickLookURL = BrowserURLLibraryService.shared.quickLookURL(for: entry)
            pill.trackingIdentifier = "browser-url:\(entry.id)"
            pill.searchTerms = [
                entry.title, entry.url.absoluteString, entry.domain,
                entry.browserName, entry.kind.rawValue,
                "browser", "url", "recent", "history", "bookmark",
            ]
            // Async favicon; globe/safari icon shows immediately, never blocks typing.
            return pill.applyingSafariFavicon(entry.url)
        }
    }

    // MARK: - Safari Tab Switcher
    @MainActor
    func loadSafariTabs() async {
        guard
            NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == "com.apple.Safari" })
        else {
            setPinnedResults([], title: "Safari Tabs", excludeTypes: [])
            return
        }

        let tabs = await SafariTabManager.shared.fetchTabs()

        let results: [SearchResult] = tabs.map { tab in
            SearchResult(
                title: tab.title.isEmpty ? tab.domain : tab.title,
                subtitle: tab.domain,
                icon: nil,
                action: {
                    SafariTabManager.shared.switchTo(tab)
                },
                type: .webSearch,
                filePath: nil,
                contactData: nil
            )
        }

        setPinnedResults(
            results,
            title: "Safari Tabs — \(tabs.count) open",
            excludeTypes: [.webSearch]
        )
    }


}
