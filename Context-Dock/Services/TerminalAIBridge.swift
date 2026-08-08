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
    /// `modelRequiresApproval` is the model's own `requires_approval` answer from the
    /// run_command tool call. It can only ever *add* friction: true forces the approval
    /// sheet, false grants nothing on its own. The classifier stays the authority on
    /// what is allowed to auto-run, so a model that lies with `false` changes nothing.
    func processAICommand(
        _ command: String,
        purpose: String,
        modelRequiresApproval: Bool = false
    ) async -> (success: Bool, output: String) {
        // AI placeholder tokens (CURRENT_VIDEO_URL, <url>, PASTE_LINK_HERE…) must never
        // reach the shell. URL-shaped placeholders are substituted with the live page
        // URL when we have one; anything else unresolved blocks with a clear message.
        var command = command
        switch Self.resolvePlaceholders(in: command, pageURL: currentPageURLForSubstitution()) {
        case .clean:
            break
        case .resolved(let fixed):
            command = fixed
        case .unresolvable(let token):
            return (
                false,
                "The command contains the placeholder \"\(token)\" and I couldn't fill it from "
                + "the current page. Open the exact page (e.g. the video you want) and ask again."
            )
        }

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

        // Set when the command was otherwise eligible to auto-run but failed the argv gate.
        var unattendedRejection: String?

        // Check if auto-approval applies. A model-declared requires_approval vetoes it —
        // the model is the only party that knows the *intent* behind a command that the
        // classifier can only see the shape of.
        if !modelRequiresApproval,
           classification.shouldAutoExecute || TerminalCommandPreferences.shared.shouldAutoApprove(command) {
            // Second, independent gate. The classifier judges the command's SHAPE, and
            // shape-based judgement has been wrong twice: prefix patterns whitelisted
            // `ls && curl … | bash`, and suffix patterns whitelisted `nc host port -v`
            // without naming an executable at all. This gate judges IDENTITY instead —
            // exactly one allowlisted binary, arguments that cannot become code — and runs
            // it with no shell. A command that cannot pass simply takes the approval path,
            // where the user sees it before it runs.
            switch ArgvCommandGate.evaluate(command) {
            case .allowed(let executable, let arguments):
                let detailed = await executeCommand(
                    command,
                    classification: classification,
                    wasApproved: true,
                    argv: (executable, arguments)
                )
                return (detailed.success, detailed.output)
            case .rejected(let reason):
                // Fall through to the approval path, carrying why it could not run unattended.
                unattendedRejection = reason
            }
        }

        // Check if auto-deny applies
        if TerminalCommandPreferences.shared.shouldAutoDeny(command) {
            return (false, "Command automatically denied based on your preferences")
        }

        // Request user approval. When the command was otherwise eligible to run unattended,
        // say what stopped it — "grep is fine but that pipe isn't" is far more useful than a
        // bare approval prompt, and it tells the user something true about the command.
        let approvalPurpose = unattendedRejection.map { "\(purpose) — \($0)" } ?? purpose
        let result = await requestApproval(
            command: command, purpose: approvalPurpose, classification: classification)

        switch result {
        case .approved(let approvedCommand):
            let detailed = await executeCommand(
                approvedCommand, classification: classification, wasApproved: true)
            return (detailed.success, detailed.output)
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

    /// Run a command the user already approved via an inline chat card. Applies the same
    /// placeholder resolution + critical-command block as `processAICommand`, but NEVER
    /// re-prompts and NEVER touches the pending-approval continuation. Uses the reliable
    /// background/terminal executor (real exit code + captured output), not a PTY marker
    /// wait — so an inline "Approve & Run" always produces output.
    /// - Parameter onLine: receives each output line as it arrives, so a caller can show
    ///   live progress instead of a frozen spinner until the command exits.
    func runPreApprovedCommand(
        _ command: String,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (success: Bool, output: String, exitCode: Int32) {
        var command = command
        switch Self.resolvePlaceholders(in: command, pageURL: currentPageURLForSubstitution()) {
        case .clean:
            break
        case .resolved(let fixed):
            command = fixed
        case .unresolvable(let token):
            return (
                false,
                "The command contains the placeholder \"\(token)\" and I couldn't fill it from "
                + "the current page. Open the exact page and ask again.",
                -1
            )
        }
        let classification = TerminalCommandClassifier.shared.classify(command)
        if classification.riskLevel == .critical {
            let message = "Command blocked: \(classification.blockedReason ?? "Security risk")"
            if let alternative = classification.suggestedAlternative {
                return (false, "\(message)\n\nAlternative: \(alternative)", -1)
            }
            return (false, message, -1)
        }
        return await executeCommand(
            command, classification: classification, wasApproved: true, onLine: onLine)
    }

    // MARK: - Direct Execution

    /// Execute a command directly in the terminal
    /// `argv` is supplied only by the unattended path, where ArgvCommandGate has resolved an
    /// allowlisted executable. When present the command runs as that process directly — no
    /// shell is involved — instead of going through `zsh -lc`.
    private func executeCommand(
        _ command: String,
        classification: TerminalCommandClassifier.CommandClassification,
        wasApproved: Bool,
        argv: (executable: URL, arguments: [String])? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (success: Bool, output: String, exitCode: Int32) {
        isExecuting = true
        currentCommand = command
        let startTime = Date()

        defer {
            isExecuting = false
            currentCommand = nil
        }

        // Long jobs (downloads, transcodes, clones) produce nothing visible until they finish —
        // the chat says "downloading…" and then the app looks idle for minutes. Post a running
        // entry so the work is visible in the notification scope while it happens.
        let progressLabel = Self.longRunningLabel(for: command)
        var progressID: UUID?
        if let progressLabel {
            progressID = ILauncherNotificationManager.shared.post(
                title: progressLabel,
                body: "Running… \(command.prefix(80))",
                icon: "arrow.down.circle",
                accentColor: "blue")
        }

        // Execute in terminal if available, otherwise background. An argv-gated command
        // bypasses both: it runs as a resolved process with no shell, which is the whole
        // point of the gate — a login shell would re-introduce the interpretation the gate
        // exists to remove.
        let (output, exitCode): (String, Int32)
        if let argv {
            (output, exitCode) = await Self.runArgv(
                executable: argv.executable, arguments: argv.arguments, onLine: onLine)
        } else {
            (output, exitCode) = await executeInTerminalOrBackground(command, onLine: onLine)
        }

        // CLI scope terminals are transcript surfaces for non-interactive work:
        // execute once for a real result, then render that result in the visible PTY.
        if terminalController?.showsCapturedExecutionTranscript == true,
            !isTUICommand(command)
        {
            terminalController?.appendExecutionTranscript(
                command: command, output: output, exitCode: exitCode)
        }

        if let progressID { ILauncherNotificationManager.shared.remove(progressID) }
        if let progressLabel {
            ILauncherNotificationManager.shared.post(
                title: exitCode == 0 ? "\(progressLabel) finished" : "\(progressLabel) failed",
                body: exitCode == 0
                    ? "Completed in \(Int(Date().timeIntervalSince(startTime)))s"
                    : String(output.suffix(160)),
                icon: exitCode == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                accentColor: exitCode == 0 ? "green" : "red")
        }

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

        // Download / conversion finished with a real file → badge it in the
        // notification scope so the user can find + reveal the result.
        if exitCode == 0, let produced = Self.detectProducedFile(command: command, output: output) {
            ILauncherNotificationManager.shared.fileReady(
                name: produced.lastPathComponent, url: produced)
        }

        return (exitCode == 0, output, exitCode)
    }

    // MARK: - Placeholder resolution

    enum PlaceholderResolution {
        case clean
        case resolved(String)
        case unresolvable(String)
    }

    /// Live page URL usable to fill URL-shaped placeholders (browser or Safari Web App).
    private func currentPageURLForSubstitution() -> String? {
        if SafariBrowserBridge.shared.isFresh,
            let url = SafariBrowserBridge.shared.latestContext?.url, !url.isEmpty {
            return url
        }
        let ctx = AXContextReader.shared.current
        if let url = ctx.currentURL, !url.isEmpty { return url }
        if let app = AppDelegate.shared?.previousFrontmostApp,
            let bundleId = app.bundleIdentifier,
            let live = AXContextReader.shared.liveCurrentURL(
                pid: app.processIdentifier, bundleId: bundleId) {
            return live
        }
        return nil
    }

    /// Finds AI placeholder tokens (ALL_CAPS_WITH_UNDERSCORES, `<angle placeholders>`).
    /// URL/link/video/page-shaped ones are replaced with `pageURL`; any other
    /// placeholder makes the command unresolvable.
    static func resolvePlaceholders(in command: String, pageURL: String?) -> PlaceholderResolution {
        let patterns = [
            "[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+",   // CURRENT_VIDEO_URL, PASTE_LINK_HERE
            "<[A-Za-z][A-Za-z0-9 _-]*>",       // <url>, <video url>
        ]
        var result = command
        var didSubstitute = false
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let token = String(result[range])
                let upper = token.uppercased()
                // Real shell tokens like $HOME or ${HTTP_PROXY} must survive.
                if range.lowerBound > result.startIndex,
                    ["$", "{", "%"].contains(String(result[result.index(before: range.lowerBound)])) {
                    continue
                }
                // Env assignments (HTTP_PROXY=…) are real shell syntax, not placeholders.
                if range.upperBound < result.endIndex, result[range.upperBound] == "=" {
                    continue
                }
                let urlShaped = ["URL", "LINK", "VIDEO", "PAGE", "ADDRESS"].contains {
                    upper.contains($0)
                }
                if urlShaped, let pageURL, !pageURL.isEmpty {
                    result.replaceSubrange(range, with: pageURL)
                    didSubstitute = true
                } else if upper.contains("_") || token.hasPrefix("<") {
                    return .unresolvable(token)
                }
            }
        }
        return didSubstitute ? .resolved(result) : .clean
    }

    // MARK: - Produced-file detection (downloads, conversions)

    /// Best-effort: find the file a download/convert command produced, from its
    /// output ("Destination: …", "Merging formats into …") or its output argument.
    /// Human label for jobs worth showing progress for. Downloads, transcodes and clones can run
    /// for minutes; everything else finishes fast enough that a notification would be noise.
    static func longRunningLabel(for command: String) -> String? {
        let lowered = command.lowercased()
        let jobs: [(needle: String, label: String)] = [
            ("yt-dlp", "Download"),
            ("youtube-dl", "Download"),
            ("ffmpeg", "Convert"),
            ("handbrakecli", "Convert"),
            ("git clone", "Clone"),
            ("brew install", "Install"),
            ("brew upgrade", "Upgrade"),
            ("curl ", "Download"),
            ("wget ", "Download"),
            ("ditto ", "Archive"),
            ("rsync", "Sync"),
        ]
        return jobs.first { lowered.contains($0.needle) }?.label
    }

    static func detectProducedFile(command: String, output: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        func existingURL(_ rawPath: String) -> URL? {
            let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !path.isEmpty else { return nil }
            let candidates = path.hasPrefix("/") || path.hasPrefix("~")
                ? [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
                : [
                    home.appendingPathComponent(path),
                    home.appendingPathComponent("Downloads/\(path)"),
                    URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(path),
                ]
            return candidates.first { fm.fileExists(atPath: $0.path) }
        }

        // yt-dlp / youtube-dl / ffmpeg-style output lines, last match wins
        for line in output.components(separatedBy: .newlines).reversed() {
            if let r = line.range(of: "Destination: ") {
                if let url = existingURL(String(line[r.upperBound...])) { return url }
            }
            if let r = line.range(of: "Merging formats into \"") {
                let rest = String(line[r.upperBound...])
                if let end = rest.firstIndex(of: "\""),
                    let url = existingURL(String(rest[..<end])) { return url }
            }
            if let r = line.range(of: "has already been downloaded") {
                let prefix = String(line[..<r.lowerBound])
                    .replacingOccurrences(of: "[download]", with: "")
                if let url = existingURL(prefix) { return url }
            }
        }

        // curl -o / wget -O / ffmpeg <out> / HandBrakeCLI -o: explicit output argument
        let tokens = command.components(separatedBy: .whitespaces)
        for (idx, token) in tokens.enumerated() where ["-o", "-O", "--output"].contains(token) {
            if idx + 1 < tokens.count, let url = existingURL(tokens[idx + 1]) { return url }
        }
        return nil
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
        routing(for: command) == .terminal
    }

    /// Where a command should run.
    enum CommandRoute {
        case terminal
        case headless
        /// Unknown subcommand of an interactive tool: try headless behind a deadline.
        case probe
    }

    /// Decided per invocation, not per tool.
    ///
    /// The per-tool "Needs a terminal" mark says *some* of this tool's commands take over the
    /// tty — for terminal-browser that is `open` and nothing else. Treating the mark as a
    /// verdict on every invocation sent `ls` and `setup` to the PTY too, where they produced
    /// no output for the chat, the console or the verifier to work with.
    func routing(for command: String) -> CommandRoute {
        let parts = command.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
        let executable = (parts.first ?? "").components(separatedBy: "/").last ?? ""
        let execLower = executable.lowercased()

        // The allowlist cannot know every TUI tool — terminal-browser, for one — so the
        // user's own mark counts alongside it. Both are statements about the *tool*; which
        // of its commands are interactive is CommandInteractivity's question. This is a Set
        // lookup kept by TerminalPackageManager, not a scan of ~950 packages.
        let tuiKeywords = ["tui", "ncurses", "curses"]
        let toolIsInteractive =
            TerminalPackageManager.shared.interactiveCommands.contains(execLower)
            || Self.knownTUIApps.contains(execLower)
            || tuiKeywords.contains(where: { execLower.contains($0) })

        switch CommandInteractivity.verdict(
            for: command, toolIsMarkedInteractive: toolIsInteractive)
        {
        case .interactive: return .terminal
        case .headless: return .headless
        case .unknown: return .probe
        }
    }

    /// Execute command either in visible terminal or background
    private func executeInTerminalOrBackground(
        _ command: String,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (output: String, exitCode: Int32) {
        let route = routing(for: command)

        // TUI / interactive apps MUST go to the visible terminal (real PTY)
        if route == .terminal {
            return launchInTerminal(command, purpose: "Interactive terminal command")
        }

        let lineHandler = streamLineHandler

        // Unknown subcommand of a tool the user marked interactive. Run it headless with a
        // deadline: a one-shot answers well inside it, and anything still alive afterwards
        // was waiting for a terminal it was never given. Either way the answer is recorded,
        // so this costs one probe per subcommand, not one per question.
        let bgResult: (output: String, exitCode: Int32)
        if route == .probe {
            let probe = await executeInBackground(
                command, onLine: onLine ?? lineHandler,
                probeDeadline: CommandInteractivity.probeDeadline)
            if probe.exitCode == Self.probeDeadlineExitCode {
                CommandInteractivity.record(true, for: command)
                return launchInTerminal(command, purpose: "Interactive terminal command")
            }
            // It finished, but it may still have refused for want of a tty — that is the
            // check below, and it gets to record the verdict instead of this line.
            bgResult = probe
        } else {
            // Non-interactive commands: stream line-by-line to active panel, capture full output
            bgResult = await executeInBackground(command, onLine: onLine ?? lineHandler)
        }

        // If the command itself complains it needs a TTY, re-route to visible terminal
        // A tool that wants a tty says so, but not always by failing: `terminal-browser ls`
        // prints "cannot control this terminal" and exits 0, so keying this off a non-zero
        // exit missed it and the user got the refusal as their answer. The length guard is
        // what keeps a help page that happens to mention "not a tty" from being read as a
        // refusal — a refusal is one line, documentation is not.
        let interactivePhrases = [
            "requires an interactive terminal", "is running interactively", "needs a terminal",
            "not a tty", "no tty present", "cannot control this terminal",
            "no controlling terminal", "must be run in a terminal", "requires a terminal",
        ]
        let lowerOutput = bgResult.output.lowercased()
        if lowerOutput.count < 400, interactivePhrases.contains(where: { lowerOutput.contains($0) })
        {
            // The command said so itself — the most reliable signal there is, so it is worth
            // remembering rather than rediscovering on every ask.
            CommandInteractivity.record(true, for: command)
            if terminalController != nil {
                _ = launchInTerminal(command, purpose: "Interactive fallback")
                return ("'\(command)' requires an interactive terminal — launched in the Terminal tab.", 0)
            }
        } else if route == .probe {
            // Ran to completion and did not ask for a tty: a real headless command.
            CommandInteractivity.record(false, for: command)
        }

        return bgResult
    }

    /// Hands a command to the visible PTY and registers it as a worker.
    ///
    /// One place, so the direct route, the probe result and the "needs a tty" fallback all
    /// launch identically — they used to be three near-copies that had already drifted.
    private func launchInTerminal(
        _ command: String, purpose: String
    ) -> (output: String, exitCode: Int32) {
        guard let controller = terminalController else {
            return (
                "Cannot run '\(command)': requires an interactive terminal. Open the Terminal tab first.",
                1
            )
        }
        controller.sendCommand(command)

        let executable = command.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? command
        let workerIntent = detectWorkerIntent(for: executable)
        let workerID = BackgroundWorkerPool.shared.registerPTYWorker(
            command: command, purpose: purpose, intent: workerIntent)

        // Show mini-player if this is a music tool
        if workerIntent == .musicPlayer {
            MiniPlayerController.shared.show(
                workerID: workerID, toolName: executable, intent: .musicPlayer)
        }

        return (
            "Launched '\(command)' in terminal (interactive mode, worker: \(workerID.uuidString.prefix(6)))",
            0
        )
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
    /// Printed on stderr by the command script before the command runs. Everything the shell
    /// emitted before it came from the user's dotfiles, not from the command.
    nonisolated static let stderrBeginMarker = "__DORAX_CMD_STDERR_BEGIN__"

    /// Drops shell-startup output that precedes the marker. Without a marker the text is
    /// returned unchanged — better to show extra noise than to swallow a real error.
    /// `nonisolated`: called from the process termination handler, off the main actor.
    nonisolated static func commandStderr(_ raw: String) -> String {
        guard let range = raw.range(of: stderrBeginMarker) else { return raw }
        return String(raw[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs an ArgvCommandGate-approved command as a process, with no shell anywhere in the
    /// chain. The environment is rebuilt rather than inherited: the user's dotfiles are the
    /// reason `zsh -lc` exists on the approved path, and they are exactly what must not
    /// influence a command running without approval.
    nonisolated static func runArgv(
        executable: URL,
        arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "LANG": "en_US.UTF-8",
                "TERM": "dumb",
            ]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            var finished = false
            let lock = NSLock()
            func finish(_ result: (String, Int32)) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }

            process.terminationHandler = { proc in
                let out = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                let err = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                let combined = out.isEmpty ? err : (err.isEmpty ? out : out + "\n" + err)
                if let onLine {
                    for line in combined.split(separator: "\n") { onLine(String(line)) }
                }
                finish((combined.trimmingCharacters(in: .whitespacesAndNewlines),
                        proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                finish(("Failed to run \(executable.lastPathComponent): "
                        + error.localizedDescription, 127))
            }
        }
    }

    func executeInBackground(
        _ command: String,
        onLine: (@Sendable (String) -> Void)? = nil,
        probeDeadline: TimeInterval? = nil
    ) async -> (output: String, exitCode: Int32) {
        let toolDirectories = TerminalPackageManager.shared.pinnedToolDirectories()
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // A login shell sources the user's dotfiles, and anything they print lands on this
            // process's stderr before the command has even started. One broken line in
            // ~/.zshenv (a rakubrew init whose Perl cache no longer compiles) therefore
            // appeared in chat as though `brew search` had produced it.
            //
            // The shell still sources those files — commands rely on the aliases, functions and
            // PATH they set — but the script announces itself on stderr first, so everything
            // before that marker is provably startup noise and not this command's output.
            process.arguments = [
                "-lc", "printf '%s\\n' '\(Self.stderrBeginMarker)' >&2\n" + command,
            ]

            // Set up environment with full tool paths (Homebrew Apple Silicon + Intel)
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            let currentPath = environment["PATH"] ?? "/usr/bin:/bin"
            // The directories the user's own pinned tools actually live in come first.
            // terminal-browser installs to ~/.local/bin, which is on PATH only if a dotfile
            // puts it there — so a tool DoraX scanned, listed and scoped could still fail to
            // run as "command not found". We know each tool's resolved path; use it.
            environment["PATH"] =
                (toolDirectories
                    + [
                        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                        "/usr/bin", "/bin",
                    ]).joined(separator: ":") + ":" + currentPath
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
                // Streaming counterpart of the marker split: nothing on stderr counts as
                // output until the command announces itself.
                let commandStarted = TerminalStderrGate()
                errorPipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    for line in chunk.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .controlCharacters)
                        guard !trimmed.isEmpty else { continue }
                        if trimmed.contains(Self.stderrBeginMarker) {
                            commandStarted.open()
                            continue
                        }
                        guard commandStarted.isOpen else { continue }
                        appendCollectedLine(trimmed)
                        onLine(trimmed)
                    }
                }
            }

            // Set when the probe deadline fires, so the termination handler can report a
            // command that was killed for hanging rather than one that failed on its own.
            let deadlineExpired = TerminalStderrGate()

            process.terminationHandler = { proc in
                if deadlineExpired.isOpen {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        returning: (
                            "'\(command)' did not finish — it is waiting for a terminal.",
                            Self.probeDeadlineExitCode
                        ))
                    return
                }
                // Drain any remaining bytes when no streaming handler
                if onLine == nil {
                    let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    var output = String(data: outData, encoding: .utf8) ?? ""
                    let err = Self.commandStderr(String(data: errData, encoding: .utf8) ?? "")
                    if !err.isEmpty {
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
                if let probeDeadline {
                    DispatchQueue.global().asyncAfter(deadline: .now() + probeDeadline) {
                        guard process.isRunning else { return }
                        deadlineExpired.open()
                        // The command runs under `zsh -lc`, so terminating the process kills
                        // the shell and can leave the tool itself parented to launchd. Take
                        // the children first, or the probe leaves a second copy running that
                        // the PTY relaunch then competes with.
                        let reaper = Process()
                        reaper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                        reaper.arguments = ["-TERM", "-P", "\(process.processIdentifier)"]
                        try? reaper.run()
                        reaper.waitUntilExit()
                        process.terminate()
                    }
                }
            } catch {
                continuation.resume(returning: ("Error: \(error.localizedDescription)", 1))
            }
        }
    }

    /// Exit code for a probe the deadline killed. Outside the 0…255 range a real process can
    /// return, so it cannot collide with a command's own failure.
    static let probeDeadlineExitCode: Int32 = -777

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
            #if DEBUG
            print("Failed to write audit log: \(error)")
            #endif
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

/// Tiny thread-safe latch for the streaming stderr gate. The pipe's readability handler runs
/// off the main thread, so the "has the command started" flag it shares with its own later
/// invocations needs a lock rather than a captured `var`.
final class TerminalStderrGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}
