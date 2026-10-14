import Combine
import SwiftUI
import SwiftTerm

// MARK: - CLI Scope embedded terminal
//
// A real SwiftTerm PTY docked at the bottom of a CLI tool scope (VSCode/Codex
// style). Collapsed to a thin strip by default; a chevron expands it. Approved CLI
// commands from the scope's "Run command?" card run LIVE in this terminal
// (real-time output, scrollback, interactivity) instead of bouncing to Terminal.app.
//
// A singleton manager owns the PTY so the approval handler can reach it, while the
// panel view renders wherever the CLI scope sheet places it. The PTY is created
// lazily on first use and reset when the user exits the scope.

@MainActor
final class CLIScopeTerminalManager: ObservableObject {
    static let shared = CLIScopeTerminalManager()
    private init() {}

    @Published var isExpanded = false
    @Published var height: CGFloat = 240
    @Published private(set) var hasController = false

    /// The live PTY. `isPanel: true` so it never steals the AI bridge's main slot.
    private(set) var controller: TerminalHostController?

    /// Create the PTY on demand (first time the CLI scope shows its terminal).
    func ensureController() -> TerminalHostController {
        if let controller { return controller }
        let created = TerminalHostController(isPanel: true)
        created.showsCapturedExecutionTranscript = true
        controller = created
        hasController = true
        return created
    }

    /// Make this CLI scope's PTY the bridge target and reveal it for the command.
    func prepareForExecution() -> TerminalHostController {
        let controller = ensureController()
        isExpanded = true
        TerminalAIBridge.shared.terminalController = controller
        return controller
    }

    /// Run an approved command live in the embedded terminal, expanding it so the
    /// user sees the output.
    func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isFreshController = controller == nil
        let controller = prepareForExecution()
        // Give a freshly-created PTY a moment to finish starting its shell before the
        // command is typed, so nothing is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + (isFreshController ? 0.35 : 0.05)) {
            controller.sendCommand(trimmed)
        }
    }

    /// Tear the PTY down when the CLI scope is exited so a new scope starts clean.
    func reset() {
        controller = nil
        hasController = false
        isExpanded = false
    }
}

// MARK: - Panel view

