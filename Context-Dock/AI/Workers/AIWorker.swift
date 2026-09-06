import Foundation

/// An external agent runtime DoraX can hand a bounded problem to.
///
/// Not a provider and not a capability. A provider is a model DoraX reasons with; a capability
/// is a deterministic action it performs. A worker is a harness that can read, search, run and
/// verify on its own — Claude Code and Codex are ones the user already has installed.
///
/// They are seeded today as CLI tools on the Claude and Codex app adapters
/// (`AdapterIntegrationSeeder`), which makes them reachable from those two chats and invisible
/// everywhere else. Modelling them here is what lets any scope consider one without pinning
/// Claude Code to every app in the list.
enum AIWorkerKind: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Offer order when several can do the job. Fixed rather than derived, so the button under
    /// the user's cursor is in the same place every time.
    var offerRank: Int {
        switch self {
        case .claudeCode: return 0
        case .codex: return 1
        }
    }
}

/// What a worker is good for. A worker that claims everything is a hammer, and the point of
/// this layer is that a specialist is chosen deliberately.
enum AIWorkerDomain: String, Codable, CaseIterable, Sendable {
    case coding
    case repository
    case build
    case test
    case systemInspection
}

struct AIWorker: Equatable, Identifiable, Sendable {
    let kind: AIWorkerKind
    let executablePath: URL
    let domains: Set<AIWorkerDomain>

    var id: String { kind.rawValue }
    var displayName: String { kind.displayName }
}

/// Whether a request is work for a specialist, and which ones may be offered.
///
/// Pure on purpose: a worker costs minutes and money, so the decision to offer one has to be
/// testable without installing either agent or spawning anything.
enum AIWorkerRouter {
    /// Is this work, rather than a question?
    ///
    /// The rung above this one proposes a read-only command the user approves, which answers a
    /// question in a moment. Handing "is there a newer version" to an agent for minutes to
    /// learn what one curl returns is the mistake this gate exists to prevent — so a request
    /// has to name work before a worker is even considered.
    static func isWorkerShaped(_ query: String) -> Bool {
        let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let questionOpeners = ["what", "when", "where", "who", "why", "how", "is", "are", "does",
                               "did", "can", "should", "summarise", "summarize", "tell me"]
        let firstWord = text.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        if questionOpeners.contains(firstWord) { return false }
        if text.hasSuffix("?") { return false }

        return !domains(for: text).isEmpty
    }

    /// The domains a request touches. Empty means nothing recognisable — and unrecognised work
    /// is not handed to a specialist on a guess.
    static func domains(for query: String) -> Set<AIWorkerDomain> {
        let text = query.lowercased()
        var found: Set<AIWorkerDomain> = []

        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if any(["fix", "refactor", "implement", "write code", "rename", "edit", "debug",
                "compile error", "stack trace", "crash"]) {
            found.insert(.coding)
        }
        if any(["repo", "repository", "git", "branch", "commit", "diff", "merge"]) {
            found.insert(.repository)
        }
        if any(["build", "compile", "xcodebuild", "bundle"]) { found.insert(.build) }
        if any(["test", "tests", "suite", "coverage"]) { found.insert(.test) }
        if any(["installation", "installed", "inspect", "investigate", "diagnose",
                "why does", "package manager", "brew"]) {
            found.insert(.systemInspection)
        }
        return found
    }

    /// The workers that may be offered for this request, best first.
    ///
    /// Installed workers are passed in rather than looked up: discovery belongs to the layer
    /// that caches it, and a router that reaches for a singleton cannot be tested without one.
    static func eligible(for query: String, from installed: [AIWorker]) -> [AIWorker] {
        guard isWorkerShaped(query) else { return [] }
        let wanted = domains(for: query)
        guard !wanted.isEmpty else { return [] }

        return installed
            .filter { !$0.domains.isDisjoint(with: wanted) }
            .sorted { left, right in
                let leftMatches = left.domains.intersection(wanted).count
                let rightMatches = right.domains.intersection(wanted).count
                if leftMatches != rightMatches { return leftMatches > rightMatches }
                return left.kind.offerRank < right.kind.offerRank
            }
    }
}
