// StickyNoteWindow.swift
// Context-Dock
//
// Pins a Quick Note into its own floating Stickies-style window: always on top,
// visible on every Space, and non-activating so it never steals focus from
// Context-Dock or whatever app you're working in. Content is bound live to
// QuickNotesStore, so edits in the sticky and in the Quick Note scope stay in sync.

import AppKit
import SwiftUI

@MainActor
final class StickyNotesManager {
    static let shared = StickyNotesManager()

    private var windows: [UUID: NSWindow] = [:]

    private init() {}

    func isPinned(_ id: UUID) -> Bool { windows[id] != nil }

    /// Pin the note if it isn't already; otherwise close its sticky.
    func toggle(_ id: UUID) {
        if let existing = windows[id] {
            existing.close()
            return
        }
        pin(id)
    }

    func pin(_ id: UUID) {
        guard windows[id] == nil else {
            windows[id]?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 320),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let root = StickyNoteView(
            noteID: id,
            onClose: { [weak panel] in panel?.close() }
        )
        panel.contentView = NSHostingView(rootView: root)

        // Cascade so stacked pins don't fully overlap.
        let offset = CGFloat(windows.count % 6) * 26
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(
                NSPoint(x: f.minX + 60 + offset, y: f.maxY - 60 - offset))
        }

        // Clean up our reference when the user closes the sticky.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[id] = nil }
        }

        windows[id] = panel
        panel.orderFrontRegardless()
    }

    /// Close a sticky whose note was deleted.
    func closeIfOpen(_ id: UUID) {
        windows[id]?.close()
    }
}

private struct StickyNoteView: View {
    let noteID: UUID
    var onClose: () -> Void

    @ObservedObject private var store = QuickNotesStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var focused: Bool
    @State private var prompt: String = ""
    @State private var isGenerating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.35)

            if store.notes.contains(where: { $0.id == noteID }) {
                TextEditor(text: binding)
                    .focused($focused)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                composer
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 18))
                    Text("Note deleted").font(.system(size: 12))
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(stickyBackground)
    }

    /// ChatGPT-style composer pinned to the bottom: type a prompt, Return sends it
    /// to the selected AI provider and appends the reply into this note.
    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Ask AI…", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { send() }
                .disabled(isGenerating)
            if isGenerating {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(
                            prompt.trimmingCharacters(in: .whitespaces).isEmpty
                                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        prompt = ""
        isGenerating = true
        let provider = settings.selectedAIProvider
        let key = settings.getAPIKey(for: provider)
        Task { @MainActor in
            let reply: String
            do {
                reply = try await AIProviderService.shared.sendMessage(
                    text,
                    context: .none,
                    provider: provider,
                    apiKey: key.isEmpty ? nil : key
                )
            } catch {
                reply = "⚠️ AI error: \(error.localizedDescription)"
            }
            let existing = store.notes.first(where: { $0.id == noteID })?.text ?? ""
            let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateText(existing.isEmpty ? body : existing + "\n\n" + body, for: noteID)
            isGenerating = false
        }
    }

    private var title: String {
        let text = store.notes.first(where: { $0.id == noteID })?.text ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Note" : firstLine
    }

    private var binding: Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == noteID })?.text ?? "" },
            set: { store.updateText($0, for: noteID) }
        )
    }

    /// Match the launcher's own surface instead of a yellow Stickies sheet.
    private var stickyBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.28))
    }
}
