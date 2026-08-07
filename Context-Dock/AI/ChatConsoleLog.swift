// ChatConsoleLog.swift
// Context-Dock
//
// What DoraX actually ran for a thread, in the order it happened.
//
// The chat says what it concluded; this says what it did. Every command, tool call and
// route lands here with its real output, so a claim in the transcript can be checked
// rather than trusted — the same reason Codex keeps a terminal beside the conversation.
//
// Kept per thread and in memory: it is a record of this session's work, not a second
// conversation to persist.

import Combine
import Foundation

struct ChatConsoleEntry: Identifiable, Equatable {
    enum Source: String {
        case command      // a shell command
        case tool         // an agent tool or MCP call
        case route        // a route the user picked
        case note         // something the surface wants on the record

        var symbol: String {
            switch self {
            case .command: return "terminal"
            case .tool: return "wrench.and.screwdriver"
            case .route: return "arrow.triangle.branch"
            case .note: return "info.circle"
            }
        }
    }

    let id = UUID()
    let at: Date
    let source: Source
    /// What ran, verbatim where possible: `git log -1`, `run_capability(yt-history)`.
    let title: String
    /// Raw output. Never summarised — a receipt that paraphrases is not a receipt.
    let output: String
    let success: Bool
}

@MainActor
final class ChatConsoleLog: ObservableObject {
    static let shared = ChatConsoleLog()

    /// Entries by scope storage key, so switching threads switches the log with it.
    @Published private(set) var entriesByScope: [String: [ChatConsoleEntry]] = [:]

    private let maxPerScope = 200

    private init() {}

    func entries(for scope: GeneralChatScope) -> [ChatConsoleEntry] {
        entriesByScope[scope.storageKey] ?? []
    }

    func append(_ entry: ChatConsoleEntry, scope: GeneralChatScope) {
        var list = entriesByScope[scope.storageKey] ?? []
        list.append(entry)
        if list.count > maxPerScope { list.removeFirst(list.count - maxPerScope) }
        entriesByScope[scope.storageKey] = list
    }

    func append(
        _ source: ChatConsoleEntry.Source,
        title: String,
        output: String,
        success: Bool,
        scope: GeneralChatScope
    ) {
        append(
            ChatConsoleEntry(
                at: Date(), source: source, title: title, output: output, success: success),
            scope: scope)
    }

    func clear(scope: GeneralChatScope) {
        entriesByScope[scope.storageKey] = []
    }

    /// The whole log as text, for copying into a bug report or a commit message.
    func plainText(scope: GeneralChatScope) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries(for: scope)
            .map { entry in
                let head = "[\(formatter.string(from: entry.at))] \(entry.title)"
                return entry.output.isEmpty ? head : "\(head)\n\(entry.output)"
            }
            .joined(separator: "\n\n")
    }
}
