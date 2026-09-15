// CodexCLIService.swift
// Context-Dock
//
// One bounded, non-interactive Codex run, for the specialist-worker layer.
//
// Same stance as `ClaudeCodeCLIService`: the envelope is expressed as how the process starts,
// not as something the model is asked to respect. `codex exec --sandbox read-only -C <dir>`
// is a process that cannot write outside its own sandbox, whatever it decides to try.
//
// Codex has no system-prompt flag, so the instructions travel at the top of the prompt. It
// streams JSON events on stdout (`--json`): `item.started` / `item.completed` carry commands
// and agent messages, `turn.completed` ends the run. The last agent message is the report;
// `--output-last-message` writes it to a file as well, which is what is read back when the
// stream was cut short.

import Foundation
import os

@MainActor
enum CodexCLIService {
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "CodexCLI")

    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Codex isn't installed. Install it with `npm i -g @openai/codex`, then "
                    + "run `codex login` once."
            case .failed(let detail):
                return detail.isEmpty ? "Codex returned no answer." : detail
            }
        }
    }

    /// One line of the `--json` event stream, reduced to what DoraX shows or keeps.
    enum StreamLine: Equatable {
        /// A factual stage worth a step row — a command being run.
        case step(String)
        /// An agent message. The last one is the report.
        case message(String)
        /// The turn ended.
        case completed
        /// An error item from the CLI itself.
        case failure(String)
        case ignored
    }

    /// Where the CLI is, if it is anywhere. The same candidate list discovery scans, so the
    /// worker offered is the worker run.
    static func binaryPath() -> String? {
        AIWorkerDiscovery.defaultCandidates[.codex]?
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The exact argument list for one invocation. Pure, so the flags can be asserted without
    /// running the binary.
    ///
    /// `allowsWrites` is accepted and ignored on purpose: no write path with its own approval
    /// exists yet, so the sandbox is read-only whatever the caller says. When one exists, this
    /// is the single place that changes.
    nonisolated static func arguments(
        prompt: String,
        workingDirectory: URL?,
        allowsWrites: Bool
    ) -> [String] {
        _ = allowsWrites
        var arguments = ["exec", "--sandbox", "read-only", "--json", "--skip-git-repo-check"]
        // Nothing this run does belongs in the user's own Codex history.
        arguments.append("--ephemeral")
        if let workingDirectory {
            arguments.append(contentsOf: ["-C", workingDirectory.path])
        }
        arguments.append(prompt)
        return arguments
    }

    nonisolated static func parse(streamLine line: String) -> StreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return .ignored }

        switch type {
        case "turn.completed":
            return .completed
        case "item.started", "item.completed":
            guard let item = object["item"] as? [String: Any],
                let itemType = item["type"] as? String
            else { return .ignored }
            switch itemType {
            case "command_execution":
                // A command is announced once, when it starts; its completion is not a
                // second stage.
                guard type == "item.started", let command = item["command"] as? String
                else { return .ignored }
                return .step("Running \(displayCommand(command))")
            case "agent_message":
                guard type == "item.completed", let text = item["text"] as? String,
                    !text.isEmpty
                else { return .ignored }
                return .message(text)
            case "error":
                return .failure(item["message"] as? String ?? "Codex reported an error.")
            default:
                return .ignored
            }
        default:
            return .ignored
        }
    }

    /// The last agent message in a transcript of event lines, or nil when there is none.
    nonisolated static func report(fromTranscript transcript: String) -> String? {
        var last: String?
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            if case .message(let text) = parse(streamLine: String(line)) { last = text }
        }
        return last
    }

    /// `/bin/zsh -lc 'ls -la'` is how the sandbox runs a command; `ls -la` is what the user
    /// wants to read in a step row.
    private nonisolated static func displayCommand(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -c ", "/bin/zsh -c ", "bash -lc "] {
            if text.hasPrefix(shell) {
                text = String(text.dropFirst(shell.count))
                break
            }
        }
        if text.count >= 2, text.first == "'", text.last == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return String(text.prefix(80))
    }

    /// One bounded run: prompt in, report out. Steps go to `onProgress` as they happen.
    static func send(
        prompt: String,
        workingDirectory: URL?,
        timeout: TimeInterval,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let binary = binaryPath() else { throw Failure.notInstalled }

        let lastMessageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-last-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMessageURL) }

        var arguments = arguments(
            prompt: prompt, workingDirectory: workingDirectory, allowsWrites: false)
        // Before the prompt, which must stay last.
        arguments.insert(contentsOf: ["-o", lastMessageURL.path], at: arguments.count - 1)

        log.notice("codex \(arguments.dropLast().joined(separator: " "), privacy: .public)")

        let transcript = try await run(
            binary: binary, arguments: arguments, workingDirectory: workingDirectory,
            timeout: timeout,
            onLine: { line in
                switch parse(streamLine: line) {
                case .step(let step): onProgress?(step)
                case .failure(let message): onProgress?("Codex: \(message)")
                case .message, .completed, .ignored: break
                }
            })

        if let report = report(fromTranscript: transcript) { return report }
        if let fromFile = try? String(contentsOf: lastMessageURL, encoding: .utf8),
            !fromFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return fromFile
        }
        throw Failure.failed(
            transcript.contains("timed out") ? transcript : "Codex returned no answer.")
    }

    // MARK: - Process

    private static func run(
        binary: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory ?? FileManager.default.temporaryDirectory

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            process.environment = environment

            // Closed stdin: `codex exec` otherwise waits on "Reading additional input from
            // stdin…" and the run never begins.
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            // Diagnostics stay off the event stream; a parser fed log lines has to skip them
            // and a user shown them has to read them.
            process.standardError = FileHandle.nullDevice

            let buffer = CodexLineBuffer()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<String, Error>) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                continuation.resume(with: result)
            }

            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in buffer.append(data) {
                    Task { @MainActor in onLine(line) }
                }
            }
            process.terminationHandler = { _ in
                output.fileHandleForReading.readabilityHandler = nil
                for line in buffer.drain() {
                    Task { @MainActor in onLine(line) }
                }
                finish(.success(buffer.transcript))
            }
            do {
                try process.run()
            } catch {
                finish(.failure(Failure.failed(error.localizedDescription)))
                return
            }
            // The task's own budget, applied as a fact: past it the process is gone, and the
            // transcript so far is what there is.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                finish(.success(buffer.transcript + "\nCodex timed out after \(Int(timeout)) s."))
            }
        }
    }
}

/// Whole lines out of whatever chunks the pipe delivers; the tail waits for its newline.
private final class CodexLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var everything = ""

    var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return everything
    }

    func append(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        everything += text
        pending += text
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            lines.append(String(pending[..<newline]))
            pending = String(pending[pending.index(after: newline)...])
        }
        return lines
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = pending
        pending = ""
        return rest.isEmpty ? [] : [rest]
    }
}
