// NotepadScopeView.swift
// Context-Dock
//
// The in-sheet surface for the "Quick Note" (provider:notepad) Global Command.
// A split panel: notes list on the left (delete inline), a live editor on the
// right — type to edit or update the selected note, saved as you go.

import SwiftUI

struct NotepadScopeView: View {
    @ObservedObject var store = QuickNotesStore.shared
    @Binding var selectedNoteID: UUID?
    var isDark: Bool
    var isGenerating: Bool = false
    var aiProviderName: String = "AI"
    var onExit: () -> Void

    @FocusState private var editorFocused: Bool
    @State private var hoveredNoteID: UUID?

    private var accent: Color { .indigo }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 300)
            Divider()
            editorColumn
                .frame(maxWidth: .infinity)
        }
        .frame(height: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.clear)
        )
        .onAppear {
            if selectedNoteID == nil { selectedNoteID = store.notes.first?.id }
        }
    }

    // MARK: - Left: notes list

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NOTES")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                Spacer()
                Button {
                    let id = store.create()
                    selectedNoteID = id
                    editorFocused = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if store.notes.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No notes yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.notes) { note in
                            noteRow(note)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func noteRow(_ note: QuickNote) -> some View {
        let isSelected = selectedNoteID == note.id
        let isHovered = hoveredNoteID == note.id
        let title = firstLine(note.text)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "New Note" : title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(relativeDate(note.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isHovered || isSelected {
                Button(role: .destructive) {
                    let wasSelected = selectedNoteID == note.id
                    store.delete(id: note.id)
                    if wasSelected { selectedNoteID = store.notes.first?.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(5)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? accent.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : .clear))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedNoteID = note.id
            editorFocused = true
        }
        .onHover { hoveredNoteID = $0 ? note.id : (hoveredNoteID == note.id ? nil : hoveredNoteID) }
    }

    // MARK: - Right: editor

    @ViewBuilder
    private var editorColumn: some View {
        if let id = selectedNoteID, store.notes.contains(where: { $0.id == id }) {
            VStack(spacing: 0) {
                TextEditor(text: editorBinding(for: id))
                    .focused($editorFocused)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color.clear)
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("Asking \(aiProviderName)…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(accent.opacity(0.10))
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("Select a note, or press ⌘N for a new one")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == id })?.text ?? "" },
            set: { store.updateText($0, for: id) }
        )
    }

    // MARK: - Helpers

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
