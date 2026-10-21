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
    /// Verbs that change local state (§6.1). `save` writes a file to disk.
    static let writeVerbs: Set<String> = [
        "delete", "move", "archive", "flag", "mark", "rm", "trash", "edit", "set",
        "create", "update", "rename", "mkdir", "save",
    ]
    /// Verbs that send data to another person — a write that is also outbound (§6.1).
    static let outboundVerbs: Set<String> = [
        "send", "compose", "reply", "forward",
    ]
    /// Collection nouns that name something to enumerate — a read. Explicit, because a
    /// blanket "any plural noun is a read" rule would mis-read a mutating verb that happens
    /// to end in `s` (compress, process) as safe. These are the known enumeration nouns of
    /// the mail CLIs §2b/§7 describe; an unknown token is a write, never a read.
    static let readNouns: Set<String> = [
        "accounts", "account", "mailboxes", "mailbox", "attachments", "messages",
        "folders", "labels", "threads", "drafts", "drives",
    ]

    /// Classify a subcommand, case-insensitively. Every non-flag token is considered, not
    /// only the first: a noun-first command like `attachments save` must be seen as the write
    /// its later token makes it, not read as its leading noun. Flags (`--json`, `-h`) and
    /// quoted values are skipped so a flag value cannot flip the class.
    static func classify(_ subcommand: String) -> CLIVerbClass {
        let words = subcommand
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.hasPrefix("-") && !$0.hasPrefix("\"") && !$0.hasPrefix("'") }
        // Most-dangerous class wins: a send anywhere in the invocation is outbound; any write
        // verb makes it a write. `send` is deliberately in both buckets and outbound wins.
        if words.contains(where: outboundVerbs.contains) { return .outbound }
        if words.contains(where: writeVerbs.contains) { return .write }
        // Only a recognised read verb or enumeration noun as the leading word runs cardless.
        if let first = words.first, readVerbs.contains(first) || readNouns.contains(first) {
            return .read
        }
        // Unknown: ask. The safe default (§6.1).
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
