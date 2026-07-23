import AppKit
import SwiftUI

// MARK: - Finder desktop folder drill-down
//
// In Finder desktop-only mode, Right-arrow on a focused folder replaces the result
// list with that folder's contents (Finder-style), a breadcrumb footer shows the
// current path, and Backspace on an empty field walks back out — to the parent
// folder, then back to the search results.

extension LauncherView {

    var isBrowsingFinderFolder: Bool { finderBrowsePath != nil }

    /// Drill into `path`, replacing the results with its contents.
    func browseFinderFolder(path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else { return }
        finderBrowsePath = path
        searchState.query = ""
        l2.focusedPillIndex = nil
        listViewHoveredIndex = nil
        commitFinderDesktopModeSnapshot(query: "", preserveFocus: false)
    }

    /// Right-arrow: if the focused Finder-desktop row is a folder, drill into it.
    @discardableResult
    func drillIntoFocusedFinderFolderIfPossible() -> Bool {
        guard isFinderDesktopOnlyMode else { return false }
        guard let pill = currentFocusedDockPillForQuickLook() ?? firstFinderFolderPill(),
            let url = pill.resolvedURL
        else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        browseFinderFolder(path: url.path)
        return true
    }

    private func firstFinderFolderPill() -> DockPill? {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return renderedOrderDockPills(for: q).first {
            !$0.isSeparator
                && ($0.resolvedURL.map { url -> Bool in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                        && isDir.boolValue
                } ?? false)
        }
    }

    /// Backspace on an empty field while browsing: pop to the parent folder, or exit
    /// browsing back to the search results at the top level.
    @discardableResult
    func popFinderBrowseFromEmptyBackspaceIfNeeded() -> Bool {
        guard let current = finderBrowsePath,
            searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let parent = (current as NSString).deletingLastPathComponent
        // Stop popping once we reach a search root (or the filesystem root) → back to
        // the normal Finder desktop search results.
        let roots = Set(finderDesktopSearchRootPaths().map { ($0 as NSString).standardizingPath })
        if parent.isEmpty || parent == "/" || roots.contains((current as NSString).standardizingPath) {
            exitFinderBrowse()
            return true
        }
        browseFinderFolder(path: parent)
        return true
    }

    func exitFinderBrowse() {
        guard finderBrowsePath != nil else { return }
        finderBrowsePath = nil
        l2.focusedPillIndex = nil
        listViewHoveredIndex = nil
        commitFinderDesktopModeSnapshot(query: "", preserveFocus: false)
    }

    /// The contents of `finderBrowsePath` as desktop pills — folders first, then
    /// files, alphabetical, hidden files skipped. Filtered by the typed query so the
    /// same field searches within the folder.
    func finderBrowseContentsPills(query: String) -> [DockPill] {
        guard let path = finderBrowsePath else { return [] }
        let dir = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        else { return [] }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        struct Entry { let url: URL; let isDir: Bool; let name: String }
        let items: [Entry] = entries.compactMap { url in
            let name = url.lastPathComponent
            if !q.isEmpty, !name.lowercased().contains(q) { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return Entry(url: url, isDir: isDir, name: name)
        }
        .sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }  // folders first
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        .prefix(300)
        .map { $0 }

        return items.map { entry in
            makeDesktopPill(
                path: entry.url.path,
                name: entry.name,
                badge: finderDisplayPath(dir.path),
                rankingKind: "finderBrowse",
                query: nil,
                isDirectoryHint: entry.isDir)
        }
    }

    // MARK: - Breadcrumb footer

    /// Finder-style breadcrumb of the folder being browsed (Macintosh HD ▸ … ▸ Folder).
    @ViewBuilder
    var finderBrowseBreadcrumb: some View {
        if let path = finderBrowsePath {
            let comps = breadcrumbComponents(for: path)
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(Array(comps.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(name)
                        .font(.system(size: 11, weight: index == comps.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == comps.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("⌫ back")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func breadcrumbComponents(for path: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = path
        if display.hasPrefix(home) {
            display = "~" + display.dropFirst(home.count)
        }
        let raw = display.split(separator: "/").map(String.init)
        // Keep it short: last 4 components, prefixed with a leading marker.
        let tail = Array(raw.suffix(4))
        if raw.count > tail.count { return ["…"] + tail }
        return tail
    }
}
