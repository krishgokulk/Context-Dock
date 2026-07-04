// GeneralChatCapabilityHub.swift
// Cross-app capability access for General Chat mode.
//
// Context Dock chat is scoped to one app's MCP tools and adapters. General Chat had no
// tool access at all, so "how many notes do I have?" answered "I don't have access".
// This hub exposes EVERY enabled app adapter's MCP tools plus the saved app-scoped chat
// histories to the general chat tool loop, so the model can pick the right app's tools
// itself — the same way Claude/Codex reference tools.

import AppKit
import Foundation

@MainActor
final class GeneralChatCapabilityHub {
    static let shared = GeneralChatCapabilityHub()

    private var cachedBlock: String?
    private var cachedAt: Date = .distantPast
    private let cacheTTL: TimeInterval = 300
    private let chatPanelKeyPrefix = "dock_app_"

    private init() {}

    func invalidate() {
        cachedBlock = nil
        cachedAt = .distantPast
    }

    // MARK: - Prompt block

    /// System-prompt section listing all app tools General Chat may call.
    /// Cached for 5 minutes — connecting to every linked MCP server per message is too slow.
    /// `compact` trims descriptions and tool counts for small-context providers (on-device).
    func capabilityPromptBlock(compact: Bool = false) async -> String {
        if let cachedBlock, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return compact ? compacted(cachedBlock) : cachedBlock
        }

        var mcpLines: [String] = []
        let adapters = AppAdapterManager.shared.adapters.filter { $0.isEnabled }
        for adapter in adapters {
            guard !MCPServerManager.shared.servers(forBundleId: adapter.bundleId).isEmpty else {
                continue
            }
            let tools = await MCPRuntime.shared.tools(forBundleId: adapter.bundleId)
            guard !tools.isEmpty else { continue }
            mcpLines.append("### \(adapter.appName) (\(adapter.bundleId))")
            for entry in tools.prefix(16) {
                let desc = entry.tool.description.isEmpty
                    ? "" : " — \(String(entry.tool.description.prefix(140)))"
                mcpLines.append("- server \"\(entry.server)\", tool \"\(entry.tool.name)\"\(desc)")
            }
        }

        let historyApps = savedChatApps()
        let historyLines = historyApps.map { "- \($0.appName) (\($0.bundleId))" }

        guard !mcpLines.isEmpty || !historyLines.isEmpty else {
            cachedBlock = ""
            cachedAt = Date()
            return ""
        }

        var lines: [String] = [
            "## App Tools (available in General Chat)",
            "You CAN access the user's installed apps through the tools below — even in",
            "General Chat. When the user asks about one of these apps, call its tool instead",
            "of saying you lack access. Never claim you cannot access an app listed here.",
            "",
            "To call an app's MCP tool, reply with ONLY one line of JSON and nothing else:",
            "{\"mcp_call\": {\"app\": \"<bundleId>\", \"server\": \"<server>\", \"tool\": \"<tool>\", \"arguments\": { … }}}",
            "",
            "To read the user's saved conversation history with an app (past app-scoped chats",
            "in this launcher), reply with ONLY:",
            "{\"app_chat_history\": {\"app\": \"<bundleId or app name>\"}}",
            "",
            "After the tool result returns, answer the user's actual question in plain language.",
            "If the user asks \"how many\", count the items in the result.",
        ]
        if !mcpLines.isEmpty {
            lines.append("")
            lines.append("Apps with live MCP tools:")
            lines.append(contentsOf: mcpLines)
        }
        if !historyLines.isEmpty {
            lines.append("")
            lines.append("Apps with saved chat history (readable via app_chat_history):")
            lines.append(contentsOf: historyLines)
        }

