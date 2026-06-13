import Foundation
import SwiftUI
import Combine
import SwiftTerm

// MARK: - Terminal AI Bridge

private final class TerminalOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func output() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Manages communication between AI and Terminal for command execution
@MainActor
class TerminalAIBridge: ObservableObject {
    static let shared = TerminalAIBridge()

    // MARK: - Published State

    @Published var isExecuting = false
    @Published var currentCommand: String?
    @Published var lastOutput: String = ""
    @Published var lastExitCode: Int32 = 0
    @Published var executionHistory: [CommandExecution] = []
    @Published var pendingApproval: PendingCommand?
    private var approvalExpiryTask: Task<Void, Never>?

    /// Optional per-line streaming callback set by the active panel.
    /// Called on a background thread — callers must dispatch to MainActor themselves.
    var streamLineHandler: (@Sendable (String) -> Void)?

    // MARK: - Types

    struct CommandExecution: Identifiable, Codable {
        let id: UUID
        let command: String
        let output: String
        let exitCode: Int32
        let timestamp: Date
        let duration: TimeInterval
        let wasApproved: Bool
        let category: String
        let riskLevel: String

        init(
            command: String,
            output: String,
            exitCode: Int32,
            duration: TimeInterval,
            wasApproved: Bool,
            classification: TerminalCommandClassifier.CommandClassification
        ) {
            self.id = UUID()
            self.command = command
            self.output = output
            self.exitCode = exitCode
            self.timestamp = Date()
            self.duration = duration
            self.wasApproved = wasApproved
            self.category = classification.category.rawValue
            self.riskLevel = classification.riskLevel.displayName
        }
    }

    struct PendingCommand: Identifiable {
        let id = UUID()
        let command: String
        let purpose: String
        let classification: TerminalCommandClassifier.CommandClassification
        let continuation: CheckedContinuation<CommandResult, Never>
    }

    enum CommandResult {
        case approved(command: String)
        case denied
        case blocked(reason: String)
    }

    struct WorkflowStep: Codable {
        let command: String
        let description: String
        let dependsOnPrevious: Bool
        let optional: Bool
        let timeout: TimeInterval

        init(command: String, description: String, dependsOnPrevious: Bool = true, optional: Bool = false, timeout: TimeInterval = 120) {
            self.command = command
            self.description = description
            self.dependsOnPrevious = dependsOnPrevious
            self.optional = optional
            self.timeout = timeout
        }
    }

    struct WorkflowResult {
        let steps: [StepResult]
        let overallSuccess: Bool
        let summary: String

        struct StepResult {
            let step: WorkflowStep
            let output: String
            let exitCode: Int32
            let success: Bool
            let skipped: Bool
        }
    }

    // MARK: - Terminal Controller Reference

    weak var terminalController: TerminalHostController?

    // MARK: - Command Execution

    /// Process an AI-generated terminal command
    func processAICommand(_ command: String, purpose: String) async -> (success: Bool, output: String) {
        let classifier = TerminalCommandClassifier.shared
        let classification = classifier.classify(command)

        // Check if blocked
        if classification.riskLevel == .critical {
            let message = "Command blocked: \(classification.blockedReason ?? "Security risk")"
            if let alternative = classification.suggestedAlternative {
                return (false, "\(message)\n\nAlternative: \(alternative)")
            }
            return (false, message)
        }

        // Check if auto-approval applies
        if classification.shouldAutoExecute || TerminalCommandPreferences.shared.shouldAutoApprove(command) {
            return await executeCommand(command, classification: classification, wasApproved: true)
        }

        // Check if auto-deny applies
        if TerminalCommandPreferences.shared.shouldAutoDeny(command) {
            return (false, "Command automatically denied based on your preferences")
        }

        // Request user approval
        let result = await requestApproval(command: command, purpose: purpose, classification: classification)

        switch result {
        case .approved(let approvedCommand):
            return await executeCommand(approvedCommand, classification: classification, wasApproved: true)
        case .denied:
            return (false, "Command denied by user")
        case .blocked(let reason):
            return (false, "Command blocked: \(reason)")
        }
    }

