// GeneralChatSessionStore.swift
// Context-Dock
//
// Conversations kept per scope, so the general chat window can act as one hub for every app
// and CLI tool rather than a single rolling chat.
//
// A session is just stored text: it does not require its app to be running, or installed, or
// frontmost. That is the point — "what did I ask Reminders last week" should be answerable
// with Reminders closed, the same way a desktop chat app keeps a thread per topic.
//
// Message bodies stay in GeneralAIChatConversationStore's format. This adds the index — which
// sessions exist, what each is about — and one conversation blob per session, so the existing
// sheet/window round trip is untouched.

import AppKit
import Foundation

/// What a session is scoped to. The raw value is the storage key, so it must stay stable.
enum GeneralChatScope: Codable, Hashable {
    /// An installed app, by bundle identifier.
    case app(bundleId: String)
    /// A pinned CLI tool, by command.
    case cli(command: String)
    /// The unscoped conversation — the one the result sheet and the window already share.
    case general

    var storageKey: String {
        switch self {
        case .app(let bundleId): return "app:\(bundleId)"
        case .cli(let command): return "cli:\(command.lowercased())"
        case .general: return "general"
        }
    }
}

struct GeneralChatSession: Identifiable, Codable, Equatable {
    var id: String { scope.storageKey }
    let scope: GeneralChatScope
    /// Shown in the sidebar. Held rather than derived so a renamed or removed app still reads
    /// as what the user was talking to.
    var title: String
    var updatedAt: Date
    var messageCount: Int

    static func == (lhs: GeneralChatSession, rhs: GeneralChatSession) -> Bool {
        lhs.scope == rhs.scope && lhs.updatedAt == rhs.updatedAt
            && lhs.messageCount == rhs.messageCount && lhs.title == rhs.title
    }
}

enum GeneralChatSessionStore {
    private static let indexKey = "dorax.generalAI.sessionIndex.v1"

    /// Sessions, most recently used first.
    static func index() -> [GeneralChatSession] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
            let sessions = try? JSONDecoder().decode([GeneralChatSession].self, from: data)
        else { return [] }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func writeIndex(_ sessions: [GeneralChatSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: indexKey)
    }

    /// Registers a session, or refreshes what the sidebar shows for it.
    static func upsert(scope: GeneralChatScope, title: String, messageCount: Int) {
        var sessions = index().filter { $0.scope != scope }
        sessions.append(
            GeneralChatSession(
                scope: scope, title: title, updatedAt: Date(), messageCount: messageCount))
        writeIndex(sessions)
    }

    static func remove(scope: GeneralChatScope) {
        writeIndex(index().filter { $0.scope != scope })
        UserDefaults.standard.removeObject(forKey: conversationKey(scope))
    }

    // MARK: - Conversations

    private static func conversationKey(_ scope: GeneralChatScope) -> String {
        "dorax.generalAI.session.\(scope.storageKey).v1"
    }

    /// The unscoped session deliberately reads and writes the existing store, so a chat
    /// started in the result sheet is the same conversation the window opens on.
    static func load(scope: GeneralChatScope) -> [AIChatMessage] {
        guard scope != .general else { return GeneralAIChatConversationStore.load() }
        return GeneralAIChatConversationStore.load(key: conversationKey(scope))
    }

    static func save(_ messages: [AIChatMessage], scope: GeneralChatScope, title: String) {
        if scope == .general {
            GeneralAIChatConversationStore.save(messages)
        } else {
            GeneralAIChatConversationStore.save(messages, key: conversationKey(scope))
        }
        upsert(scope: scope, title: title, messageCount: messages.count)
    }

    // MARK: - Presentation

    /// Icon for a session row: the app's real icon, or a terminal glyph for a CLI tool.
    @MainActor
    static func icon(for scope: GeneralChatScope) -> NSImage? {
        switch scope {
        case .app(let bundleId):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .cli:
            return NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
        case .general:
            return NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        }
    }
}
