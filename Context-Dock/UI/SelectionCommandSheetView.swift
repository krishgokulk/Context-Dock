import AppKit
import SwiftUI

struct SelectionContextSnapshot: Equatable {
    let sourceAppName: String
    let sourceBundleID: String
    let selectedText: String?
    let selectedFiles: [URL]
    let iconName: String
    let title: String
    let subtitle: String

    var userContext: UserContext {
        if !selectedFiles.isEmpty { return .filesSelected(selectedFiles) }
        if let selectedText, !selectedText.isEmpty { return .textSelected(selectedText) }
        return .appFocused(name: sourceAppName, bundleID: sourceBundleID)
    }
}

struct SelectionSheetCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let section: String
    let systemImage: String
    /// Real icon (app icon for Open With / Switch rows, file icon, etc.). When
    /// set, the row renders this instead of the SF symbol.
    let iconImage: NSImage?
    let shortcutDisplay: String?
    let score: Double
    let action: () -> Void

    init(
        id: String, title: String, subtitle: String, section: String,
        systemImage: String, iconImage: NSImage? = nil,
        shortcutDisplay: String?, score: Double, action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.section = section
        self.systemImage = systemImage
        self.iconImage = iconImage
        self.shortcutDisplay = shortcutDisplay
        self.score = score
        self.action = action
    }

    /// A copy promoted into the "Recommended" section. Subtitle becomes the origin
    /// section so the user sees *why* it's surfaced (the match reason).
    func recommendedCopy() -> SelectionSheetCommand {
        SelectionSheetCommand(
            id: "rec-\(id)", title: title, subtitle: section, section: "Recommended",
            systemImage: systemImage, iconImage: iconImage,
            shortcutDisplay: shortcutDisplay, score: score, action: action
        )
    }

    /// Single source of truth for ranked, sectioned ordering — used by both the
    /// sheet UI and keyboard navigation so display order and arrow order match.
    static func ranked(_ commands: [SelectionSheetCommand], searching: Bool)
        -> [(title: String, items: [SelectionSheetCommand])]
    {
        var order: [String] = []
        var dict: [String: [SelectionSheetCommand]] = [:]
        for command in commands {
            if dict[command.section] == nil { order.append(command.section) }
            dict[command.section, default: []].append(command)
        }
        for key in dict.keys { dict[key]?.sort { $0.score > $1.score } }
        var result = order.map { (title: $0, items: dict[$0] ?? []) }

        if !searching, result.count >= 2 {
            let top = commands.sorted { $0.score > $1.score }.prefix(3).map { $0.recommendedCopy() }
            if top.count >= 2 {
                result.insert((title: "Recommended", items: Array(top)), at: 0)
            }
        }
        return result
    }

    static func filtered(_ commands: [SelectionSheetCommand], query: String) -> [SelectionSheetCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return commands }
        return commands
            .compactMap { command -> SelectionSheetCommand? in
                let haystack = [
                    command.title,
                    command.subtitle,
                    command.section,
                    command.shortcutDisplay ?? "",
                ].joined(separator: " ").lowercased()
                guard haystack.contains(q) else { return nil }
                var score = command.score
                let title = command.title.lowercased()
                if title == q { score += 10_000 }
                if title.hasPrefix(q) { score += 7_500 }
                if title.contains(q) { score += 5_000 }
                return SelectionSheetCommand(
                    id: command.id,
                    title: command.title,
                    subtitle: command.subtitle,
                    section: command.section,
                    systemImage: command.systemImage,
                    iconImage: command.iconImage,
                    shortcutDisplay: command.shortcutDisplay,
                    score: score,
                    action: command.action
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }
}

