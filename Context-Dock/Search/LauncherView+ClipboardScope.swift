import AppKit
import Combine
import Foundation
import ImageIO
import Quartz
import SwiftUI
import UniformTypeIdentifiers

private enum ClipboardScopeRenderCache {
    static let thumbnails = NSCache<NSString, NSImage>()
    static let appIcons = NSCache<NSString, NSImage>()
    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

extension LauncherView {
    // MARK: - Clipboard Pocket Pill



    // MARK: - Clipboard history sorted by frontmost app relevance
    func relevantClipboardHistory() -> [ClipboardEntry] {
        let isBrowser = [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.Browser",
        ].contains(frontmost.bundleID)
        let isFinder = frontmost.bundleID == "com.apple.finder"

        if isBrowser {
            return clipboardHistory.sorted { a, b in
                if a.isURL && !b.isURL { return true }
                if !a.isURL && b.isURL { return false }
                return a.timestamp > b.timestamp
            }
        } else if isFinder {
            return clipboardHistory.sorted { a, b in
                if a.isFilePath && !b.isFilePath { return true }
                if !a.isFilePath && b.isFilePath { return false }
                return a.timestamp > b.timestamp
            }
        }
        return clipboardHistory
    }







    func clipboardEntrySubtitle(_ entry: ClipboardEntry) -> String {
        var parts: [String] = []
        if !entry.sourceAppName.isEmpty {
            parts.append("Copied from \(entry.sourceAppName)")
        }
        if entry.fileCount > 0 {
            parts.append(entry.fileCount == 1 ? "1 file" : "\(entry.fileCount) files")
        }
        let age = ClipboardScopeRenderCache.relativeDateFormatter.localizedString(
            for: entry.timestamp, relativeTo: Date())
        parts.append(age)
        return parts.joined(separator: " • ")
    }

    func copyClipboardEntryToPasteboard(_ entry: ClipboardEntry) {
        writeClipboardEntriesToPasteboard([entry])
    }

    /// Puts one *or many* clips on the pasteboard — through the one writer both shells share
    /// (`ClipboardScopeService.writeToPasteboard`), so the Dock and the Corner cannot differ
    /// on what a mixed selection pastes as.
    func writeClipboardEntriesToPasteboard(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        // The always-on monitor must not re-import what we just wrote — a clip re-entering
        // its own history churns the list (and the image blob behind it) for no reason.
        lastCheckedPasteboardCount = ClipboardScopeService.writeToPasteboard(entries)
    }










    func clipboardDragProvider(for entry: ClipboardEntry) -> NSItemProvider? {
        if let firstPath = entry.filePaths.first {
            let url = URL(fileURLWithPath: firstPath)
            if FileManager.default.fileExists(atPath: url.path),
                let provider = NSItemProvider(contentsOf: url)
            {
                return provider
            }
        }

        if let imageData = clipboardImageData(for: entry),
            let url = temporaryClipboardDragFile(data: imageData, fileExtension: "png"),
            let provider = NSItemProvider(contentsOf: url)
        {
            return provider
        }

        if entry.isURL, let url = URL(string: entry.text),
            let provider = NSItemProvider(contentsOf: url)
        {
            return provider
        }

        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return NSItemProvider(object: text as NSString)
    }

    func temporaryClipboardDragFile(data: Data, fileExtension: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextDockClipboardDrag", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
                fileExtension)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }





    func clipboardSearchResults() -> [SearchResult] {
        visibleClipboardEntriesForScope().map { entry in
            return SearchResult(
                title: entry.preview,
                subtitle: clipboardEntrySubtitle(entry),
                icon: clipboardEntryImage(for: entry),
                action: {
                    copyClipboardEntryToPasteboard(entry)
                },
                score: 100,
                type: entry.fileCount > 0 ? .file : .document,
                // Image/text preview files are created only when Quick Look is requested.
                // Writing one file per row here blocks the main thread before scrolling.
                filePath: entry.filePaths.first,
                contactData: nil,
                displayBadges: clipboardEntryBadges(entry),
                showsTypeLabel: false,
                dismissesLauncher: false,
                dragProvider: {
                    clipboardDragProvider(for: entry)
                }
            )
        }
    }

