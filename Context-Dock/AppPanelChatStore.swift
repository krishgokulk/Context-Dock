// AppPanelChatStore.swift
// ILauncher
//
// Persistent chat history — one JSON file per app panel key.
// Storage: ~/Library/Application Support/ILauncher/Chats/{appKey}.json
// Keeps the last 200 messages per panel. Automatically created on first save.

import Foundation

// MARK: - Codable message (subset of AIChatMessage — skips interactive roles)

struct StoredChatMessage: Codable {
    let role: String          // "user" | "assistant" | "tool"
    let content: String
    let timestamp: Date
    let isError: Bool

    init(from msg: AIChatMessage) {
        switch msg.role {
        case .user:       role = "user"
        case .tool:       role = "tool"
        case .approval:   role = "approval"   // persisted but rendered as assistant
        case .assistant:  role = "assistant"
        }
        content   = msg.content
        timestamp = msg.timestamp
        isError   = msg.isError
    }

    func toAIChatMessage() -> AIChatMessage {
        let chatRole: AIChatMessage.ChatRole = {
            switch role {
            case "user":    return .user
            case "tool":    return .tool
            default:        return .assistant
            }
        }()
        return AIChatMessage(role: chatRole, content: content, isError: isError)
    }
}

// MARK: - Store

final class AppPanelChatStore {
    static let shared = AppPanelChatStore()

    private let baseDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxMessages = 200   // cap per panel

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        baseDir = support.appendingPathComponent("ILauncher/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: Load

    func load(for appKey: String) -> [AIChatMessage] {
        let file = chatFile(for: appKey)
        guard let data = try? Data(contentsOf: file),
              let stored = try? decoder.decode([StoredChatMessage].self, from: data)
        else { return [] }
        return stored.map { $0.toAIChatMessage() }
    }

    // MARK: Save

    func save(_ messages: [AIChatMessage], for appKey: String) {
        let stored = messages.suffix(maxMessages).map { StoredChatMessage(from: $0) }
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: chatFile(for: appKey), options: .atomic)
    }

    // MARK: Append single message (faster than full rewrite for live chats)

    func append(_ message: AIChatMessage, to appKey: String, existing: [AIChatMessage]) {
        var all = existing
        all.append(message)
        save(all, for: appKey)
    }

    // MARK: Clear

    func clear(for appKey: String) {
        try? FileManager.default.removeItem(at: chatFile(for: appKey))
    }

    func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: List all panels that have saved chats

    func allPanelKeys() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: Helpers

    private func chatFile(for appKey: String) -> URL {
        // Sanitise key so it's safe as a filename
        let safe = appKey
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined(separator: "_")
        return baseDir.appendingPathComponent("\(safe).json")
    }
}

// MARK: - Notification for tool removal

extension Notification.Name {
    static let appPanelToolRemoved = Notification.Name("AppPanelToolRemoved")
}
