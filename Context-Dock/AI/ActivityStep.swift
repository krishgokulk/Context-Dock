// ActivityStep.swift
// Context-Dock
//
// One row per thing DoraX actually ran during a turn.
//
// Progress used to be a list of strings — "Understanding your request…", "Thinking…",
// "Running globalcmd.volume…", "Ran globalcmd.volume", "Task complete" — and the answer's
// disclosure expanded to that narration. Half of it described nothing that happened, and
// none of it could say what the command was given or what came back.
//
// A step is recorded where a tool executes (AgentToolRegistry dispatch, the CLI providers'
// own tool events), never parsed out of status words. Narration still drives the live line
// while a turn runs; the finished answer shows only steps.

import Foundation

nonisolated struct ActivityStep: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: String, Sendable {
        /// A shell command DoraX ran through its own gate.
        case command
        /// Something read: a status, a page, a file, the user's data.
        case read
        /// A DoraX capability or app action that does something.
        case tool
        /// A call into an MCP server.
        case mcp
        /// A command the CLI provider (Claude Code, Codex) ran in its own shell.
        case providerShell
        /// Waiting on the user to approve.
        case approval
    }

    nonisolated enum Status: String, Sendable {
        case running, ok, failed, denied
    }

    let id: UUID
    var kind: Kind
    /// "Ran globalcmd.volume", "Read Bluetooth status".
    var title: String
    /// The one-line input: "value 30", the command line, the MCP arguments.
    var detail: String
    var status: Status
    var startedAt: Date
    var duration: TimeInterval?
    /// What came back, clipped to `outputLimit`. Shown only when the row is opened.
    var output: String
    /// The value a read-back observed after a write, when one was taken.
    var readBack: String?

    static let outputLimit = 8_000

    init(
        id: UUID = UUID(), kind: Kind, title: String, detail: String = "",
        status: Status = .running, startedAt: Date = Date(), duration: TimeInterval? = nil,
        output: String = "", readBack: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
        self.output = Self.clip(output)
        self.readBack = readBack
    }

    static func clip(_ text: String) -> String {
        guard text.count > outputLimit else { return text }
        return String(text.prefix(outputLimit)) + "\n… (clipped)"
    }

    /// A receipt is an execution record too. Surfaces that write receipts but never go
    /// through the tool registry (menu routes, workers) still get one row per thing done.
    @MainActor
    init(receipt: DoraXActionReceipt) {
        let command = receipt.command
        let isRead = receipt.isVerification || command.hasPrefix("read_")
            || command.hasPrefix("verify_")
        self.init(
            kind: isRead ? .read : .tool,
            title: (isRead ? "Read " : "Ran ") + Self.receiptSubject(command),
            detail: command,
            status: receipt.success ? .ok : .failed,
            startedAt: receipt.recordedAt,
            output: receipt.output)
    }

    /// `route(menuCommand, New Window)` → `New Window`; `run_command(ls)` → `ls`.
    private static func receiptSubject(_ command: String) -> String {
        guard let open = command.firstIndex(of: "("), command.hasSuffix(")") else {
            return command
        }
        let inner = command[command.index(after: open)..<command.index(before: command.endIndex)]
        let parts = inner.split(separator: ",", maxSplits: 1)
        let subject = (parts.count == 2 ? parts[1] : inner)
            .trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? command : subject
    }

    /// The steps a finished message shows: what the turn recorded, or — for a path that only
    /// wrote receipts — one step per receipt.
    @MainActor
    static func steps(recorded: [ActivityStep], receipts: [DoraXActionReceipt]) -> [ActivityStep] {
        recorded.isEmpty ? receipts.map(ActivityStep.init(receipt:)) : recorded
    }
}

// MARK: - Recorder

