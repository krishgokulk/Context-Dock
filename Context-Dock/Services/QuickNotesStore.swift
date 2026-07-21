// QuickNotesStore.swift
// Context-Dock
//
// Persistent store behind the "Quick Note" Global Command (provider:notepad).
// Notes live as JSON under Application Support/Context-Dock/ — the same root the
// rest of the app's file-based config uses. Newest first.

import AppKit
import Combine
import Foundation

struct QuickNote: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

@MainActor
final class QuickNotesStore: ObservableObject {
    static let shared = QuickNotesStore()

    @Published private(set) var notes: [QuickNote] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("quicknotes.json")
        load()
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

    func delete(_ note: QuickNote) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
