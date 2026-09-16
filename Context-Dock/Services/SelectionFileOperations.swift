import AppKit
import Foundation

/// Real file operations for Selection Scope, so "move to pictures", "rename", "trash" actually
/// happen instead of being narrated.
///
/// Tool choice: **FileManager + NSWorkspace**, never `mv`/`cp` in a shell and never AppleScript
/// to Finder. FileManager handles cross-volume moves, reports precise errors, and needs no
/// automation permission; `trashItem` puts files in the Trash with Put Back intact, which `rm`
/// cannot do. NSWorkspace covers the two things FileManager has no concept of — revealing a file
/// in Finder, and opening it. Shell tools stay reserved for content work (`sips`, `markitdown`,
/// `ditto`) where a real binary does the transformation.
struct SelectionFileOperationResult {
    let success: Bool
    /// One line per item, e.g. "IMG_4588.jpg → ~/Pictures/IMG_4588.jpg".
    let details: [String]
    let failureReason: String?

    var summary: String {
        if let failureReason { return failureReason }
        return details.joined(separator: "\n")
    }
}

final class SelectionFileOperations {
    static let shared = SelectionFileOperations()
    private init() {}

    private let fm = FileManager.default

    // MARK: - Destination resolution

    /// Accepts a real path, "~/Pictures", or a plain folder name ("pictures", "desktop",
    /// "downloads"). Returns nil when the target doesn't resolve to an existing directory —
    /// the caller then reports that instead of moving files somewhere unexpected.
    func resolveDestinationDirectory(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded)
            }
            return nil
        }

        let key = trimmed.lowercased()
            .replacingOccurrences(of: " folder", with: "")
            .trimmingCharacters(in: .whitespaces)
        let home = fm.homeDirectoryForCurrentUser
        let named: [String: URL] = [
            "pictures": home.appendingPathComponent("Pictures"),
            "photos": home.appendingPathComponent("Pictures"),
            "downloads": home.appendingPathComponent("Downloads"),
            "desktop": home.appendingPathComponent("Desktop"),
            "documents": home.appendingPathComponent("Documents"),
            "docs": home.appendingPathComponent("Documents"),
            "movies": home.appendingPathComponent("Movies"),
            "music": home.appendingPathComponent("Music"),
            "home": home,
            "applications": URL(fileURLWithPath: "/Applications"),
        ]
        guard let url = named[key] else { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return url
    }

    // MARK: - Operations

    func move(_ urls: [URL], to directory: URL) -> SelectionFileOperationResult {
        transfer(urls, to: directory, copying: false)
    }

    func copy(_ urls: [URL], to directory: URL) -> SelectionFileOperationResult {
        transfer(urls, to: directory, copying: true)
    }

    private func transfer(_ urls: [URL], to directory: URL, copying: Bool)
        -> SelectionFileOperationResult
    {
        guard !urls.isEmpty else { return failure("Nothing was selected.") }
        var details: [String] = []
        for url in urls {
            let target = uniqueDestination(for: url.lastPathComponent, in: directory)
            do {
                if copying {
                    try fm.copyItem(at: url, to: target)
                } else {
                    try fm.moveItem(at: url, to: target)
                }
                details.append(
                    "\(url.lastPathComponent) → \(displayPath(target))")
            } catch {
                details.append(
                    "\(url.lastPathComponent) — failed: \(error.localizedDescription)")
            }
        }
        return SelectionFileOperationResult(
            success: !details.contains { $0.contains("— failed:") },
            details: details,
            failureReason: nil)
    }

    func rename(_ urls: [URL], to newName: String) -> SelectionFileOperationResult {
        guard let url = urls.first else { return failure("Nothing was selected.") }
        guard urls.count == 1 else {
            return failure("Rename works on one item at a time — \(urls.count) are selected.")
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            return failure("\"\(newName)\" is not a usable file name.")
        }
        // Keep the original extension when the new name omits it.
        let ext = url.pathExtension
        let finalName =
            (!ext.isEmpty && (trimmed as NSString).pathExtension.isEmpty)
            ? "\(trimmed).\(ext)" : trimmed
        let target = url.deletingLastPathComponent().appendingPathComponent(finalName)
        guard !fm.fileExists(atPath: target.path) else {
            return failure("\(finalName) already exists in that folder.")
        }
        do {
            try fm.moveItem(at: url, to: target)
            return SelectionFileOperationResult(
                success: true,
                details: ["\(url.lastPathComponent) → \(finalName)"],
                failureReason: nil)
        } catch {
            return failure("Rename failed: \(error.localizedDescription)")
        }
    }

    func trash(_ urls: [URL]) -> SelectionFileOperationResult {
        guard !urls.isEmpty else { return failure("Nothing was selected.") }
        var details: [String] = []
        for url in urls {
            do {
                // trashItem (not rm) so the items keep Put Back in the Finder.
                try fm.trashItem(at: url, resultingItemURL: nil)
                details.append("\(url.lastPathComponent) → Trash")
            } catch {
                details.append(
                    "\(url.lastPathComponent) — failed: \(error.localizedDescription)")
            }
        }
        return SelectionFileOperationResult(
            success: !details.contains { $0.contains("— failed:") },
            details: details,
            failureReason: nil)
    }

    func duplicate(_ urls: [URL]) -> SelectionFileOperationResult {
        guard !urls.isEmpty else { return failure("Nothing was selected.") }
        var details: [String] = []
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let target = uniqueDestination(
                for: copyName, in: url.deletingLastPathComponent())
            do {
                try fm.copyItem(at: url, to: target)
                details.append("\(url.lastPathComponent) → \(target.lastPathComponent)")
            } catch {
                details.append(
                    "\(url.lastPathComponent) — failed: \(error.localizedDescription)")
            }
        }
        return SelectionFileOperationResult(
            success: !details.contains { $0.contains("— failed:") },
            details: details,
            failureReason: nil)
    }

    /// Creates a folder beside the selection and moves the selected items into it.
    func newFolder(named name: String, containing urls: [URL]) -> SelectionFileOperationResult {
        guard let first = urls.first else { return failure("Nothing was selected.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            return failure("\"\(name)\" is not a usable folder name.")
        }
        let parent = first.deletingLastPathComponent()
        let folder = uniqueDestination(for: trimmed, in: parent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            return failure("Could not create the folder: \(error.localizedDescription)")
        }
        var result = transfer(urls, to: folder, copying: false)
        result = SelectionFileOperationResult(
            success: result.success,
            details: ["Created \(displayPath(folder))"] + result.details,
            failureReason: nil)
        return result
    }

    func tag(_ urls: [URL], names: [String]) -> SelectionFileOperationResult {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return failure("No tag name was given.") }
        guard !urls.isEmpty else { return failure("Nothing was selected.") }
        var details: [String] = []
        for url in urls {
            do {
                var target = url
                let existing =
                    (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                var values = URLResourceValues()
                values.tagNames = Array(Set(existing + cleaned))
                try target.setResourceValues(values)
                details.append("\(url.lastPathComponent) tagged \(cleaned.joined(separator: ", "))")
            } catch {
                details.append(
                    "\(url.lastPathComponent) — failed: \(error.localizedDescription)")
            }
        }
        return SelectionFileOperationResult(
            success: !details.contains { $0.contains("— failed:") },
            details: details,
            failureReason: nil)
    }

    @MainActor
    func reveal(_ urls: [URL]) -> SelectionFileOperationResult {
        guard !urls.isEmpty else { return failure("Nothing was selected.") }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return SelectionFileOperationResult(
            success: true,
            details: ["Revealed \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") in Finder"],
            failureReason: nil)
    }

    // MARK: - Helpers

    private func failure(_ reason: String) -> SelectionFileOperationResult {
        SelectionFileOperationResult(success: false, details: [], failureReason: reason)
    }

    /// Never overwrite: "IMG.jpg" becomes "IMG 2.jpg" when the name is taken.
    private func uniqueDestination(for name: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while index < 1_000 {
            let attempt = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appendingPathComponent(attempt)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
        return candidate
    }

    private func displayPath(_ url: URL) -> String {
        let home = fm.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}
