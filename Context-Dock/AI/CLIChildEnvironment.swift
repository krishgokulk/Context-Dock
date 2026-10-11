import Foundation

/// The environment DoraX hands to a CLI it spawns (`claude -p`, `codex exec`).
///
/// DoraX inherits whatever environment launched it. When that was a Claude Code or Claude
/// desktop session — an agent running `./scripts/dev-run.sh` — the process carries the host
/// session's markers: `CLAUDECODE=1`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ENTRYPOINT`,
/// the host's messaging socket and token, its OAuth scopes, and an `ANTHROPIC_BASE_URL`
/// pointing at the host's own proxy. A `claude -p` that sees them believes it is a child of
/// that session, waits on host-provided auth, and answers "Not logged in · Please run /login"
/// (seen in Mail App Chat, 2026-10-06). The spawned CLI is DoraX's own process, not the
/// host's child, so those variables are removed.
///
/// What is kept on purpose: `ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR` and every other variable
/// a person sets in their own shell. A host session does not inject those; when present they
/// were configured deliberately and the CLI should honour them. `ANTHROPIC_BASE_URL` is the
/// one ambiguous case — a person can set it for a gateway — so it is removed only when the
/// host-session marker says the host put it there.
enum CLIChildEnvironment {

    /// Variables a host Claude Code session sets for its own children, beyond the
    /// `CLAUDE_CODE_` prefix.
    static let hostSessionKeys: Set<String> = [
        "CLAUDECODE",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
        "CLAUDE_AGENT_SDK_VERSION",
        "CLAUDE_PREVIEW_CLASSIFIER_FLOOR",
    ]

    /// Set by the host only when it is one; dropped together with the marker.
    static let hostInjectedKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "MCP_CONNECTION_NONBLOCKING",
        "MCP_SERVER_CONNECTION_BATCH_SIZE",
    ]

    /// `base` with host-session variables removed and `HOME` pinned to the real home folder.
    static func make(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        let launchedByHostSession = base["CLAUDECODE"] != nil
        var environment = base.filter { key, _ in
            if key.hasPrefix("CLAUDE_CODE_") || hostSessionKeys.contains(key) { return false }
            if launchedByHostSession && hostInjectedKeys.contains(key) { return false }
            return true
        }
        environment["HOME"] = home
        return environment
    }
}
