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
        let body: Data
    }

    private static func parseRequest(_ buffer: Data) -> Request? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        let body = buffer[separator.upperBound...]

        var contentLength = 0
        var authorization: String?
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": contentLength = Int(parts[1]) ?? 0
            case "authorization": authorization = parts[1]
            default: break
            }
        }
        guard body.count >= contentLength else { return nil }
        return Request(authorization: authorization, body: Data(body.prefix(contentLength)))
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

        log.notice("\(method, privacy: .public)")
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
            result = ["tools": Self.toolDefinitions]

        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            lastRequest = name
            let text = await callTool(named: name, arguments: arguments)
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

    /// Writes the MCP config the Claude Code CLI is launched with, and returns its path.
    ///
    /// A file rather than an inline `--mcp-config` string, because the token is a bearer
    /// credential for everything this server exposes and argv is world-readable: passed on the
    /// command line it would sit in every `ps` listing on the Mac. The file is owner-only.
    ///
    /// Rewritten on every launch rather than cached, so rotating the token cannot leave a
    /// stale file authorising nothing while the CLI reports a connection failure the user
    /// cannot explain.
    static func writeCLIConfig() -> URL? {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock")
        else { return nil }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("claude-mcp-config.json")
        let config: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)/mcp",
                    "headers": ["Authorization": "Bearer \(token)"],
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

    private static let toolDefinitions: [[String: Any]] = [
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
            "name": "dorax_browser_tabs",
            "description":
                "The pages the user has open in Safari, with titles and URLs. Call this when "
                + "the user refers to documentation, an issue, or a page they are reading.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
    ]

    private func callTool(named name: String, arguments: [String: Any]) async -> String {
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

        case "dorax_browser_tabs":
            let tabs = SafariTabManager.shared.cachedTabs(maxAge: 30)
            guard !tabs.isEmpty else {
                return "No Safari tabs cached. Safari may not be running."
            }
            return tabs.prefix(40)
                .map { "- \($0.title)\n  \($0.url)" }
                .joined(separator: "\n")

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
            let context = AgentToolContext(
                // An outside agent gets no shell through this door. It asked for a menu
                // command; the menu command is what it may have.
                commandExecutor: { _, _, _ in
                    (false, "Running shell commands is not available through the DoraX MCP server.", 1)
                },
                userRequest: "Menu command requested by a connected coding agent: \(app) ▸ \(path)",
                grantedApps: grantedApps)
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

    /// The frontmost app's own accessibility state, read at the moment of the call.
    private static func liveFrontmostContext() -> AXContext {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
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
