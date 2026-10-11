// ClaudeCodeCLIService+Privacy.swift
// Context-Dock
//
// E1c: which Claude Code CLI turns may hold the CLI's own network and shell tools.
//
// The CLI runs `WebFetch`, `WebSearch` and `Bash` under its own permissions. DoraX's outbound
// gate (OutboundGate.swift) governs DoraX's tools and nothing else, so in a Mail chat an
// injected "fetch https://site/?d=<your mail>" was stopped only by the model choosing to refuse.
//
// The rule: a chat that can hold private data — any app-scoped chat, any chat a private read
// has happened in — launches the CLI without those three. Network and shell go through DoraX's
// MCP tools instead (`dorax_read_url`, `dorax_run_command`), where the gate runs with the
// turn's taint and raises the same card the API providers raise. A coding chat with no private
// read keeps them; the moment one happens (a DoraX MCP read, a capability that reads the
// user's data) they are dropped for the rest of the session, and a CLI turn still holding
// them is stopped and run again without.

import Foundation

/// The chat a CLI turn runs for. Bound by the surface that knows it (`AppScopedChatService`,
/// `ScopedTurnRunner`); a task-local so the provider layers between do not each grow a
/// parameter. Unbound means unknown, which is treated as private.
nonisolated enum ClaudeCodeChat {
    @TaskLocal static var scope: GeneralChatScope?

    /// A registry turn that already holds this conversation's taint, bound by a loop that runs
    /// several CLI passes and DoraX capabilities between them (the tool-less scoped loop). A CLI
    /// pass joins it instead of starting a fresh record that has forgotten what was read.
    @TaskLocal static var turn: AgentTurnToken?
}

extension ClaudeCodeCLIService {

    /// Whether a chat can hold the user's private data. Pure.
    ///
    /// - App-scoped: always. The prompt carries that app's context, and the app is the
    ///   user's (a mailbox, a thread, a project).
    /// - A General Chat thread, the shared conversation, a pinned CLI or a folder: only once a
    ///   private read has happened in the session.
    /// - No scope known: yes. A caller that cannot say is treated as one that could.
    nonisolated static func holdsPrivateData(
        scope: GeneralChatScope?, sessionHadPrivateRead: Bool
    ) -> Bool {
        if sessionHadPrivateRead { return true }
        switch scope {
        case nil, .app: return true
        case .thread, .general, .cli, .folder: return false
        }
    }

    // MARK: - What each session has read

    /// What each chat has read this launch, by storage key. Once set, a flag stays set: the
    /// data is in the session's history, which every later turn sends again.
    private static var sessionTaints: [String: TurnTaint] = [:]

    static func sessionTaint(_ scope: GeneralChatScope?) -> TurnTaint {
        guard let scope else { return TurnTaint() }
        return sessionTaints[scope.storageKey] ?? TurnTaint()
    }

    /// Folds what a turn or a capability read into its session's record.
    static func noteRead(_ taint: TurnTaint, in scope: GeneralChatScope?) {
        guard let scope, taint.readPrivateData || taint.readUntrustedContent else { return }
        var merged = sessionTaints[scope.storageKey] ?? TurnTaint()
        merged.readPrivateData = merged.readPrivateData || taint.readPrivateData
        merged.readUntrustedContent = merged.readUntrustedContent || taint.readUntrustedContent
        sessionTaints[scope.storageKey] = merged
    }

    /// For tests.
    static func forgetSessionReads() { sessionTaints.removeAll() }

    // MARK: - Live CLI turns

    /// What one running CLI turn was launched with, for the MCP server.
    struct LiveTurn {
        /// The CLI holds its own WebFetch / WebSearch / Bash this turn.
        var holdsOwnOutboundTools: Bool
        /// The user's access level lets this turn run commands (`.full`), so the MCP server
        /// offers `dorax_run_command` to it.
        var mayRunCommands: Bool
        /// The chat the turn runs for, so a gate card raised by one of its MCP calls lands in
        /// that chat rather than wherever approvals go by default.
        var scope: GeneralChatScope?
        /// Stops the process. Set once it is launched.
        var stop: (() -> Void)?
        /// A private read arrived while the turn held its own outbound tools: it was stopped,
        /// and is run again without them.
        var restartForPrivateRead = false
    }

    private static var liveTurns: [UUID: LiveTurn] = [:]

    static func liveTurn(_ id: UUID) -> LiveTurn? { liveTurns[id] }

    static func registerLiveTurn(_ id: UUID, _ turn: LiveTurn) { liveTurns[id] = turn }

    static func setStop(_ id: UUID, _ stop: @escaping () -> Void) { liveTurns[id]?.stop = stop }

    /// Removes the record and says whether it was stopped for a private read.
    @discardableResult
    static func finishLiveTurn(_ id: UUID) -> Bool {
        liveTurns.removeValue(forKey: id)?.restartForPrivateRead ?? false
    }

    /// Called by the MCP server before it hands a private read to a CLI turn.
    ///
    /// A turn that holds the CLI's own network or shell must not receive the user's private
    /// data: the next call could carry it anywhere, and DoraX would not see it. So the read is
    /// refused (returns true), the process is stopped, and `send` runs the turn again with
    /// those tools gone. A turn without them returns false and the read goes ahead.
    static func stopBeforePrivateRead(turnID: UUID) -> Bool {
        guard var turn = liveTurns[turnID], turn.holdsOwnOutboundTools else { return false }
        turn.restartForPrivateRead = true
        liveTurns[turnID] = turn
        turn.stop?()
        return true
    }

    static func chatScope(turnID: UUID?) -> GeneralChatScope? {
        turnID.flatMap { liveTurns[$0]?.scope }
    }

    /// Whether the MCP server may offer this turn a shell.
    static func mayRunCommands(turnID: UUID?) -> Bool {
        guard let turnID else { return false }
        return liveTurns[turnID]?.mayRunCommands ?? false
    }
}
