// ClaudeCodeCLIService.swift
// Context-Dock
//
// The Claude subscription, without a proxy in the middle.
//
// A bridge works by replaying a subscription's token against the API endpoints — which is
// outside Anthropic's and OpenAI's consumer terms, and puts the user's account at risk, not
// ours. It also has to be installed, running, and pointed at a model it happens to serve;
// three things that can each be wrong, and two of which were.
//
// The Claude Code CLI is the sanctioned path: `claude` is included in Pro and Max, it holds
// its own login, and `-p` runs it headless with JSON out. DoraX shells out to the binary the
// user already has. No endpoint, no API key, no port, nothing to keep running.
//
// The CLI is itself an agent with file and shell tools, and how much of that DoraX hands it is
// a setting rather than a constant — see ClaudeCodeToolAccess.
//
// Worth stating plainly, because it is the one place DoraX gives up its own guarantees: every
// gate this app has — the approval sheet, AppMenuConsentStore, CapabilityScopeGuard, declared
// risk levels, receipts, CommandOutcomeVerifier — governs DoraX's *own* capability route. A
// CLI subprocess holding its own tools answers to none of them, and DoraX cannot write a
// receipt for work it did not run. Above `.answerOnly`, the CLI's own permission model is the
// only thing between the model and the disk, which is why the working directory is pinned and
// the level is visible in Settings rather than assumed.

import Foundation
import OSLog

