// GeneralChatWindowView.swift
// Context-Dock
//
// Body of the standalone General Chat window: a translucent sidebar column and an
// opaque content column, split by one vertical line that runs from the titlebar to
// the bottom of the window. Same assistant the result sheet answers in — this is
// the full-window version of it, not a second chat surface.

import AppKit
import SwiftUI

struct GeneralChatWindowView: View {
    @ObservedObject private var chrome = GeneralChatWindowChromeState.shared
    @ObservedObject private var model = GeneralChatWindowModel.shared
    @ObservedObject private var console = ChatConsoleLog.shared
    /// The same approval queue the dock reads, so a command proposed in a window thread can
    /// be answered here rather than expiring unseen.
    @ObservedObject private var terminalBridge = TerminalAIBridge.shared
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    /// Sidebar width survives relaunches — a width the user dragged is a preference.
    @AppStorage("generalChatSidebarWidth") private var sidebarWidth: Double = 200
    @State private var dragStartWidth: Double?
    @State private var showsSidebarAppPicker = false
    @State private var hoveredSidebarRow: String?
    /// Bumped when remembered routes are cleared, so the list redraws — the store is
    /// UserDefaults-backed and publishes nothing on its own.
    @State private var routeResetToken = 0
    @State private var cachedInventory: ScopeInventory?
    /// Bumped to rebuild the terminal view after its shell is restarted.
    @State private var terminalToken = 0

