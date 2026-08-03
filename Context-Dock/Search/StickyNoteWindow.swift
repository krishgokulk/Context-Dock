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

/// The floating-glass panel Quick Note uses. Extracted so other surfaces (user
/// extension panels) inherit exactly the same behaviour — always on top, on every
/// Space, non-activating, resizable, transparent for Liquid Glass — instead of each
/// re-deriving a subtly different window.
@MainActor
enum GlassFloatingPanel {
    static func make(size: NSSize, minSize: NSSize) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        p.minSize = minSize
        // Hide native window buttons + tabbing — the SwiftUI header owns all of it, so
        // nothing opaque or square floats over the glass.
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.tabbingMode = .disallowed
        return p
    }
}

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

        let p = GlassFloatingPanel.make(
            size: NSSize(width: 820, height: 520),
            minSize: NSSize(width: 620, height: 380)
        )
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
            // New note lives at the leading edge; the controls that act on the whole
            // window group together on the right, matching the extension panels.
            Button { manager.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note tab")

            // One glass chip per open note. A single tab reads as a plain title.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.openNoteIDs, id: \.self) { id in
                        tabChip(id)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("Pinned — notes stay open until closed")

            Button { settings.quickNoteAISidecarVisible.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(settings.quickNoteAISidecarVisible
                                     ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(settings.quickNoteAISidecarVisible ? "Hide assistant" : "Show assistant")

            Button { manager.closeWindow() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
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

// MARK: - Single note (editor + sidecar AI conversation)

private struct StickyNoteContent: View {
    let noteID: UUID

    @ObservedObject private var store = QuickNotesStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("quickNoteAIChatWidth") private var aiChatWidth = 330.0
    @State private var prompt: String = ""
    @State private var isGenerating = false

    var body: some View {
        Group {
            if store.notes.contains(where: { $0.id == noteID }) {
                GeometryReader { proxy in
                    let showsChat = settings.quickNoteAISidecarVisible
                    let chatWidth = showsChat ? sidePaneWidth(for: proxy.size.width) : 0
                    let editorWidth = showsChat
                        ? max(310, proxy.size.width - chatWidth - 8)
                        : proxy.size.width
                    HStack(spacing: 0) {
                        notePane(width: editorWidth)
                        // Hiding the assistant gives the whole window back to the note.
                        if showsChat {
                            StickySplitDivider(
                                width: $aiChatWidth,
                                maximumWidth: max(260, min(480, proxy.size.width - 310))
                            )
                            chatPane(width: chatWidth)
                        }
                    }
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

    private func notePane(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            StickyAttachmentEditor(
                text: binding,
                onReceiveAttachments: attachFiles
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleFileDrop(providers)
                return true
            }
            attachmentStrip
        }
        .frame(minWidth: width, idealWidth: width, maxWidth: width, maxHeight: .infinity)
    }

    private func chatPane(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Ask AI")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(settings.selectedAIProvider.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.35)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if chatMessages.isEmpty && !isGenerating {
                            ContentUnavailableView {
                                Label("Ask about this note", systemImage: "text.bubble")
                            } description: {
                                Text("The note text and attached file names are included as context.")
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, minHeight: 160)
                        }

                        ForEach(chatMessages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }

                        if isGenerating {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .id("thinking")
                        }
                    }
                    .padding(10)
                }
                .onChange(of: chatMessages.count) { _, _ in
                    guard let last = chatMessages.last else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: isGenerating) { _, generating in
                    if generating {
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
            }

            chatComposer
        }
        .frame(minWidth: width, idealWidth: width, maxWidth: width, maxHeight: .infinity)
    }

    private func sidePaneWidth(for availableWidth: CGFloat) -> CGFloat {
        let maximum = max(260, min(480, availableWidth - 310))
        return min(max(CGFloat(aiChatWidth), 260), maximum)
    }

    private var chatMessages: [ChatMessage] {
        store.notes.first(where: { $0.id == noteID })?.chatMessages ?? []
    }

    private func chatBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.content)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !isUser {
                    // The model never edits notes itself — every write is one of these
                    // explicit choices, so a wrong answer can't destroy what's written.
                    HStack(spacing: 12) {
                        Button("Add to note") { appendToNote(message.content) }
                        Button("New note") { createNote(from: message.content) }
                        Button("Replace") { replaceNote(with: message.content) }
                            .foregroundStyle(.orange)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isUser ? Color.accentColor.opacity(0.78) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            if !isUser { Spacer(minLength: 18) }
        }
    }

    private func appendToNote(_ text: String) {
        let existing = store.notes.first(where: { $0.id == noteID })?.text ?? ""
        store.updateText(existing.isEmpty ? text : existing + "\n\n" + text, for: noteID)
    }

    /// Put the reply into a brand-new note and open it as its own tab, leaving the
    /// note the user was working in untouched.
    private func createNote(from text: String) {
        let id = store.create()
        store.updateText(text, for: id)
        StickyNotesManager.shared.pin(id)
    }

    /// Overwrite this note with the reply. Destructive, so it is never automatic —
    /// only ever the user pressing Replace.
    private func replaceNote(with text: String) {
        store.updateText(text, for: noteID)
    }

    /// Composer stays inside the sidecar, so typing to AI never changes the note.
    private var chatComposer: some View {
        HStack(spacing: 8) {
            Menu {
                Button(action: attachFrontmostWindow) {
                    Label("Attach Frontmost Window", systemImage: "macwindow")
                }
                Divider()
                Button { attachFile(imagesOnly: true) } label: {
                    Label("Upload Photo", systemImage: "photo")
                }
                Button { attachFile(imagesOnly: false) } label: {
                    Label("Attach Files…", systemImage: "paperclip")
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
            .help("Attach to note")

            TextField("Ask AI…", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { send() }
                .disabled(isGenerating)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(
                        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        prompt = ""
        store.appendChatMessage(ChatMessage(role: .user, content: text), for: noteID)
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
                    apiKey: key.isEmpty ? nil : key,
                    conversationHistory: Array(chatMessages.dropLast()),
                    additionalContextPrompt: noteContext,
                    attachments: noteAttachments,
                    surfaceScoped: true
                )
            } catch {
                reply = "⚠️ AI error: \(error.localizedDescription)"
            }
            let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            store.appendChatMessage(ChatMessage(role: .assistant, content: body), for: noteID)
            isGenerating = false
        }
    }

    private var noteContext: String {
        let note = store.notes.first(where: { $0.id == noteID })
        let text = note?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filenames = note?.attachments ?? []
        var parts = ["""
        You are the assistant inside a Quick Note. Your ONLY domain is this user's notes: \
        writing them, editing them, summarising them, answering questions about them.

        You cannot run shell commands, open apps, browse the web or touch files. Never emit \
        directives like [TERMINAL_COMMAND: …] or any other bracketed command protocol — \
        those belong to a different surface and do nothing here. If a request needs any of \
        that, say plainly that it's outside a note and offer the note-shaped alternative.

        When the user asks for note content, reply with the content itself and nothing else \
        — no preamble, no "here's your note". The user gets buttons to create a new note or \
        add your reply to the current one, so your whole reply should be exactly what they'd \
        want written down.

        Never rewrite the note silently; the user decides via those buttons.
        """]
        if !text.isEmpty { parts.append("Current note:\n\(text)") }
        if !filenames.isEmpty { parts.append("Attached files: \(filenames.joined(separator: ", "))") }
        return parts.joined(separator: "\n\n")
    }

    private var noteAttachments: [AIAttachment] {
        let filenames = store.notes.first(where: { $0.id == noteID })?.attachments ?? []
        return filenames.map { AIAttachment.inferred(from: store.attachmentURL($0)) }
    }

    private var binding: Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == noteID })?.text ?? "" },
            set: { store.updateText($0, for: noteID) }
        )
    }

    /// Every non-text item is copied into QuickNoteFiles before it is shown.  The note
    /// therefore keeps a real, independent copy rather than a transient file:// string.
    private func attachFiles(_ urls: [URL]) {
        _ = store.attachFiles(urls, to: noteID)
    }

    private func attachFile(imagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = !imagesOnly
        panel.allowsMultipleSelection = true
        // A sticky note is a storage box: non-photo attachment picks deliberately
        // accept every document type (and folders), not only the handful of types
        // an AI provider can directly inspect.
        if imagesOnly { panel.allowedContentTypes = [.image] }
        panel.message = "Attach files to this note"
        guard panel.runModal() == .OK else { return }
        attachFiles(panel.urls)
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
            await MainActor.run { attachFiles([url]) }
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
        let text = parts.joined(separator: "\n")
        let existing = store.notes.first(where: { $0.id == noteID })?.text ?? ""
        store.updateText(existing.isEmpty ? text : existing + "\n" + text, for: noteID)
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        let attachments = store.notes.first(where: { $0.id == noteID })?.attachments ?? []
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments, id: \.self) { name in
                        let url = store.attachmentURL(name)
                        HStack(spacing: 5) {
                            // A screenshot chip showed the generic PNG glyph, so a note
                            // full of captures was a column of identical icons. Same
                            // QuickLook thumbnail the dock rows use.
                            FileThumbnailImage(
                                filePath: url.path,
                                fallbackImage: NSWorkspace.shared.icon(forFile: url.path),
                                systemName: "doc",
                                tint: .secondary,
                                size: 16,
                                cornerRadius: 3
                            )
                            .frame(width: 16, height: 16)
                            Text(name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 130, alignment: .leading)
                            Button {
                                store.removeAttachment(name, from: noteID)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .help(url.path)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { attachFiles(urls) }
    }
}

/// A real AppKit tracking view prevents a panel's draggable background from stealing
/// a divider drag. SwiftUI owns the persisted width; AppKit only handles the mouse.
/// Draggable split divider. Shared with the extension panels so every split
/// in the app resizes the same way.
struct StickySplitDivider: NSViewRepresentable {
    @Binding var width: Double
    var maximumWidth: CGFloat
    /// A hardcoded floor inverted the clamp on a narrow panel — max fell below it and
    /// the pane locked to one width. Callers state their own minimum.
    var minimumWidth: CGFloat = 260

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.update(width: width, maximumWidth: maximumWidth,
                    minimumWidth: minimumWidth, binding: $width)
        return view
    }

    func updateNSView(_ view: DividerView, context: Context) {
        view.update(width: width, maximumWidth: maximumWidth,
                    minimumWidth: minimumWidth, binding: $width)
    }

    final class DividerView: NSView {
        private var startingWidth: Double = 330
        private var startingMouseX: CGFloat = 0
        private var maximumWidth: CGFloat = 480
        private var minimumWidth: CGFloat = 260
        private var binding: Binding<Double>?

        override var mouseDownCanMoveWindow: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.withAlphaComponent(0.55).setFill()
            NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        func update(width: Double, maximumWidth: CGFloat,
                    minimumWidth: CGFloat = 260, binding: Binding<Double>) {
            self.maximumWidth = maximumWidth
            self.minimumWidth = minimumWidth
            self.binding = binding
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            startingWidth = binding?.wrappedValue ?? 330
            startingMouseX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            let proposed = startingWidth - Double(event.locationInWindow.x - startingMouseX)
            let lower = Double(minimumWidth)
            let upper = max(lower, Double(maximumWidth))
            binding?.wrappedValue = min(max(proposed, lower), upper)
        }
    }
}

/// A small AppKit bridge for the one capability TextEditor lacks: converting a file
/// or image pasted with Cmd-V into a note attachment instead of inserting its file URL
/// as prose.  SwiftUI owns the note text; AppKit only normalises the pasteboard boundary.
private struct StickyAttachmentEditor: NSViewRepresentable {
    @Binding var text: String
    var onReceiveAttachments: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = StickyAttachmentTextView()
        textView.delegate = context.coordinator
        textView.attachmentHandler = onReceiveAttachments
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.registerForDraggedTypes([.fileURL, .URL])

        let scrollView = StickyAttachmentScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.attachmentHandler = onReceiveAttachments
        scrollView.registerForDraggedTypes([.fileURL, .URL])
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? StickyAttachmentTextView else { return }
        textView.attachmentHandler = onReceiveAttachments
        (scrollView as? StickyAttachmentScrollView)?.attachmentHandler = onReceiveAttachments
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StickyAttachmentEditor
        init(parent: StickyAttachmentEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }
    }
}

private final class StickyAttachmentTextView: NSTextView {
    var attachmentHandler: (([URL]) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter(\.isFileURL)
        if !fileURLs.isEmpty {
            attachmentHandler?(fileURLs)
            return
        }
        if let image = NSImage(pasteboard: pasteboard), let stagedURL = stage(image: image) {
            attachmentHandler?([stagedURL])
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggedFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        attachmentHandler?(urls)
        return true
    }

    private func draggedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter(\.isFileURL)
    }

    private func stage(image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextDockStickyPaste-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// `NSTextView` shrinks to the text it contains. This companion scroll view owns
/// Finder drops over the rest of the empty editor area, which is where users most
/// naturally drop files into a new note.
private final class StickyAttachmentScrollView: NSScrollView {
    var attachmentHandler: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggedFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        attachmentHandler?(urls)
        return true
    }
}

private func draggedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
        .filter(\.isFileURL)
}
