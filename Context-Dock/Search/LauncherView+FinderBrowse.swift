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
        // Everything in the folder, not what the search that found it happened to match.
        // The query that led here describes the folder, not its contents: "documents" has
        // no business hiding the rest of a folder the user has just stepped into. The
        // ghost goes with it, or the field still offers to complete the old search.
        // One animated step, so the folder replaces the search results in the sheet that
        // is already open rather than the sheet closing on the cleared field and a new one
        // opening behind it.
        withAnimation(.dockSoft) {
            searchState.query = ""
            l2.appCompletion = nil
            l2.focusedPillIndex = nil
            listViewHoveredIndex = nil
            // Land on the first row, so the folder can be walked with the arrow keys
            // straight away instead of needing a Down press to pick anything up.
            l2.pillNavViaKeyboard = false
            commitFinderDesktopModeSnapshot(query: "", preserveFocus: false)
        }
        isSearchFieldFocused = true
        // The listing is nearly always taller than the results it replaced; resizing in
        // the same beat keeps the sheet from snapping to its new height afterwards.
        requestWindowSizeUpdate(reason: .modeChanged, animated: true)
    }

    /// Right-arrow: if the focused Finder-desktop row is a folder, drill into it.
    ///
    /// The focused row can come from either list. A typed query renders the grouped
    /// sheet — FOLDERS, then DOCUMENTS — whose rows live in the grouped navigation
    /// state, not in renderedOrderDockPills. Looking only at the latter meant Right
    /// arrow on a folder in a search result found nothing to drill into and fell
    /// through to app-scoping, which is why it appeared to do nothing at all.
    /// `requireExplicitFocus` is what keeps this from stealing Right arrow: asked early,
    /// before every other Right-arrow branch, it only acts on a row the user has actually
    /// arrowed to. The fallback to "the first folder in the list" is offered later, once
    /// the other branches have declined the key.
    @discardableResult
    func drillIntoFocusedFinderFolderIfPossible(requireExplicitFocus: Bool = false) -> Bool {
        guard isFinderDesktopOnlyMode else { return false }
        guard let url = focusedFinderFolderURL(requireExplicitFocus: requireExplicitFocus) else {
            return false
        }
        browseFinderFolder(path: url.path)
        return true
    }

    /// The folder under the focus right now, wherever the focus lives.
    private func focusedFinderFolderURL(requireExplicitFocus: Bool) -> URL? {
        var candidates: [URL?] = [
            currentFocusedDockPillForQuickLook()?.resolvedURL,
            focusedGlobalGroupedListPill()?.resolvedURL,
            focusedGlobalAppResultForInputPreview()?.filePath.map {
                URL(fileURLWithPath: $0)
            },
        ]
        if !requireExplicitFocus {
            candidates.append(firstFinderFolderPill()?.resolvedURL)
        }
        for case let url? in candidates where isDirectory(url) { return url }
        return nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
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
        withAnimation(.dockSoft) {
            finderBrowsePath = nil
            searchState.query = ""
            l2.appCompletion = nil
            l2.focusedPillIndex = nil
            listViewHoveredIndex = nil
            commitFinderDesktopModeSnapshot(query: "", preserveFocus: false)
        }
        requestWindowSizeUpdate(reason: .modeChanged, animated: true)
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

    /// Finder-style breadcrumb of the folder being browsed (… ▸ scripts ▸ office ▸ helpers).
    ///
    /// Every crumb is a button. It used to be text: the only way out was Backspace on an
    /// empty field, so typing something that matched nothing inside the folder read as
    /// being stuck in it — the query had to be cleared before the key that leaves would
    /// do anything.
    @ViewBuilder
    var finderBrowseBreadcrumb: some View {
        if let path = finderBrowsePath {
            let crumbs = breadcrumbEntries(for: path)
            HStack(spacing: 4) {
                Button { exitFinderBrowse() } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to Finder results")

                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    let isLast = index == crumbs.count - 1
                    Button {
                        guard !isLast else { return }
                        if let target = crumb.path {
                            browseFinderFolder(path: target)
                        } else {
                            exitFinderBrowse()
                        }
                    } label: {
                        Text(crumb.name)
                            .font(.system(size: 11, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? .primary : .secondary)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                    .help(isLast ? "" : "Go to \(crumb.name)")
                }

                Spacer(minLength: 0)

                Button { popFinderBrowseLevel() } label: {
                    Text("⌫ back")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Up one folder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    /// Up one level regardless of what is typed. Backspace only does this on an empty
    /// field — it has to, or it could not delete a character — so the footer offers the
    /// same move without clearing the query first.
    func popFinderBrowseLevel() {
        guard let current = finderBrowsePath else { return }
        let parent = (current as NSString).deletingLastPathComponent
        let roots = Set(finderDesktopSearchRootPaths().map { ($0 as NSString).standardizingPath })
        if parent.isEmpty || parent == "/"
            || roots.contains((current as NSString).standardizingPath)
        {
            exitFinderBrowse()
        } else {
            browseFinderFolder(path: parent)
        }
    }

    /// Crumbs with the folder each one stands for. A nil path is the truncation marker,
    /// which leaves browsing altogether rather than jumping somewhere unnamed.
    private func breadcrumbEntries(for path: String) -> [(name: String, path: String?)] {
        let standardized = (path as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var components: [(name: String, path: String?)] = []
        var walker = standardized
        while walker != "/" && !walker.isEmpty {
            let name = (walker as NSString).lastPathComponent
            components.append((name: name, path: walker))
            if walker == home { break }
            walker = (walker as NSString).deletingLastPathComponent
        }
        components.reverse()
        if standardized.hasPrefix(home), let first = components.first, first.path == home {
            components[0] = (name: "~", path: home)
        }

        // Keep it short: the last four, with a marker for what was cut.
        guard components.count > 4 else { return components }
        return [(name: "…", path: nil)] + Array(components.suffix(4))
    }
}
