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
// The CLI is itself an agent with file and shell tools. That is emphatically not what a chat
// provider should be, so every invocation passes `--allowed-tools ""`: DoraX supplies the
// context and runs the actions, and the model here only answers.

import Foundation

@MainActor
enum ClaudeCodeCLIService {

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

    /// One question, one answer. No session is carried between calls: DoraX owns the
    /// conversation and sends the history it wants included, so a hidden second transcript
    /// inside the CLI would only be able to disagree with it.
    static func send(
        prompt: String,
        systemPrompt: String?,
        model: String?
    ) async throws -> String {
        guard let binary = binaryPath() else { throw Failure.notInstalled }

        var arguments = ["-p", prompt, "--output-format", "json", "--allowed-tools", ""]
        if let systemPrompt, !systemPrompt.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", systemPrompt])
        }
        if let model, !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }

        let output = try await run(binary: binary, arguments: arguments)
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

    private static func run(binary: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            // Run somewhere neutral. The CLI reads project settings from its working
            // directory, and a chat answer should not depend on which folder DoraX happened
            // to be launched from.
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

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
