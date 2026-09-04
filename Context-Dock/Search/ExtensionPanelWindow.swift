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
                .padding(.horizontal, 4)
            }

            AIComposerBar(
                text: $draft,
                isSending: isSending,
                attachedAppNames: attachedApps,
                onAttachFile: pickFiles,
                onAttachApp: { app in
                    if !attachedApps.contains(app) { attachedApps.append(app) }
                },
                onSubmit: send
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
        let apps = attachedApps
        let files = attachedFiles
        let panelIdentity = title
        let panelSubtitle = subtitle
        let panelPrompt = extraPrompt

        Task {
            defer { isSending = false }
            // Gathered at send time, not attach time: "what tabs are open" must mean
            // now, not whenever the chip was added.
            var knowledge: [String] = []
            for app in apps {
                let block = await AppKnowledgeService.context(forAppNamed: app)
                if !block.isEmpty { knowledge.append(block) }
            }
            if !files.isEmpty {
                knowledge.append("## Attached files\n" + files.joined(separator: "\n"))
            }
            let attachmentNote = knowledge.isEmpty
                ? ""
                : "\n\n# Attached context\n\n" + knowledge.joined(separator: "\n\n")

            // Scoped to this panel: without an identity of its own the model inherits
            // the launcher-wide persona and proposes shell commands it cannot run here.
            // Attached apps widen that scope deliberately — the user asked for them.
            let scopedPrompt = """
            You are the assistant inside the "\(panelIdentity)" panel in Context Dock.
            \(panelSubtitle)

            Stay within this panel's subject, plus anything the user has attached below. \
            You cannot run commands, open apps or touch files — if a request needs that, \
            say so plainly instead of emitting any bracketed command directive.

            Attached context is a live reading taken just now. Answer from it; never \
            invent a tab, link or file that is not listed.

            \(panelPrompt)\(attachmentNote)
            """.trimmingCharacters(in: .whitespacesAndNewlines)

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


// MARK: - Shared composer bar

/// The one AI input in the app: a glass capsule with the provider on the left and
/// the context controls on the right. Quick Note, pinned extension panels and the
/// folder panels all use it, so the assistant looks like one feature rather than
/// three that grew separately.
struct AIComposerBar: View {
    @Binding var text: String
    var isSending: Bool
    var attachedAppNames: [String]
    var onAttachFile: () -> Void
    var onAttachApp: (String) -> Void
    var onSubmit: () -> Void
    /// Surface-specific attach items (Quick Note's screenshot / window capture).
    /// When nil, "+" is a plain file picker.
    var extraAttachMenu: (() -> AnyView)? = nil
    /// Spell the provider out beside its glyph ("Claude ⌄"). Off on the narrow
    /// panels, where the name ate half the bar; on in the chat window, which has
    /// the width for it.
    var showsProviderName: Bool = false
    /// Clear the conversation. Nil on surfaces that have no transcript to clear.
    var onClear: (() -> Void)? = nil
    /// Detach an app. Nil leaves the attached icons read-only.
    var onRemoveApp: ((String) -> Void)? = nil
    /// Images pasted with ⌘V. Nil leaves paste as text-only on that surface.
    var onPasteImages: (([URL]) -> Void)? = nil
    /// Empty-field layer navigation. Nil on composers that do not participate.
    var onEmptyLeftArrow: (() -> Bool)? = nil
    /// The other direction. A surface that can be arrowed into has to be arrowable out of,
    /// or the keyboard is a one-way door.
    var onEmptyRightArrow: (() -> Bool)? = nil
    /// Escape, handled by the surface so it can unwind its own state before closing.
    /// `onKeyPress` only reaches a focused view, and in the corner this field is the only
    /// thing focused — so a surface with no key handling of its own cannot be escaped at all.
    var onEscape: (() -> Bool)? = nil
    /// Stop the turn that is running. Nil where the surface cannot cancel one.
    var onStop: (() -> Void)? = nil
    /// ↑/↓ while a picker is open above the field. Returning true means the surface moved
    /// its own selection and the field should not treat the key as text navigation.
    var onMoveSelection: ((Int) -> Bool)? = nil
    /// Return, when the surface owns the picker and knows which row is selected. Takes
    /// precedence over this bar's own "first match wins" rule.
    var onCommitSelection: (() -> Bool)? = nil
    /// Corner panels cannot safely host an NSPopover child window. On those surfaces
    /// the app button enters the same inline "/" picker used while typing.
    var usesInlineAppPicker: Bool = false
    /// Corner-only keep-open affordance. Nil on surfaces whose lifecycle is external.
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    /// Whether the bar shows its own `/` matches.
    ///
    /// Off in the corner, which stacks them as a list above the composer and has to know
    /// their height in advance — a strip the bar grew on its own would push itself out
    /// through the top of a card already sized for one row.
    var rendersSlashMatches: Bool = true
    /// Whether the bar draws its own capsule.
    ///
    /// Off in the corner, where the pill is already a bordered card: a capsule inside it
    /// is a second border and a second set of insets, which is what made General mode read
    /// as taller and looser than App mode when the two show the same single row.
    var drawsChrome: Bool = true

    @ObservedObject private var settings = AppSettings.shared
    @State private var showAppPicker = false
    /// Which attached app the cursor is over — hovering swaps its icon for an "×",
    /// the same affordance the dock's chips use.
    @State private var hoveredAppName: String?

    /// Apps matching the "/" filter — running first, prefix matches before
    /// substring ones, so the leftmost icon is what Return will take.
    ///
    /// Sourced from ChatAppDirectory, the same list the dock filters. Reading the app
    /// catalogue directly was why "/finder" matched nothing here while it worked in the
    /// dock: the catalogue does not scan /System/Library/CoreServices.
    private var slashApps: [ChatAppEntry] {
        ChatSlashAppPicker.matches(for: text)
    }

    private func pickSlashApp(_ app: ChatAppEntry) {
        onAttachApp(app.name)
        text = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if rendersSlashMatches, !slashApps.isEmpty {
                ChatSlashAppChipStrip(matches: slashApps, onPick: pickSlashApp)
            }

            HStack(spacing: 8) {
            // Provider chip: switching model is part of asking, so it lives in the bar.
            Menu {
                ForEach(AIProvider.allCases) { provider in
                    Button {
                        settings.selectedAIProvider = provider
                    } label: {
                        if provider == settings.selectedAIProvider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            } label: {
                // Icon only by default: the placeholder already says which model this
                // is, and the name repeated beside it ate half the bar on a narrow panel.
                HStack(spacing: 4) {
                    AIProviderIcon(provider: settings.selectedAIProvider, size: 14)
                        .foregroundStyle(.primary)
                    if showsProviderName {
                        Text(settings.selectedAIProvider.shortName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            TextField("Ask \(settings.selectedAIProvider.shortName)…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .onSubmit {
                    // A surface drawing its own picker knows which row is highlighted;
                    // this bar only knows the order it handed over.
                    if onCommitSelection?() == true { return }
                    // "/rem" + Return means "work with that app", not "ask about the
                    // string /rem".
                    if let first = slashApps.first {
                        pickSlashApp(first)
                        return
                    }
                    onSubmit()
                }
                .onKeyPress(.leftArrow) {
                    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          onEmptyLeftArrow?() == true
                    else { return .ignored }
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          onEmptyRightArrow?() == true
                    else { return .ignored }
                    return .handled
                }
                .onKeyPress(.escape) {
                    onEscape?() == true ? .handled : .ignored
                }
                .onKeyPress(.upArrow) {
                    onMoveSelection?(-1) == true ? .handled : .ignored
                }
                .onKeyPress(.downArrow) {
                    onMoveSelection?(1) == true ? .handled : .ignored
                }

            if let extraAttachMenu {
                Menu {
                    Button { onAttachFile() } label: {
                        Label("Attach Files…", systemImage: "paperclip")
                    }
                    Divider()
                    extraAttachMenu()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button(action: onAttachFile) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach a file")
            }

            // Every attached app, not just the first: a chat can be scoped to
            // Reminders AND Safari, and a bar showing one of them reads as though the
            // other was dropped.
            if !attachedAppNames.isEmpty {
                HStack(spacing: 4) {
                    ForEach(attachedAppNames.prefix(5), id: \.self) { name in
                        Button {
                            onRemoveApp?(name)
                        } label: {
                            ZStack {
                                Group {
                                    if let icon = AppContextPicker.icon(forAppNamed: name) {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                    } else {
                                        Image(systemName: "app.dashed")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 17, height: 17)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .opacity(hoveredAppName == name ? 0.22 : 1)

                                if hoveredAppName == name {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(width: 17, height: 17)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onRemoveApp == nil)
                        .help(onRemoveApp == nil ? name : "Remove \(name)")
                        .onHover { hovering in
                            guard onRemoveApp != nil else { return }
                            withAnimation(.easeOut(duration: 0.1)) {
                                hoveredAppName = hovering ? name : nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
            }

            Button {
                if usesInlineAppPicker {
                    ChatSlashAppPicker.openInline(text: &text)
                } else {
                    showAppPicker = true
                }
            } label: {
                Image(systemName: "app.dashed")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Work with an app")
            .popover(isPresented: $showAppPicker, arrowEdge: .bottom) {
                AppContextPicker(selectedNames: Set(attachedAppNames)) { app in
                    onAttachApp(app)
                    showAppPicker = false
                }
            }

            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear this conversation")
            }

            if let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Keep this open")
            }

            if isSending {
                if let onStop {
                    // A spinner says "wait". A surface that can cancel should offer that
                    // instead, or the only way out of a long turn is to sit through it.
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.12), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, drawsChrome ? 10 : 0)
            .background {
                if drawsChrome {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                }
            }
        }
        .acceptsPastedImages { urls in onPasteImages?(urls) }
    }
}


// MARK: - App picker

/// Every installed app, searchable, running ones first — the same set the launcher
/// searches. A menu of running apps only was too narrow: "work with Notes" is a
/// reasonable thing to ask before Notes is open.
struct AppContextPicker: View {
    let onPick: (String) -> Void
    /// Apps already attached, so the list can show what is on rather than only offering.
    var selectedNames: Set<String> = []

    @State private var rows: [ScopedAppPickerRow] = []

    var body: some View {
        ScopedAppPickerList(
            rows: rows,
            selectedIDs: Set(selectedNames.map { $0.lowercased() })
        ) { row in
            onPick(row.name)
        }
        .task { rows = ScopedAppPickerRow.allApps() }
    }

    /// The icon for an attached app, wherever it came from. Through the directory rather
    /// than the app catalogue: the catalogue does not carry Finder, so an attached Finder
    /// chip and its sidebar row both drew the dashed placeholder for an app that is
    /// running right there.
    static func icon(forAppNamed name: String) -> NSImage? {
        ChatAppDirectory.all().first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.icon
    }
}
