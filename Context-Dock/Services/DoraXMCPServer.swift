// DoraXMCPServer.swift
// Context-Dock
//
// Lets any coding agent ask what is on the user's screen.
//
// Claude Code, Codex and Gemini live in a terminal. They can read a repository and run
// commands, and they cannot see the app the user is testing, the text they selected, or
// the page in front of them. When the answer is on screen, the user has to become the
// courier: notice it, capture it, describe it, paste it.
//
// The bridge in ClaudeCodeBridge solved that in one direction — this app pushes a
// question to Claude Code. This is the other direction, and it is the more useful one:
// the agent pulls, mid-task, as often as it needs, without the user doing anything. And
// because MCP is a standard rather than a vendor's API, the same server answers Codex and
// Gemini too.
//
// Streamable HTTP on the loopback interface, rather than a stdio server: a stdio server
// would have to be a second process the agent spawns, and this app must already be
// running to see anything. It is the running app that has the accessibility permission
// and the window state, so it is the running app that should answer.
//
// Two things are deliberate:
//
// - **Off until switched on.** A server that starts itself and listens for requests about
//   the user's screen, without being asked, is not something to default to.
// - **A bearer token, checked on every request.** Loopback is not a permission boundary —
//   every process on the Mac can reach 127.0.0.1. Without a token, any of them could take
//   a screenshot through this.

import AppKit
import Combine
import Foundation
import Network
import OSLog

/// Somewhere for a turn's live steps to land while it runs.
///
/// `onStatus` is called from whichever stage is speaking, on whichever actor it happens to be
/// on, so the collector locks rather than assuming the main one.
final class StepCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func append(_ step: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !collected.contains(step) else { return }
        collected.append(step)
    }

    var steps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

@MainActor
final class DoraXMCPServer: ObservableObject {
    static let shared = DoraXMCPServer()

    private init() {}

    private let log = Logger(subsystem: "com.krishgokul.ContextDock", category: "MCP")

    static let enabledKey = "doraxMCPServerEnabled"
    private static let tokenKey = "doraxMCPServerToken"

    /// Fixed so the command a user copies once keeps working across restarts.
    static let port: UInt16 = 8213

    @Published private(set) var isRunning = false
    @Published private(set) var lastRequest: String?

    private var listener: NWListener?

