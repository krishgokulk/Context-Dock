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




    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
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



}
