import Foundation

/// Where the specialists are, resolved once rather than per request.
///
/// Deliberately not on the typing path. Global Context answers while the user types, and a
/// filesystem probe there — let alone a process launch — is how a launcher stops feeling like
/// one. This runs on a background pass and writes what it found into `AIWorkerRegistry`; a
/// request reads that and nothing else.
///
/// The lookup is injected so the decision can be tested without either agent installed: what
/// counts as "found" is a rule, and a rule that can only be exercised on a machine that
/// happens to have Codex on it is not being tested at all.
enum AIWorkerDiscovery {
    /// Where each agent installs, in the order worth trying. The same list
    /// `ClaudeCodeCLIService.binaryPath()` walks for the CLI it runs as a provider — kept here
    /// too because a worker is found the same way whether it answers as a provider or is
    /// delegated to as a specialist.
    static var defaultCandidates: [AIWorkerKind: [String]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            .claudeCode: [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.claude/local/claude",
            ],
            .codex: [
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ],
        ]
    }

    /// What each specialist is good for. A property of the agent, not of where it was found.
    static func domains(for kind: AIWorkerKind) -> Set<AIWorkerDomain> {
        switch kind {
        case .claudeCode, .codex:
            return [.coding, .repository, .build, .test, .systemInspection]
        }
    }

    static func workers(
        candidates: [AIWorkerKind: [String]],
        isExecutable: (String) -> Bool
    ) -> [AIWorker] {
        candidates
            .compactMap { kind, paths -> AIWorker? in
                guard let path = paths.first(where: isExecutable) else { return nil }
                return AIWorker(
                    kind: kind,
                    executablePath: URL(fileURLWithPath: path),
                    domains: domains(for: kind))
            }
            // Dictionaries have no order, and an offer whose first button changes between
            // identical requests is worse than no offer.
            .sorted { $0.kind.offerRank < $1.kind.offerRank }
    }

    /// The real pass: run it off the main actor, at a moment nobody is waiting.
    static func discoverInstalled() -> [AIWorker] {
        workers(
            candidates: defaultCandidates,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
