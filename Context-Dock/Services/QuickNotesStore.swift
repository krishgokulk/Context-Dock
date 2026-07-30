// QuickNotesStore.swift
// Context-Dock
//
// Persistent store behind the "Quick Note" Global Command (provider:notepad).
// Notes live as JSON under Application Support/Context-Dock/ — the same root the
// rest of the app's file-based config uses. Newest first.

import AppKit
import Combine
import Foundation

struct QuickNote: Identifiable, Codable {
    let id: UUID
    var text: String
    var createdAt: Date
    /// Filenames of real files the user dropped, copied into the note's storage folder
    /// (QuickNoteFiles/) — Quick Note doubles as a drop/storage box.
    var attachments: [String] = []
    /// A note owns its sidecar conversation.  Keeping this separate from `text`
    /// means an AI answer never overwrites or pollutes the editable note.
    var chatMessages: [ChatMessage] = []

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        attachments: [String] = [],
        chatMessages: [ChatMessage] = []
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.chatMessages = chatMessages
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, attachments, chatMessages
    }

    /// Old notes predate attachments and sidecar chat. Decode them losslessly.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        attachments = try values.decodeIfPresent([String].self, forKey: .attachments) ?? []
        chatMessages = try values.decodeIfPresent([ChatMessage].self, forKey: .chatMessages) ?? []
    }
}

@MainActor
final class QuickNotesStore: ObservableObject {
    static let shared = QuickNotesStore()

    @Published private(set) var notes: [QuickNote] = []

    private let fileURL: URL
    /// Folder holding the real dropped files (copies), so notes survive the originals
    /// being moved or deleted.
    let attachmentsDir: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("quicknotes.json")
        attachmentsDir = dir.appendingPathComponent("QuickNoteFiles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: attachmentsDir, withIntermediateDirectories: true)
        load()
    }

    /// Resolve a stored attachment filename to its on-disk URL.
    func attachmentURL(_ filename: String) -> URL {
        attachmentsDir.appendingPathComponent(filename)
    }

    /// Copy dropped files into the note's storage folder and attach them. Returns the
    /// note id (creating a note if none is given) so the caller can focus it.
    @discardableResult
    func attachFiles(_ urls: [URL], to id: UUID?) -> UUID? {
        let stored: [String] = urls.compactMap { src in
            guard src.isFileURL else { return nil }
            let ext = src.pathExtension
            let base = src.deletingPathExtension().lastPathComponent
            var name = src.lastPathComponent
            var dest = attachmentsDir.appendingPathComponent(name)
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                dest = attachmentsDir.appendingPathComponent(name)
                n += 1
            }
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                return name
            } catch { return nil }
        }
        guard !stored.isEmpty else { return id }
        let targetID = id ?? create()
        guard let idx = notes.firstIndex(where: { $0.id == targetID }) else { return targetID }
        notes[idx].attachments.append(contentsOf: stored)
        save()
        return targetID
    }

    /// Remove one attachment (and delete its stored copy).
    func removeAttachment(_ filename: String, from id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].attachments.removeAll { $0 == filename }
        try? FileManager.default.removeItem(at: attachmentURL(filename))
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([QuickNote].self, from: data)
        else { return }
        notes = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        notes.insert(QuickNote(text: trimmed), at: 0)
        save()
        return true
    }

    /// Create a blank note and return its id, for immediate editing.
    @discardableResult
    func create() -> UUID {
        let note = QuickNote(text: "")
        notes.insert(note, at: 0)
        save()
        return note.id
    }

    /// Live text edit from the split editor. Keeps position/order (does not bump
    /// createdAt), so the row you're editing doesn't jump under the cursor.
    func updateText(_ text: String, for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].text = text
        save()
    }

    func appendChatMessage(_ message: ChatMessage, for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].chatMessages.append(message)
        save()
    }

    func delete(_ note: QuickNote) {
        deleteAttachmentFiles(note.attachments)
        notes.removeAll { $0.id == note.id }
        save()
    }

    func delete(id: UUID) {
        if let note = notes.first(where: { $0.id == id }) {
            deleteAttachmentFiles(note.attachments)
        }
        notes.removeAll { $0.id == id }
        save()
    }

    private func deleteAttachmentFiles(_ filenames: [String]) {
        for name in filenames {
            try? FileManager.default.removeItem(at: attachmentURL(name))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