/// Collects the steps of one turn. Bound with `ActivityRecorder.$current.withValue` around
/// the turn, so every tool dispatched inside it — on any actor — lands in the right turn,
/// and two General Chat threads answering at once never share a list.
nonisolated final class ActivityRecorder: @unchecked Sendable {
    @TaskLocal static var current: ActivityRecorder?

    /// The recorder for a surface whose turns run in tasks nothing binds (the dock). A
    /// bound turn always wins; this only catches work no turn has claimed.
    static var fallback: ActivityRecorder? {
        get { fallbackLock.lock(); defer { fallbackLock.unlock() }; return fallbackStorage }
        set { fallbackLock.lock(); fallbackStorage = newValue; fallbackLock.unlock() }
    }
    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static var fallbackStorage: ActivityRecorder?

    /// Where a tool call running now should record itself.
    static var active: ActivityRecorder? { current ?? fallback }

    private let lock = NSLock()
    private var recorded: [ActivityStep] = []
    private let onChange: (@Sendable ([ActivityStep]) -> Void)?
    /// CLI tool-use ids to the rows they opened.
    private var external: [String: UUID] = [:]

    init(onChange: (@Sendable ([ActivityStep]) -> Void)? = nil) {
        self.onChange = onChange
    }

    var steps: [ActivityStep] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    @discardableResult
    func begin(kind: ActivityStep.Kind, title: String, detail: String = "") -> UUID {
        let step = ActivityStep(kind: kind, title: title, detail: detail)
        mutate { $0.append(step) }
        return step.id
    }

    func finish(
        _ id: UUID, status: ActivityStep.Status, output: String, readBack: String? = nil,
        title: String? = nil
    ) {
        mutate { steps in
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].status = status
            steps[index].output = ActivityStep.clip(output)
            steps[index].readBack = readBack
            steps[index].duration = Date().timeIntervalSince(steps[index].startedAt)
            if let title { steps[index].title = title }
        }
    }

    /// Closes anything still running — a turn that ended while a tool was in flight must
    /// not leave a spinner on the finished answer.
    func settle() {
        mutate { steps in
            for index in steps.indices where steps[index].status == .running {
                steps[index].status = .failed
                steps[index].duration = Date().timeIntervalSince(steps[index].startedAt)
                if steps[index].output.isEmpty { steps[index].output = "Stopped when the turn ended." }
            }
        }
    }

    /// A CLI provider's own tool event: Claude Code's tool_use / tool_result, Codex's
    /// command_execution and mcp_tool_call items.
    func apply(_ event: CLIActivityEvent) {
        switch event {
        case .started(let externalID, let kind, let title, let detail):
            let id = begin(kind: kind, title: title, detail: detail)
            lock.lock()
            external[externalID] = id
            lock.unlock()
        case .finished(let externalID, let ok, let output):
            lock.lock()
            let id = external.removeValue(forKey: externalID)
            lock.unlock()
            guard let id else { return }
            finish(id, status: ok ? .ok : .failed, output: output)
        }
    }

    private func mutate(_ change: (inout [ActivityStep]) -> Void) {
        lock.lock()
        change(&recorded)
        let snapshot = recorded
        lock.unlock()
        onChange?(snapshot)
    }
}

// MARK: - Naming a tool call