        let block = lines.joined(separator: "\n")
        cachedBlock = block
        cachedAt = Date()
        return compact ? compacted(block) : block
    }

    private func compacted(_ block: String) -> String {
        // On-device models have a small context window — keep the catalog lean.
        String(block.prefix(3_000))
    }

    // MARK: - Execution

    struct ToolCallResult {
        let handled: Bool
        let success: Bool
        let output: String
        /// Human-readable chip label, e.g. "search_items via Artifacts"
        let label: String
    }

    /// Dispatch a tool command the model emitted through the tool loop.
    /// Returns handled=false when the command is not an app tool call (caller falls back
    /// to the terminal bridge or treats the text as the final answer).
    func execute(_ command: String) async -> ToolCallResult {
        if let call = extractJSONObject(containing: "\"mcp_call\"", in: command),
           let mcp = call["mcp_call"] as? [String: Any],
           let tool = mcp["tool"] as? String {
            let server = (mcp["server"] as? String) ?? ""
            let arguments = (mcp["arguments"] as? [String: Any]) ?? [:]
            let appRef = (mcp["app"] as? String) ?? (mcp["bundleId"] as? String) ?? ""
            guard let bundleId = resolveBundleId(appRef: appRef, serverName: server) else {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "No app adapter matches \"\(appRef)\" / server \"\(server)\".",
                    label: tool)
            }
            let label = "\(tool) via \(displayName(forBundleId: bundleId))"
            do {
                let result = try await MCPRuntime.shared.callTool(
                    bundleId: bundleId, server: server, tool: tool, arguments: arguments)
                return ToolCallResult(handled: true, success: true, output: result, label: label)
            } catch {
                return ToolCallResult(
                    handled: true, success: false,
                    output: "MCP tool \(tool) failed: \(error.localizedDescription)",
                    label: label)
            }
        }

        if let call = extractJSONObject(containing: "\"app_chat_history\"", in: command),
           let historyCall = call["app_chat_history"] as? [String: Any],
           let appRef = (historyCall["app"] as? String) ?? (historyCall["bundleId"] as? String) {
            return ToolCallResult(
                handled: true, success: true,
                output: chatHistoryText(for: appRef),
                label: "chat history: \(appRef)")
        }

        return ToolCallResult(handled: false, success: false, output: "", label: "")
    }

    // MARK: - Chat history

    private struct SavedChatApp {
        let bundleId: String
        let appName: String
    }

    private func savedChatApps() -> [SavedChatApp] {
        AppPanelChatStore.shared.allPanelKeys()
            .filter { $0.hasPrefix(chatPanelKeyPrefix) }
            .map { String($0.dropFirst(chatPanelKeyPrefix.count)) }
            .map { SavedChatApp(bundleId: $0, appName: displayName(forBundleId: $0)) }
    }

    private func chatHistoryText(for appRef: String) -> String {
        guard let bundleId = resolveChatHistoryBundleId(appRef: appRef) else {
            return "No saved chat history found for \"\(appRef)\"."
        }
        let messages = AppPanelChatStore.shared.load(for: chatPanelKeyPrefix + bundleId)
        guard !messages.isEmpty else {
            return "No saved chat history found for \(displayName(forBundleId: bundleId))."
        }
        let lines = messages.suffix(30).map { msg -> String in
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .tool: role = "tool"
            default: role = "assistant"
            }
            return "\(role): \(String(msg.content.prefix(400)))"
        }
        return "Saved chat history with \(displayName(forBundleId: bundleId)) "
            + "(last \(lines.count) messages):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Resolution helpers

    private func resolveBundleId(appRef: String, serverName: String) -> String? {
        let ref = appRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapters = AppAdapterManager.shared.adapters.filter { $0.isEnabled }
        if !ref.isEmpty {
            if let exact = adapters.first(where: {
                $0.bundleId.caseInsensitiveCompare(ref) == .orderedSame
            }) { return exact.bundleId }
            if let byName = adapters.first(where: {
                $0.appName.caseInsensitiveCompare(ref) == .orderedSame
            }) { return byName.bundleId }
            // Singular/plural + partial-name tolerance ("artifact" → "Artifacts")
            let lowerRef = ref.lowercased()
            if let loose = adapters.first(where: {
                let name = $0.appName.lowercased()
                return name.contains(lowerRef) || lowerRef.contains(name)
                    || name.hasPrefix(lowerRef) || lowerRef.hasPrefix(name)
            }) { return loose.bundleId }
            // Bundle id the model produced but no adapter exists — still try it directly
            // if any MCP server is linked to it.
            if !MCPServerManager.shared.servers(forBundleId: ref).isEmpty { return ref }
        }
        // Fall back: the adapter whose linked servers contain the named server.
        if !serverName.isEmpty {
            for adapter in adapters {
                let servers = MCPServerManager.shared.servers(forBundleId: adapter.bundleId)
                if servers.contains(where: { $0.name.caseInsensitiveCompare(serverName) == .orderedSame }) {
                    return adapter.bundleId
                }
            }
        }
        return nil
    }

    private func resolveChatHistoryBundleId(appRef: String) -> String? {
        let ref = appRef.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        let saved = savedChatApps()
        if let exact = saved.first(where: { $0.bundleId.lowercased() == ref }) {
            return exact.bundleId
        }
        if let byName = saved.first(where: { $0.appName.lowercased() == ref }) {
            return byName.bundleId
        }
        // Loose match: "notes" → com.apple.Notes
        return saved.first(where: {
            $0.appName.lowercased().contains(ref) || $0.bundleId.lowercased().contains(ref)
        })?.bundleId
    }

    private func displayName(forBundleId bundleId: String) -> String {
        if let adapter = AppAdapterManager.shared.adapters.first(where: {
            $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame
        }) { return adapter.appName }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }

    // MARK: - JSON extraction

    /// Balance-matched extraction of the JSON object that contains `key`, tolerant of the
    /// model wrapping it in prose or code fences (same approach as parseMCPCall).
    private func extractJSONObject(containing key: String, in text: String) -> [String: Any]? {
        guard let keyRange = text.range(of: key) else { return nil }
        guard let open = text[..<keyRange.lowerBound].lastIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = open
        while i < text.endIndex {
            switch text[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { end = text.index(after: i) }
            default: break
            }
            if end != nil { break }
            i = text.index(after: i)
        }
        guard let endIdx = end else { return nil }
        let slice = String(text[open..<endIdx])
        guard let data = slice.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }
}
