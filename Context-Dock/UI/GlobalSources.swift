// GlobalSources.swift
// Context-Dock
//
// S4 of the smarter-search plan (owner 2026-10-17: "clipboard, knowledge, notification…
// more power but it's not united yet"): what DoraX keeps itself — the clipboard's history,
// quick notes and its own notifications — answers in Global Context's one list, each in a
// section of its own after the apps, menus and pages, so those results stay as they are.

import AppKit

enum GlobalSources {
    static let clipKind = "globalClip"
    static let noteKind = "globalNote"
    static let notificationKind = "globalNotification"
    static let kinds: Set<String> = [clipKind, noteKind, notificationKind]

    static let clipboard = "Clipboard"
    static let notes = "Notes"
    static let notifications = "Notifications"

    /// The words that name a source rather than say what is in it.
    private static let clipWords: Set<String> = ["clipboard", "clip", "clips", "copied", "copy"]
    private static let noteWords: Set<String> = ["note", "notes", "quick"]
    private static let notificationWords: Set<String> = ["notification", "notifications", "alert", "alerts"]
    /// How many of each source the list is offered; the section's own cap shows five.
    static let limit = 10

    /// The rows for what is typed: each item holding every asked word, or — when the words
    /// only name a source ("clipboard") — that source's newest. Nothing for a lone letter.
    static func rows(
        query: String,
        clips: [DockCore.ClipboardEntry],
        notes quickNotes: [QuickNote],
        notifications sent: [ILauncherNotification],
        now: Date = Date(),
        within range: DateInterval? = nil,
        copy: @escaping (DockCore.ClipboardEntry) -> Void,
        openNote: @escaping (QuickNote) -> Void,
        openNotification: @escaping (ILauncherNotification) -> Void
    ) -> [AppChatRow] {
        let typed = Set(GlobalQuery.words(query))
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let sourceWords = clipWords.union(noteWords).union(notificationWords)
        let asked = GlobalQuery.askedWords(in: query, appNames: []).filter { !sourceWords.contains($0) }

        func matching<T>(
            _ all: [T], names: Set<String>, date: (T) -> Date, text: (T) -> String
        ) -> [T] {
            // "copied yesterday": the time first, so the newest ten are yesterday's (S3).
            let items = range.map { range in all.filter { range.contains(date($0)) } } ?? all
            if asked.isEmpty {
                return typed.isDisjoint(with: names) ? [] : Array(items.prefix(limit))
            }
            return Array(items.filter { item in
                let hay = GlobalQuery.words(text(item))
                return asked.allSatisfy { word in hay.contains { $0.hasPrefix(word) } }
            }.prefix(limit))
        }

        let clipRows = matching(clips, names: clipWords, date: \.timestamp, text: clipText).map { entry in
            pill(
                "clip-\(entry.id)", firstLine(clipText(entry)), "doc.on.clipboard", clipKind, clipboard,
                context: ["Copied " + ago(entry.timestamp, now), entry.sourceAppName]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                bundleID: entry.sourceBundleId, date: entry.timestamp
            ) { copy(entry) }
        }
        let noteRows = matching(quickNotes, names: noteWords, date: \.createdAt) { $0.text }.map { note in
            pill(
                "note-\(note.id)", firstLine(note.text), "note.text", noteKind, notes,
                context: "Quick note · " + ago(note.createdAt, now), date: note.createdAt
            ) { openNote(note) }
        }
        let notificationRows = matching(sent, names: notificationWords, date: \.date) { "\($0.title) \($0.body)" }
            .map { item in
                pill(
                    "notification-\(item.id)", item.title, item.icon, notificationKind, notifications,
                    context: [item.body, ago(item.date, now)].filter { !$0.isEmpty }
                        .joined(separator: " · "),
                    date: item.date
                ) { openNotification(item) }
            }
        return (clipRows + noteRows + notificationRows).map(AppChatRow.dock)
    }

    /// What a clip can be found by: its text, else the names of its files, else what was
    /// read off its image.
    static func clipText(_ entry: DockCore.ClipboardEntry) -> String {
        if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return entry.text }
        if !entry.filePaths.isEmpty {
            return entry.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
        return entry.ocrText.isEmpty ? "Image" : entry.ocrText
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    private static func ago(_ date: Date, _ now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func pill(
        _ id: String, _ name: String, _ symbol: String, _ kind: String, _ section: String,
        context: String, bundleID: String = "", date: Date? = nil, execute: @escaping () -> Void
    ) -> DockPill {
        var pill = DockPill(id: id, name: name, icon: symbol, badge: nil, execute: execute)
        pill.rankingKind = kind
        pill.resultSection = section
        pill.menuContext = context
        pill.sourceBundleId = bundleID
        pill.date = date
        return pill
    }
}
