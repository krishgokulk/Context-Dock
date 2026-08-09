// ClaudeCodeBridge.swift
// Context-Dock
//
// Runs Claude Code headless and answers in the chat, instead of printing a command.
//
// The chat could already reach a model, but not a model that can read the user's repo.
// "What problem is this screenshot showing?" needs the screenshot *and* the project it
// came from — the files, the branch, CLAUDE.md. That is exactly what Claude Code has and
// a bare API call does not, so the answer used to be a terminal command the user had to
// run themselves, in a terminal, and read there.
//
// So the chat runs it. `claude -p --output-format stream-json` is a subprocess that
// streams NDJSON: tool calls as they happen, text as it is written, a final result.
// The conversation reads it and speaks it.
//
// Two properties matter more than the plumbing:
//
// - **A thread is a session.** Each chat scope keeps one Claude Code session id, so a
//   follow-up continues the same conversation with the same context rather than starting
//   from nothing and re-reading the repo.
// - **Read-only unless the user says otherwise.** Bash, Edit, Write and NotebookEdit are
//   denied outright, so this cannot change anything in a real repository. Writing is a
//   decision, not a default — and `--dangerously-skip-permissions` is never passed.

import AppKit
import Foundation
import OSLog

@MainActor
final class ClaudeCodeBridge {
    static let shared = ClaudeCodeBridge()

    private init() {}

    private let log = Logger(subsystem: "com.krishgokul.ContextDock", category: "ClaudeCode")

    struct Result {
        let text: String
        /// Tools Claude Code actually ran, for the receipt chips.
        let toolsRan: [String]
        let success: Bool
        /// The full NDJSON-derived transcript, for the Console panel.
        let transcript: String
    }

    // MARK: - Availability

    /// Where the CLI is, if it is installed. Checked in install-order rather than shelling
    /// out to `which`: a GUI app's PATH is not the user's shell PATH, so `which` from here
    /// misses the common install location entirely.
    static var executableURL: URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var isAvailable: Bool { executableURL != nil }

    /// A request meant for Claude Code rather than the chat's own model.
    ///
    /// Deliberately narrow. A chat scoped to a coding app mentions "claude" constantly,
    /// and hijacking every one of those would take the conversation away from the user
    /// without being asked.
    static func shouldHandle(_ query: String) -> Bool {
        guard isAvailable else { return false }
        let lower = query.lowercased()
        let patterns = [
            #"\bclaude code\b"#,
            #"\b(ask|with|via|using|use|send (?:this |it )?to)\s+claude\b"#,
            #"^claude[,:]"#,
        ]
        return patterns.contains {
            lower.range(of: $0, options: .regularExpression) != nil
        }
    }

    // MARK: - Session continuity

    private static let sessionDefaultsKey = "claudeCodeSessionIDs"

    /// The Claude Code session this chat thread owns. One per scope, so the second question
    /// continues the first — the whole point of using Claude Code over a one-shot call.
    private func sessionID(for scope: GeneralChatScope) -> (id: String, isNew: Bool) {
        var map = UserDefaults.standard.dictionary(forKey: Self.sessionDefaultsKey)
            as? [String: String] ?? [:]
        if let existing = map[scope.storageKey] { return (existing, false) }
        let fresh = UUID().uuidString.lowercased()
        map[scope.storageKey] = fresh
        UserDefaults.standard.set(map, forKey: Self.sessionDefaultsKey)
        return (fresh, true)
    }

    /// Forgets the thread's session. Clearing a chat should clear what the agent remembers
    /// about it too — otherwise "clear" leaves a conversation running somewhere the user
    /// can no longer see.
    func forgetSession(for scope: GeneralChatScope) {
        var map = UserDefaults.standard.dictionary(forKey: Self.sessionDefaultsKey)
            as? [String: String] ?? [:]
        guard map.removeValue(forKey: scope.storageKey) != nil else { return }
        UserDefaults.standard.set(map, forKey: Self.sessionDefaultsKey)
    }

    // MARK: - Run

