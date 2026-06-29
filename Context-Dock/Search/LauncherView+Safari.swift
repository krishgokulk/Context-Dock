import AppKit
import SwiftUI

extension LauncherView {
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

        BrowserURLLibraryService.shared.refreshIfNeeded {
            scheduleDockPillRebuild(
                query: searchState.query, delayNanoseconds: 0, refreshContext: false)
        }

        let entries = BrowserURLLibraryService.shared.entries(
            matching: query,
            bundleId: isGlobalContextActive ? nil : scopedBrowserBundleId
        )
        guard explicitlyRequestsHistory || !entries.isEmpty else { return [] }

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
                    AppDelegate.shared?.hideLauncher()
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
                    AppDelegate.shared?.hideLauncher()
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

    // MARK: - Safari Tab List View
    @ViewBuilder
    var safariTabListView: some View {
        let items = appPanelDisplayedItems
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(
                    NSWorkspace.shared.runningApplications
                        .contains(where: { $0.bundleIdentifier == "com.apple.Safari" })
                        ? "No tabs found"
                        : "Safari is not running"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            item.action()
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.10))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: safariTabIcon(for: item.subtitle))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                idx % 2 == 0
                                    ? Color.clear
                                    : Color.primary.opacity(0.02)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
            }
        }
    }

    func safariTabIcon(for domain: String) -> String {
        let d = domain.lowercased()
        if d.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if d.contains("youtube") { return "play.rectangle.fill" }
        if d.contains("mail.google") { return "envelope.fill" }
        if d.contains("docs.google") { return "doc.text.fill" }
        if d.contains("notion") { return "square.grid.2x2" }
        if d.contains("figma") { return "paintbrush.fill" }
        if d.contains("stackoverflow") { return "questionmark.circle.fill" }
        if d.contains("twitter") || d.contains("x.com") { return "bird.fill" }
        if d.contains("reddit") { return "bubble.left.and.bubble.right.fill" }
        if d.contains("apple") { return "applelogo" }
        if d.contains("localhost") || d.contains("127.0.0.1") { return "server.rack" }
        return "safari"
    }
}
