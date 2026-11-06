// ConversationsBoardCard.swift
// Context-Dock
//
// Conversations Board: browse and reopen past conversations across all scopes (Issue #334).
//
// Reads existing conversation storage (GeneralChatSessionStore and AppPanelChatStore)
// without duplicating transcripts. Reopening a conversation displays its stored messages
// in its proper scope view.

import AppKit
import SwiftUI

// MARK: - Board Model & Helpers

enum ConversationsBoardMetrics {
    static let headerHeight: CGFloat = 38
    static let footerHeight: CGFloat = 36
    static var size: CGSize { ClipboardBoardMetrics.size }
}

enum ConversationsBoardFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case appPets = "App Pets"
    case generalCombined = "General & Combined"

    var id: String { rawValue }
}

struct ConversationsBoardItem: Identifiable, Equatable {
    var id: String { session.id }
    let session: GeneralChatSession
    let relativeDate: String
    let icon: NSImage?
    let iconSymbol: String
    let scopeLabel: String
    let previewSnippet: String

    static func == (lhs: ConversationsBoardItem, rhs: ConversationsBoardItem) -> Bool {
        lhs.session == rhs.session && lhs.previewSnippet == rhs.previewSnippet
    }
}

enum ConversationsBoard {
    static let provider = "conversations"

    static func relativeDateString(for date: Date) -> String {
        let elapsed = -date.timeIntervalSinceNow
        if elapsed < 60 { return "just now" }
        if elapsed < 3_600 {
            let mins = max(1, Int(elapsed / 60))
            return "\(mins)m ago"
        }
        if elapsed < 86_400 {
            let hours = max(1, Int(elapsed / 3_600))
            return "\(hours)h ago"
        }
        if elapsed < 172_800 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func items(
        sessions: [GeneralChatSession],
        query: String,
        filter: ConversationsBoardFilter
    ) -> [ConversationsBoardItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filteredByScope = sessions.filter { session in
            switch filter {
            case .all:
                return true
            case .appPets:
                if case .app = session.scope { return true }
                if case .cli = session.scope { return true }
                return false
            case .generalCombined:
                if case .general = session.scope { return true }
                if case .thread = session.scope { return true }
                if case .folder = session.scope { return true }
                return false
            }
        }

        let sorted = filteredByScope.sorted { $0.sortDate > $1.sortDate }

        let mapped = sorted.compactMap { session -> ConversationsBoardItem? in
            let titleLower = session.title.lowercased()
            let scopeKeyLower = session.scope.storageKey.lowercased()

            // Scope metadata
            let icon: NSImage?
            let iconSymbol: String
            let scopeLabel: String

            switch session.scope {
            case .app(let bundleId):
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    icon = NSWorkspace.shared.icon(forFile: url.path)
                } else {
                    icon = nil
                }
                iconSymbol = "app.fill"
                scopeLabel = "App Pet"
            case .cli(let cmd):
                icon = nil
                iconSymbol = "terminal"
                scopeLabel = "CLI"
            case .general:
                icon = nil
                iconSymbol = "bubble.left.and.bubble.right"
                scopeLabel = "General Chat"
            case .thread(let id):
                icon = nil
                iconSymbol = session.scope.isWorkspace ? "person.2.fill" : "archivebox"
                scopeLabel = session.scope.isWorkspace ? "Combined Chat" : "Thread"
            case .folder:
                icon = nil
                iconSymbol = "folder"
                scopeLabel = "Folder"
            }

            // Quick message snippet lookup for query matching & subtitle
            let messages = GeneralChatSessionStore.load(scope: session.scope)
            let lastAssistant = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })
            let lastUser = messages.last(where: { $0.role == .user && !$0.content.isEmpty })
            let snippet = lastAssistant?.content ?? lastUser?.content ?? ""
            let cleanSnippet = snippet.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedQuery.isEmpty {
                let matchesTitle = titleLower.contains(trimmedQuery)
                let matchesScope = scopeKeyLower.contains(trimmedQuery)
                let matchesSnippet = cleanSnippet.lowercased().contains(trimmedQuery)
                guard matchesTitle || matchesScope || matchesSnippet else { return nil }
            }

            return ConversationsBoardItem(
                session: session,
                relativeDate: relativeDateString(for: session.sortDate),
                icon: icon,
                iconSymbol: iconSymbol,
                scopeLabel: scopeLabel,
                previewSnippet: cleanSnippet.isEmpty ? "No messages" : cleanSnippet
            )
        }

        return mapped
    }

    static func moved(from current: String?, in ids: [String], down: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + (down ? 1 : -1), 0), ids.count - 1)]
    }
}

// MARK: - Board View

struct ConversationsBoardCard: View {
    @ObservedObject var prompt: AppChatPromptModel
    @State private var focusedID: String?
    @State private var activeFilter: ConversationsBoardFilter = .all
    @State private var previewMessages: [AIChatMessage] = []
    @State private var isDeleting = false

    private var size: CGSize { ConversationsBoardMetrics.size }

    private var sessions: [GeneralChatSession] {
        GeneralChatSessionStore.index()
    }

    private var items: [ConversationsBoardItem] {
        ConversationsBoard.items(
            sessions: sessions,
            query: prompt.query,
            filter: activeFilter
        )
    }

