// ChatThreadTerminal.swift
// Context-Dock
//
// A live terminal for a CLI thread, docked in the chat window's side panel.
//
// Some tools cannot be run with their output captured. A browser, an editor, a pager or a
// dashboard needs a tty: with none it either hangs or prints escape codes at you. Running
// `terminal-browser` through the captured executor did exactly that — the command sat
// until the watchdog stopped it, and the chat reported a timeout for a tool that was
// working perfectly and simply had nowhere to draw.
//
// So a CLI thread gets a real PTY beside the conversation. The assistant types into it,
// the user can type into it too, and what the tool draws is visible rather than described.
// One PTY per thread, kept while the window lives, so a session with a tool survives
// switching away and back.

import Combine
import SwiftUI

@MainActor
final class ChatThreadTerminalManager: ObservableObject {
    static let shared = ChatThreadTerminalManager()

    private init() {}

    /// One PTY per thread, by scope storage key. Shared PTYs would let one tool's session
    /// scroll past inside another tool's thread.
    private var controllers: [String: TerminalHostController] = [:]

    /// Threads whose terminal has been created, so the panel can show its state without
    /// creating a PTY just by looking.
    @Published private(set) var liveScopeKeys: Set<String> = []

    func hasTerminal(for scope: GeneralChatScope) -> Bool {
        controllers[scope.storageKey] != nil
    }

    /// The thread's terminal, started on first use. `isPanel` so it never takes the AI
    /// bridge's main slot from the dock's own terminal.
    ///
    /// A CLI thread's terminal starts the tool, not a bare shell. Opening the panel for
    /// `terminal-browser` and getting an empty zsh prompt is the reason the assistant kept
    /// reporting "terminal-browser is not currently running" and typing `help` into a shell
    /// one character at a time: the panel exists to run that tool, and nothing ran it.
    @discardableResult
    func controller(for scope: GeneralChatScope) -> TerminalHostController {
        if let existing = controllers[scope.storageKey] { return existing }
        let created = TerminalHostController(isPanel: true)
        controllers[scope.storageKey] = created
        liveScopeKeys.insert(scope.storageKey)

        if case .cli(let command) = scope, Self.needsTerminal(command: command),
            Self.unsupportedReason(for: command) == nil
        {
            // After the shell has come up. Sending immediately writes into a PTY that has
            // not finished starting, and the line is lost.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak created] in
                created?.sendCommand(command)
            }
        }
        return created
    }

    /// Types a command into the thread's terminal. Returns once it has been sent — a TUI
    /// has no completion to wait for, and pretending otherwise is what hung the turn.
    func run(_ command: String, scope: GeneralChatScope) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isNew = controllers[scope.storageKey] == nil
        let controller = controller(for: scope)
        // A freshly started shell needs a moment before it will accept a line.
        DispatchQueue.main.asyncAfter(deadline: .now() + (isNew ? 0.35 : 0.05)) {
            controller.sendCommand(trimmed)
        }
    }

    /// Raw keystrokes, for driving a TUI that is already running: arrows, Enter, Ctrl-C.
    func sendKeys(_ keys: String, scope: GeneralChatScope) {
        guard let controller = controllers[scope.storageKey] else { return }
        controller.sendKeys(keys)
    }

    func close(scope: GeneralChatScope) {
        controllers[scope.storageKey] = nil
        liveScopeKeys.remove(scope.storageKey)
    }

    // Deliberately not launched under tmux.
    //
    // tmux was the obvious move — the tool names it as supported, and it multiplexes panes
    // inside one PTY. It made things worse. Refusing to run, terminal-browser printed
    // advice and stopped; under tmux it believed the terminal was capable and started
    // streaming kitty-graphics image data, which SwiftTerm cannot decode and which froze
    // the app while it tried. A tool that declines is recoverable. A frozen window is not,
    // so the capability check the tool performs is left to succeed or fail on its own.

    /// Why a tool cannot run here, when it cannot.
    ///
    /// Some terminal tools need capabilities a terminal *emulator* does not have: a
    /// remote-control API to split its own panes, and the kitty graphics protocol to draw
    /// images into the grid. SwiftTerm has neither, and neither does Terminal.app — this is
    /// not a gap specific to this app.
    ///
    /// Naming them is better than launching them. Started anyway, the tool either prints an
    /// error the user has to interpret or, worse, decides the terminal is capable and
    /// streams image data that hangs the window.
    static func unsupportedReason(for command: String) -> String? {
        let graphicsTools = ["terminal-browser", "carbonyl", "browsh"]
        guard graphicsTools.contains(command.lowercased()) else { return nil }
        return "\(command) draws web pages with the kitty graphics protocol and controls its "
            + "own split panes. A terminal emulator can't provide either — this tool needs "
            + "Ghostty, kitty or WezTerm. Everything else about this thread works: ask "
            + "questions, run its other subcommands, and read the results here."
    }

    /// True when this tool draws its own screen and must not be run with captured output.
    static func needsTerminal(command: String) -> Bool {
        TerminalPackageManager.shared.packages.first {
            $0.command.caseInsensitiveCompare(command) == .orderedSame
        }?.isInteractive ?? false
    }
}