    func refreshCompactScopeResults(resetSelection: Bool = true) {
        guard let key = searchState.activeSmartQueryKey,
            key == "clipboard" || key == "notifications"
        else { return }

        let results: [SearchResult] =
            key == "clipboard"
            ? clipboardSearchResults()
            : notificationSearchResults()
        searchState.results = results
        searchState.grouped = {
            var grouped = GroupedResults()
            grouped.pinnedResults = results
            grouped.pinnedSectionTitle = key == "clipboard" ? "Clipboard Items" : "Notifications"
            return grouped
        }()
        if resetSelection {
            searchState.selectedIndex = nil
            focusedClipboardEntryIndex = nil
            isKeyboardNavigation = false
        } else if let index = searchState.selectedIndex, index >= results.count {
            searchState.selectedIndex = results.isEmpty ? nil : max(results.count - 1, 0)
        }
        searchState.revision += 1
        refreshQuickLookPreviewForCurrentFocusIfVisible()
    }

    /// Provider usage rows as SearchResults so the notification scope has content
    /// (and a correctly-sized sheet) the moment it opens, before any notification.
    func aiUsageSearchResults() -> [SearchResult] {
        aiUsageScopeRows().map { row in
            SearchResult(
                title: row.title,
                subtitle: row.subtitle,
                icon: NSImage(
                    systemSymbolName: row.systemIcon, accessibilityDescription: row.title),
                action: {},
                type: .extensionCommand,
                filePath: nil,
                contactData: nil,
                displayBadges: ["Usage"],
                showsTypeLabel: false,
                dismissesLauncher: false
            )
        }
    }

    func notificationSearchResults() -> [SearchResult] {
        aiUsageSearchResults() + filteredNotificationsForScope().map { notification in
            SearchResult(
                title: notification.title,
                subtitle:
                    "\(notification.body) • \(notification.date.formatted(date: .abbreviated, time: .shortened))",
                icon: NSImage(
                    systemSymbolName: notification.icon,
                    accessibilityDescription: notification.title),
                action: {
                    notificationManager.tap(notification.id)
                    refreshCompactScopeResults(resetSelection: false)
                },
                type: .extensionCommand,
                filePath: nil,
                contactData: nil,
                displayBadges: notification.isRead ? [] : ["Unread"],
                showsTypeLabel: false,
                dismissesLauncher: false
            )
        }
    }





    /// The board's usage rows, shared with the Corner's Notifications board.
    func aiUsageScopeRows() -> [SharedResultRowModel] { AIUsageRows.rows() }




