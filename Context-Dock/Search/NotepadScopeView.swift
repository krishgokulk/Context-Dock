// NotepadScopeView.swift
// Context-Dock
//
// The in-sheet surface for the "Quick Note" (provider:notepad) Global Command.
// A split panel: notes list on the left (delete inline), a live editor on the
// right — type to edit or update the selected note, saved as you go.

import SwiftUI
import UniformTypeIdentifiers

struct NotepadScopeView: View {
    @ObservedObject var store = QuickNotesStore.shared
    @Binding var selectedNoteID: UUID?
    var isDark: Bool
    var isGenerating: Bool = false
    var aiProviderName: String = "AI"
    var frontmostLabel: String? = nil
    var hasCapturedText: Bool = false
    var attachments: [URL] = []
    var onAttachFrontmost: () -> Void = {}
    var onUploadPhoto: () -> Void = {}
    var onTakeScreenshot: () -> Void = {}
    var onCaptureArea: () -> Void = {}
    var onCaptureText: () -> Void = {}
    var onRemoveCapturedText: () -> Void = {}
    var onRemoveAttachment: (URL) -> Void = { _ in }
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
            HStack(spacing: 8) {
                Text("NOTES")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                Spacer()
                // Attach context for the next AI prompt: frontmost window, photo,
                // full screenshot, or a captured region.
                Menu {
                    Button(action: onAttachFrontmost) {
                        Label(
                            frontmostLabel == nil
                                ? "Attach Frontmost Window" : "Detach \(frontmostLabel!)",
                            systemImage: "macwindow")
                    }
                    Divider()
                    Button(action: onUploadPhoto) { Label("Upload Photo", systemImage: "photo") }
                    Button(action: onTakeScreenshot) {
                        Label("Take Screenshot", systemImage: "camera.viewfinder")
                    }
                    Button(action: onCaptureArea) { Label("Capture Area", systemImage: "crop") }
                    Button(action: onCaptureText) {
                        Label("Capture Text", systemImage: "text.viewfinder")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach context for AI")
                // Pin the selected note into its own floating Stickies-style window.
                if let id = selectedNoteID, store.notes.contains(where: { $0.id == id }) {
                    Button {
                        StickyNotesManager.shared.toggle(id)
                    } label: {
                        Image(systemName: StickyNotesManager.shared.isPinned(id) ? "pin.fill" : "pin")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StickyNotesManager.shared.isPinned(id) ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("Pin note as a floating window")
                }
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

            if let frontmostLabel {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Using \(frontmostLabel) for next AI prompt")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button(action: onAttachFrontmost) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.10))
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 9))
                                Text(url.lastPathComponent)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: 90)
                                Button { onRemoveAttachment(url) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            if hasCapturedText {
                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Captured text attached to next AI prompt")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button(action: onRemoveCapturedText) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.10))
            }

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
                // ↑/↓ move the selection through the whole list, so the list has to
                // follow it — without this the highlight walked off-screen and the
                // editor changed under a list that never moved.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.notes) { note in
                                noteRow(note)
                                    .id(note.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedNoteID) { _, newValue in
                        guard let newValue else { return }
                        // nil anchor scrolls the minimum distance needed, so a
                        // already-visible row does not jump to the middle.
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(newValue, anchor: nil)
                        }
                    }
                    .onAppear {
                        guard let id = selectedNoteID else { return }
                        proxy.scrollTo(id, anchor: nil)
                    }
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
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers, into: id)
                        return true
                    }
                attachmentStrip(for: id)
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

    /// File chips for a note's stored attachments: icon + name, drag out, open on tap,
    /// remove with ✕.
    @ViewBuilder
    private func attachmentStrip(for id: UUID) -> some View {
        let attachments = store.notes.first(where: { $0.id == id })?.attachments ?? []
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments, id: \.self) { name in
                        let url = store.attachmentURL(name)
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)
                            Button {
                                store.removeAttachment(name, from: id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .help(url.path)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func editorBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == id })?.text ?? "" },
            set: { store.updateText($0, for: id) }
        )
    }

    /// Dropped files are COPIED into the note's storage folder and attached — Quick
    /// Note is a real drop/storage box, not just a path list.
    private func handleDrop(_ providers: [NSItemProvider], into id: UUID) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            store.attachFiles(urls, to: id)
        }
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
