// FolderScopeDigest.swift
// Context-Dock
//
// What a folder-scoped chat knows about its folder before anyone asks anything.
//
// A thread scoped to ~/Documents/Invoices that has to call a tool to discover it holds
// PDFs answers its first question with a tool call and its second with another. One
// bounded read up front means "what's in here?" is answered from context, and the tools
// are left for the work that actually needs them — reading a file, finding duplicates,
// moving things.
//
// Bounded deliberately: immediate children only, capped and truncated. Walking a home
// directory to build a prompt would cost more than the answer is worth, and the
// capabilities can go deeper on demand.

import Foundation

enum FolderScopeDigest {

    /// Immediate children listed for the prompt, newest first.
    private static let entryLimit = 40

    struct Counts {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0
    }

    /// The block that goes into a folder thread's system prompt.
    static func promptBlock(for url: URL) -> String {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles])
        else {
            return """
                FOLDER SCOPE
                Path: \(url.path)
                DoraX could not read this folder — it may have been moved, or macOS may not \
                have granted access yet. Say so rather than guessing at its contents.
                """
        }

        let entries = children
            .map { child -> (url: URL, isDirectory: Bool, size: Int64, modified: Date) in
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                ])
                return (
                    url: child,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modified > $1.modified }

        var counts = Counts()
        for entry in entries {
            if entry.isDirectory { counts.folders += 1 } else { counts.files += 1 }
            counts.bytes += entry.size
        }

        var lines: [String] = [
            "FOLDER SCOPE",
            "Path: \(url.path)",
            summaryLine(counts),
        ]

        if entries.isEmpty {
            lines.append("The folder is empty.")
        } else {
            let shown = entries.prefix(entryLimit)
            lines.append("Contents, newest first:")
            for entry in shown {
                lines.append("- \(describe(entry))")
            }
            if entries.count > shown.count {
                lines.append(
                    "…and \(entries.count - shown.count) more. Use finder.listFolder or "
                        + "finder.searchFiles for the rest.")
            }
        }

        lines.append(
            """
            This is the whole scope of the conversation. Every finder.* capability acts on \
            this folder when no path is given, so answer about what is here rather than \
            about the user's Desktop or Documents. Subfolders are in scope; anything above \
            this folder is not — say so instead of reaching for it.
            """)

        return lines.joined(separator: "\n")
    }

    /// One-line description for the sidebar panel, where there is no room for the listing.
    static func subtitle(for url: URL) -> String {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return "Not readable" }

        var counts = Counts()
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory ?? false { counts.folders += 1 } else { counts.files += 1 }
            counts.bytes += Int64(values?.fileSize ?? 0)
        }
        return summaryLine(counts)
    }

    /// Immediate children as display rows for the scope panel, newest first.
    static func topEntries(for url: URL, limit: Int = 12) -> [String] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles])
        else { return [] }

        return children
            .map { child -> (url: URL, isDirectory: Bool, size: Int64, modified: Date) in
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                ])
                return (
                    url: child,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(describe)
    }

    // MARK: - Formatting

    private static func summaryLine(_ counts: Counts) -> String {
        let total = counts.files + counts.folders
        guard total > 0 else { return "Empty folder" }
        var parts: [String] = []
        if counts.files > 0 { parts.append("\(counts.files) file\(counts.files == 1 ? "" : "s")") }
        if counts.folders > 0 {
            parts.append("\(counts.folders) folder\(counts.folders == 1 ? "" : "s")")
        }
        if counts.bytes > 0 { parts.append(byteText(counts.bytes)) }
        return parts.joined(separator: " · ")
    }

    private static func describe(
        _ entry: (url: URL, isDirectory: Bool, size: Int64, modified: Date)
    ) -> String {
        let name = entry.url.lastPathComponent
        if entry.isDirectory {
            return "\(name)/ — folder, changed \(dateText(entry.modified))"
        }
        return "\(name) — \(byteText(entry.size)), changed \(dateText(entry.modified))"
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func dateText(_ date: Date) -> String {
        guard date != .distantPast else { return "unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
