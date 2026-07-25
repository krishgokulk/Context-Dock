// StickyNoteWindow.swift
// Context-Dock
//
// Pins a Quick Note into its own floating Stickies-style window: always on top,
// visible on every Space, and non-activating so it never steals focus from
// Context-Dock or whatever app you're working in. Content is bound live to
// QuickNotesStore, so edits in the sticky and in the Quick Note scope stay in sync.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StickyNotesManager {
    static let shared = StickyNotesManager()

    private var windows: [UUID: NSWindow] = [:]

    private init() {}

    func isPinned(_ id: UUID) -> Bool { windows[id] != nil }

    /// Tab labels come from NSWindow.title — keep it in sync with the note heading.
    func updateTitle(_ id: UUID, to title: String) {
        windows[id]?.title = title.isEmpty ? "Note" : title
    }

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
        // Transparent window so the SwiftUI Liquid Glass material shows the desktop
        // behind it — otherwise the opaque panel renders the material as solid black.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Hide ALL native window buttons — the SwiftUI header carries its own title and
        // × so the native traffic lights don't float detached over the glass.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // No native window tabbing: the system tab bar is opaque and square, clashing
        // with the borderless glass sticky. Each note is its own clean glass panel.
        panel.tabbingMode = .disallowed

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
                // New note → opens in its own sticky window (a new "tab").
                Button {
                    let id = store.create()
                    StickyNotesManager.shared.pin(id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New note in a new window")
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear { StickyNotesManager.shared.updateTitle(noteID, to: title) }
        .onChange(of: title) { _, newTitle in
            StickyNotesManager.shared.updateTitle(noteID, to: newTitle)
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

    /// Follows the app's Appearance settings (Liquid Glass + Glass Darkness) so a
    /// sticky reads as part of Context-Dock, not a yellow Stickies sheet.
    private var stickyBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.10 + 0.45 * settings.glassDarkness))
    }
}
