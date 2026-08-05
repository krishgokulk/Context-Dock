// ExtensionPanelWindow.swift
// Context-Dock
//
// Floating panel host for user-authored Global Context extensions.
//
// Shares GlassFloatingPanel with Quick Note, so an extension panel behaves exactly
// like a sticky note: always on top, visible on every Space, non-activating,
// resizable, and pinnable. Content is the extension's script-produced rows plus —
// when the author enabled it — a chat composer wired to the app's AI stack.

import AppKit
import Combine
import SwiftUI

@MainActor
final class ExtensionPanelManager: ObservableObject {
    static let shared = ExtensionPanelManager()

    /// Extensions currently open, in tab order.
    @Published private(set) var openExtensionIDs: [UUID] = []
    @Published var activeExtensionID: UUID?
    /// Pinned panels survive focus loss and the dock closing; unpinned ones close
    /// when the user moves on, matching Quick Note's pin semantics.
    @Published private(set) var pinnedExtensionIDs: Set<UUID> = []

    private var panel: NSPanel?

    private init() {}

    func isOpen(_ id: UUID) -> Bool { openExtensionIDs.contains(id) }
    func isPinned(_ id: UUID) -> Bool { pinnedExtensionIDs.contains(id) }

    func togglePin(_ id: UUID) {
        if pinnedExtensionIDs.contains(id) {
            pinnedExtensionIDs.remove(id)
        } else {
            pinnedExtensionIDs.insert(id)
        }
    }

    /// Open (or focus) an extension's panel.
    func open(_ ext: UserGlobalExtension) {
        ensureWindow()
        if !openExtensionIDs.contains(ext.id) { openExtensionIDs.append(ext.id) }
        activeExtensionID = ext.id
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func close(_ id: UUID) {
        guard let idx = openExtensionIDs.firstIndex(of: id) else { return }
        openExtensionIDs.remove(at: idx)
        pinnedExtensionIDs.remove(id)
        if activeExtensionID == id {
            activeExtensionID = openExtensionIDs.indices.contains(idx)
                ? openExtensionIDs[idx]
                : openExtensionIDs.last
        }
        if openExtensionIDs.isEmpty { panel?.close() }
    }

    func closeWindow() { panel?.close() }

    private func ensureWindow() {
        guard panel == nil else { return }

        let p = GlassFloatingPanel.make(
            size: NSSize(width: 720, height: 560),
            minSize: NSSize(width: 480, height: 360)
        )
        p.contentView = NSHostingView(rootView: ExtensionPanelRootView())

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 780, y: f.maxY - 60))
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel = nil
                self?.openExtensionIDs = []
                self?.activeExtensionID = nil
                self?.pinnedExtensionIDs = []
            }
        }

        panel = p
        p.orderFrontRegardless()
    }
}

// MARK: - Root view

struct ExtensionPanelRootView: View {
    @ObservedObject private var manager = ExtensionPanelManager.shared
    @ObservedObject private var store = UserGlobalExtensionStore.shared