    /// Minted once and kept. Regenerating per launch would invalidate the command the user
    /// already registered with their agent.
    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: tokenKey)
        return fresh
    }

    /// What the user pastes into their agent to connect it.
    static var registrationCommand: String {
        "claude mcp add --transport http dorax http://127.0.0.1:\(port)/mcp "
            + "--header \"Authorization: Bearer \(token)\""
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        start()
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Loopback only. This answers questions about the user's screen; it has no
            // business being reachable from the network.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in self?.receive(on: connection, buffer: Data()) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.log.notice("listening on 127.0.0.1:\(Self.port, privacy: .public)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.log.notice("failed: \(error.localizedDescription, privacy: .public)")
                        self?.stop()
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.notice("could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            Task { @MainActor in
                guard error == nil else { connection.cancel(); return }

                // Keep reading until the whole body named by Content-Length has arrived —
                // a JSON-RPC request larger than one TCP segment is otherwise parsed as
                // truncated JSON and rejected.
                guard let request = Self.parseRequest(buffer) else {
                    if isComplete { connection.cancel() } else {
                        self.receive(on: connection, buffer: buffer)
                    }
                    return
                }
                let response = await self.handle(request)
                connection.send(
                    content: response,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private struct Request {
        let authorization: String?
        /// `X-DoraX-Turn`: present only on requests from a CLI turn DoraX itself launched.
        var turnKey: String? = nil
        /// `X-DoraX-Turn-Id`: which live turn of DoraX's own CLI this call belongs to.
        var turnID: String? = nil
        let body: Data
    }

    private static func parseRequest(_ buffer: Data) -> Request? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        let body = buffer[separator.upperBound...]

        var contentLength = 0
        var authorization: String?
        var turnKey: String?
        var turnID: String?
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": contentLength = Int(parts[1]) ?? 0
            case "authorization": authorization = parts[1]
            case attendedHeader.lowercased(): turnKey = parts[1]
            case turnIDHeader.lowercased(): turnID = parts[1]
            default: break
            }
        }
        guard body.count >= contentLength else { return nil }
        return Request(
            authorization: authorization, turnKey: turnKey, turnID: turnID,
            body: Data(body.prefix(contentLength)))
    }

    private static func httpResponse(status: String, json: Any?) -> Data {
        var body = Data()
        if let json {
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
        let head = """
            HTTP/1.1 \(status)\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r\n
            """
        return Data(head.utf8) + body
    }

    // MARK: - JSON-RPC

    private func handle(_ request: Request) async -> Data {
        guard request.authorization == "Bearer \(Self.token)" else {
            log.notice("rejected: bad token")
            return Self.httpResponse(status: "401 Unauthorized", json: nil)
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body)
            as? [String: Any],
            let method = message["method"] as? String
        else {
            return Self.httpResponse(status: "400 Bad Request", json: nil)
        }

        // A notification carries no id and expects no result — answering one with a
        // JSON-RPC response is a protocol error, not just noise.
        guard let id = message["id"] else {
            return Self.httpResponse(status: "202 Accepted", json: nil)
        }

        let attended = Self.isAttendedCaller(turnKey: request.turnKey)
        // Which turn this call belongs to, for the outbound gate: only a request carrying the
        // attended key AND the id of a turn that is still live has one. Everyone else has none,
        // and the gate treats a call with no turn as having touched everything.
        let turn = attended ? AgentToolRegistry.shared.liveTurn(id: request.turnID) : nil
        log.notice("\(method, privacy: .public) attended=\(attended, privacy: .public)")
        lastRequest = method

        let result: Any
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "dorax", "version": "1.0.0"],
            ]

        case "tools/list":
            result = [
                "tools": Self.toolDefinitions(
                    attended: attended, liveTurn: turn != nil,
                    mayRunCommands: ClaudeCodeCLIService.mayRunCommands(turnID: turn?.id))
            ]

        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            lastRequest = name
            let text = await callTool(
                named: name, arguments: arguments, attended: attended, turn: turn)
            result = ["content": [["type": "text", "text": text]]]

        default:
            return Self.httpResponse(
                status: "200 OK",
                json: [
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Unknown method \(method)"],
                ])
        }

        return Self.httpResponse(
            status: "200 OK", json: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: - Handing this server to a CLI

    /// The header that marks a request as coming from a CLI turn DoraX launched itself.
    static let attendedHeader = "X-DoraX-Turn"

    /// The header that says which live turn of DoraX's own CLI a call belongs to. Minted per
    /// CLI turn (`AgentToolRegistry.beginTurn`) and written into that turn's own MCP config, so
    /// two CLI turns at once never share what they have read.
    static let turnIDHeader = "X-DoraX-Turn-Id"

    /// Minted per app launch and only ever written into the config DoraX hands its own CLI.
    /// The bearer token says a caller may talk to this server; this says the user is at the
    /// keyboard in the chat that started the turn, so its approvals are shown, not refused.
    /// An agent registered with `claude mcp add` never has it and stays unattended.
    static let attendedTurnKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        .lowercased()

    /// True only for DoraX's own CLI turns. Anything else — no header, a stale key from an
    /// earlier launch — is an unknown caller and runs unattended.
    static func isAttendedCaller(turnKey: String?) -> Bool {
        turnKey == attendedTurnKey
    }

    /// Writes the MCP config the Claude Code CLI is launched with, and returns its path.
    ///
    /// A file rather than an inline `--mcp-config` string, because the token is a bearer
    /// credential for everything this server exposes and argv is world-readable: passed on the
    /// command line it would sit in every `ps` listing on the Mac. The file is owner-only.
    ///
    /// Rewritten on every launch rather than cached, so rotating the token cannot leave a
    /// stale file authorising nothing while the CLI reports a connection failure the user
    /// cannot explain.
    ///
    /// `turn` names the live turn this config belongs to. It gets its own file (so two CLI turns
    /// at once do not overwrite each other's) and a header carrying the turn's id; the caller
    /// deletes it when the turn ends.
    static func writeCLIConfig(turn: AgentTurnToken? = nil) -> URL? {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock")
        else { return nil }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(
            turn.map { "claude-mcp-config-\($0.id.uuidString).json" } ?? "claude-mcp-config.json")
        var headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            attendedHeader: attendedTurnKey,
        ]
        if let turn { headers[turnIDHeader] = turn.id.uuidString }
        let config: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)/mcp",
                    "headers": headers,
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted])
        else { return nil }

        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        return url
    }

    /// The name the CLI knows this server by, and therefore the prefix its tools carry:
    /// `mcp__dorax__dorax_selection`.
    static let serverName = "dorax"

    // MARK: - Tools

    /// A turn DoraX launched is told its approvals reach the user; an outside agent is told
    /// they are refused. Each description has to match what the call will actually do.
    ///
    /// `liveTurn`: the call belongs to a CLI turn DoraX is running now, so the outbound gate has
    /// its taint and can ask in its chat. Only those get the network (`dorax_read_url`), and
    /// the shell (`dorax_run_command`) only where `mayRunCommands` — the CLI's own were taken
    /// away in a private chat (E1c) and the user's access level grants one.
    static func toolDefinitions(
        attended: Bool, liveTurn: Bool = false, mayRunCommands: Bool = false
    ) -> [[String: Any]] {
        guard attended else { return baseToolDefinitions }
        var extra: [[String: Any]] = []
        if liveTurn { extra.append(readURLDefinition) }
        if liveTurn, mayRunCommands { extra.append(runCommandDefinition) }
        return (baseToolDefinitions + extra).map { tool in
            guard tool["name"] as? String == "dorax_ask" else { return tool }
            var tool = tool
            tool["description"] =
                "Ask DoraX's own assistant to answer or do something on the user's Mac — a "
                + "setting's state, the volume, an app action — and get back its answer, the "
                + "steps it took and the receipts of what it ran. Anything that changes "
                + "something shows the user DoraX's approval sheet and runs only if they "
                + "approve; a denial comes back in the answer."
            return tool
        }
    }

    private static let readURLDefinition: [String: Any] = [
        "name": "dorax_read_url",
        "description":
            "Fetch a web page by URL and read it as Markdown, through DoraX. Use this for every "
            + "web address in this chat — you have no fetch tool of your own here. When this "
            + "chat holds the user's private data and text they did not write, DoraX asks them "
            + "before contacting the host; a refusal comes back as the result. Read-only.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "The full URL, including https://."],
                "focus": [
                    "type": "string",
                    "description": "Optional: what you are looking for on that page.",
                ],
            ] as [String: Any],
            "required": ["url"],
        ],
    ]

    private static let runCommandDefinition: [String: Any] = [
        "name": "dorax_run_command",
        "description":
            "Run a shell command on the user's Mac through DoraX and get its output. Use this "
            + "instead of a shell of your own — you have none in this chat. DoraX's approval "
            + "applies: a command that changes something, or that could reach the network once "
            + "this chat holds private data, is shown to the user first.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "The exact shell command."],
                "purpose": ["type": "string", "description": "One line: what it does."],
                "requires_approval": [
                    "type": "boolean",
                    "description": "True when it modifies files, installs software, or "
                        + "cannot be undone.",
                ],
            ] as [String: Any],
            "required": ["command", "purpose"],
        ],
    ]

    private static let baseToolDefinitions: [[String: Any]] = [
        [
            "name": "dorax_frontmost_app",
            "description":
                "What the user is looking at right now on their Mac: the frontmost app, its "
                + "window title, and the document or URL it has open. Call this when a question "
                + "depends on what is on screen rather than what is in the repository.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "dorax_selection",
            "description":
                "The text the user currently has selected, in any app, plus any files selected "
                + "in Finder. Call this when the user refers to \"this\" — this error, this "
                + "function, these files — without pasting it.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "dorax_screenshot",
            "description":
                "Takes a screenshot of the user's screen and returns the file path. Read the "
                + "returned path to see it. Call this to check what an app is actually "
                + "displaying — a rendering bug, a crash dialog, whether a fix worked.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "dorax_run_menu_command",
            "description":
                "Click a menu command in a Mac app on the user's behalf — app: \"Claude\", "
                + "path: \"Claude > Check for Updates…\". The user is shown the exact app and "
                + "menu path and must approve it before anything is clicked; a path that does "
                + "not exist in the app's menus is refused. Call this when the user has asked "
                + "for something the app itself does through its menus and no repository or "
                + "shell route can do it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "The app's name."],
                    "path": [
                        "type": "string",
                        "description": "Menu path, e.g. \"Claude > Check for Updates…\".",
                    ],
                ] as [String: Any],
                "required": ["app", "path"],
            ],
        ],
        [
            "name": "dorax_ask",
            "description":
                "Ask DoraX's own assistant a question, exactly as the user would in an app "
                + "chat, and get back its answer along with the steps it took and the "
                + "receipts of what it actually ran. Call this to TEST DoraX itself — to "
                + "check that a question reaches a real reader, that the right capability is "
                + "chosen, or that a change fixed what it was meant to fix.\n\n"
                + "Runs unattended: every approval is refused without being shown, and the "
                + "capability ids that asked are returned in approvalsRequested. So nothing "
                + "is sent, deleted or written, and the thing worth asserting is which "
                + "approval was requested rather than whether the side effect happened.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The question, worded as the user would type it.",
                    ],
                    "app": [
                        "type": "string",
                        "description":
                            "Optional app name or bundle id to scope the question to, e.g. "
                            + "\"Notes\" or \"com.apple.Notes\". Omit for General Chat.",
                    ],
                ] as [String: Any],
                "required": ["query"],
            ],
        ],
        [
            "name": "dorax_find_files",
            "description":
                "Find files on the user's Mac by name — Spotlight first, then a bounded scan of "
                + "Desktop, Documents, Downloads and iCloud Drive, so it works when Spotlight is "
                + "off. Returns full absolute paths, newest first. Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Words the file name contains, e.g. \"passport pdf\".",
                    ]
                ] as [String: Any],
                "required": ["query"],
            ],
        ],
        [
            "name": "dorax_list_shortcuts",
            "description":
                "List the names of the user's shortcuts in the Shortcuts app. Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "dorax_run_shortcut",
            "description":
                "Run one of the user's shortcuts by its exact name (from dorax_list_shortcuts), "
                + "with optional short text input. The user must approve each run in DoraX; when "
                + "DoraX is not showing them the approval (an unattended agent), the call is "
                + "refused and nothing runs. Returns the shortcut's output and exit status.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Exact shortcut name."],
                    "input": ["type": "string", "description": "Optional short text input."],
                ] as [String: Any],
                "required": ["name"],
            ],
        ],
        [
            "name": "dorax_write_output_file",
            "description":
                "Write a new .md, .txt, .csv or .docx file into the user's DoraX Outputs folder "
                + "(~/Documents/DoraX Outputs) and return its full path. Never overwrites. The "
                + "user must approve each file in DoraX; when DoraX is not showing them the "
                + "approval (an unattended agent), the call is refused and nothing is written.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Plain file name, no folders.",
                    ],
                    "format": [
                        "type": "string",
                        "description": "One of: md, txt, csv, docx.",
                    ],
                    "content": ["type": "string", "description": "The whole file content."],
                ] as [String: Any],
                "required": ["name", "format", "content"],
            ],
        ],
        [
            "name": "dorax_browser_tabs",
            "description":
                "The pages the user has open in Safari, with titles and URLs. Call this when "
                + "the user refers to documentation, an issue, or a page they are reading.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
    ]

    /// Run one DoraX turn and report what it decided.
    ///
    /// Unattended (an outside agent): the point is testing the *decision* — which reader ran,
    /// which capability was chosen, which approval was asked for. Approvals are refused
    /// throughout — an agent looping over an eval set must not be able to send mail because a
    /// sheet resolved on its own, and there is no one there to refuse it.
    ///
    /// Attended (a CLI turn DoraX launched from a chat): the user is right there, so approvals
    /// go to the same sheet an in-app capability uses, and the capability runs if approved.
    private func runTurn(query: String, app: String?, attended: Bool) async -> String {
        let resolved = await MainActor.run { () -> (scope: GeneralChatScope, name: String) in
            guard let app, !app.isEmpty else {
                return (.thread(id: attended ? "dorax-cli-turn" : "dorax-mcp-eval"), "General Chat")
            }
            // Accept either a bundle id or the name a person would type.
            //
            // Discovery rather than the cache: a cold cache answered "nothing is installed",
            // the name fell through to the branch below, and the turn ran with
            // `.app(bundleId: "Safari")` — a display name where every other layer expects an
            // id. The Safari chat then asked the user to enable Safari.
            let installed = InstalledApplicationsCatalog.discoverInstalledApps()
            if let match = installed.first(where: {
                $0.bundleId.caseInsensitiveCompare(app) == .orderedSame
                    || $0.name.caseInsensitiveCompare(app) == .orderedSame
            }) {
                return (.app(bundleId: match.bundleId), match.name)
            }
            // An unrecognised name is used as-is rather than silently becoming General Chat:
            // a test that asked about Notes and was quietly answered unscoped would pass or
            // fail for the wrong reason.
            return (.app(bundleId: app), app)
        }

        var liveSteps: [String] = []
        let answer: AppScopedChatService.Answer
        var approvals: [String] = []
        do {
            // The steps the harness narrates as it works. Without this the tool whose whole
            // purpose is "check what DoraX did" returned an empty `steps` for a turn that had
            // read a page, listed fifteen tabs and chosen a route.
            let collected = StepCollector()
            let send = {
                try await AppScopedChatService.send(
                    scope: resolved.scope, appName: resolved.name, query: query, history: [],
                    onStatus: { step in collected.append(step) })
            }
            if attended {
                answer = try await send()
            } else {
                let run = try await AICapabilityApprovalCenter.withUnattendedRun(send)
                answer = run.result
                approvals = run.approvalsRequested
            }
            liveSteps = collected.steps
        } catch {
            // A turn that threw is a result an eval needs to see, reported in the same shape
            // as any other — not an exception the caller has to guess the meaning of.
            let failure: [String: Any] = [
                "scope": resolved.name,
                "failed": true,
                "error": error.localizedDescription,
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]),
                let text = String(data: data, encoding: .utf8)
            else { return "The turn failed: \(error.localizedDescription)" }
            return text
        }

        var payload: [String: Any] = [
            "answer": answer.text,
            "scope": resolved.name,
            "steps": liveSteps.isEmpty ? answer.trace : liveSteps + answer.trace,
            "toolChips": answer.toolChips,
            "receipts": answer.evidenceReceipts.map { receipt in
                [
                    "command": receipt.command,
                    "output": String(receipt.output.prefix(400)),
                    "success": receipt.success,
                    "isVerification": receipt.isVerification,
                ] as [String: Any]
            },
        ]
        if !answer.routeChoices.isEmpty {
            payload["askedToChooseBetween"] = answer.routeChoices.map(\.title)
        }
        if let enable = answer.enableApp {
            payload["blockedNeedingAccessTo"] = enable.name
        }
        if !attended {
            payload["approvalsRequested"] = approvals
            payload["note"] =
                "Approvals were refused unattended. approvalsRequested is what DoraX decided to "
                + "ask for; nothing was executed behind them."
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return answer.text
        }
        return text
    }

    private func callTool(
        named name: String, arguments: [String: Any], attended: Bool, turn: AgentTurnToken? = nil
    ) async -> String {
        let registry = AgentToolRegistry.shared
        // What the CLI turn has now read, for the outbound gate. These tools hand over the
        // user's screen, selection, tabs and file names (private) from apps whose text the
        // user did not write (untrusted).
        switch name {
        case "dorax_frontmost_app", "dorax_selection", "dorax_screenshot", "dorax_browser_tabs",
            "dorax_find_files":
            // E1c: a CLI turn still holding its own fetch or shell does not get the user's data;
            // it is stopped and run again without them, and then this read goes ahead.
            if let turn, ClaudeCodeCLIService.stopBeforePrivateRead(turnID: turn.id) {
                return "Not read: DoraX is restarting this turn without web and shell tools "
                    + "before it hands over the user's data. Stop here."
            }
            registry.taint.notePrivateRead(turn)
            registry.taint.noteUntrusted(turn)
        default: break
        }
        switch name {
        case "dorax_frontmost_app":
            // Read live rather than trusting the shared snapshot. That snapshot updates on
            // app-activation events, so an agent asking a second after the user switched
            // windows — or at any point before the first event of a session — would be told
            // "nothing is in front" while the user stares at their editor.
            let context = Self.liveFrontmostContext()
            guard !context.isEmpty else { return "Nothing readable in front right now." }
            var lines = ["App: \(context.appName) (\(context.bundleId))"]
            if let title = context.windowTitle, !title.isEmpty { lines.append("Window: \(title)") }
            if let url = context.currentURL, !url.isEmpty { lines.append("Document/URL: \(url)") }
            if let role = context.focusedElementRole, !role.isEmpty {
                lines.append("Focused element: \(role)")
            }
            return lines.joined(separator: "\n")

        case "dorax_selection":
            let context = Self.liveFrontmostContext()
            var lines: [String] = []
            if let selected = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !selected.isEmpty
            {
                lines.append("Selected text in \(context.appName):\n\(selected.prefix(4000))")
            }
            if !context.selectedFilePaths.isEmpty {
                lines.append(
                    "Selected files:\n"
                        + context.selectedFilePaths.prefix(50).joined(separator: "\n"))
            }
            return lines.isEmpty
                ? "Nothing is selected right now." : lines.joined(separator: "\n\n")

        case "dorax_screenshot":
            return Self.captureScreen()

        case "dorax_ask":
            let query = (arguments["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "dorax_ask needs a query." }
            return await runTurn(
                query: query,
                app: (arguments["app"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                attended: attended)

        case "dorax_find_files":
            let query = (arguments["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "dorax_find_files needs a query." }
            return await AgentToolRegistry.runFileSearch(query: query).1

        case "dorax_list_shortcuts":
            return await AgentToolRegistry.runListShortcuts().1

        case "dorax_run_shortcut":
            if let target = OutboundGate.target(toolName: "run_shortcut", arguments: arguments),
                let stopped = await registry.gateOutbound(
                    target: target,
                    what: AgentToolRegistry.outboundDescription(
                        name: "run_shortcut", arguments: arguments),
                    turn: turn, chatScope: nil, attended: attended)
            {
                return stopped.output
            }
            let result = await AgentToolRegistry.runRunShortcut(
                name: arguments["name"] as? String ?? "",
                input: arguments["input"] as? String,
                scope: nil, attended: attended)
            return result.output

        case "dorax_write_output_file":
            let result = await AgentToolRegistry.runWriteOutputFile(
                name: arguments["name"] as? String ?? "",
                format: arguments["format"] as? String ?? "",
                content: arguments["content"] as? String ?? "",
                scope: nil, attended: attended)
            return result.output

        case "dorax_browser_tabs":
            let tabs = SafariTabManager.shared.cachedTabs(maxAge: 30)
            guard !tabs.isEmpty else {
                return "No Safari tabs cached. Safari may not be running."
            }
            return tabs.prefix(40)
                .map { tab in
                    // A bank or sign-in tab is listed by origin only: no title, path or query.
                    ScopedGroundingBlocks.withheldTabRow(url: tab.url)
                        ?? "- \(tab.title)\n  \(tab.url)"
                }
                .joined(separator: "\n")

        case "dorax_read_url":
            return await Self.readURL(arguments: arguments, turn: turn, registry: registry)

        case "dorax_run_command":
            guard ClaudeCodeCLIService.mayRunCommands(turnID: turn?.id) else {
                return "Running commands is not available to this chat."
            }
            return await Self.runCommand(
                arguments: arguments, turn: turn, registry: registry,
                executor: { command, purpose, approval in
                    await TerminalCommandExecutor.shared.run(
                        command, purpose: purpose, modelRequiresApproval: approval)
                })

        case "dorax_run_menu_command":
            // Deliberately the same tool the app's own chat uses, dispatched through the same
            // registry: the approval card, the cached-path check, the live verification and
            // the receipt all come with it. A second implementation here would be a second
            // authority boundary, and the weaker one would be the one an outside agent holds.
            let app = (arguments["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let path = (arguments["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty, !path.isEmpty else {
                return "Both app and path are required, e.g. app: \"Claude\", path: \"Claude > Check for Updates…\"."
            }
            var grantedApps: [String: String] = [:]
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
            }), let bundleId = running.bundleIdentifier {
                grantedApps[app.lowercased()] = bundleId
                grantedApps[bundleId.lowercased()] = bundleId
            }
            // An outside agent (unattended) cannot answer the gate's card, so it is held back
            // here; a CLI turn DoraX launched is asked inside `dispatch` below.
            if !attended,
                let target = OutboundGate.target(
                    toolName: "run_menu_command", arguments: ["app": app, "path": path]),
                let stopped = await registry.gateOutbound(
                    target: target, what: "run_menu_command: \(path)", turn: turn,
                    chatScope: nil, attended: false)
            {
                return "Did not run — \(stopped.output)"
            }
            let context = AgentToolContext(
                // An outside agent gets no shell through this door. It asked for a menu
                // command; the menu command is what it may have.
                commandExecutor: { _, _, _ in
                    (false, "Running shell commands is not available through the DoraX MCP server.", 1)
                },
                userRequest: "Menu command requested by a connected coding agent: \(app) ▸ \(path)",
                grantedApps: grantedApps, turn: turn)
            let result = await AgentToolRegistry.shared.dispatch(
                name: "run_menu_command",
                arguments: ["app": app, "path": path],
                context: context)
            guard let result else { return "Menu commands are unavailable in this build." }
            return result.success
                ? (result.output.isEmpty ? "Done — \(app) ▸ \(path)." : result.output)
                : "Did not run — \(result.output)"

        default:
            return "Unknown tool \(name)."
        }
    }

    // MARK: - Network and shell for a private CLI chat (E1c)

    /// `dorax_read_url`: DoraX's own `read_url`, dispatched through the registry with the CLI
    /// turn, so the outbound gate decides with what that turn has read and asks in its chat.
    /// Only a live DoraX CLI turn has one; anyone else is refused before the gate is reached.
    static func readURL(
        arguments: [String: Any], turn: AgentTurnToken?, registry: AgentToolRegistry
    ) async -> String {
        guard let turn else {
            return "dorax_read_url is only available to a chat DoraX is running."
        }
        let url = (arguments["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var forwarded: [String: Any] = ["url": url]
        if let focus = arguments["focus"] as? String { forwarded["focus"] = focus }
        let result = await registry.dispatch(
            name: "read_url", arguments: forwarded,
            context: AgentToolContext(
                commandExecutor: { _, _, _ in
                    (false, "Running shell commands is not part of reading a page.", 1)
                },
                userRequest: "Page requested by DoraX's Claude Code turn: \(url)",
                chatScope: ClaudeCodeCLIService.chatScope(turnID: turn.id), turn: turn))
        guard let result else { return "Reading web pages is unavailable in this build." }
        return result.success ? result.output : "Not fetched — \(result.output)"
    }

    /// `dorax_run_command`: DoraX's own `run_command` — the outbound gate (E1b's allow-list
    /// decides what reaches the network), then the executor's approval for anything risky.
    static func runCommand(
        arguments: [String: Any], turn: AgentTurnToken?, registry: AgentToolRegistry,
        executor: @escaping (String, String, Bool) async -> (Bool, String, Int32)
    ) async -> String {
        guard let turn else {
            return "dorax_run_command is only available to a chat DoraX is running."
        }
        let result = await registry.dispatch(
            name: "run_command", arguments: arguments,
            context: AgentToolContext(
                commandExecutor: executor,
                userRequest: "Command requested by DoraX's Claude Code turn",
                chatScope: ClaudeCodeCLIService.chatScope(turnID: turn.id), turn: turn))
        guard let result else { return "Running commands is unavailable in this build." }
        return result.success ? result.output : "Did not run — \(result.output)"
    }

    /// The frontmost app's own accessibility state, read at the moment of the call.
    ///
    /// `NSWorkspace.shared.frontmostApplication` reports Context-Dock itself the instant
    /// any of our own panels (the corner included) has taken key focus — the same trap
    /// fixed everywhere else this app reads "what's frontmost" — so a tool call made right
    /// after opening the corner asked this app about its own empty UI instead of whatever
    /// the user was actually looking at a moment before.
    private static func liveFrontmostContext() -> AXContext {
        guard
            let frontmost = AppDelegate.shared?.menuBarOwningUserFacingApplication()
                ?? NSWorkspace.shared.frontmostApplication,
            let bundleId = frontmost.bundleIdentifier
        else { return AXContextReader.shared.current }

        var context = ContextResolver.axContext(
            for: bundleId, appName: frontmost.localizedName ?? bundleId)
        // Selection and Finder paths are not part of the window-level read, and they are
        // the whole point of the selection tool.
        let shared = AXContextReader.shared.current
        if context.selectedText?.isEmpty != false {
            context.selectedText = ContextDetector.shared.getSelectedText(from: frontmost)
                ?? (shared.bundleId == bundleId ? shared.selectedText : nil)
        }
        if context.selectedFilePaths.isEmpty, shared.bundleId == bundleId {
            context.selectedFilePaths = shared.selectedFilePaths
        }
        return context
    }

    /// Whole screen, no shutter sound, no interaction. An agent calling this is mid-task
    /// and cannot answer a region-selection prompt.
    private static func captureScreen() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-mcp-\(Int(Date().timeIntervalSince1970)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", path.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Couldn't take a screenshot: \(error.localizedDescription)"
        }
        guard FileManager.default.fileExists(atPath: path.path),
            (try? Data(contentsOf: path))?.isEmpty == false
        else {
            // screencapture writes nothing at all when the permission is missing, which
            // otherwise reads to the agent as an empty screen rather than a blocked one.
            return "Screenshot failed — Context Dock needs Screen Recording permission "
                + "in System Settings › Privacy & Security."
        }
        return "Screenshot saved to \(path.path) — read that path to see it."
    }
}
