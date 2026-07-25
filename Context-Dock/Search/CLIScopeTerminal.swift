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
        controller = created
        hasController = true
        return created
    }

    /// Run an approved command live in the embedded terminal, expanding it so the
    /// user sees the output.
    func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isFreshController = controller == nil
        let controller = ensureController()
        isExpanded = true
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

struct CLIScopeTerminalPanel: View {
    @ObservedObject var manager = CLIScopeTerminalManager.shared
    let isDark: Bool
    var accentColor: SwiftUI.Color = .green

    @State private var isDraggingResize = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if manager.isExpanded {
                Divider().opacity(0.15)
                terminalBody
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SwiftUI.Color.black.opacity(isDark ? 0.28 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SwiftUI.Color.white.opacity(0.10), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                if manager.isExpanded {
                    manager.isExpanded = false
                } else {
                    _ = manager.ensureController()
                    manager.isExpanded = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text("Terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: manager.isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(manager.isExpanded ? "Collapse terminal" : "Expand terminal")
    }

    @ViewBuilder
    private var terminalBody: some View {
        VStack(spacing: 0) {
            TerminalResizeHandle(
                height: $manager.height,
                isDragging: $isDraggingResize,
                minHeight: 120,
                maxHeight: 460
            )
            if let controller = manager.controller {
                PanelTerminalView(controller: controller)
                    .frame(height: manager.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
    }
}