    /// The project this question is about: the scoped app's open folder, else whatever is
    /// in front. Claude Code reads CLAUDE.md and the git state from here, which is what
    /// makes the answer about *this* project rather than about code in general.
    private func projectRoot(for scope: GeneralChatScope, bundleId: String?) -> String {
        if let bundleId,
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).first,
            let root = ProjectContextResolver.shared.projectRoot(for: running)
        {
            return root
        }
        if let frontmost = ProjectContextResolver.shared.frontmostProjectRoot() {
            return frontmost
        }
        return NSHomeDirectory()
    }

    func ask(
        query: String,
        scope: GeneralChatScope,
        attachments: [URL] = [],
        /// Called as work happens — tool activity and the first text — so the chat can say
        /// what it is doing instead of showing a spinner for a minute.
        onProgress: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> Result {
        guard let executable = Self.executableURL else {
            return Result(
                text: "Claude Code isn't installed. Install it, then ask again.",
                toolsRan: [], success: false, transcript: "")
        }

        var bundleId: String?
        if case .app(let id) = scope { bundleId = id }
        let root = projectRoot(for: scope, bundleId: bundleId)
        let session = sessionID(for: scope)

        // Attachments go in as absolute paths. Claude Code's Read tool opens images
        // itself, so a screenshot is read at full fidelity rather than passed through the
        // chat's own OCR — which is the entire reason to route a screenshot here.
        var prompt = query
        if !attachments.isEmpty {
            let files = attachments.map(\.path).joined(separator: "\n")
            prompt = "\(query)\n\nFiles to look at:\n\(files)"
        }

        var arguments = [
            "-p", prompt,
            "--verbose",  // required by the CLI whenever -p is paired with stream-json
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--add-dir", root,
            // Read-only, enforced by the deny list rather than the allow list. An allow
            // list only pre-approves — with no one at a permission prompt, a tool that is
            // merely absent from it still runs. Verified: allowlisting Read/Grep/Glob
            // alone, Claude Code reached for Bash on the first question asked.
            "--allowedTools", "Read", "Grep", "Glob",
            "--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit",
            "--permission-mode", "dontAsk",
        ]
        arguments += session.isNew ? ["--session-id", session.id] : ["--resume", session.id]

        log.notice(
            "run session=\(session.id, privacy: .public) new=\(session.isNew, privacy: .public) root=\(root, privacy: .public)")

        return await withCheckedContinuation { continuation in
            Self.execute(
                executable: executable, arguments: arguments, workingDirectory: root,
                onProgress: onProgress
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - NDJSON

    /// Runs the process off the main actor and parses the stream as it arrives.
    ///
    /// nonisolated because the read loop blocks: doing this on the main actor would freeze
    /// the window for the length of the run, which on a real question is minutes.
    private nonisolated static func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: String,
        onProgress: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            let output = Pipe()
            process.standardOutput = output
            // stderr is separated and dropped: the user's own Claude Code hooks write
            // there, and a broken hook's noise is not part of the answer.
            process.standardError = Pipe()

            var text = ""
            var tools: [String] = []
            var transcript: [String] = []
            var success = false
            var buffer = Data()

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        completion(
                            Result(
                                text: "Couldn't start Claude Code: \(error.localizedDescription)",
                                toolsRan: [], success: false, transcript: ""))
                    }
                }
                return
            }

            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                // NDJSON: one object per line, and a chunk boundary lands mid-line often
                // enough that parsing per-chunk instead of per-line loses events.
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty,
                        let object = try? JSONSerialization.jsonObject(with: line)
                            as? [String: Any],
                        let type = object["type"] as? String
                    else { continue }

                    switch type {
                    case "stream_event":
                        guard let event = object["event"] as? [String: Any],
                            event["type"] as? String == "content_block_delta",
                            let delta = event["delta"] as? [String: Any],
                            let piece = delta["text"] as? String
                        else { continue }
                        text += piece

                    case "assistant":
                        guard let message = object["message"] as? [String: Any],
                            let blocks = message["content"] as? [[String: Any]]
                        else { continue }
                        for block in blocks where block["type"] as? String == "tool_use" {
                            guard let name = block["name"] as? String else { continue }
                            if !tools.contains(name) { tools.append(name) }
                            let target = (block["input"] as? [String: Any])
                                .flatMap { $0["file_path"] ?? $0["pattern"] ?? $0["path"] }
                                .map { "\($0)" }
                            let label = target.map { "\(name) \(URL(fileURLWithPath: $0).lastPathComponent)" }
                                ?? name
                            transcript.append("· \(label)")
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { onProgress(label) }
                            }
                        }

                    case "result":
                        success = (object["is_error"] as? Bool) == false
                        if let final = object["result"] as? String, !final.isEmpty {
                            text = final
                        }
                        if let denials = object["permission_denials"] as? [[String: Any]],
                            !denials.isEmpty
                        {
                            let names = denials.compactMap { $0["tool_name"] as? String }
                            transcript.append(
                                "Refused (read-only): " + names.joined(separator: ", "))
                        }

                    default:
                        continue
                    }
                }
            }
            process.waitUntilExit()

            let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = Result(
                text: finalText.isEmpty
                    ? "Claude Code finished without an answer." : finalText,
                toolsRan: tools,
                success: success && !finalText.isEmpty,
                transcript: transcript.joined(separator: "\n"))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(answer) }
            }
        }
    }
}
