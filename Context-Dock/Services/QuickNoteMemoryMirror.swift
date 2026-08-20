//
//  QuickNoteMemoryMirror.swift
//  Context-Dock
//
//  Quick Note is where things get captured; memory is where they get found. Until this
//  existed the two never met — a note lived in quicknotes.json, which nothing reads but
//  the Quick Note UI, so writing something down made it *less* reachable than saying it
//  in a chat, where at least `remember that` would file it.
//
//  The mirror is one-directional on purpose. The JSON stays the record the editor writes
//  to, and the markdown is a derived view kept in step with it. Two writers over one
//  document is how notes get lost, and a note the user typed is the last thing that
//  should be resolved by a merge.
//

import Foundation

@MainActor
enum QuickNoteMemoryMirror {
    /// Notes shorter than this are almost always a stray keystroke or a half-typed
    /// thought that was abandoned — mirroring them fills memory with noise that then
    /// competes with real notes for room in the prompt.
    private static let minimumLength = 12

    static func sync(_ notes: [QuickNote]) {
        let folder = MarkdownMemoryStore.shared.notesFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var written = Set<String>()
        let appNames = AppAdapterManager.shared.adapters.map { ($0.appName, $0.bundleId) }
        // Folders the user has actually scoped a chat to. Matching against these rather
        // than against any path-looking string keeps the link real: a note that says
        // "Downloads" only links to a folder the user works in, not to the word.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders: [(name: String, path: String)] = GeneralChatSessionStore.index()
            .compactMap { session in
                guard let url = session.scope.folderURL else { return nil }
                let path = url.path
                // The home folder and the root are scopes people really do open a chat on,
                // and they are useless as links: the account name appears in every absolute
                // path a note ever quotes, so every note would link to home and the graph
                // would gain one hub that means nothing.
                guard path != home, path != "/" else { return nil }
                let name = url.lastPathComponent
                return name.count >= 4 ? (name, path) : nil
            }

        for note in notes {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumLength else { continue }
            let filename = self.filename(for: note)
            written.insert(filename)
            let url = folder.appendingPathComponent(filename)
            let markdown = self.markdown(
                for: note, text: text, appNames: appNames, folders: folders)
            // Only write when the content actually changed: this runs after every edit,
            // and rewriting an unchanged file churns modification dates that the daily
            // brief and the dashboard both read as activity.
            let existing = try? String(contentsOf: url, encoding: .utf8)
            guard existing != markdown else { continue }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }

        // A note deleted in the editor has to disappear here too, or memory keeps
        // answering with something the user has already thrown away.
        let stale = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && !written.contains($0.lastPathComponent) }
        for url in stale {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Rendering

    private static func markdown(
        for note: QuickNote,
        text: String,
        appNames: [(String, String)],
        folders: [(name: String, path: String)]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var lines = [
            "# \(title(from: text))",
            "",
            "> Quick Note · captured \(formatter.string(from: note.createdAt))",
            "",
            text,
        ]

        // Apps the note names get linked to their own memory file, which is what turns a
        // pile of notes into something with a shape — the same mechanic as a wiki link,
        // resolved against adapters the user actually has rather than against free text.
        let mentioned = appNames.filter { name, _ in
            !name.isEmpty && text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let mentionedFolders = folders.filter { folder in
            text.range(of: folder.name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let links = mentioned.map { "[[apps/\($0.1)]]" }
            + mentionedFolders.map { "[[folders/\($0.path)]]" }
        if !links.isEmpty {
            lines.append("")
            lines.append("Related: " + links.joined(separator: " "))
        }

        if !note.attachments.isEmpty {
            lines.append("")
            lines.append("Attachments: " + note.attachments.joined(separator: ", "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The first line, which is how people title a note whether or not they meant to.
    private static func title(from text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Note"
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// Id first so a retitled note keeps its file instead of leaving an orphan behind,
    /// slug second so the folder is readable when opened outside the app.
    private static func filename(for note: QuickNote) -> String {
        let slug = title(from: note.text)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = note.id.uuidString.prefix(8).lowercased()
        return slug.isEmpty ? "\(prefix).md" : "\(prefix)-\(slug.prefix(48)).md"
    }
}