    private var activeExtension: UserGlobalExtension? {
        guard let id = manager.activeExtensionID else { return nil }
        return store.extensions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let ext = activeExtension {
                ExtensionPanelContentView(ext: ext)
                    .id(ext.id)
            } else {
                Spacer()
                Text("No extension open")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let ext = activeExtension {
                Image(systemName: ext.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(ext.name)
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()

            if let ext = activeExtension {
                Button {
                    manager.togglePin(ext.id)
                } label: {
                    Image(systemName: manager.isPinned(ext.id) ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(manager.isPinned(ext.id) ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(manager.isPinned(ext.id) ? "Unpin panel" : "Pin panel — keeps it open")

                Button {
                    manager.close(ext.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Content

struct ExtensionPanelContentView: View {
    let ext: UserGlobalExtension

    @State private var rows: [UserExtensionRow] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var lastActionOutput: String?

    var body: some View {
        VStack(spacing: 0) {
            rowsSection

            if ext.aiEnabled {
                Divider().opacity(0.3)
                ExtensionPanelAIComposer(title: ext.name, subtitle: ext.description,
                                         extraPrompt: ext.aiPrompt)
                    .frame(minHeight: 180)
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var rowsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if isLoading && rows.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                }

                ForEach(rows) { row in
                    Button {
                        Task { await activate(row) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if let lastActionOutput, !lastActionOutput.isEmpty {
                    Text(lastActionOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Re-run the rows script")
        }
    }

    private func envVars() -> [String: String] {
        let ctx = AXContextReader.shared.current
        return [
            "CD_QUERY": "",
            "CD_URL": ctx.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
            "CD_TEXT": ctx.selectedText ?? "",
            "CD_APP": ctx.appName,
        ]
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        switch await UserExtensionScriptRunner.rows(for: ext, envVars: envVars()) {
        case .success(let loaded):
            rows = loaded
            loadError = nil
        case .failure(let error):
            loadError = error.message
        }
    }

    private func activate(_ row: UserExtensionRow) async {
        switch await UserExtensionScriptRunner.runRowAction(
            for: ext, row: row, envVars: envVars()
        ) {
        case .success(let output):
            lastActionOutput = output
            // Rows often describe mutable state (a toggle, a running process), so
            // re-read them rather than leaving a stale list on screen.
            await reload()
        case .failure(let error):
            lastActionOutput = "Error: \(error.message)"
        }
    }
}

// MARK: - AI composer

/// Chat surface shown inside the panel when the extension author enabled AI.
/// Goes through AIProviderService like every other surface, so the Settings-level
/// Global Context Prompt is folded in by the router automatically; the extension's
/// own `aiPrompt` rides along as the per-surface addendum.
struct ExtensionPanelAIComposer: View {
    /// Plain strings rather than a model, so both extension routes — a
    /// UserGlobalExtension and a SystemCommand list extension — host the same
    /// composer instead of each growing its own.
    let title: String
    let subtitle: String
    let extraPrompt: String

    @ObservedObject private var settings = AppSettings.shared
    @State private var history: [ChatMessage] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    /// Extra context the user pinned onto the conversation. Named apps and files are
    /// described to the model; nothing is read without being shown as a chip first.
    @State private var attachedApps: [String] = []
    @State private var attachedFiles: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if history.isEmpty && errorText == nil {
                        Text("Ask about \(title)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(history) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.role == .user ? "You" : "AI")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(message.content)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
            }
            .onChange(of: history.count) { _, _ in
                if let last = history.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Attached context reads back as chips, so what the model will see is
            // visible before sending rather than implied.
            if !attachedApps.isEmpty || !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(attachedApps, id: \.self) { app in
                            contextChip(app, icon: "app.badge") {
                                attachedApps.removeAll { $0 == app }
                            }
                        }
                        ForEach(attachedFiles, id: \.self) { file in
                            contextChip((file as NSString).lastPathComponent, icon: "doc") {
                                attachedFiles.removeAll { $0 == file }
                            }
                        }
                    }
                }
                .frame(height: 22)
            }

            HStack(spacing: 8) {
                Menu {
                    Section("Attach app context") {
                        ForEach(runningApps, id: \.self) { app in
                            Button(app) {
                                if !attachedApps.contains(app) { attachedApps.append(app) }
                            }
                        }
                    }
                    Divider()
                    Button("Attach file…") { pickFiles() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)

                TextField("Ask AI…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...5)
                    .onSubmit { send() }

                if isSending {
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : Color.secondary)
                            .frame(width: 22, height: 22)
                            .background(canSend ? Color.accentColor : Color.primary.opacity(0.10),
                                        in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }

    /// Apps with a visible window, newest first — the same set the dock shows.
    private var runningApps: [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap(\.localizedName)
            .sorted()
    }

    @ViewBuilder
    private func contextChip(_ label: String, icon: String,
                             remove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !attachedFiles.contains(url.path) {
            attachedFiles.append(url.path)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        draft = ""
        errorText = nil
        history.append(ChatMessage(role: .user, content: text))
        isSending = true

        let priorHistory = history
        let attachmentNote: String = {
            var parts: [String] = []
            if !attachedApps.isEmpty {
                parts.append("The user attached these apps for context: "
                             + attachedApps.joined(separator: ", ") + ".")
            }
            if !attachedFiles.isEmpty {
                parts.append("The user attached these files: "
                             + attachedFiles.joined(separator: ", ") + ".")
            }
            return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n")
        }()
        // Scoped to this panel: without an identity of its own the model inherits the
        // launcher-wide persona and starts proposing shell commands it cannot run here.
        let scopedPrompt = """
        You are the assistant inside the "\(title)" panel in Context Dock.
        \(subtitle)

        Stay within this panel's subject. You cannot run commands, open apps or touch \
        files — if a request needs that, say so plainly instead of emitting any bracketed \
        command directive.

        \(extraPrompt)\(attachmentNote)
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            defer { isSending = false }
            do {
                let reply = try await AIProviderService.shared.sendMessage(
                    text,
                    context: .none,
                    provider: settings.selectedAIProvider,
                    conversationHistory: priorHistory,
                    additionalContextPrompt: scopedPrompt,
                    surfaceScoped: true
                )
                history.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
