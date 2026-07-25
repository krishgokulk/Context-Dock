// StickyNoteWindow.swift
// Context-Dock
//
// Pins Quick Notes into ONE floating Stickies-style glass window: always on top,
// visible on every Space, non-activating so it never steals focus. Multiple notes
// live as custom in-app tabs inside that single window (the native NSWindow tab bar
// is opaque and square, so it's replaced with a glass tab strip). Content is bound
// live to QuickNotesStore, so edits in the sticky and the Quick Note scope stay in sync.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StickyNotesManager: ObservableObject {
    static let shared = StickyNotesManager()

    /// Notes currently open as tabs, in tab order.
    @Published private(set) var openNoteIDs: [UUID] = []
    /// The tab shown in the editor.
    @Published var activeNoteID: UUID?

    private var panel: NSPanel?

    private init() {}

    func isPinned(_ id: UUID) -> Bool { openNoteIDs.contains(id) }

    /// Open the note as a tab if closed; otherwise close that tab.
    func toggle(_ id: UUID) {
        if openNoteIDs.contains(id) { closeTab(id) } else { pin(id) }
    }

    /// Open (or focus) a note as a tab in the single sticky window.
    func pin(_ id: UUID) {
        ensureWindow()
        if !openNoteIDs.contains(id) { openNoteIDs.append(id) }
        activeNoteID = id
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    /// New blank note → new tab.
    func newTab() {
        pin(QuickNotesStore.shared.create())
    }

    /// Close one tab; closes the whole window when the last tab goes.
    func closeTab(_ id: UUID) {
        guard let idx = openNoteIDs.firstIndex(of: id) else { return }
        openNoteIDs.remove(at: idx)
        if activeNoteID == id {
            activeNoteID = openNoteIDs[safe: idx] ?? openNoteIDs.last
        }
        if openNoteIDs.isEmpty { panel?.close() }
    }

    func closeWindow() { panel?.close() }

    /// Close the tab of a note that was deleted from the store.
    func closeIfOpen(_ id: UUID) { closeTab(id) }

    private func ensureWindow() {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 340),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        // Transparent window so the SwiftUI Liquid Glass material shows the desktop
        // behind it — otherwise the opaque panel renders the material as solid black.
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        // Hide native window buttons + tabbing — the SwiftUI header/tab strip owns all
        // of it, so nothing opaque or square floats over the glass.
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.tabbingMode = .disallowed

        p.contentView = NSHostingView(rootView: StickyRootView())

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.minX + 60, y: f.maxY - 60))
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel = nil
                self?.openNoteIDs = []
                self?.activeNoteID = nil
            }
        }

        panel = p
        p.orderFrontRegardless()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Root (tab strip + active note)

private struct StickyRootView: View {
    @ObservedObject private var manager = StickyNotesManager.shared
    @ObservedObject private var store = QuickNotesStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            if let active = manager.activeNoteID {
                StickyNoteContent(noteID: active)
                    .id(active)
            } else {
                Color.clear
            }
        }
        .background(stickyBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // One glass chip per open note. A single tab reads as a plain title.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.openNoteIDs, id: \.self) { id in
                        tabChip(id)
                    }
                }
            }

            Spacer(minLength: 4)

            Button { manager.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New note tab")

            Button { manager.closeWindow() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close notes")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func tabChip(_ id: UUID) -> some View {
        let isActive = manager.activeNoteID == id
        let single = manager.openNoteIDs.count == 1
        return HStack(spacing: 4) {
            Text(tabTitle(id))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            if !single {
                Button { manager.closeTab(id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, single ? 0 : 8)
        .padding(.vertical, single ? 0 : 3)
        .background(
            Group {
                if !single {
                    Capsule().fill(Color.white.opacity(isActive ? 0.14 : 0.05))
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { manager.activeNoteID = id }
        .frame(maxWidth: single ? .infinity : 140, alignment: .leading)
    }

    private func tabTitle(_ id: UUID) -> String {
        let text = store.notes.first(where: { $0.id == id })?.text ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Note" : firstLine
    }

    /// Follows the app's Appearance settings (Liquid Glass + Glass Darkness) so a
    /// sticky reads as part of Context-Dock, not a yellow Stickies sheet.
    private var stickyBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.10 + 0.45 * settings.glassDarkness))
    }
}

// MARK: - Single note (editor + AI composer)

private struct StickyNoteContent: View {
    let noteID: UUID

    @ObservedObject private var store = QuickNotesStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var focused: Bool
    @State private var prompt: String = ""
    @State private var isGenerating = false

    var body: some View {
        Group {
            if store.notes.contains(where: { $0.id == noteID }) {
                VStack(spacing: 0) {
                    TextEditor(text: binding)
                        .focused($focused)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                    composer
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 18))
                    Text("Note deleted").font(.system(size: 12))
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// ChatGPT-style composer pinned to the bottom: type a prompt, Return sends it
    /// to the selected AI provider and appends the reply into this note.
    private var composer: some View {
        HStack(spacing: 8) {
            // Same attach menu the Quick Note scope offers.
            Menu {
                Button(action: attachFrontmostWindow) {
                    Label("Attach Frontmost Window", systemImage: "macwindow")
                }
                Divider()
                Button { attachFile(imagesOnly: true) } label: {
                    Label("Upload Photo", systemImage: "photo")
                }
                Button { captureScreen(interactive: false) } label: {
                    Label("Take Screenshot", systemImage: "camera.viewfinder")
                }
                Button { captureScreen(interactive: true) } label: {
                    Label("Capture Area", systemImage: "crop")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach context")
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

    private var binding: Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == noteID })?.text ?? "" },
            set: { store.updateText($0, for: noteID) }
        )
    }

    private func append(_ text: String) {
        let existing = store.notes.first(where: { $0.id == noteID })?.text ?? ""
        store.updateText(existing.isEmpty ? text : existing + "\n" + text, for: noteID)
    }

    private func attachFile(imagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = imagesOnly ? [.image] : [.image, .pdf, .plainText, .data]
        panel.message = "Attach files to this note"
        guard panel.runModal() == .OK else { return }
        let lines = panel.urls.map { "\($0.lastPathComponent) — \($0.path)" }
            .joined(separator: "\n")
        guard !lines.isEmpty else { return }
        append(lines)
    }

    private func captureScreen(interactive: Bool) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-dock-shot-\(UUID().uuidString).png")
        var args = interactive ? ["-i"] : ["-x"]
        args.append(url.path)
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
            } catch { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            await MainActor.run { append("Screenshot — \(url.path)") }
        }
    }

    private func attachFrontmostWindow() {
        let ctx = AXContextReader.shared.current
        let name = ctx.appName.isEmpty ? "Frontmost app" : ctx.appName
        var parts = ["Frontmost app: \(name)"]
        if let title = ctx.windowTitle, !title.isEmpty { parts.append("Window: \(title)") }
        if let url = ctx.currentURL, !url.isEmpty { parts.append("URL: \(url)") }
        if let sel = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty
        {
            parts.append("Selected text:\n\(sel)")
        }
        append(parts.joined(separator: "\n"))
    }
}