    func filteredNotificationsForScope() -> [ILauncherNotification] {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return notificationManager.notifications }
        return notificationManager.notifications.filter { notification in
            notification.title.lowercased().contains(q)
                || notification.body.lowercased().contains(q)
        }
    }



    func clipboardEntryImage(for entry: ClipboardEntry) -> NSImage? {
        let cacheKey = entry.id.uuidString as NSString
        if let cached = ClipboardScopeRenderCache.thumbnails.object(forKey: cacheKey) {
            return cached
        }
        if let imageData = clipboardImageData(for: entry),
            let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        {
            let image = NSImage(cgImage: thumbnail, size: .zero)
            ClipboardScopeRenderCache.thumbnails.setObject(
                image, forKey: cacheKey, cost: thumbnail.bytesPerRow * thumbnail.height)
            return image
        }
        if entry.filePaths.count == 1 {
            return NSWorkspace.shared.icon(forFile: entry.filePaths[0])
        }
        return NSImage(systemSymbolName: entry.icon, accessibilityDescription: entry.preview)
    }

    func clipboardEntriesForScope(query: String) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = relevantClipboardHistory()
        guard !q.isEmpty, q != "clip", q != "clipboard" else { return entries }
        // Matching against the rendered subtitle used to rebuild a relative-date string
        // per entry per keystroke; the same fields are already covered below.
        return entries.filter {
            $0.preview.lowercased().contains(q)
                || $0.text.lowercased().contains(q)
                || $0.ocrText.lowercased().contains(q)
                || $0.filePaths.joined(separator: " ").lowercased().contains(q)
                || $0.sourceAppName.lowercased().contains(q)
        }
    }

    /// Row badges: "Capture" marks clips this app produced (Capture Text / Capture Area),
    /// "OCR" marks an image whose text Vision has already read out.
    func clipboardEntryBadges(_ entry: ClipboardEntry) -> [String] {
        var badges: [String] = []
        if entry.isScreenCapture { badges.append("Capture") }
        if !entry.ocrText.isEmpty { badges.append("OCR") }
        return badges
    }

    func buildClipboardHistoryPills(query q: String) -> [DockPill] {
        let entries = clipboardEntriesForScope(query: q)
        return entries.prefix(maxListViewDockPills).enumerated().map { index, entry in
            var pill = DockPill(
                id: "clipboard-history-\(entry.id.uuidString)",
                name: entry.preview.isEmpty ? "Clipboard Item" : entry.preview,
                icon: entry.icon,
                accentColorName: entry.isImage
                    ? "purple" : (entry.fileCount > 0 ? "green" : "blue"),
                badge: clipboardEntrySubtitle(entry),
                execute: {
                    copyClipboardEntryToPasteboard(entry)
                    searchState.query = ""
                    focusedClipboardEntryIndex = nil
                    l2.focusedPillIndex = nil
                }
            )
            pill.menuItemImage = clipboardEntryImage(for: entry)
            pill.sourceBundleId = entry.sourceBundleId
            pill.sourceAppName = entry.sourceAppName.isEmpty ? "Clipboard" : entry.sourceAppName
            pill.rankingKind = "clipboard"
            pill.trackingIdentifier = "clipboard:\(entry.id.uuidString)"
            pill.searchTerms = [
                entry.preview,
                entry.text,
                entry.ocrText,
                entry.filePaths.joined(separator: " "),
                entry.sourceAppName,
                clipboardEntrySubtitle(entry),
                "clipboard",
                "clip",
            ]
            pill.quickLookURL = entry.filePaths.first.map { URL(fileURLWithPath: $0) }
            pill.dragProvider = {
                clipboardDragProvider(for: entry)
            }
            pill.rankingScore = Double(maxListViewDockPills - index)
            return pill
        }
    }












    func filteredClipboardEntriesForScope() -> [ClipboardEntry] {
        clipboardEntriesForScope(query: searchState.query)
    }

    func visibleClipboardEntriesForScope() -> [ClipboardEntry] {
        let entries = filteredClipboardEntriesForScope()
        guard !clipboardSourceFilterBundleId.isEmpty else { return entries }
        return entries.filter { $0.sourceBundleId == clipboardSourceFilterBundleId }
    }













    func quickLookURL(for entry: ClipboardEntry) -> URL? {
        if let path = entry.filePaths.first, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextDockClipboardQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let imageData = clipboardImageData(for: entry) {
            let url = directory.appendingPathComponent("\(entry.id.uuidString).png")
            try? imageData.write(to: url, options: .atomic)
            return url
        }

        if let url = URL(string: entry.text), url.scheme != nil {
            let previewURL = directory.appendingPathComponent("\(entry.id.uuidString).webloc")
            let body = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict><key>URL</key><string>\(url.absoluteString)</string></dict></plist>
                """
            try? body.write(to: previewURL, atomically: true, encoding: .utf8)
            return previewURL
        }

        let previewURL = directory.appendingPathComponent("\(entry.id.uuidString).txt")
        try? entry.text.write(to: previewURL, atomically: true, encoding: .utf8)
        return previewURL
    }

    func currentFocusedDockPillForQuickLook() -> DockPill? {
        guard isL2ContextActive, usesVerticalListDockLayout else { return nil }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Read the SAME clustered/grouped pill order the keyboard navigates and the
        // list renders — otherwise focusedPillIndex points into an ungrouped array and
        // Space previews a different file than the highlighted row (e.g. a Finder
        // search grouped into Files/Images regrouped the rows).
        let pills: [DockPill] =
            (shouldUsePureGlobalAppSearch || isActiveGlobalRunningAppMenuScope())
            ? visibleGlobalGroupedListNavigationState(for: q).menuPills
            : renderedOrderDockPills(for: q)
        let index = l2.focusedPillIndex ?? listViewHoveredIndex
        guard let index, pills.indices.contains(index), !pills[index].isSeparator else {
            return nil
        }
        return pills[index]
    }


    /// Focused pill in the global grouped list (app-scope sheet), for Space peeks.
    func focusedGlobalGroupedListPill() -> DockPill? {
        guard isGlobalContextActive else { return nil }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = globalGroupedListNavigationState(for: q)
        guard state.totalCount > 0,
            let index = currentGlobalGroupedFocusIndex(state: state)
        else { return nil }
        let menuIndex = index - state.appResults.count
        guard menuIndex >= 0, menuIndex < state.menuPills.count else { return nil }
        return state.menuPills[menuIndex]
    }





}
