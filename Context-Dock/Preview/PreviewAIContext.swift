// PreviewAIContext.swift
// Context-Dock
//
// What the assistant beside a preview is looking at.
//
// The first version handed the model a name, a path and a size, then asked it to
// organise a folder of fifty-seven files. "I can't see the contents" was the honest
// answer. A preview is the best-scoped surface in the app — the target is never
// ambiguous, it is the thing on screen — and that is only worth anything if the model
// is shown the same thing the user is.

import AppKit
import Foundation

enum PreviewAIContext {
    /// A folder's listing is capped: a five-thousand-file directory would otherwise
    /// become a five-thousand-line prompt, and the tools can count what the list cannot.
    private static let listingLimit = 200

    static func prompt(
        for item: PreviewItem,
        siblings: [PreviewItem],
        currentIndex: Int,
        extractedText: String?
    ) -> String {
        var sections: [String] = [
            """
            You are the assistant inside Context Dock's preview panel. The user is \
            looking at the item below — when they say "this", "the file", "here" or \
            "the folder", they mean it. You never have to ask which one.

            \(item.metadataForAI)
            """
        ]

        switch item.kind {
        case .folder:
            sections.append(folderListing(item.url))
        case .image:
            sections.append(
                """
                The image itself is attached, so look at it rather than guessing from \
                the filename.\(extractedText.map { "\n\nText recognised in it:\n\($0)" } ?? "")
                """)
        case .text, .document:
            if let extractedText, !extractedText.isEmpty {
                sections.append("Contents:\n\(extractedText)")
            } else {
                sections.append(
                    """
                    This file's text could not be extracted. Use the tools to inspect it \
                    rather than guessing what it says.
                    """)
            }
        case .web:
            sections.append("This is a web page: \(item.url.absoluteString)")
        }

        if siblings.count > 1 {
            let list = siblings.enumerated().map { index, other in
                "\(index + 1). \(other.title)\(index == currentIndex ? " ← showing" : "")"
            }
            sections.append(
                """
                Previewed as a set of \(siblings.count). Questions about "these" mean all \
                of them:
                \(list.joined(separator: "\n"))
                """)
        }

        sections.append(
            """
            You can run shell commands, and they run in the folder this item lives in, so \
            relative paths work. Anything that writes, moves, renames or deletes asks the \
            user first — propose it and let the approval happen; do not pretend it is done. \
            Read-only inspection needs no permission, so prefer looking over asking the \
            user to describe what you could have read yourself.

            When you move or rename files:
            - Match by extension in lower case only. Globbing is case-insensitive here, so \
              *.jpg already covers .JPG; listing both moves the same file twice.
            - Do not guess at extensions that might not be there. The listing above says \
              exactly which ones exist — use those.
            - Move one kind per command. A single command that moves several kinds reports \
              one result for all of them, so a partial failure looks like a total one.
            - Reuse a folder that is already there. The listing shows which exist; a second \
              Images beside the user's own Images is worse than not tidying at all.
            - Always `mkdir -p Name`, never `mkdir Name && mv …`. mkdir fails when the \
              folder exists, and the && means nothing after it runs.
            - Check afterwards. List the folder again and say what actually moved, not what \
              you asked for.

            When a command fails, quote the error it returned, word for word, and say what \
            it means. Do not summarise it as "access issues" or "something went wrong", and \
            never fall back to telling the user to do it by hand in Finder before you have \
            shown them what actually failed — "Command denied by user" and "Operation not \
            permitted" send them looking in completely different places.
            """)

        return sections.joined(separator: "\n\n")
    }

    /// The folder scope a preview's commands belong to: the directory itself, or the one
    /// the file sits in. Gives the tool loop a real working directory and somewhere to
    /// file anything it produces.
    static func scope(for item: PreviewItem) -> GeneralChatScope? {
        guard item.url.isFileURL else { return nil }
        let directory = item.kind == .folder ? item.url : item.url.deletingLastPathComponent()
        return .folder(path: directory.path)
    }

    private static func folderListing(_ url: URL) -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        guard !contents.isEmpty else { return "This folder is empty." }

        let sorted = contents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let rows = sorted.prefix(listingLimit).map { child -> String in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let size = isDirectory
                ? "folder"
                : ByteCountFormatter.string(
                    fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            let modified = values?.contentModificationDate
                .map { " · " + $0.formatted(date: .numeric, time: .omitted) } ?? ""
            return "- \(child.lastPathComponent) — \(size)\(modified)"
        }

        var listing = "Contents (\(contents.count) items):\n" + rows.joined(separator: "\n")
        if contents.count > listingLimit {
            listing += "\n… \(contents.count - listingLimit) more not listed — use the tools "
                + "if you need the rest."
        }
        return listing
    }
}
