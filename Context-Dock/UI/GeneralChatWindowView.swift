// GeneralChatWindowView.swift
// Context-Dock
//
// Body of the standalone General Chat window: a translucent sidebar column and an
// opaque content column, split by one vertical line that runs from the titlebar to
// the bottom of the window. Same assistant the result sheet answers in — this is
// the full-window version of it, not a second chat surface.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @State private var hoveredSidebarRow: String?
    @State private var hoveringCombinedChat = false
    @State private var showsAllThreads = false
    /// Kept across launches: a pinned workflow is a standing arrangement, not a gesture to
    /// repeat every session.
    @AppStorage("generalChatPinnedCombinedChat") private var pinnedCombinedChat = false
    /// Bumped when remembered routes are cleared, so the list redraws — the store is
    /// UserDefaults-backed and publishes nothing on its own.
    @State private var routeResetToken = 0
    @State private var cachedInventory: ScopeInventory?
    /// Bumped to rebuild the terminal view after its shell is restarted.
    @State private var terminalToken = 0
    @State private var panelTab: PanelTab = .terminal
    /// The artifact a transcript card asked for. The panel shows the last candidate, so
    /// choosing one moves it to the end rather than teaching the panel a second concept.
    @State private var focusedArtifact: URL?

    private let minSidebarWidth: Double = 160
    private let maxSidebarWidth: Double = 380
    /// Kept across launches: a width someone dragged to is a preference, not a gesture to
    /// repeat every time they open the window.
    @AppStorage("generalChatSidePanelWidth") private var sidePanelWidth: Double = 300
    @State private var panelDragStart: Double?
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
        // Dragging from Finder is how a folder gets here without a file panel. A folder
        // becomes its own thread; a file joins the thread you are in, because dropping a
        // PDF on a conversation means "read this", not "start again".
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedItems(providers)
        }
        .task(id: model.activeScope.storageKey) {
            cachedInventory = model.activeScopeInventory
            model.refreshFinderSelection()
        }
        // Coming back to this window is the moment the selection may have changed: the
        // user cannot click in Finder without leaving here first, so there is nothing to
        // poll for and one read on return is enough.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshFinderSelection()
        }
        .onChange(of: routeResetToken) { _, _ in
            cachedInventory = model.activeScopeInventory
        }
    }

    /// Sorts a drop into the two things it can mean. Returns true if anything was taken,
    /// which is what tells the drag to land rather than snap back.
    private func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: url.path, isDirectory: &isDirectory)
                    guard exists else { return }
                    if isDirectory.boolValue {
                        model.openFolderSession(url)
                    } else if !model.attachments.contains(url) {
                        model.attachments.append(url)
                    }
                }
            }
        }
        return handled
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Scope stays above every navigation section, even in a long history.
                    // Shown whenever the current thread is about more than one app.
                    //
                    // Restricting this to the general thread was wrong: attaching an app in
                    // General opens that app's own thread, so a second app lands as an
                    // attachment on a scoped thread — Safari + Messages *is* the Safari
                    // thread. Hiding the row there hid the combined chat exactly where
                    // combining actually happens.
                    if model.scopeAppNames.count > 1, chrome.mode == .work {
                        combinedChatEntry
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                    }
                    sessionList
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row per app or CLI tool the user has opened a thread with.
    ///
    /// These persist independently of whether the app is running — the window is a hub, so
    /// "what did I ask tailscale yesterday" has to be answerable with tailscale closed.
    @ViewBuilder
    private var sessionList: some View {
        // Folders get their own heading: a directory listed under "Apps & tools" reads as
        // an app that is not one, and the two are picked for different reasons.
        // Work lists workspaces and nothing else; Chat lists everything that is not one.
        // A list that mixes them cannot say which is which, which is what made a workspace
        // look like a stray copy of one of its members.
        let isWorkspaces = chrome.mode == .work
        let all = model.sessions.filter { $0.scope != .general }
            .filter { $0.scope.isWorkspace == isWorkspaces }
        let folderRows = all.filter { $0.scope.folderURL != nil }
        // Conversations with something in them, newest first — the rows worth returning
        // to. In Chat these were buried in installation order among every app ever opened;
        // eighteen dormant rows above the one from ten minutes ago is a history that
        // answers the wrong question.
        let recentRows =
            (isWorkspaces
                ? model.sessions.filter { $0.scope.isWorkspace && $0.messageCount > 0 }
                : model.sessions.filter {
                    !$0.scope.isWorkspace && $0.scope != .general && $0.messageCount > 0
                })
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
            .map { $0 }
        let rows = all.filter { $0.scope.folderURL == nil && !$0.scope.isGeneralChat }
        // A lone attached app has no session of its own — it is a scope on the current
        // conversation — but from the sidebar it reads as the same thing: one app this
        // chat is about. Listing it here is what stops it disappearing from the sidebar
        // when Combined chat stops applying.
        let loneApp =
            model.activeScopeAppName == nil && model.attachedAppNames.count == 1
            ? model.attachedAppNames.first : nil
        if !recentRows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sidebarSectionTitle("Recents")
                ForEach(recentRows) { session in sessionRow(session) }
            }
        }

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

                // Not the ones already listed above: a row in two places at once reads as
                // two conversations, and the user has to compare timestamps to find out
                // it is one.
                let recentIDs = Set(recentRows.map(\.id))
                let remaining = rows.filter { !recentIDs.contains($0.id) }
                ForEach(showsAllThreads ? remaining : Array(remaining.prefix(8))) { session in
                    sessionRow(session)
                }

                if remaining.count > 8 {
                    Button(showsAllThreads ? "Show less" : "View all (\(remaining.count))") {
                        showsAllThreads.toggle()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }
        }

        if !folderRows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Folders")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)
                    Spacer(minLength: 0)
                    Button {
                        model.attachFolder()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Chat with another folder")
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 4)

                ForEach(folderRows) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
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

    /// Hover fill that redraws only itself.
    ///
    /// The sidebar kept its hovered row in the window's own @State, so moving the pointer
    /// across one row invalidated the entire view — transcript, side panel and composer
    /// included — and the whole window flickered. Hover is a property of the row, so the
    /// row is where it lives.
    private struct HoverFill: ViewModifier {
        let isActive: Bool
        @State private var hovering = false

        func body(content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isActive
                                ? Color.primary.opacity(0.10)
                                : (hovering ? Color.primary.opacity(0.06) : .clear)))
                .onHover { hovering = $0 }
        }
    }

    private func sessionRow(_ session: GeneralChatSession) -> some View {
        let isActive = session.scope == model.activeScope
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
            .modifier(HoverFill(isActive: isActive))
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
        // A folder's name is rarely enough — two "Invoices" in the sidebar are told apart
        // by where they are, not what they are called.
        .help(session.scope.folderURL?.path ?? session.title)
        .contextMenu {
            if let folder = session.scope.folderURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Divider()
            }
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
            HStack(spacing: 4) {
                Text("Combined chat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Shown on hover, or whenever it is already pinned — a pin the user set
                // has to stay visible, or there is no way to find it again to unset it.
                if hoveringCombinedChat || pinnedCombinedChat {
                    Button {
                        pinnedCombinedChat.toggle()
                    } label: {
                        Image(systemName: pinnedCombinedChat ? "pin.fill" : "pin")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(pinnedCombinedChat ? Color.accentColor : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        pinnedCombinedChat
                            ? "Unpin — hide this while working in another thread"
                            : "Pin — keep this workflow visible from every thread")
                }
            }
            .padding(.horizontal, 4)
            .onHover { hoveringCombinedChat = $0 }

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
                        case .dashboard: DashboardPane()
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
                    sidePanelResizeHandle
                    Divider().opacity(0.55)
                    sidePanel
                        .frame(width: sidePanelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { revealHandoffIfNeeded() }
            .onChange(of: model.pendingPreviewFile) { _, _ in revealHandoffIfNeeded() }
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
            followUpChip
            composer
        }
    }

    /// The one next step the last action earned, if it earned one.
    ///
    /// Only while the conversation is idle and has something in it: offering a next move
    /// while an answer is still arriving asks the user to choose before they have read
    /// what they are choosing about.
    @ViewBuilder
    private var followUpChip: some View {
        if !model.isSending, !model.messages.isEmpty,
            let followUp = ChatFollowUp.suggestion(for: model.activeScope)
        {
            HStack {
                Button {
                    model.input = followUp.prompt
                    model.send()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(followUp.title)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            // A scoped thread already says what it is about, so it opens on its own name.
            // Only the unscoped chat has nothing to go on, and that is where a starting
            // point is worth the space.
            if model.activeScope == .general {
                GeneralChatStartView { prompt in
                    model.input = prompt
                    model.send()
                }
            } else {
                Spacer()
                Text("Where should we begin?")
                    .font(.system(size: 28, weight: .semibold))
                Spacer()
            }
            if chrome.temporaryChat {
                Text("Temporary chat — this conversation is not saved.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
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

                            // What this answer built, where it built it. The panel lists
                            // everything the thread has ever produced, which is the wrong
                            // place to learn that the message you are reading made a
                            // document — so the document appears under the message, and
                            // opens in the panel beside it.
                            let produced = ArtifactStore.artifacts(
                                mentionedIn: message.content, scope: model.activeScope)
                            if message.role == .assistant, !produced.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(produced, id: \.path) { url in
                                        artifactCard(url)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
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
        if let adapterPending = adapterManager.pendingApproval {
            // The same decision the dock shows inline, in the conversation that asked.
            InlineAdapterApprovalCard(request: adapterPending)
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
        }
        if let pending = terminalBridge.pendingApproval, pending.origin == .window {
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
            selectionPill

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
                            // A folder is a thread, not an attachment — see
                            // GeneralChatWindowModel.attachFolder.
                            Button {
                                model.attachFolder()
                            } label: { Label("Chat with a Folder…", systemImage: "folder") }
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
                },
                onPasteImages: { urls in
                    model.attachments.append(
                        contentsOf: urls.filter { !model.attachments.contains($0) })
                }
            )
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    /// One document an answer produced, as a row under that answer.
    ///
    /// Deliberately a card rather than rendered inline: an artifact is a thing to look at,
    /// and the panel already renders it properly with room to scroll. This says it exists
    /// and takes you there.
    private func artifactCard(_ url: URL) -> some View {
        Button {
            focusedArtifact = url
            panelTab = .artifacts
            chrome.showSidePanel()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbolForArtifact(url))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Document · \(url.pathExtension.uppercased())")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("Open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .frame(maxWidth: 320, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
    }

    private func symbolForArtifact(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "csv": return "tablecells"
        case "svg": return "scribble"
        default: return "doc.richtext"
        }
    }

    /// What Finder has highlighted, when this thread is entitled to speak for it.
    ///
    /// Shown rather than applied silently: the answer to "rename these" changes completely
    /// depending on what "these" is, and the user should be able to see it — and dismiss
    /// it — before pressing Return, not discover it in the receipt.
    @ViewBuilder
    private var selectionPill: some View {
        let selection = model.selectionInScope
        if !selection.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(model.selectionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· in Finder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    model.ignoreSelectionForActiveThread()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ignore the selection in this thread")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5))
            .help(selection.map(\.path).joined(separator: "\n"))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    // MARK: - Work mode

    /// Workspaces: conversations that span several apps.
    ///
    /// Chat is for asking; Work is for getting something done across apps. Keeping both in
    /// one list was the source of most of the confusion — a Safari + Notes workflow sat
    /// beside a plain Safari chat looking like a third kind of Safari, and adding an app to
    /// a conversation quietly turned it into something the Chat list could not describe.
    /// Separating them means the question "is this a chat or a workflow?" is answered by
    /// which tab you are in.
    private var workPane: some View {
        Group {
            if model.activeScope.isWorkspace {
                chatPane
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Workspaces")
                        .font(.system(size: 15, weight: .semibold))
                    Text(
                        "Add two or more apps to a conversation — with \"/\", or by enabling "
                            + "them when asked — and it becomes a workspace here, with only "
                            + "those apps' tools."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

    /// Drag to trade width between the conversation and the panel.
    ///
    /// The panel holds a live terminal and a file being edited, and 300pt was chosen for a
    /// list of tool names. Reading either at that width means giving up the conversation,
    /// which defeats having them side by side.
    private var sidePanelResizeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                // set(), not push()/pop(). A push that misses its pop — which happens when
                // the pointer leaves during a drag — leaves the resize cursor stuck over
                // the whole app.
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = panelDragStart ?? sidePanelWidth
                        if panelDragStart == nil { panelDragStart = start }
                        // Dragging left widens the panel: it is pinned to the right edge.
                        sidePanelWidth = min(760, max(240, start - Double(value.translation.width)))
                    }
                    .onEnded { _ in panelDragStart = nil }
            )
            .overlay(Divider().opacity(0.4))
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

            // Two things the panel shows rather than describes: the tool's own screen, and
            // the file the thread is working on. They share the space — the panel is narrow,
            // and stacking both leaves neither enough room to be useful.
            if hasTerminal || !previewFiles.isEmpty || !artifactFiles.isEmpty {
                panelTabs
                switch effectivePanelTab {
                case .terminal where hasTerminal:
                    if let reason = unsupportedToolReason {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        threadTerminal
                    }
                case .artifacts:
                    ChatThreadPreviewPanel(candidates: orderedArtifactFiles)
                        .id("artifacts-" + (orderedArtifactFiles.last?.path ?? "none"))
                default:
                    ChatThreadPreviewPanel(candidates: previewFiles)
                        .id(previewFiles.last?.path ?? "none")
                }
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
                        HStack(spacing: 6) {
                            AIProviderIcon(
                                provider: AppSettings.shared.selectedAIProvider, size: 12)
                            Text(AppSettings.shared.selectedAIProvider.displayName)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface(dark))
    }

    private enum PanelTab: String { case terminal, preview, artifacts }

    /// Artifacts with the chosen one last, because the panel opens on the last candidate.
    private var orderedArtifactFiles: [URL] {
        guard let focusedArtifact, artifactFiles.contains(focusedArtifact) else {
            return artifactFiles
        }
        return artifactFiles.filter { $0 != focusedArtifact } + [focusedArtifact]
    }

    private var artifactFiles: [URL] {
        ArtifactStore.artifacts(for: model.activeScope)
    }

    private var unsupportedToolReason: String? {
        guard case .cli(let command) = model.activeScope else { return nil }
        return ChatThreadTerminalManager.unsupportedReason(for: command)
    }

    private var hasTerminal: Bool {
        if case .cli = model.activeScope { return true }
        return false
    }

    /// Falls back rather than showing an empty half: a thread with no terminal opens on the
    /// preview, and one with no files opens on the terminal.
    private var effectivePanelTab: PanelTab {
        if panelTab == .artifacts, artifactFiles.isEmpty {
            return previewFiles.isEmpty ? .terminal : .preview
        }
        if panelTab == .terminal, !hasTerminal {
            return previewFiles.isEmpty && !artifactFiles.isEmpty ? .artifacts : .preview
        }
        if panelTab == .preview, previewFiles.isEmpty {
            if !artifactFiles.isEmpty { return .artifacts }
            if hasTerminal { return .terminal }
        }
        return panelTab
    }

    /// Files this thread is working on: what the user attached, plus any absolute path in
    /// the transcript that actually exists. Derived rather than tracked, so a path the
    /// assistant only planned to write never appears — it isn't there.
    private var previewFiles: [URL] {
        var seen = Set<String>()
        var found: [URL] = []

        func considerHandoff() {
            guard let handed = model.pendingPreviewFile,
                FileManager.default.fileExists(atPath: handed.path)
            else { return }
            seen.insert(handed.path)
            found.append(handed)
        }

        func consider(_ path: String) {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'.,)]"))
            var isDirectory: ObjCBool = false
            guard trimmed.hasPrefix("/"), !seen.contains(trimmed),
                FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { return }
            seen.insert(trimmed)
            found.append(URL(fileURLWithPath: trimmed))
        }

        // Tool output is where a file a command produced actually announces itself — the
        // assistant's prose may never mention the path at all.
        for entry in ChatConsoleLog.shared.entries(for: model.activeScope).suffix(20) {
            let output = entry.output
            var index = output.startIndex
            while let range = output.range(
                of: "/[A-Za-z0-9._~/@+-]+\\.[A-Za-z0-9]{1,8}", options: .regularExpression,
                range: index..<output.endIndex)
            {
                consider(String(output[range]))
                index = range.upperBound
            }
        }

        for message in model.messages.suffix(30) {
            message.attachments.forEach { consider($0.path) }
            let pattern = "/[A-Za-z0-9._~/@+-]+\\.[A-Za-z0-9]{1,8}"
            let content = message.content
            var index = content.startIndex
            while let range = content.range(
                of: pattern, options: .regularExpression, range: index..<content.endIndex)
            {
                consider(String(content[range]))
                index = range.upperBound
            }
        }
        model.attachments.forEach { consider($0.path) }
        // What this thread built, after what it merely mentioned: a chart the answer just
        // produced is more likely to be what the user wants to look at than a path it
        // quoted in passing.
        ArtifactStore.artifacts(for: model.activeScope).forEach { consider($0.path) }
        // Last, so it is the one Preview opens on — the file the user asked to see wins
        // over whatever the transcript happened to mention most recently.
        considerHandoff()
        return found
    }

    /// Opens the panel on the handed-over file. Without this the file is merely in the
    /// candidate list, behind a panel that may be closed and a tab that may be Terminal —
    /// which is indistinguishable from the handoff not working.
    private func revealHandoffIfNeeded() {
        guard model.pendingPreviewFile != nil else { return }
        chrome.sidePanelVisible = true
        panelTab = .preview
    }

    private var panelTabs: some View {
        HStack(spacing: 6) {
            if hasTerminal { tabPill("Terminal", tab: .terminal, symbol: "terminal") }
            if !previewFiles.isEmpty {
                tabPill("Preview", tab: .preview, symbol: "doc.text")
            }
            if !artifactFiles.isEmpty {
                // Counted, because a report filed by a capability says so in the answer and
                // then sits behind a tab that looks identical whether it holds one document
                // or none. A number is the difference between "it saved something" and
                // having to go and check.
                tabPill(
                    "Artifacts", tab: .artifacts, symbol: "square.on.square",
                    badge: artifactFiles.count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func tabPill(
        _ title: String, tab: PanelTab, symbol: String, badge: Int? = nil
    ) -> some View {
        let active = effectivePanelTab == tab
        return Button { panelTab = tab } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                active ? Color.accentColor.opacity(0.32)
                                       : Color.primary.opacity(0.12)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
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
