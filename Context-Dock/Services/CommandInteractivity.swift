// CommandInteractivity.swift
// Context-Dock
//
// Whether a *command* needs a real terminal — not whether its *tool* sometimes does.
//
// The "Needs a terminal" checkbox in CLI Tool Scope is per tool, and that was too coarse.
// terminal-browser has four subcommands: `open` genuinely takes over the tty, while `ls`,
// `setup` and `action` are one-shot commands whose output is the whole point of running
// them. Marking the tool interactive sent all four to the PTY, where they returned
// "Launched '…' in terminal" and no output at all — so the chat could only narrate what it
// had done, the console had nothing to show, and the answer verifier saw a turn with no
// evidence and asked the model to try again.
//
// So the decision is made per invocation, from three sources in order: what we learned by
// running this exact tool+subcommand before, a small table of verbs that are interactive
// (or not) in essentially every CLI, and — when both are silent — an actual probe. The
// probe is the only honest answer for an unknown subcommand: run it headless with a short
// deadline, and if it is still alive when the deadline passes, it wanted a terminal.
//
// Learned verdicts are persisted, so a tool is probed once per subcommand, not once per ask.

import Foundation

enum CommandInteractivity {
    enum Verdict {
        /// Send straight to the PTY.
        case interactive
        /// Run headless and capture the output.
        case headless
        /// No idea yet — run headless behind a short deadline and find out.
        case unknown
    }

    /// Subcommand verbs that hand the terminal over to the program. Deliberately short:
    /// a wrong guess here costs the user the output of a command that would have printed it.
    private static let interactiveVerbs: Set<String> = [
        "open", "browse", "shell", "repl", "attach", "console", "interactive",
        "tui", "ui", "edit", "top", "monitor", "dashboard", "watch",
    ]

    /// Verbs that print and exit. Also short, and for the same reason in reverse.
    private static let headlessVerbs: Set<String> = [
        "help", "version", "list", "ls", "status", "info", "show", "get", "config",
        "setup", "init", "install", "uninstall", "add", "remove", "rm", "search",
        "doctor", "check", "which", "path", "completion", "update", "upgrade",
    ]

    private static let learnedKey = "dorax.cli.interactivity.v1"

    // MARK: - Invocation identity

    /// `terminal-browser open https://…` → `terminal-browser open`. Flags are skipped so
    /// `brew --quiet install x` keys the same as `brew install x`; a bare tool with no
    /// subcommand keys as just the tool.
    static func invocationKey(_ command: String) -> String {
        let parts = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard let executable = parts.first else { return "" }
        let tool = (executable.components(separatedBy: "/").last ?? executable).lowercased()
        guard let verb = parts.dropFirst().first(where: { !$0.hasPrefix("-") })?.lowercased()
        else { return tool }
        return "\(tool) \(verb)"
    }

    /// True when the command is the tool on its own — `btop`, `terminal-browser`. A TUI tool
    /// invoked bare is the case the per-tool flag was always right about.
    static func isBareInvocation(_ command: String) -> Bool {
        !invocationKey(command).contains(" ")
    }

    private static func verb(in command: String) -> String? {
        let key = invocationKey(command)
        guard let space = key.firstIndex(of: " ") else { return nil }
        return String(key[key.index(after: space)...])
    }

    // MARK: - Verdict

    /// What we know about this exact invocation. `toolIsMarkedInteractive` is the user's
    /// per-tool checkbox: it decides the bare invocation and raises the probe for the rest,
    /// but it never by itself sends a subcommand to the PTY.
    static func verdict(for command: String, toolIsMarkedInteractive: Bool) -> Verdict {
        let key = invocationKey(command)
        guard !key.isEmpty else { return .headless }

        if let learned = learned()[key] { return learned ? .interactive : .headless }

        guard let verb = verb(in: command) else {
            // Bare tool: the checkbox (or the TUI allowlist, which the caller checks) is the
            // whole signal, and it is a reliable one.
            return toolIsMarkedInteractive ? .interactive : .headless
        }

        if interactiveVerbs.contains(verb) { return .interactive }
        if headlessVerbs.contains(verb) { return .headless }

        // An unrecognised subcommand of a tool the user says needs a terminal is worth
        // probing. For every other tool, headless has been the assumption all along and the
        // "needs a tty" fallback in TerminalAIBridge already catches the ones that complain.
        return toolIsMarkedInteractive ? .unknown : .headless
    }

    // MARK: - Learning

    private static func learned() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: Bool] ?? [:]
    }

    /// Remembers what a probe found, so the same subcommand is never probed twice.
    static func record(_ isInteractive: Bool, for command: String) {
        let key = invocationKey(command)
        guard !key.isEmpty, key.contains(" ") else { return }
        var map = learned()
        guard map[key] != isInteractive else { return }
        map[key] = isInteractive
        UserDefaults.standard.set(map, forKey: learnedKey)
    }

    /// Clears what was learned about a tool — used when its binary changes version, since a
    /// new release can turn a printing subcommand into an interactive one.
    static func forget(tool: String) {
        let prefix = tool.lowercased() + " "
        var map = learned()
        let before = map.count
        map = map.filter { !$0.key.hasPrefix(prefix) }
        guard map.count != before else { return }
        UserDefaults.standard.set(map, forKey: learnedKey)
    }

    /// How long a probe waits before calling the command interactive. Long enough for a
    /// slow one-shot (a network call, a package index read), short enough that a user
    /// watching a TUI launch does not think the app hung.
    static let probeDeadline: TimeInterval = 8
}