    /// Request user approval for a command
    private func requestApproval(
        command: String,
        purpose: String,
        classification: TerminalCommandClassifier.CommandClassification
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            approvalExpiryTask?.cancel()
            pendingApproval = PendingCommand(
                command: command,
                purpose: purpose,
                classification: classification,
                continuation: continuation
            )
            approvalExpiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.denyCommand()
            }
        }
    }

    /// Called when user approves the command
    func approveCommand(_ command: String) {
        guard let pending = pendingApproval else { return }
        approvalExpiryTask?.cancel()
        approvalExpiryTask = nil
        pending.continuation.resume(returning: .approved(command: command))
        pendingApproval = nil
    }

    /// Called when user denies the command
    func denyCommand() {
        guard let pending = pendingApproval else { return }
        approvalExpiryTask?.cancel()
        approvalExpiryTask = nil
        pending.continuation.resume(returning: .denied)
        pendingApproval = nil
    }

    // MARK: - Direct Execution

    /// Execute a command directly in the terminal
    private func executeCommand(
        _ command: String,
        classification: TerminalCommandClassifier.CommandClassification,
        wasApproved: Bool
    ) async -> (success: Bool, output: String) {
        isExecuting = true
        currentCommand = command
        let startTime = Date()

        defer {
            isExecuting = false
            currentCommand = nil
        }

        // Execute in terminal if available, otherwise background
        let (output, exitCode) = await executeInTerminalOrBackground(command)

        let duration = Date().timeIntervalSince(startTime)
        lastOutput = output
        lastExitCode = exitCode

        // Record execution
        let execution = CommandExecution(
            command: command,
            output: output,
            exitCode: exitCode,
            duration: duration,
            wasApproved: wasApproved,
            classification: classification
        )

        executionHistory.append(execution)

        // Log to audit trail
        logExecution(execution)

        return (exitCode == 0, output)
    }

    // MARK: - TUI Detection

    /// Known TUI / interactive apps that require a real PTY (ncurses-based or full-screen).
    private static let knownTUIApps: Set<String> = [
        "ymc", "youtube-music-cli", "ncspot", "musikcube", "mpv", "mplayer", "vlc",
        "htop", "btop", "bpytop", "glances", "nmon", "iotop", "iftop", "nethogs",
        "vim", "vi", "neovim", "nvim", "nano", "emacs", "helix", "hx",
        "ranger", "nnn", "midnight-commander", "mc",
        "lazygit", "tig", "gitui",
        "fzf", "peco",
        "tmux", "screen", "zellij",
        "man", "less", "more",
        "top",       // top is TUI; ps is NOT — ps runs fine in background
        "pomodoro",  // Rich TUI timer
        // Common Rust TUI apps
        "broot", "gitui", "lazydocker", "bottom", "bandwhich", "dust",
        "diskonaut", "procs", "zoxide", "starship",
        // Other ncurses/TUI tools
        "cmus", "moc", "mocp", "neomutt", "mutt", "aerc",
        "calcurse", "khal", "tuir", "rtv", "newsboat"
    ]

    /// Returns true if the given command requires an interactive PTY (ncurses/fullscreen TUI).
    /// Uses the explicit allowlist and a tight keyword heuristic only — NOT the intent registry,
    /// which produces too many false positives (e.g. brew mentioning "services"/"daemon").
    func isTUICommand(_ command: String) -> Bool {
        let parts = command.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
        let executable = (parts.first ?? "").components(separatedBy: "/").last ?? ""
        let execLower = executable.lowercased()

        // Primary: explicit allowlist of known interactive TUI apps
        if Self.knownTUIApps.contains(execLower) { return true }

        // Secondary: tight keyword heuristic on the binary name only (not args)
        let tuiKeywords = ["tui", "ncurses", "curses"]
        return tuiKeywords.contains(where: { execLower.contains($0) })
    }

    /// Execute command either in visible terminal or background
    private func executeInTerminalOrBackground(_ command: String) async -> (output: String, exitCode: Int32) {
        // TUI / interactive apps MUST go to the visible terminal (real PTY)
        if isTUICommand(command) {
            if let controller = terminalController {
                controller.sendCommand(command)

                // Register as PTY worker in the pool
                let executable = command.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? command
                let workerIntent = detectWorkerIntent(for: executable)
                let workerID = BackgroundWorkerPool.shared.registerPTYWorker(
                    command: command,
                    purpose: "Interactive terminal command",
                    intent: workerIntent
                )

                // Show mini-player if this is a music tool
                if workerIntent == .musicPlayer {
                    MiniPlayerController.shared.show(
                        workerID: workerID,
                        toolName: executable,
                        intent: .musicPlayer
                    )
                }

                return ("Launched '\(command)' in terminal (interactive mode, worker: \(workerID.uuidString.prefix(6)))", 0)
            }
            return ("Cannot run '\(command)': requires an interactive terminal. Open the Terminal tab first.", 1)
        }

        // Non-interactive commands: stream line-by-line to active panel, capture full output
        let lineHandler = streamLineHandler
        let bgResult = await executeInBackground(command, onLine: lineHandler)

        // If the command itself complains it needs a TTY, re-route to visible terminal
        let interactivePhrases = ["requires an interactive terminal", "is running interactively", "needs a terminal", "not a tty", "no tty present"]
        let lowerOutput = bgResult.output.lowercased()
        if bgResult.exitCode != 0, interactivePhrases.contains(where: { lowerOutput.contains($0) }) {
            if let controller = terminalController {
                controller.sendCommand(command)
                let executable = command.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? command
                let workerIntent = detectWorkerIntent(for: executable)
                _ = BackgroundWorkerPool.shared.registerPTYWorker(command: command, purpose: "Interactive fallback", intent: workerIntent)
                return ("'\(command)' requires an interactive terminal — launched in the Terminal tab.", 0)
            }
        }

        return bgResult
    }

    // MARK: - Worker Intent Detection

    func detectWorkerIntent(for executable: String) -> L2ToolIntent? {
        // Check manifest DB first
        if let manifest = ToolManifestDB.shared.manifest(for: executable),
           let intent = L2ToolIntent(rawValue: manifest.primaryIntent) {
            return intent
        }
        // Check packages via intent registry
        if let pkg = TerminalPackageManager.shared.packages.first(where: { $0.command == executable }) {
            return L2IntentRegistry.shared.detectIntents(for: pkg).first
        }
        return nil
    }

    // MARK: - spawn_worker support (non-blocking background execution)

    /// Sends raw keystrokes to the currently running TUI process via PTY injection.
    /// No newline is appended — pass "\r" or "\n" explicitly when needed.
    /// Returns a brief status string for the AI.
    func sendKeys(_ keys: String) -> String {
        guard let ctrl = terminalController else {
            return "No active terminal — launch the TUI first with spawn_worker."
        }
        ctrl.sendKeys(keys)
        // Human-readable description for AI response
        let display = keys
            .replacingOccurrences(of: "\r", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\u{1B}", with: "ESC")
            .replacingOccurrences(of: "\u{03}", with: "Ctrl-C")
            .replacingOccurrences(of: "\u{1B}[A", with: "↑")
            .replacingOccurrences(of: "\u{1B}[B", with: "↓")
            .replacingOccurrences(of: "\u{1B}[C", with: "→")
            .replacingOccurrences(of: "\u{1B}[D", with: "←")
        return "Keys sent to TUI: \(display)"
    }

    /// Spawn a command as a background worker without blocking. Returns workerID string.
    func spawnWorker(command: String, purpose: String) -> String {
        let executable = command.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? command
        let intent = detectWorkerIntent(for: executable)

        if isTUICommand(command) {
            // TUI: send to terminal, register as PTY worker
            terminalController?.sendCommand(command)
            let id = BackgroundWorkerPool.shared.registerPTYWorker(
                command: command, purpose: purpose, intent: intent
            )
            if intent == .musicPlayer {
                MiniPlayerController.shared.show(workerID: id, toolName: executable,
                                                  intent: .musicPlayer)
            }
            return id.uuidString
        } else {
            // Background: spawn process worker
            let id = BackgroundWorkerPool.shared.spawn(command: command, purpose: purpose, intent: intent)
            return id.uuidString
        }
    }

    /// Execute command in background, streaming each line to `onLine` as it arrives.
    /// Returns the full combined output + exit code when the process finishes.
    func executeInBackground(
        _ command: String,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            // Set up environment with full tool paths (Homebrew Apple Silicon + Intel)
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            let currentPath = environment["PATH"] ?? "/usr/bin:/bin"
            environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:" + currentPath
            process.environment = environment

            // Set working directory to home
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            let outputPipe = Pipe()
            let errorPipe  = Pipe()
            process.standardOutput = outputPipe
            process.standardError  = errorPipe

            let outputCollector = TerminalOutputCollector()
            @Sendable func appendCollectedLine(_ line: String) {
                outputCollector.append(line)
            }
            @Sendable func collectedOutput() -> String {
                outputCollector.output()
            }

            // Stream stdout line-by-line
            if let onLine {
                outputPipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    for line in chunk.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .controlCharacters)
                        guard !trimmed.isEmpty else { continue }
                        appendCollectedLine(trimmed)
                        onLine(trimmed)
                    }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    for line in chunk.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .controlCharacters)
                        guard !trimmed.isEmpty else { continue }
                        appendCollectedLine(trimmed)
                        onLine(trimmed)
                    }
                }
            }

            process.terminationHandler = { proc in
                // Drain any remaining bytes when no streaming handler
                if onLine == nil {
                    let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    var output = String(data: outData, encoding: .utf8) ?? ""
                    if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
                        output += "\n" + err
                    }
                    continuation.resume(returning: (output.trimmingCharacters(in: .whitespacesAndNewlines), proc.terminationStatus))
                } else {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler  = nil
                    continuation.resume(returning: (collectedOutput(), proc.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("Error: \(error.localizedDescription)", 1))
            }
        }
    }

    // MARK: - Multi-Step Workflow

    /// Execute a multi-step workflow with approval
    func executeWorkflow(
        name: String,
        steps: [WorkflowStep],
        onProgress: @escaping (Int, String) -> Void
    ) async -> WorkflowResult {
        var results: [WorkflowResult.StepResult] = []
        var previousFailed = false

        for (index, step) in steps.enumerated() {
            onProgress(index, step.description)

            // Skip if previous failed and this depends on it
            if previousFailed && step.dependsOnPrevious && !step.optional {
                results.append(WorkflowResult.StepResult(
                    step: step,
                    output: "Skipped due to previous failure",
                    exitCode: -1,
                    success: false,
                    skipped: true
                ))
                continue
            }

            // Execute the step
            let (success, output) = await processAICommand(step.command, purpose: step.description)

            results.append(WorkflowResult.StepResult(
                step: step,
                output: output,
                exitCode: success ? 0 : 1,
                success: success,
                skipped: false
            ))

            if !success && !step.optional {
                previousFailed = true
            }
        }

        let successCount = results.filter { $0.success }.count
        let totalCount = results.count
        let overallSuccess = results.allSatisfy { $0.success || $0.step.optional || $0.skipped }

        return WorkflowResult(
            steps: results,
            overallSuccess: overallSuccess,
            summary: "Completed \(successCount)/\(totalCount) steps\(overallSuccess ? "" : " (some failures)")"
        )
    }

    // MARK: - Audit Logging

    private func logExecution(_ execution: CommandExecution) {
        // Log to file for audit trail
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ILauncher")

        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

            let logFile = logDir.appendingPathComponent("terminal_audit.log")
            let logEntry = """
            [\(ISO8601DateFormatter().string(from: execution.timestamp))] \
            [\(execution.riskLevel)] \
            [\(execution.category)] \
            [Exit: \(execution.exitCode)] \
            \(execution.wasApproved ? "[APPROVED]" : "[AUTO]") \
            \(execution.command)

            """

            if FileManager.default.fileExists(atPath: logFile.path) {
                let handle = try FileHandle(forWritingTo: logFile)
                handle.seekToEndOfFile()
                if let data = logEntry.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try logEntry.write(to: logFile, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to write audit log: \(error)")
        }
    }

    // MARK: - Context for AI

    /// Get recent execution context for AI follow-up
    func getRecentContext(lastN: Int = 5) -> String {
        let recent = executionHistory.suffix(lastN)
        guard !recent.isEmpty else { return "No recent commands." }

        var context = "Recent terminal commands:\n"
        for execution in recent {
            context += """

            Command: \(execution.command)
            Result: \(execution.exitCode == 0 ? "Success" : "Failed (exit \(execution.exitCode))")
            Output: \(execution.output.prefix(500))\(execution.output.count > 500 ? "..." : "")

            """
        }
        return context
    }

    /// Get the last command output for AI analysis
    func getLastOutputForAI() -> String {
        guard let last = executionHistory.last else {
            return "No commands executed yet."
        }

        return """
        Last command: \(last.command)
        Exit code: \(last.exitCode)
        Output:
        \(last.output)
        """
    }
}

