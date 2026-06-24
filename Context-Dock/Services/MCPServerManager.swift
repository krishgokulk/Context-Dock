// MCPServerManager.swift
// Stores MCP (Model Context Protocol) servers the user links to app adapters. Scoped dock
// chat for an app can advertise its linked MCP servers to AI tools. Persisted as JSON in
// Application Support. Stdio transport (command + args) mirrors the standard mcpServers config.

import Foundation
import Combine

struct MCPServerConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var command: String
    var args: [String] = []
    var transport: String = "stdio"
    /// App-adapter bundleIds this server is linked to (shown under that app).
    var bundleIds: [String] = []

    var argsDisplay: String { args.joined(separator: " ") }
}

@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    @Published private(set) var servers: [MCPServerConfig] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mcp_servers.json")
    }()

    private init() { load() }

    func servers(forBundleId bundleId: String) -> [MCPServerConfig] {
        servers
            .filter { $0.bundleIds.contains(bundleId) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Add a server linked to an app adapter. Merges into an existing same-name server for
    /// the app instead of duplicating.
    func add(_ server: MCPServerConfig, linkedTo bundleId: String) {
        var s = server
        if !s.bundleIds.contains(bundleId) { s.bundleIds.append(bundleId) }
        if let idx = servers.firstIndex(where: {
            $0.name.caseInsensitiveCompare(s.name) == .orderedSame && $0.command == s.command
        }) {
            var existing = servers[idx]
            if !existing.bundleIds.contains(bundleId) { existing.bundleIds.append(bundleId) }
            existing.args = s.args
            existing.transport = s.transport
            servers[idx] = existing
        } else {
            servers.append(s)
        }
        save()
    }

    /// Unlink a server from one app adapter; drops the server entirely if unused afterwards.
    func unlink(id: UUID, from bundleId: String) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].bundleIds.removeAll { $0 == bundleId }
        if servers[idx].bundleIds.isEmpty { servers.remove(at: idx) }
        save()
    }

    /// Parse a standard `{ "mcpServers": { "<name>": { "command", "args", "transport" } } }`
    /// JSON blob and link every server found to `bundleId`. Returns the count added.
    @discardableResult
    func addFromJSON(_ json: String, linkedTo bundleId: String) -> Int {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mcp = root["mcpServers"] as? [String: Any]
        else { return 0 }
        var count = 0
        for (name, value) in mcp {
            guard let cfg = value as? [String: Any],
                let command = cfg["command"] as? String, !command.isEmpty
            else { continue }
            let args = (cfg["args"] as? [String]) ?? []
            let transport = (cfg["transport"] as? String) ?? "stdio"
            add(
                MCPServerConfig(name: name, command: command, args: args, transport: transport),
                linkedTo: bundleId)
            count += 1
        }
        return count
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data)
        else { return }
        servers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
