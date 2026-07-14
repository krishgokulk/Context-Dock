// MCPRuntime.swift
// Owns the live MCPClient connections and exposes the linked servers' tools to scoped dock
// chat. Builds a tool-description block for the AI prompt and dispatches tool calls the AI
// requests back to the right server.

import Foundation

actor MCPRuntime {
    static let shared = MCPRuntime()

    private var clients: [UUID: MCPClient] = [:]  // keyed by MCPServerConfig.id

    private init() {}

    /// Connect (lazily) to every MCP server linked to `bundleId` and return the aggregate
    /// tool list as (serverName, serverId, tool). Failures are skipped silently.
    func tools(forBundleId bundleId: String) async
        -> [(server: String, serverId: UUID, tool: MCPTool)]
    {
        let configs = await MainActor.run { MCPServerManager.shared.servers(forBundleId: bundleId) }
        var out: [(String, UUID, MCPTool)] = []
        for config in configs {
            let client = await connectedClient(for: config)
            guard let client else { continue }
            let toolList = await client.tools
            for t in toolList { out.append((config.name, config.id, t)) }
        }
        return out.map { (server: $0.0, serverId: $0.1, tool: $0.2) }
    }

    /// Tools from ALREADY-CONNECTED servers only — never opens a new connection. Safe to
    /// call on the hot resolve path (no network/latency): returns empty until a server has
    /// been warmed (e.g. by scoped chat), so the deterministic resolver stays fast.
    func cachedTools(forBundleId bundleId: String) async
        -> [(server: String, serverId: UUID, tool: MCPTool)]
    {
        let configs = await MainActor.run { MCPServerManager.shared.servers(forBundleId: bundleId) }
        var out: [(String, UUID, MCPTool)] = []
        for config in configs {
            guard let client = clients[config.id], await client.isConnected else { continue }
            for t in await client.tools { out.append((config.name, config.id, t)) }
        }
        return out.map { (server: $0.0, serverId: $0.1, tool: $0.2) }
    }

    /// AI-prompt block describing available MCP tools and how to call one. Empty when none.
    func toolPromptBlock(forBundleId bundleId: String) async -> String {
        let all = await tools(forBundleId: bundleId)
        guard !all.isEmpty else { return "" }
        var lines: [String] = [
            "## MCP Tools (live, for this app)",
            "You can call these Model Context Protocol tools. To call one, reply with ONLY a",
            "single line of JSON and nothing else:",
            "{\"mcp_call\": {\"server\": \"<server>\", \"tool\": \"<tool>\", \"arguments\": { … }}}",
            "After the tool result is returned, answer the user in plain language.",
            "",
            "Available tools:",
        ]
        for entry in all {
            let desc = entry.tool.description.isEmpty ? "" : " — \(entry.tool.description)"
            lines.append("- server \"\(entry.server)\", tool \"\(entry.tool.name)\"\(desc)")
        }
        return lines.joined(separator: "\n")
    }

    /// Execute a tool call requested by the AI. `server` matches MCPServerConfig.name.
    func callTool(
        bundleId: String, server: String, tool: String, arguments: [String: Any]
    ) async throws -> String {
        let configs = await MainActor.run { MCPServerManager.shared.servers(forBundleId: bundleId) }
        guard let config = configs.first(where: { $0.name == server }) ?? configs.first
        else { throw MCPClientError.notConnected }
        guard let client = await connectedClient(for: config) else {
            throw MCPClientError.notConnected
        }
        return try await client.callTool(name: tool, arguments: arguments)
    }

    private func connectedClient(for config: MCPServerConfig) async -> MCPClient? {
        if let existing = clients[config.id], await existing.isConnected {
            return existing
        }
        let client = MCPClient(config: config)
        do {
            try await client.connect()
            clients[config.id] = client
            return client
        } catch {
            return nil
        }
    }

    // MARK: - Global (all-apps) access — used by the general AI chat

    /// Aggregate tools from every configured server across all app adapters.
    func allTools() async -> [(server: String, serverId: UUID, tool: MCPTool)] {
        let configs = await MainActor.run { MCPServerManager.shared.servers }
        var out: [(String, UUID, MCPTool)] = []
        for config in configs {
            let client = await connectedClient(for: config)
            guard let client else { continue }
            let toolList = await client.tools
            for t in toolList { out.append((config.name, config.id, t)) }
        }
        return out.map { (server: $0.0, serverId: $0.1, tool: $0.2) }
    }

    /// Tool-description block for ALL linked servers — injected into the general chat system prompt.
    func toolPromptBlockForAll() async -> String {
        let all = await allTools()
        guard !all.isEmpty else { return "" }
        var lines: [String] = [
            "## MCP Tools (from your linked app adapters)",
            "You can call any of these tools. To call one, reply with ONLY a single line of JSON:",
            "{\"mcp_call\": {\"server\": \"<server>\", \"tool\": \"<tool>\", \"arguments\": { … }}}",
            "After the tool result arrives, answer the user in plain language.",
            "",
            "Available tools:",
        ]
        for entry in all {
            let desc = entry.tool.description.isEmpty ? "" : " — \(entry.tool.description)"
            lines.append("- server \"\(entry.server)\", tool \"\(entry.tool.name)\"\(desc)")
        }
        return lines.joined(separator: "\n")
    }

    /// Dispatch a tool call to any configured server by name — no bundleId scope.
    func callToolGlobally(server: String, tool: String, arguments: [String: Any]) async throws -> String {
        let configs = await MainActor.run { MCPServerManager.shared.servers }
        guard let config = configs.first(where: { $0.name == server }) ?? configs.first
        else { throw MCPClientError.notConnected }
        guard let client = await connectedClient(for: config) else {
            throw MCPClientError.notConnected
        }
        return try await client.callTool(name: tool, arguments: arguments)
    }

    func shutdownAll() async {
        for (_, client) in clients { await client.shutdown() }
        clients.removeAll()
    }
}