struct SelectionCommandSheetView: View {
    let snapshot: SelectionContextSnapshot
    let commands: [SelectionSheetCommand]
    let onSelect: (SelectionSheetCommand) -> Void
    let onClose: () -> Void
    let onExpand: () -> Void
    let onAdd: () -> Void
    var chatMessages: [AIChatMessage] = []
    var isChatLoading: Bool = false
    var onAsk: (String) -> Void = { _ in }
    @Binding var focusedCommandID: String?
    @Binding var searchQuery: String
    @Binding var isExpanded: Bool
    @State private var localExpanded = false
    @State private var pendingCollapseResizeTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @Namespace private var focusNamespace
    private let focusEffectID = "selection-sheet-focus"
    private let collapsedPanelHeight: CGFloat = 132
    private let expandedPanelHeight: CGFloat = 560
    private var chatActive: Bool { !chatMessages.isEmpty || isChatLoading }
    private var hasQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // Auto-expand the moment the user types — results filter live, no need to
    // press the expand button first (Spotlight/Raycast behavior).
    private var expanded: Bool { localExpanded || isExpanded || chatActive || hasQuery }

    private var visibleCommands: [SelectionSheetCommand] {
        SelectionSheetCommand.filtered(commands, query: searchQuery)
    }

    private var sections: [(title: String, items: [SelectionSheetCommand])] {
        let searching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return SelectionSheetCommand.ranked(visibleCommands, searching: searching)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            if expanded {
                Divider().padding(.horizontal, 8)
                if chatActive {
                    // Chat replaces actions/menus/extensions in the same sheet.
                    chatList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    resultList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(width: 420)
        .onAppear {
            localExpanded = isExpanded
            pendingCollapseResizeTask?.cancel()
            ShortcutSheetPanelPresenter.shared.resize(
                height: expanded ? expandedPanelHeight : collapsedPanelHeight
            )
            focusedCommandID = nil
            DispatchQueue.main.async { searchFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { searchFocused = true }
        }
        .onChange(of: isExpanded) { _, newValue in
            localExpanded = newValue
            resizePanelForExpansionState(newValue)
        }
        .onChange(of: hasQuery) { _, _ in
            // Grow on first keystroke, shrink back when the field is cleared
            // (unless the user manually expanded or a chat is open).
            resizePanelForExpansionState(expanded)
        }
        .onChange(of: focusedCommandID) { _, id in
            if id == nil { DispatchQueue.main.async { searchFocused = true } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Close lives top-left only once the sheet is expanded — collapsed
            // state stays minimal (exit is the X inside the field).
            if expanded {
                sheetChromeButton(systemImage: "xmark", help: "Close", action: onClose)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Image(systemName: snapshot.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(snapshot.subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("Selection")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
            sheetChromeButton(
                systemImage: expanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: expanded ? "Collapse" : "Expand",
                action: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        localExpanded.toggle()
                        isExpanded = localExpanded
                        if !localExpanded {
                            focusedCommandID = nil
                        }
                    }
                    resizePanelForExpansionState(localExpanded)
                    if localExpanded {
                        onExpand()
                    }
                }
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            // Collapsed: the selection's own icon marks the field. Expanded:
            // it becomes a search glyph (the field is now a query box).
            Image(systemName: expanded ? "sparkle.magnifyingglass" : snapshot.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    expanded
                        ? (searchFocused ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        : AnyShapeStyle(Color.blue))
            TextField(
                expanded ? "Ask or run action" : snapshot.title,
                text: $searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($searchFocused)
            .onSubmit { submitQuery() }
            .onChange(of: searchQuery) { _, _ in
                let visibleIDs = Set(visibleCommands.map(\.id))
                if let focusedCommandID, !visibleIDs.contains(focusedCommandID) {
                    self.focusedCommandID = nil
                }
            }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    focusedCommandID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            // Right-end affordance: collapsed → exit (X), expanded → add-to-dock (+).
            if expanded {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.86))
                        .frame(width: 23, height: 23)
                        .background(
                            Circle().fill(Color.primary.opacity(searchFocused ? 0.13 : 0.09))
                        )
                }
                .buttonStyle(.plain)
                .help("Add selection to dock")
            } else {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.78))
                        .frame(width: 23, height: 23)
                        .background(Circle().fill(Color.primary.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 8)
        .background {
            capsuleGlass(focused: searchFocused && focusedCommandID == nil)
                .matchedGeometryEffect(
                    id: focusEffectID,
                    in: focusNamespace,
                    properties: .frame,
                    isSource: true
                )
                .opacity(focusedCommandID == nil ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Enter in the search field: run the top action only when it's a real
    /// match (word-prefix, not an accidental substring like "hi" ⊂ "this");
    /// otherwise send the query to the user's selected AI provider and switch
    /// the sheet into chat mode.
    private func submitQuery() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return }
        if !chatActive,
            let first = visibleCommands.first,
            isStrongCommandMatch(first, query: q)
        {
            onSelect(first)
            return
        }
        onAsk(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isStrongCommandMatch(_ command: SelectionSheetCommand, query: String) -> Bool {
        let words =
            command.title.lowercased().split(separator: " ").map(String.init)
            + command.subtitle.lowercased().split(separator: " ").map(String.init)
        let queryTokens = query.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty else { return false }
        return queryTokens.allSatisfy { token in
            words.contains { $0.hasPrefix(token) }
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chatMessages) { message in
                        chatBubble(message)
                            .id(message.id)
                    }
                    if isChatLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .id("selection-chat-loading")
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 420)
            .onChange(of: chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    if isChatLoading {
                        proxy.scrollTo("selection-chat-loading", anchor: .bottom)
                    } else if let last = chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = chatMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: AIChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(message.isError ? Color.red : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            message.role == .user
                                ? Color.accentColor.opacity(0.28)
                                : Color.primary.opacity(0.07)
                        )
                )
            if message.role != .user { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var resultList: some View {
        Group {
            if visibleCommands.isEmpty {
                Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No selection actions found"
                     : "No selection actions match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections, id: \.title) { section in
                                Section {
                                    ForEach(section.items) { command in
                                        SelectionSheetRowView(
                                            command: command,
                                            isFocused: focusedCommandID == command.id,
                                            namespace: focusNamespace,
                                            focusEffectID: focusEffectID,
                                            onSelect: onSelect
                                        )
                                        .id(command.id)
                                    }
                                } header: {
                                    Text(section.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.thinMaterial)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: focusedCommandID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.08)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func capsuleGlass(focused: Bool) -> some View {
        ZStack {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.white.opacity(focused ? 0.20 : 0.12), Color.white.opacity(0.035)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(focused ? 0.56 : 0.28), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? 1.2 : 0.8
                )
        }
    }

    private func sheetChromeButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func resizePanelForExpansionState(_ expanded: Bool) {
        pendingCollapseResizeTask?.cancel()
        if expanded {
            ShortcutSheetPanelPresenter.shared.resize(height: expandedPanelHeight)
            return
        }
        pendingCollapseResizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            ShortcutSheetPanelPresenter.shared.resize(height: collapsedPanelHeight)
        }
    }
}

private struct SelectionSheetRowView: View {
    let command: SelectionSheetCommand
    let isFocused: Bool
    let namespace: Namespace.ID
    let focusEffectID: String
    let onSelect: (SelectionSheetCommand) -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var highlighted: Bool { isFocused || isHovered }

    private var primaryTextColor: Color {
        if isFocused { return .white }
        if isHovered { return isDark ? .white : .primary }
        return .primary
    }
    private var accessoryColor: Color {
        if isFocused { return .white.opacity(0.82) }
        if isHovered { return isDark ? .white.opacity(0.8) : .secondary }
        return .secondary
    }
    private var accessoryBadgeFill: Color {
        isFocused ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)
    }

    var body: some View {
        Button { onSelect(command) } label: {
            HStack(spacing: 10) {
                if let iconImage = command.iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: command.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isFocused ? .white.opacity(0.92) : (isHovered && isDark ? .white.opacity(0.92) : .secondary))
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                    if !command.subtitle.isEmpty {
                        Text(command.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accessoryColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let shortcutDisplay = command.shortcutDisplay {
                    Text(shortcutDisplay)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(accessoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(accessoryBadgeFill)
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    if isFocused {
                        Capsule(style: .continuous)
                            .fill(isDark ? AnyShapeStyle(.ultraThinMaterial)
                                         : AnyShapeStyle(Color.accentColor))
                            .matchedGeometryEffect(
                                id: focusEffectID,
                                in: namespace,
                                properties: .frame,
                                isSource: false
                            )
                        if isDark {
                            Capsule(style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.055)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                        } else {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.8)
                        }
                    } else if isHovered {
                        Capsule(style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.08)
                                         : Color.accentColor.opacity(0.12))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