@MainActor
enum ClaudeCodeCLIService {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "ClaudeCLI")

    enum Failure: LocalizedError {
        case notInstalled
        case notAuthenticated
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Claude Code isn't installed. Install it, then run `claude` once to "
                    + "sign in with your Claude subscription."
            case .notAuthenticated:
                return "Claude Code is installed but not signed in. Run `claude` in a "
                    + "terminal and log in with your subscription."
            case .failed(let detail):
                return detail.isEmpty ? "Claude Code returned no answer." : detail
            }
        }
    }

    /// Where the CLI is, if it is anywhere.
    ///
    /// `which` is not enough: DoraX runs without the user's interactive shell, so a binary
    /// in ~/.local/bin — where the native installer puts it — is invisible unless we look
    /// there ourselves. Same lesson the CLI scopes taught.
    static func binaryPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binaryPath() != nil }

    /// How much of the CLI's own agent DoraX turns on.
    ///
    /// The names are the CLI's built-in tools, passed to `--tools`. `--permission-mode
    /// acceptEdits` is required alongside them: `-p` is non-interactive, so a tool that stops
    /// to ask for permission has nobody to ask and the turn stalls.
    enum ToolAccess: String, CaseIterable, Sendable {
        /// The model answers and nothing else. DoraX supplies the context and runs the actions.
        case answerOnly
        /// Reading and research: it can open files, search a project and fetch pages, but
        /// changes nothing. The useful half, with no way to damage anything.
        case research
        /// Everything, including editing files and running shell commands, inside the working
        /// directory below. DoraX's approval sheet does not apply to any of it.
        case full

        var toolList: String {
            switch self {
            case .answerOnly: return ""
            case .research: return "Read,Glob,Grep,WebFetch,WebSearch"
            case .full: return "Read,Glob,Grep,WebFetch,WebSearch,Edit,Write,Bash"
            }
        }

        var runsTools: Bool { self != .answerOnly }

        var title: String {
            switch self {
            case .answerOnly: return "Answer only"
            case .research: return "Read and research"
            case .full: return "Full — edit files and run commands"
            }
        }

        var detail: String {
            switch self {
            case .answerOnly:
                return "Claude answers questions. DoraX supplies the context and performs every "
                    + "action itself, through its own approval prompts."
            case .research:
                return "Claude can read files, search the project and fetch web pages in the "
                    + "folder below. It cannot change anything."
            case .full:
                return "Claude can edit files and run shell commands in the folder below, using "
                    + "its own permission model. DoraX's approval prompts do not apply to it."
            }
        }
    }

    /// The exact argument list for one invocation. Pure, so the flags can be asserted without
    /// running the binary — they were guessed once and silently disabled every tool.
    static func arguments(
        prompt: String,
        systemPrompt: String?,
        model: String?,
        access: ToolAccess,
        workingDirectory: URL?
    ) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "json", "--tools", access.toolList]
        if access.runsTools {
            // Two different things, and passing only the first is why WebFetch kept coming
            // back "Claude requested permissions to use WebFetch, but you haven't granted it".
            // `--tools` says which tools exist; `--allowedTools` is the permission allowlist.
            // `--permission-mode acceptEdits` covers edits and nothing else, so a fetch still
            // stopped to ask — and `-p` is non-interactive, so there was nobody to ask.
            arguments.append(contentsOf: ["--allowedTools", access.toolList])
            arguments.append(contentsOf: ["--permission-mode", "acceptEdits"])
            if let workingDirectory {
                arguments.append(contentsOf: ["--add-dir", workingDirectory.path])
            }
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", systemPrompt])
        }
        if let model, !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        return arguments
    }

    /// One question, one answer. No session is carried between calls: DoraX owns the
    /// conversation and sends the history it wants included, so a hidden second transcript
    /// inside the CLI would only be able to disagree with it.
    static func send(
        prompt: String,
        systemPrompt: String?,
        model: String?,
        access: ToolAccess? = nil,
        workingDirectory: URL? = nil
    ) async throws -> String {
        guard let binary = binaryPath() else { throw Failure.notInstalled }

        let access = access ?? AppSettings.shared.claudeCodeToolAccess
        // Answering needs no folder, and reading project settings from wherever DoraX happened
        // to launch would make the answer depend on it. Anything that runs tools gets a real
        // directory, because "edit the file" has to mean somewhere.
        let directory: URL? = access.runsTools
            ? (workingDirectory ?? ChatWorkingDirectory.resolve(for: nil))
            : nil
        let arguments = arguments(
            prompt: prompt, systemPrompt: systemPrompt, model: model,
            access: access, workingDirectory: directory)
        log.notice(
            "claude cli access=\(access.rawValue, privacy: .public) dir=\(directory?.path ?? "-", privacy: .public)")

        let output = try await run(
            binary: binary, arguments: arguments, workingDirectory: directory)
        guard let payload = decodeFirstObject(in: output) else {
            // The CLI prints its auth complaint as prose, not JSON.
            if output.lowercased().contains("login") || output.lowercased().contains("auth") {
                throw Failure.notAuthenticated
            }
            throw Failure.failed(String(output.prefix(300)))
        }

        if let usage = payload["usage"] as? [String: Any] {
            AITokenLedger.shared.record(
                provider: .claudeCode,
                model: (payload["model"] as? String) ?? model ?? "claude",
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                cachedInputTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0)
        }

        if payload["is_error"] as? Bool == true {
            throw Failure.failed(
                (payload["result"] as? String) ?? "Claude Code reported an error.")
        }
        guard let result = payload["result"] as? String, !result.isEmpty else {
            throw Failure.failed("Claude Code returned no answer.")
        }
        return result
    }

    // MARK: - Process

    private static func run(
        binary: String, arguments: [String], workingDirectory: URL? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            // Somewhere neutral when it is only answering: the CLI reads project settings from
            // its working directory, and a chat answer should not depend on which folder DoraX
            // happened to be launched from. When it holds tools, the folder is the point.
            process.currentDirectoryURL =
                workingDirectory ?? FileManager.default.temporaryDirectory

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
            }
        }
    }

    /// The CLI writes one JSON object and a trailing newline; some versions add a line of
    /// their own before it. Decoding the first object found survives both.
    private static func decodeFirstObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        let candidate = String(output[start...])
        guard let data = candidate.data(using: .utf8) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        // Trailing bytes after the object make strict parsing fail; retry on each closing
        // brace from the end until one parses.
        var slice = candidate
        while let lastBrace = slice.lastIndex(of: "}") {
            let attempt = String(slice[...lastBrace])
            if let data = attempt.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return object
            }
            slice = String(slice[..<lastBrace])
        }
        return nil
    }
}

extension ClaudeCodeCLIService {
    /// Folds the conversation into the single prompt the CLI takes.
    ///
    /// `-p` is one shot: it has no memory of the last call, and resuming its own session
    /// would give the CLI a transcript DoraX cannot see or edit. So the history DoraX holds
    /// is the history that gets sent, and the two can never disagree.
    static func promptWithHistory(message: String, history: [ChatMessage]) -> String {
        guard !history.isEmpty else { return message }
        let recent = history.suffix(12).map { entry in
            "\(entry.role == .user ? "User" : "Assistant"): \(entry.content)"
        }
        return """
            Earlier in this conversation:
            \(recent.joined(separator: "\n"))

            Now answer this, using the conversation above for context:
            \(message)
            """
    }
}