// MARK: - Terminal Host Controller Extension

extension TerminalHostController {
    /// Execute a command and capture output for AI
    func executeAndCapture(_ command: String) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            var capturedOutput = ""
            var outputComplete = false
            let commandMarker = "___ILAUNCHER_CMD_END_\(UUID().uuidString.prefix(8))___"

            // Set up output capture
            let originalOutputHandler = onOutputReceived
            onOutputReceived = { text in
                capturedOutput += text

                // Check if command completed
                if capturedOutput.contains(commandMarker) {
                    outputComplete = true
                    // Remove the marker from output
                    capturedOutput = capturedOutput.replacingOccurrences(of: commandMarker, with: "")
                    capturedOutput = capturedOutput.replacingOccurrences(of: "echo \(commandMarker)", with: "")
                }

                originalOutputHandler?(text)
            }

            // Send command with completion marker
            let fullCommand = "\(command); echo \(commandMarker)\n"
            terminalView.send(txt: fullCommand)

            // Wait for completion with timeout
            Task {
                let startTime = Date()
                let timeout: TimeInterval = 120

                while !outputComplete && Date().timeIntervalSince(startTime) < timeout {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                // Restore original handler
                self.onOutputReceived = originalOutputHandler

                // Extract just the command output (remove prompt, etc.)
                let cleanOutput = self.cleanCommandOutput(capturedOutput, command: command)

                // Determine exit code from output patterns
                let exitCode: Int32 = cleanOutput.contains("error") || cleanOutput.contains("Error") ||
                    cleanOutput.contains("failed") || cleanOutput.contains("not found") ? 1 : 0

                continuation.resume(returning: (cleanOutput, exitCode))
            }
        }
    }

    /// Clean command output for AI consumption
    private func cleanCommandOutput(_ output: String, command: String) -> String {
        var lines = output.components(separatedBy: "\n")

        // Remove the command itself from output
        lines = lines.filter { !$0.contains(command) }

        // Remove empty lines at start/end
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        // Remove shell prompt patterns
        lines = lines.filter { line in
            !line.contains("$") || !line.trimmingCharacters(in: .whitespaces).hasSuffix("$")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