    private let minSidebarWidth: Double = 160
    private let maxSidebarWidth: Double = 380
    private let sidePanelWidth: CGFloat = 300
    private let bottomPanelHeight: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            if chrome.sidebarVisible {
                sidebarColumn
                    .frame(width: CGFloat(sidebarWidth))
                    .background(GeneralChatSidebarMaterial())
                    .transition(.move(edge: .leading))

                sidebarResizeHandle
            }

            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(contentBackground)
        }
        .frame(minWidth: 720, minHeight: 480)
        .ignoresSafeArea()
        .task(id: model.activeScope.storageKey) {
            cachedInventory = model.activeScopeInventory
        }
        .onChange(of: routeResetToken) { _, _ in
            cachedInventory = model.activeScopeInventory
        }
    }

    /// Opaque so the two-tone split against the translucent sidebar is visible.
    private var contentBackground: Color {
        dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(nsColor: .textBackgroundColor)
    }

    /// The split line doubles as the drag handle — a 6pt hit area over a 1pt line,
    /// so the divider stays hairline-thin but is still grabbable.
    private var sidebarResizeHandle: some View {
        Divider()
            .opacity(0.55)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? sidebarWidth
                                dragStartWidth = start
                                sidebarWidth = min(
                                    maxSidebarWidth,
                                    max(minSidebarWidth, start + value.translation.width))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            )
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralChatSidebarBar(chrome: chrome)

            Button {
                model.newChat()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 16)
                    Text("New chat")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(model.activeScope == .general ? Color.primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            model.activeScope == .general
                                ? Color.primary.opacity(0.10)
                                : (hoveredSidebarRow == "new" ? Color.primary.opacity(0.06) : .clear)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    hoveredSidebarRow = hovering ? "new" : nil
                }
            }

            // One app is not a combination — it belongs with the other single-scope
            // threads under Apps & tools. "Combined chat" only earns its heading once
            // there is more than one app to combine.
            if model.scopeAppNames.count > 1 {
                combinedChatEntry
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }

            sessionList

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row per app or CLI tool the user has opened a thread with.
    ///
    /// These persist independently of whether the app is running — the window is a hub, so
    /// "what did I ask tailscale yesterday" has to be answerable with tailscale closed.
    @ViewBuilder
    private var sessionList: some View {
        let rows = model.sessions.filter { $0.scope != .general }
        // A lone attached app has no session of its own — it is a scope on the current
        // conversation — but from the sidebar it reads as the same thing: one app this
        // chat is about. Listing it here is what stops it disappearing from the sidebar
        // when Combined chat stops applying.
        let loneApp =
            model.activeScopeAppName == nil && model.attachedAppNames.count == 1
            ? model.attachedAppNames.first : nil
        if !rows.isEmpty || loneApp != nil {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps & tools")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                if let loneApp {
                    attachedAppRow(loneApp)
                }

                ForEach(rows) { session in
                    sessionRow(session)
                }
            }
        }
    }

    /// The single app this conversation is scoped to. Same shape as a session row, with
    /// an "×" instead of a message count — it is a scope you can drop, not a thread you
    /// switch to.
    private func attachedAppRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            appIcon(name)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                showsSidebarAppPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add another app — makes this a combined chat")
            .popover(isPresented: $showsSidebarAppPicker, arrowEdge: .trailing) {
                AppContextPicker { app in
                    model.attachApp(app)
                    showsSidebarAppPicker = false
                }
            }
            Button {
                model.removeApp(name)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(name) from this chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func sessionRow(_ session: GeneralChatSession) -> some View {
        let isActive = session.scope == model.activeScope
        let isHovered = hoveredSidebarRow == session.id
        let isSending = model.sendingScopeKeys.contains(session.scope.storageKey)
        return Button {
            model.openSession(session.scope, title: session.title)
        } label: {
            HStack(spacing: 9) {
                if let icon = GeneralChatSessionStore.icon(for: session.scope) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .opacity(model.isScopeLive(session.scope) ? 1 : 0.55)
                }
                Text(session.title)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // When it was last spoken to, the way a chat app lists a conversation.
                if session.messageCount > 0, !isSending {
                    Text(Self.threadTimestamp(session.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                // A thread still working shows it here, so a pending answer is visible
                // from the sidebar rather than only inside the thread you left.
                if isSending {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isActive
                            ? Color.primary.opacity(0.10)
                            : (isHovered ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(alignment: .leading) {
                // Active thread carries a rail rather than only a fill, so the current
                // scope is readable at a glance on a translucent sidebar.
                if isActive {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 2.5, height: 16)
                        .offset(x: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredSidebarRow = hovering ? session.id : nil
            }
        }
        .contextMenu {
            Button("Close thread", role: .destructive) {
                model.closeSession(session.scope)
            }
        }
    }

    /// The current chat, named by what it is scoped to. Two apps attached means one
    /// combined chat across both, not two chats — so this is a single row carrying
    /// both icons, and "+" adds another app to the same conversation.
    private var combinedChatEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Combined chat")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack(spacing: 6) {
                ForEach(model.scopeAppNames, id: \.self) { name in
                    Button {
                        guard name != model.activeScopeAppName else { return }
                        model.removeApp(name)
                    } label: {
                        appIcon(name)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(name) from this chat")
                }

                Button {
                    showsSidebarAppPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.surfaceElevated(dark))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add another app to this chat")
                .popover(isPresented: $showsSidebarAppPicker, arrowEdge: .trailing) {
                    AppContextPicker(selectedNames: Set(model.scopeAppNames)) { app in
                        model.attachApp(app)
                        showsSidebarAppPicker = false
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surfaceElevated(dark))
            )
        }
    }

    /// Time for today, "Yesterday", a weekday within the week, then a date — the ladder
    /// a chat app uses for its conversation list.
    private static func threadTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            formatter.dateFormat = "EEE"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }

    /// "Today" / "Yesterday" / a written date — the same wording a chat app uses.
    private static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func appIcon(_ name: String) -> some View {
        if let icon = AppContextPicker.icon(forAppNamed: name) {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Content column

    private var contentColumn: some View {
        VStack(spacing: 0) {
            GeneralChatContentBar(chrome: chrome, carriesWindowControls: !chrome.sidebarVisible)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Group {
                        switch chrome.mode {
                        case .chat: chatPane
                        case .work: workPane
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if chrome.bottomPanelVisible {
                        Divider().opacity(0.55)
                        bottomPanel
                            .frame(height: bottomPanelHeight)
                            .transition(.move(edge: .bottom))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if chrome.sidePanelVisible {
                    Divider().opacity(0.55)
                    sidePanel
                        .frame(width: sidePanelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Chat

    private var chatPane: some View {
        VStack(spacing: 0) {
            if model.isEmpty {
                emptyState
            } else {
                transcript
            }
            approvalCard
            composer
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Where should we begin?")
                .font(.system(size: 28, weight: .semibold))
            if chrome.temporaryChat {
                Text("Temporary chat — this conversation is not saved.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Same row view the result sheet renders, so an answer looks
                    // identical in both places.
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        VStack(alignment: .trailing, spacing: 4) {
                            // Day separator, the way chat apps date a conversation — a
                            // thread reopened next week should not read as one long today.
                            if model.startsNewDay(at: index) {
                                Text(Self.dayLabel(message.timestamp))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            // The apps this question was asked about, beside the
                            // question itself — the scope at the time, not now.
                            if let apps = model.messageApps[message.id], !apps.isEmpty {
                                HStack(spacing: 4) {
                                    Spacer(minLength: 0)
                                    ForEach(apps, id: \.self) { name in
                                        appIcon(name)
                                            .frame(width: 15, height: 15)
                                            .clipShape(
                                                RoundedRectangle(
                                                    cornerRadius: 4, style: .continuous)
                                            )
                                            .help(name)
                                    }
                                }
                            }
                            AIChatMessageView(
                                message: message,
                                onEnableApp: { model.enableApp($0) },
                                onPickAction: { model.pickRoute($0) })
                        }
                        .id(message.id)
                    }
                    if model.isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// Approve or deny a command the thread proposed.
    ///
    /// Without this the window could ask to run something and had nowhere to say yes: the
    /// approval card lives on the dock, so a request raised from a window thread sat unanswered
    /// until its 60-second continuation expired and came back as "Command denied by user" — which
    /// is why the console never showed a command running. Same TerminalAIBridge.pendingApproval
    /// the dock reads, so a request is answered wherever the user actually is.
    @ViewBuilder
    private var approvalCard: some View {
        if let pending = terminalBridge.pendingApproval {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("Run command?")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(pending.classification.riskLevel.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if !pending.purpose.isEmpty {
                    Text(pending.purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(pending.command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    Button("Deny") { terminalBridge.denyCommand() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Approve & Run") { terminalBridge.approveCommand(pending.command) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(alignment: .top) { Divider().opacity(0.4) }
        }
    }

    /// The one AI input in the app — same capsule, provider chip, attach and app
    /// picker the Quick Note and panel surfaces use, with the provider spelled out
    /// and a clear button because this surface has a transcript and the room.
    private var composer: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.attachments, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.surfaceElevated(dark), in: Capsule())
                    }
                    Spacer()
                }
            }

            AIComposerBar(
                text: $model.input,
                isSending: model.isSending,
                attachedAppNames: model.scopeAppNames,
                onAttachFile: { model.attachFiles() },
                onAttachApp: { model.attachApp($0) },
                onSubmit: { model.send() },
                extraAttachMenu: {
                    AnyView(
                        Group {
                            Button {
                                model.attachFiles(imagesOnly: true)
                            } label: { Label("Upload Photo", systemImage: "photo") }
                            Divider()
                            Button {
                                model.captureScreenshot(interactive: false)
                            } label: {
                                Label("Take Screenshot", systemImage: "camera.viewfinder")
                            }
                            Button {
                                model.captureScreenshot(interactive: true, windowFirst: true)
                            } label: { Label("Capture Area", systemImage: "crop") }
                            Button {
                                model.captureScreenText()
                            } label: { Label("Capture Text", systemImage: "text.viewfinder") }
                        }
                    )
                },
                showsProviderName: true,
                onClear: model.isEmpty ? nil : { model.clearActiveThread() },
                // The thread's own app is not detachable — closing that thread is what
                // removing it would mean, and the sidebar already does that.
                onRemoveApp: { name in
                    guard name != model.activeScopeAppName else { return }
                    model.removeApp(name)
                }
            )
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    // MARK: - Work mode

    private var workPane: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "hammer")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("Work")
                .font(.system(size: 15, weight: .semibold))
            Text("Task runs and their output will live here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Panels

    /// The thread's work, in the order it happened: every command, tool call and route
    /// with its real output. The transcript says what DoraX concluded; this says what it
    /// did, which is the part that can be checked rather than trusted.
    private var bottomPanel: some View {
        let entries = console.entries(for: model.activeScope)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Console")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !entries.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            console.plainText(scope: model.activeScope), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the whole log")

                    Button {
                        console.clear(scope: model.activeScope)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the log for this thread")
                }
                Button { chrome.toggleBottomPanel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if entries.isEmpty {
                            Text(
                                "Nothing has run in this thread yet. Commands, tool calls and "
                                + "routes appear here with their output as they happen."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        }
                        ForEach(entries) { entry in
                            consoleEntry(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.count) { _, _ in
                    guard let last = entries.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Theme.surface(dark))
    }

    private func consoleEntry(_ entry: ChatConsoleEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if entry.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12)
                } else {
                    Image(systemName: entry.source.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(entry.success ? Color.secondary : Color.red)
                }
                Text(entry.title)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        entry.isRunning
                            ? Color.secondary : (entry.success ? Color.primary : Color.red))
                    .lineLimit(2)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.title, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy this command")

                Spacer(minLength: 8)

                if entry.isRunning {
                    Text("running…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if let duration = entry.duration, duration >= 0.1 {
                    // How long it took. A tool that takes eight seconds every time is worth
                    // knowing about before it becomes a mystery.
                    Text(String(format: "%.1fs", duration))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(Self.consoleTime(entry.at))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
    }

    private static func consoleTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private var sidePanel: some View {
        // Read once per scope change, not per redraw. This calls into AX and the capability
        // stores; doing it on every frame put main-thread work behind every animation in
        // the window.
        let inventory = cachedInventory ?? model.activeScopeInventory
        return VStack(alignment: .leading, spacing: 0) {
            // Scope pill, not a title: the panel belongs to a thread, and the thread is
            // named by its app.
            HStack(spacing: 8) {
                scopePill
                Spacer(minLength: 0)
                Button { chrome.toggleSidePanel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            // A CLI thread gets a real terminal here. Some tools — a browser, an editor, a
            // pager — draw their own screen and cannot be run with output captured, so
            // describing their output is not an option: it has to be shown.
            if case .cli = model.activeScope {
                threadTerminal
                Divider().opacity(0.4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = inventory.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                    ForEach(inventory.groups) { group in
                        inventoryGroup(group)
                    }

                    if inventory.groups.isEmpty {
                        Text(
                            "Nothing is linked to this scope yet. Actions, skills, MCP servers "
                            + "and CLI tools you add show up here and in what the model can do."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let bundleId = model.activeScopeBundleId {
                        let remembered = ChatRoutePreferenceStore.remembered(bundleId: bundleId)
                        if !remembered.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                sectionLabel(
                                    "Preferred routes", symbol: "arrow.triangle.branch",
                                    count: remembered.count)
                                ForEach(remembered, id: \.intent) { entry in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: entry.kind.symbol)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                            .padding(.top, 2)
                                        Text("“\(entry.intent)” → \(entry.kind.routeLabel)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.primary.opacity(0.85))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                                Button {
                                    ChatRoutePreferenceStore.forget(bundleId: bundleId)
                                    routeResetToken += 1
                                } label: {
                                    Text("Always ask again")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("Forget these choices and ask each time")
                            }
                            .id(routeResetToken)
                        }

                        Button {
                            AppDelegate.shared?.showSettings()
                            // The settings window has to exist before it can be navigated.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                NotificationCenter.default.post(
                                    name: .openSettingsPage, object: nil,
                                    userInfo: ["page": SettingsPage.frontmostAppAdapters.rawValue])
                                NotificationCenter.default.post(
                                    name: .openAppAdapter, object: nil,
                                    userInfo: ["bundleId": bundleId])
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Add tools for \(model.activeScopeTitle)")
                                    .font(.system(size: 11.5, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open Settings → App Adapters for this app")
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        sectionLabel("Provider", symbol: "brain.head.profile", count: nil)
                        Text(AppSettings.shared.selectedAIProvider.displayName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.85))
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface(dark))
    }

    /// The thread's live PTY, with the tool's own prompt. Created on first sight of a CLI
    /// thread rather than on every scope, so a thread you never open costs nothing.
    @ViewBuilder
    private var threadTerminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("TERMINAL")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    ChatThreadTerminalManager.shared.close(scope: model.activeScope)
                    terminalToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Restart this thread's shell")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            PanelTerminalView(
                controller: ChatThreadTerminalManager.shared.controller(for: model.activeScope)
            )
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .id("\(model.activeScope.storageKey)-\(terminalToken)")
        }
    }

    private var scopePill: some View {
        HStack(spacing: 6) {
            if let bundleId = model.activeScopeBundleId {
                AppBundleIconView(
                    bundleId: bundleId, fallbackSymbol: "app.dashed", size: 15, cornerRadius: 4)
            } else {
                Image(systemName: model.activeScopeSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(model.activeScopeTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Theme.surfaceElevated(dark))
        )
        .overlay(Capsule().strokeBorder(Theme.border(dark), lineWidth: 0.5))
    }

    private func inventoryGroup(_ group: ScopeInventory.Group) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel(group.title, symbol: group.symbol, count: group.items.count)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3, height: 3)
                            .padding(.top, 6)
                        Text(item)
                            .font(
                                .system(
                                    size: 11.5,
                                    design: group.isMonospaced ? .monospaced : .default)
                            )
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func panelHeader(_ title: String, close: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