    private var focusedItem: ConversationsBoardItem? {
        let currentItems = items
        return currentItems.first { $0.id == focusedID } ?? currentItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: CornerBoardLayout.listWidth(
                        board: size.width, preview: .file(URL(fileURLWithPath: "/"))))
                Color.clear.frame(width: CornerBoardLayout.dividerWidth)
                preview
                    .frame(width: CornerBoardLayout.panelWidth(board: size.width))
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(BoardGlass())
        .onHover { _ in prompt.touch() }
        .onAppear {
            GeneralChatSessionStore.discoverDockThreads()
            registerKeys()
            loadFocusedPreview()
        }
        .onDisappear {
            ScopedListKeyBridge.shared.move = nil
            ScopedListKeyBridge.shared.run = nil
        }
        .onChange(of: focusedID) { _, _ in
            loadFocusedPreview()
        }
    }

    // MARK: - Keyboard Handling

    private func registerKeys() {
        let bridge = ScopedListKeyBridge.shared
        bridge.move = { down in
            let ids = items.map(\.id)
            guard !ids.isEmpty else { return false }
            focusedID = ConversationsBoard.moved(from: focusedItem?.id, in: ids, down: down)
            prompt.touch()
            return true
        }
        bridge.run = {
            if let target = focusedItem {
                reopen(target)
            }
            return true
        }
    }

    private func loadFocusedPreview() {
        guard let item = focusedItem else {
            previewMessages = []
            return
        }
        previewMessages = GeneralChatSessionStore.load(scope: item.session.scope)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))

            Text("Past Conversations")
                .font(.system(size: 12, weight: .semibold))

            Text("\(items.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            // Scope filter pills
            HStack(spacing: 4) {
                ForEach(ConversationsBoardFilter.allCases) { filter in
                    Button {
                        activeFilter = filter
                        prompt.touch()
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 10.5, weight: activeFilter == filter ? .semibold : .regular))
                            .foregroundStyle(activeFilter == filter ? Color.primary : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                activeFilter == filter
                                    ? Color.primary.opacity(0.12)
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .padding(.horizontal, 16)
        .frame(height: ConversationsBoardMetrics.headerHeight)
    }

    // MARK: - Left Column (List)

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Text(prompt.query.isEmpty ? "No conversations yet" : "No matching conversations")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Text("Conversations from App Pets and General Chat appear here.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(items) { item in
                            row(item)
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: focusedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ item: ConversationsBoardItem) -> some View {
        let isSelected = item.id == (focusedItem?.id ?? items.first?.id)
        return HStack(spacing: 8) {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5))
            } else {
                Image(systemName: item.iconSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(item.relativeDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 5) {
                    Text(item.scopeLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: Capsule())

                    Text(item.previewSnippet)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            focusedID = item.id
            prompt.touch()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                reopen(item)
            }
        )
    }

    // MARK: - Right Column (Preview)

    private var preview: some View {
        Group {
            if let item = focusedItem {
                VStack(alignment: .leading, spacing: 6) {
                    // Preview Header
                    HStack(spacing: 8) {
                        if let icon = item.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: item.iconSymbol)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24, height: 24)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.session.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text("\(item.scopeLabel) · \(item.session.messageCount) messages · \(item.relativeDate)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            reopen(item)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Open")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                    Divider().opacity(0.14)

                    // Transcript messages scroll
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if previewMessages.isEmpty {
                                Text("No stored messages in this thread.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 20)
                            } else {
                                ForEach(Array(previewMessages.prefix(40).enumerated()), id: \.offset) { _, msg in
                                    previewBubble(msg)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a conversation to preview")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func previewBubble(_ msg: AIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if msg.role == .user {
                Spacer(minLength: 20)
                Text(msg.content)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(msg.content)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 20)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("↩")
                    .font(.system(size: 10, weight: .bold))
                Text("Open in Chat")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("⌘⌫")
                    .font(.system(size: 10, weight: .bold))
                Text("Clear History")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)

            Spacer()

            if let item = focusedItem {
                Button {
                    clear(item)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Clear")
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear this conversation history")
            }

            Button {
                prompt.leaveScopeForGlobal()
            } label: {
                Text("Esc Back")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: ConversationsBoardMetrics.footerHeight)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Actions

    private func reopen(_ item: ConversationsBoardItem) {
        prompt.leaveScopeForGlobal()
        switch item.session.scope {
        case .app(let bundleId):
            AppChatPromptModel.changeScope(app: item.session.title, bundleID: bundleId)
            CornerChatPresentation.shared.showPet(
                target: CornerChatTarget(name: item.session.title, bundleID: bundleId))
            prompt.expectAnswer()
        case .cli(let cmd):
            AppChatPromptModel.changeScope(app: cmd, bundleID: "cli://\(cmd)")
            CornerChatPresentation.shared.showPet(
                target: CornerChatTarget(name: cmd, bundleID: "cli://\(cmd)"))
            prompt.set(.chat)
        case .general:
            CornerChatPresentation.shared.show(.general)
            GeneralChatWindowModel.shared.openGeneralSession()
            prompt.set(.hidden)
        case .thread:
            GeneralChatWindowModel.shared.openSession(item.session.scope, title: item.session.title)
            CornerChatPresentation.shared.show(.general)
            prompt.set(.hidden)
        case .folder(let path):
            AppChatPromptModel.changeScope(app: item.session.title, bundleID: path)
            CornerChatPresentation.shared.show(.general)
            prompt.set(.hidden)
        }
    }

    private func clear(_ item: ConversationsBoardItem) {
        GeneralChatSessionStore.purge(scope: item.session.scope)
        focusedID = nil
        loadFocusedPreview()
        prompt.touch()
    }
}