nonisolated enum ActivityStepNaming {
    /// Plumbing, not work on the user's Mac: looking up which capability to call, paging
    /// through a stored result. A row for these made "set volume to 30" read as three
    /// things done when one was.
    static let plumbingTools: Set<String> = [
        "find_capability", "find_route", "read_tool_result",
    ]

    /// Kind, title and one-line input for a DoraX tool call. `capabilityTitle` and
    /// `capabilityIsRead` describe the capability a `run_capability` call names, when known.
    @MainActor
    static func describe(
        tool name: String, arguments: [String: Any],
        capabilityTitle: String? = nil, capabilityIsRead: Bool = false
    ) -> (kind: ActivityStep.Kind, title: String, detail: String) {
        switch name {
        case "run_capability":
            let id = arguments["capability_id"] as? String ?? "capability"
            let input = arguments["input"] as? [String: Any] ?? [:]
            if capabilityIsRead {
                let subject = capabilityTitle.map(readableSubject) ?? id
                let lower = subject.lowercased()
                let isVerbPhrase = ["read", "search", "list", "get ", "find", "show", "check"]
                    .contains { lower.hasPrefix($0) }
                return (.read, isVerbPhrase ? subject : "Read \(subject)", inputLine(input))
            }
            return (.tool, "Ran \(id)", inputLine(input))
        case "run_command":
            let command = (arguments["command"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (.command, "Ran \(oneLine(command, limit: 60))", oneLine(command, limit: 400))
        case "run_mcp_tool":
            let tool = arguments["tool"] as? String ?? arguments["name"] as? String ?? "tool"
            let server = arguments["server"] as? String ?? ""
            let input = arguments["arguments"] as? [String: Any] ?? [:]
            return (.mcp, server.isEmpty ? "Ran \(tool)" : "Ran \(tool) via \(server)",
                inputLine(input))
        default:
            let label = ScopedToolStep.label(for: name)
                .trimmingCharacters(in: CharacterSet(charactersIn: "…"))
            let detail = inputLine(arguments.filter { $0.key != "explanation" })
            for (present, past) in [
                ("Reading ", "Read "), ("Fetching ", "Fetched "), ("Searching ", "Searched "),
            ] where label.hasPrefix(present) {
                return (.read, past + label.dropFirst(present.count), detail)
            }
            let isRead = name.hasPrefix("read_") || name.hasPrefix("get_")
                || name.hasPrefix("search_") || name.hasPrefix("list_")
            return (isRead ? .read : .tool, isRead ? "Read \(name)" : "Ran \(name)", detail)
        }
    }

    /// "Bluetooth status — read whether it is on" → "Bluetooth status".
    static func readableSubject(_ title: String) -> String {
        let head = title.components(separatedBy: " — ").first ?? title
        return head.components(separatedBy: " · ").first?
            .trimmingCharacters(in: .whitespaces) ?? head
    }

    /// `["value": "30"]` → `value 30`. Sorted so the same call always reads the same.
    static func inputLine(_ input: [String: Any]) -> String {
        let parts = input.keys.sorted().compactMap { key -> String? in
            let text = oneLine(String(describing: input[key]!), limit: 80)
            return text.isEmpty ? nil : "\(key) \(text)"
        }
        return parts.joined(separator: " · ")
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

// MARK: - Narration

nonisolated enum ActivityNarration {
    /// Lines that say the app is busy without saying what it did. Fine as the live line
    /// while a turn runs; noise in the record of a finished one.
    static func isFiller(_ line: String) -> Bool {
        let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "….")).lowercased()
        if key.isEmpty { return true }
        if fillerLines.contains(key) { return true }
        // The registry's own start/finish narration duplicates the step it describes.
        return key.hasSuffix(" complete") || key.hasSuffix(" did not complete")
            || key.hasPrefix("running ")
    }

    private static let fillerLines: Set<String> = [
        "understanding your request", "thinking", "task complete", "working",
        "writing answer", "reading tool result", "preparing the final response",
        "understanding the returned tool data", "read the result",
        "checking that actually happened", "verifying the result",
    ]

    /// The finished record: narration minus filler, without repeats.
    static func durableTrace(_ lines: [String]) -> [String] {
        var seen: Set<String> = []
        return lines.filter { line in
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !isFiller(line) && seen.insert(key).inserted
        }
    }
}

// MARK: - Header and result line

enum ActivitySummary {
    /// "Ran 1 command, read 1 source" — counted from steps, so it cannot overstate.
    static func header(for steps: [ActivityStep]) -> String {
        let reads = steps.filter { $0.kind == .read }.count
        let runs = steps.filter { $0.kind != .read && $0.kind != .approval }.count
        let failed = steps.filter { $0.status == .failed || $0.status == .denied }.count
        var parts: [String] = []
        if runs > 0 { parts.append("Ran \(runs) command\(runs == 1 ? "" : "s")") }
        if reads > 0 {
            parts.append("\(parts.isEmpty ? "Read" : "read") \(reads) source\(reads == 1 ? "" : "s")")
        }
        if parts.isEmpty { parts.append("\(steps.count) step\(steps.count == 1 ? "" : "s")") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }

    /// What a finished write says about checking itself.
    ///
    /// "Executor confirmed, no independent check" used to follow every command, which is a
    /// sentence about the absence of a verifier nobody asked about. Now: a read-back value is
    /// shown with a tick; a check that failed or could not run is said; otherwise the result
    /// stands on its own.
    static func resultLine(
        result: String, isWrite: Bool, verification: AIVerificationStatus, readBack: String?
    ) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let readBack = readBack?.trimmingCharacters(in: .whitespacesAndNewlines),
            !readBack.isEmpty, verification == .verified || verification == .executorConfirmed
        {
            return trimmed.contains("read back") ? trimmed : "\(trimmed) ✓ (read back \(readBack))"
        }
        guard isWrite else { return trimmed }
        switch verification {
        case .unverified, .notAvailable:
            return "\(trimmed)\n\nVerification: \(verification.displayName)."
        case .verified, .executorConfirmed:
            return trimmed
        }
    }
}

// MARK: - CLI providers

/// A tool the CLI provider ran in its own process — which DoraX's registry never sees, so
/// without this a sandbox-blocked `system_profiler` under Codex was simply absent.
nonisolated enum CLIActivityEvent: Equatable, Sendable {
    case started(id: String, kind: ActivityStep.Kind, title: String, detail: String)
    case finished(id: String, ok: Bool, output: String)

    /// Claude Code `stream-json` lines: the complete `assistant` message carries each
    /// tool_use with its input; the `user` message after it carries the tool_result.
    static func claudeCode(streamLine line: String) -> [CLIActivityEvent] {
        guard let object = jsonObject(line),
            let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return [] }
        switch object["type"] as? String {
        case "assistant":
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use",
                    let id = block["id"] as? String, let name = block["name"] as? String
                else { return nil }
                let input = block["input"] as? [String: Any] ?? [:]
                let described = describeClaudeCodeTool(name: name, input: input)
                return .started(
                    id: id, kind: described.kind, title: described.title,
                    detail: described.detail)
            }
        case "user":
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result",
                    let id = block["tool_use_id"] as? String
                else { return nil }
                return .finished(
                    id: id, ok: block["is_error"] as? Bool != true,
                    output: resultText(block["content"]))
            }
        default:
            return []
        }
    }

    /// Codex `--json` lines: `item.started` / `item.completed` for command_execution and
    /// mcp_tool_call items.
    static func codex(streamLine line: String) -> [CLIActivityEvent] {
        guard let object = jsonObject(line),
            let type = object["type"] as? String,
            type == "item.started" || type == "item.completed",
            let item = object["item"] as? [String: Any],
            let id = item["id"] as? String
        else { return [] }
        switch item["type"] as? String {
        case "command_execution":
            let command = unwrapShell(item["command"] as? String ?? "")
            if type == "item.started" {
                return [.started(
                    id: id, kind: .providerShell,
                    title: "Ran \(ActivityStepNaming.oneLine(command, limit: 60))",
                    detail: ActivityStepNaming.oneLine(command, limit: 400))]
            }
            let exit = (item["exit_code"] as? NSNumber)?.int32Value
            let status = item["status"] as? String ?? ""
            let ok = status != "failed" && status != "declined" && (exit ?? 0) == 0
            var output = item["aggregated_output"] as? String ?? ""
            if !ok, output.isEmpty { output = "Exited with status \(exit.map(String.init) ?? status)." }
            return [.finished(id: id, ok: ok, output: output)]
        case "mcp_tool_call":
            let server = item["server"] as? String ?? ""
            let tool = item["tool"] as? String ?? "tool"
            if type == "item.started" {
                let input = item["arguments"] as? [String: Any] ?? [:]
                return [.started(
                    id: id, kind: .mcp,
                    title: server.isEmpty ? "Ran \(tool)" : "Ran \(tool) via \(server)",
                    detail: ActivityStepNaming.inputLine(input))]
            }
            let failed = item["status"] as? String == "failed" || item["error"] != nil
            let error = (item["error"] as? [String: Any])?["message"] as? String
            return [.finished(
                id: id, ok: !failed,
                output: error ?? resultText((item["result"] as? [String: Any])?["content"]))]
        default:
            return []
        }
    }

    private static func describeClaudeCodeTool(
        name: String, input: [String: Any]
    ) -> (kind: ActivityStep.Kind, title: String, detail: String) {
        let text = { (key: String) in input[key] as? String ?? "" }
        switch name {
        case "Bash":
            let command = text("command")
            return (.providerShell, "Ran \(ActivityStepNaming.oneLine(command, limit: 60))",
                ActivityStepNaming.oneLine(command, limit: 400))
        case "Read":
            return (.read, "Read \((text("file_path") as NSString).lastPathComponent)",
                text("file_path"))
        case "Grep", "Glob":
            return (.read, "Searched \(ActivityStepNaming.oneLine(text("pattern"), limit: 60))",
                ActivityStepNaming.inputLine(input))
        case "WebFetch":
            return (.read, "Fetched \(text("url"))", text("url"))
        case "WebSearch":
            return (.read, "Searched the web", text("query"))
        default:
            // mcp__<server>__<tool>
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                let tool = parts.count > 1 ? parts.dropFirst().joined(separator: "__") : name
                let server = parts.count > 1 ? parts[0] : ""
                return (.mcp, server.isEmpty ? "Ran \(tool)" : "Ran \(tool) via \(server)",
                    ActivityStepNaming.inputLine(input))
            }
            return (.tool, "Ran \(name)", ActivityStepNaming.inputLine(input))
        }
    }

    /// A tool_result's content is a string or a list of text blocks.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// `/bin/zsh -lc 'ls -la'` is how the sandbox runs `ls -la`.
    static func unwrapShell(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -c ", "/bin/zsh -c ", "bash -lc "]
        where text.hasPrefix(shell) {
            text = String(text.dropFirst(shell.count))
            break
        }
        if text.count >= 2, text.first == "'", text.last == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
