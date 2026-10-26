// CLIVerbClassifier.swift
// Context-Dock
//
// Classifies a CLI invocation as read / write / outbound from its command path, so a
// user-installed CLI (plan §6.1) becomes capabilities with the right gate: reads run
// freely, writes and sends ask. Pure and static — the tested keystone of the CLI learner,
// reachable without a Mac, a model or a live `--help` run.

import Foundation

/// What running a command does, in gate terms.
enum CLIVerbClass: String, Codable, Equatable, Sendable {
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

    // MARK: - Classification

    /// Classify an invocation of a learned CLI.
    ///
    /// The WHOLE leading command path is read, not only its first token. A CLI whose
    /// destructive verbs live under a noun puts the verb in the second position —
    /// `mail-app-cli messages delete 42`, `mail-app-cli mailboxes mark-read`, `gh repo
    /// delete`. Reading only the first token took the noun ("messages", "mailboxes",
    /// "repo") as the command, and a plural noun reads as an enumeration, so a delete
    /// was classified as a READ and ran without asking. That is the one mistake this gate
    /// must never make: the first token is a noun far more often than it is a verb.
    ///
    /// `learnedPaths` is the tool's own manifest — the command paths its `--help` scan
    /// found. When the invocation names a command the manifest knows, the manifest
    /// decides: the tool said what that command does, and the gate believes the tool.
    /// Without a match the static verb lists decide, and anything unknown asks.
    ///
    /// `binary` is the tool's command name, stripped from the front when the model
    /// spelled the whole invocation out.
    static func classify(
        _ invocation: String,
        learnedPaths: [String] = [],
        binary: String? = nil
    ) -> CLIVerbClass {
        let chain = leadingCommandPath(invocation, binary: binary)
        guard !chain.isEmpty else { return .write }

        // 1. The tool's own manifest wins: the LONGEST learned path that prefixes the
        //    invocation names the command, and its verb decides.
        if let match = longestLearnedMatch(chain: chain, learnedPaths: learnedPaths),
           let cls = verbClass(ofCommand: match) {
            return cls
        }
        // 2. Otherwise the invocation's own verbs decide. The most dangerous class wins:
        //    a send anywhere is outbound, a mutating verb anywhere is a write.
        if let cls = verbClass(inChain: chain) { return cls }
        // 3. A single bare noun that names a collection is an enumeration, not an action.
        if chain.count == 1, readNouns.contains(chain[0].lowercased()) { return .read }
        // 4. Unknown: ask. The safe default (§6.1).
        return .write
    }

    // MARK: - The command path

    /// The leading command path: the tokens before the first flag.
    ///
    /// Everything from a flag on is that flag's value, not part of the command.
    /// `messages list --search delete` searches for the word "delete" and is still a read,
    /// so the flag ends the path rather than being scanned for verbs.
    static func leadingCommandPath(_ invocation: String, binary: String? = nil) -> [String] {
        var tokens = tokenize(invocation)
        if let binary, !binary.isEmpty,
           let first = tokens.first,
           first.caseInsensitiveCompare(binary) == .orderedSame {
            tokens.removeFirst()
        }
        var chain: [String] = []
        for token in tokens {
            if token.hasPrefix("-") { break }
            chain.append(token)
        }
        return chain
    }

    /// Split an invocation into tokens, honouring quotes so a quoted value stays one
    /// token. Deliberately lenient: the shell-syntax gate runs before this one and
    /// refuses anything unquotable, so there is nothing to reject here.
    static func tokenize(_ invocation: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var sawQuotedContent = false
        for character in invocation {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                sawQuotedContent = true
            case " ", "\t":
                if !current.isEmpty || sawQuotedContent {
                    tokens.append(current)
                    current = ""
                    sawQuotedContent = false
                }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty || sawQuotedContent { tokens.append(current) }
        return tokens
    }

    /// The longest learned command path that prefixes the invocation, or nil.
    ///
    /// Longest wins: "messages delete" says more than "messages", and the manifest is
    /// the best evidence of what a command does.
    static func longestLearnedMatch(chain: [String], learnedPaths: [String]) -> String? {
        guard !learnedPaths.isEmpty, !chain.isEmpty else { return nil }
        let known = Set(learnedPaths.map { $0.lowercased() })
        for length in stride(from: chain.count, through: 1, by: -1) {
            let candidate = chain.prefix(length).joined(separator: " ")
            if known.contains(candidate.lowercased()) { return candidate }
        }
        return nil
    }

    // MARK: - Verbs

    /// The class of a command path's verb — the last token of the path — or nil when the
    /// path names no known verb.
    static func verbClass(ofCommand command: String) -> CLIVerbClass? {
        let leaf = command.split(separator: " ").last.map(String.init) ?? command
        return verbClass(ofToken: leaf)
    }

    /// The class of the whole command path: the most dangerous verb on it decides.
    ///
    /// A send anywhere is outbound, a mutating verb anywhere is a write, and only then
    /// does a read verb grant a read. That ordering is what makes `messages list` a read
    /// and `messages delete` a write, and it is why a known verb later on the path can
    /// never make a write look like a read.
    static func verbClass(inChain chain: [String]) -> CLIVerbClass? {
        for token in chain where outboundVerbs.contains(token.lowercased()) { return .outbound }
        for token in chain where writeVerbs.contains(token.lowercased()) { return .write }
        // A compound may hide the verb: `mailboxes mark-read` is a write.
        for token in chain {
            if let cls = compoundVerbClass(ofToken: token) { return cls }
        }
        for token in chain where readVerbs.contains(token.lowercased()) { return .read }
        return nil
    }

    /// The class of one token, or nil when it names no known verb.
    static func verbClass(ofToken token: String) -> CLIVerbClass? {
        let lower = token.lowercased()
        if outboundVerbs.contains(lower) { return .outbound }
        if writeVerbs.contains(lower) { return .write }
        if readVerbs.contains(lower) { return .read }
        return compoundVerbClass(ofToken: token)
    }

    /// A compound verb ("mark-read", "unflag") is decided by its parts, and only a
    /// destructive part counts: "mark-read" is a write even though it also contains
    /// "read", while an unknown compound that merely contains a read word
    /// ("search-bar") is not a read — it stays unknown, and unknown asks.
    static func compoundVerbClass(ofToken token: String) -> CLIVerbClass? {
        let lower = token.lowercased()
        guard lower.contains("-") else { return nil }
        let parts = lower.split(separator: "-").map(String.init)
        for part in parts where outboundVerbs.contains(part) { return .outbound }
        for part in parts where writeVerbs.contains(part) { return .write }
        return nil
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
