// CLIVerbClassifier.swift
// Context-Dock
//
// Classifies a CLI subcommand as read / write / outbound from its leading verb, so a
// user-installed CLI (plan §6.1) becomes capabilities with the right gate: reads run
// freely, writes and sends ask. Pure and static — the tested keystone of the CLI learner,
// reachable without a Mac, a model or a live `--help` run.

import Foundation

/// What running a subcommand does, in gate terms.
enum CLIVerbClass: Equatable, Sendable {
    /// Reads or lists; runs without a card.
    case read
    /// Changes local state (delete/move/archive/…); asks the owner first.
    case write
    /// Sends something off this Mac (send/reply/forward): a write AND the outbound channel
    /// the lethal-trifecta gate also watches.
    case outbound

    /// Writes and sends always ask (AGENTS.md: "writes/outbound ALWAYS ask"); reads do not.
    var requiresApproval: Bool { self != .read }
}

enum CLIVerbClassifier {
    /// Verbs that only read (§6.1).
    static let readVerbs: Set<String> = [
        "list", "show", "search", "get", "read", "view", "ls", "cat", "find",
        "count", "status", "info", "describe",
    ]
    /// Verbs that change local state (§6.1).
    static let writeVerbs: Set<String> = [
        "delete", "move", "archive", "flag", "mark", "rm", "trash", "edit", "set",
        "create", "update", "rename", "mkdir",
    ]
    /// Verbs that send data to another person — a write that is also outbound (§6.1).
    static let outboundVerbs: Set<String> = [
        "send", "compose", "reply", "forward",
    ]

    /// Classify a subcommand on its first token, case-insensitively.
    static func classify(_ subcommand: String) -> CLIVerbClass {
        let token = subcommand
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map { String($0).lowercased() } ?? ""
        // Outbound first: `send` is both a write and a send, and the send is what the gate
        // must see.
        if outboundVerbs.contains(token) { return .outbound }
        if writeVerbs.contains(token) { return .write }
        if readVerbs.contains(token) { return .read }
        // A bare plural noun names a collection to enumerate (accounts, mailboxes,
        // attachments) rather than an action — a read. No write or outbound verb above is
        // plural, so this only ever widens reads.
        // ponytail: a plural destructive verb (none known on a real CLI today) would slip
        // through as a read; revisit the day a tool ships one.
        if token.count > 3, token.hasSuffix("s") { return .read }
        // Unknown verb: ask. The safe default (§6.1).
        return .write
    }
}

/// The owner's review after a CLI is learned: which subcommands fall into each class, and a
/// one-line summary for the + Add CLI flow.
struct LearnedCLISummary: Equatable {
    let read: [String]
    let write: [String]
    let outbound: [String]

    init(subcommands: [String]) {
        var r: [String] = [], w: [String] = [], o: [String] = []
        for sub in subcommands {
            switch CLIVerbClassifier.classify(sub) {
            case .read: r.append(sub)
            case .write: w.append(sub)
            case .outbound: o.append(sub)
            }
        }
        read = r; write = w; outbound = o
    }

    var total: Int { read.count + write.count + outbound.count }

    /// "Learned 12 commands: 6 read, 5 write, 1 sends mail. Enable reads? Writes ask each time."
    var sentence: String {
        var parts = ["\(read.count) read", "\(write.count) write"]
        if !outbound.isEmpty {
            parts.append("\(outbound.count) send\(outbound.count == 1 ? "s" : "") mail")
        }
        return "Learned \(total) command\(total == 1 ? "" : "s"): "
            + parts.joined(separator: ", ")
            + ". Enable reads? Writes ask each time."
    }
}
