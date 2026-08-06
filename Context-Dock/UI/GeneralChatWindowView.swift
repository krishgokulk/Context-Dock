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
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                    Text("New chat")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // One app is not a combination — it belongs with the other single-scope
            // threads under Apps & tools. "Combined chat" only earns its heading once
            // there is more than one app to combine.
            if model.attachedAppNames.count > 1 {
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
        let loneApp = model.attachedAppNames.count == 1 ? model.attachedAppNames.first : nil
        if !rows.isEmpty || loneApp != nil {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps & tools")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

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
        return Button {
            model.openSession(session.scope, title: session.title)
        } label: {
            HStack(spacing: 8) {
                if let icon = GeneralChatSessionStore.icon(for: session.scope) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(session.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if session.messageCount > 0 {
                    Text("\(session.messageCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isActive ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
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
                ForEach(model.attachedAppNames, id: \.self) { name in
                    Button {
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
                    AppContextPicker { app in
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
                    ForEach(model.messages) { message in
                        VStack(alignment: .trailing, spacing: 4) {
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
                attachedAppNames: model.attachedAppNames,
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
                onClear: model.isEmpty ? nil : { model.newChat() },
                onRemoveApp: { model.removeApp($0) }
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

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Details") { chrome.toggleSidePanel() }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(AppSettings.shared.selectedAIProvider.displayName)
                    .font(.system(size: 12.5))
                Spacer()
            }
            .padding(14)
        }
        .background(Theme.surface(dark))
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
