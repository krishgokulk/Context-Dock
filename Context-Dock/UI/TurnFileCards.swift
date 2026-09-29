// TurnFileCards.swift
// Context-Dock
//
// The files a finished answer talked about, drawn as cards under it.
//
// One card for every chat surface: `AIChatMessageView` draws it, and the Dock, the Corner
// and the Chat Window all draw answers through that view — the same way `ActivityRows`
// reaches all three. The rows are `CapabilityResultCard`'s, so a file found by a Finder
// capability and a file named by Claude Code look and act the same: Open, Reveal in
// Finder, Quick Look (the app's `PreviewController`, never a second panel owner), drag.
//
// Local UI only. Paths already on screen become buttons; nothing new reaches the model.

import SwiftUI

enum TurnFileCards {
    /// What a finished turn is loaded from. Changes when the answer or its steps do.
    struct Source: Equatable {
        /// The answer as the user reads it.
        let answer: String
        /// What the turn's steps returned — `mdfind`, `ls`, a Finder capability.
        let stepOutputs: [String]
        /// Files the message already draws in its own rows (attachments, recent files).
        let excluding: [URL]
    }

    /// The card for a finished turn, or nil when it named no file that exists.
    static func table(for source: Source) async -> CapabilityResultTable? {
        let answer = source.answer
        let outputs = source.stepOutputs
        let excluded = Set(source.excluding.map { $0.standardizedFileURL.path })
        // Disk probes stay off the main thread: a step that listed a folder is a few
        // hundred `stat`s at most (`probeBudget`), but never while the Corner is sizing.
        let found = await Task.detached(priority: .utility) {
            TurnFileExtractor.files(answer: answer, stepOutputs: outputs)
                .filter { !excluded.contains($0.path) }
                .map(TurnFileFacts.init(url:))
        }.value
        guard !found.isEmpty else { return nil }
        return CapabilityResultTable(
            capabilityID: "turn.files",
            title: "Files",
            rows: found.map { facts in
                CapabilityResultRow(
                    id: facts.url.path,
                    title: facts.name,
                    subtitle: facts.folder,
                    detail: facts.detail,
                    paths: [facts.url])
            })
    }
}

/// What a card says about one file, read off the main thread.
nonisolated struct TurnFileFacts: Sendable {
    let url: URL
    let name: String
    /// The folder it sits in, with the home folder as `~`.
    let folder: String
    /// "PDF document · 1.2 MB"; a folder has no size.
    let detail: String?

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        folder = parent.hasPrefix(home + "/") || parent == home
            ? "~" + String(parent.dropFirst(home.count))
            : parent

        let values = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey,
        ])
        var parts: [String] = []
        if let kind = values?.localizedTypeDescription { parts.append(kind) }
        if values?.isDirectory != true, let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
