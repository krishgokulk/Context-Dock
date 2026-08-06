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
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    /// Sidebar width survives relaunches — a width the user dragged is a preference.
    @AppStorage("generalChatSidebarWidth") private var sidebarWidth: Double = 200
    @State private var dragStartWidth: Double?
    @State private var showsSidebarAppPicker = false
    @State private var hoveredSidebarRow: String?

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
                // A thread still working shows it here, so a pending answer is visible
                // from the sidebar rather than only inside the thread you left.
                if isSending {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
                } else if session.messageCount > 0 {
                    Text("\(session.messageCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.08 : 0)))
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
                            AIChatMessageView(message: message)
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

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Console") { chrome.toggleBottomPanel() }
            Divider().opacity(0.4)
            ScrollView {
                Text("No output yet.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .background(Theme.surface(dark))
    }

    /// What this thread can actually reach: the scoped app's adapter tools, or a CLI
    /// scope's scanned subcommands. The same inventory the prompt is built from, so the
    /// panel answers "why did it say it can't?" without opening Settings — and links
    /// straight to where a missing tool is added.
    private var sidePanel: some View {
        let inventory = model.activeScopeInventory
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
