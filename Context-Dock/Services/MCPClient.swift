// MCPClient.swift
// Minimal Model Context Protocol client over the stdio transport. Spawns the server process,
// performs the JSON-RPC 2.0 handshake (initialize → notifications/initialized), lists tools,
// and calls them. Newline-delimited JSON messages, matched to requests by id.

import Foundation

struct MCPTool: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let inputSchema: [String: Any]

    static func == (lhs: MCPTool, rhs: MCPTool) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

enum MCPClientError: Error, LocalizedError {
    case spawnFailed(String)
    case notConnected
    case timeout
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): return "Failed to start MCP server: \(m)"
        case .notConnected: return "MCP server not connected"
        case .timeout: return "MCP server timed out"
        case .rpcError(let m): return "MCP error: \(m)"
        }
    }
}

actor MCPClient {
    let config: MCPServerConfig

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private(set) var tools: [MCPTool] = []
    private var connected = false

    init(config: MCPServerConfig) { self.config = config }

    var isConnected: Bool { connected }

    // MARK: - Lifecycle

    func connect() async throws {
        guard !connected else { return }
        let proc = Process()
        // Resolve via login shell so PATH-based commands (npx, uvx, node) resolve.
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Single-quote any part containing spaces (e.g. "/Applications/Safari Technology
        // Preview.app/Contents/MacOS/safaridriver") so the login shell keeps it as one word.
        let argv = ([config.command] + config.args)
            .map { part in
                part.contains(" ") ? "'\(part.replacingOccurrences(of: "'", with: "'\\''"))'" : part
            }
            .joined(separator: " ")
        proc.arguments = ["-lc", argv]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()  // discard stderr noise

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }

        do {
            try proc.run()
        } catch {
            throw MCPClientError.spawnFailed(error.localizedDescription)
        }
        process = proc
        stdin = inPipe.fileHandleForWriting

        // initialize handshake
        let initResult = try await request(
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "Context-Dock", "version": "1.0"],
            ])
        _ = initResult
        notify(method: "notifications/initialized", params: [:])
        connected = true

        // list tools
        await refreshTools()
    }

    func refreshTools() async {
        guard let result = try? await request(method: "tools/list", params: [:]) as? [String: Any],
            let list = result["tools"] as? [[String: Any]]
        else { return }
        tools = list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return MCPTool(
                name: name,
                description: (entry["description"] as? String) ?? "",
                inputSchema: (entry["inputSchema"] as? [String: Any]) ?? [:])
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request(
            method: "tools/call",
            params: ["name": name, "arguments": arguments])
        // MCP returns { content: [ { type:"text", text:"..." }, ... ], isError? }
        guard let dict = result as? [String: Any],
            let content = dict["content"] as? [[String: Any]]
        else { return String(describing: result) }
        let text = content.compactMap { block -> String? in
            if let t = block["text"] as? String { return t }
            if let type = block["type"] as? String { return "[\(type) content]" }
            return nil
        }.joined(separator: "\n")
        return text.isEmpty ? "(no output)" : text
    }

    func shutdown() {
        process?.terminate()
        process = nil
        connected = false
        for (_, cont) in pending { cont.resume(throwing: MCPClientError.notConnected) }
        pending.removeAll()
    }

    // MARK: - JSON-RPC

    private func request(method: String, params: [String: Any]) async throws -> Any {
        guard let stdin else { throw MCPClientError.notConnected }
        nextID += 1
        let id = nextID
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { msg["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else {
            throw MCPClientError.rpcError("encode failed")
        }
        var line = data
        line.append(0x0A)  // newline-delimited
        stdin.write(line)

        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask { try await self.awaitResponse(id: id) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)  // 30s timeout
                throw MCPClientError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func awaitResponse(id: Int) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    private func notify(method: String, params: [String: Any]) {
        guard let stdin else { return }
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { msg["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var line = data
        line.append(0x0A)
        stdin.write(line)
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handleMessage(obj)
        }
    }

    private func handleMessage(_ obj: [String: Any]) {
        guard let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else {
            return  // notification or unmatched
        }
        if let error = obj["error"] as? [String: Any] {
            let m = (error["message"] as? String) ?? "unknown"
            cont.resume(throwing: MCPClientError.rpcError(m))
        } else {
            cont.resume(returning: obj["result"] ?? [:])
        }
    }
}
