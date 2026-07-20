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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.yellow.opacity(0.9)).frame(width: 9, height: 9)
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

            Divider().opacity(0.4)

            if store.notes.contains(where: { $0.id == noteID }) {
                TextEditor(text: binding)
                    .focused($focused)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
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

    private var stickyBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.20, green: 0.19, blue: 0.10), Color(red: 0.16, green: 0.15, blue: 0.08)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(Color.yellow.opacity(0.04))
    }
}
