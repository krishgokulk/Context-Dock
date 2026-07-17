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
    func capabilityPromptBlock(compact: Bool = false, query: String = "") async -> String {
        // Built-ins are cheap (in-memory registry) and toggle live — never cache them,
        // so a flipped toggle shows up on the very next message.
        let builtinLines = builtInCapabilityLines()
        let inventoryLines = appInventoryLines()
        if let cachedBlock, Date().timeIntervalSince(cachedAt) < cacheTTL {
            let block = withInventory(
                joinedBlock(cachedBlock, builtinLines: builtinLines),
                inventoryLines: inventoryLines
            )
            return compact ? compacted(block) : block
        }

        var mcpLines: [String] = []
        // Apps exposing a query-style tool (search/find/list/get/query/read). These are the
        // fan-out / "which app?" targets for broad discovery questions that name no app.
        var searchableApps: [(name: String, bundleId: String, tools: [String])] = []
        let searchVerbs = ["search", "find", "list", "query", "get", "read", "lookup", "fetch"]
        let enabledAdapters = AppAdapterManager.shared.adapters.filter { $0.isEnabled }
        let normalizedQuery = query.lowercased()
        let explicitlyNamed = enabledAdapters.filter {
            normalizedQuery.contains($0.appName.lowercased())
                || normalizedQuery.contains($0.bundleId.lowercased())
        }
        let adapters = explicitlyNamed.isEmpty ? enabledAdapters : explicitlyNamed
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
            let queryTools = tools
                .map(\.tool.name)
                .filter { name in
                    let lower = name.lowercased()
                    return searchVerbs.contains { lower.contains($0) }
                }
            if !queryTools.isEmpty {
                searchableApps.append(
                    (adapter.appName, adapter.bundleId, Array(queryTools.prefix(4))))
            }
        }

        let historyApps = savedChatApps()
        let historyLines = historyApps.map { "- \($0.appName) (\($0.bundleId))" }

        guard !mcpLines.isEmpty || !historyLines.isEmpty || !builtinLines.isEmpty
            || !inventoryLines.isEmpty
        else {
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
            "",
            "Planning rules:",
            "- Prefer real DoraX routes over generic advice: app adapter actions, built-in capabilities, MCP tools, native share, cached app menus, CLI, then launch/activate.",
            "- If a request names or implies an app, check the installed/running/app-adapter/menu inventory below before answering.",
            "- If execution is needed, explain the route and let DoraX approval run it; do not pretend the task is complete before approval/executor success.",
            "- If the user asks about selected files, selected text, the current page, or the frontmost app, say DoraX can inspect local Accessibility/Vision context and ask before using it unless explicit chat attachments/context are already provided.",
            "- If the user asks to share/send to an app, use native macOS sharing or the app adapter route; do not invent a manual copy/paste workflow.",
            "- DISCOVERY queries that name NO app (\"do any of my apps have X\", \"where did I save Y\", \"any links stored anywhere\"): NEVER answer that you lack access, and NEVER suggest grep / the current working directory / shell — you are DoraX, not a coding agent. Instead call the query tool of each relevant app under \"Searchable apps\" below and combine the results. If several apps could match and fanning out is too broad, first ask the user which of those specific apps to search (name them).",
        ]
        if !searchableApps.isEmpty {
            lines.append("")
            lines.append("Searchable apps (call these query tools to answer discovery questions):")
            for app in searchableApps.prefix(20) {
                lines.append(
                    "- \(app.name) (\(app.bundleId)): \(app.tools.joined(separator: ", "))")
            }
        }
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
        let full = withInventory(
            joinedBlock(block, builtinLines: builtinLines),
            inventoryLines: inventoryLines
        )
        return compact ? compacted(full) : full
    }

    /// Lines describing enabled built-in capabilities (Notes/Calendar/Contacts/Reminders/
    /// GitHub) — callable with server "builtin" through the same mcp_call JSON. Also
    /// names the DISABLED families so the model suggests enabling them instead of
    /// claiming it has no access.
    private func builtInCapabilityLines() -> [String] {
        let families: [(prefix: String, name: String, flag: String)] = [
            ("notes.", "Apple Notes", "noteMCPEnabled"),
            ("calendar.", "Calendar", "calendarMCPEnabled"),
            ("contacts.", "Contacts", "contactsMCPEnabled"),
            ("reminders.", "Reminders", "remindersMCPEnabled"),
            ("github.", "GitHub (gh CLI)", "githubMCPEnabled"),
        ]
        let prefixes = families.map(\.prefix)
        let caps = CapabilityRegistry.shared.all.filter { cap in
            prefixes.contains(where: cap.id.hasPrefix)
        }
        let disabledNames = families
            .filter { family in !caps.contains { $0.id.hasPrefix(family.prefix) } }
            .map(\.name)

        var lines: [String] = []
        if !caps.isEmpty {
            lines.append("")
            lines.append("Built-in tools (call with server \"builtin\", no app needed):")
            lines.append(
                "These tools mean you are NOT limited to the local file system or shell — "
                + "never claim you cannot access an app whose tools are listed here.")
            for cap in caps {
                let fields = cap.inputSchema.fields
                    .map { "\($0.name)\($0.required ? "" : "?")" }
                    .joined(separator: ", ")
                lines.append("- tool \"\(cap.id)\": \(cap.title) | input: [\(fields)]")
            }
        }
        if !disabledNames.isEmpty {
            lines.append("")
            lines.append(
                "Built-in integrations currently DISABLED: \(disabledNames.joined(separator: ", ")). "
                + "When the user asks about these apps, do NOT say you lack access — tell them to "
                + "flip the built-in toggle in Settings → App Adapters → that app → Tools tab.")
        }
        return lines
    }

    private func appInventoryLines() -> [String] {
        let installed = InstalledApplicationsCatalog.cachedInstalledApps()
        let runningBundleIds = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let adapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        let adapterByBundle = Dictionary(uniqueKeysWithValues: adapters.map { ($0.bundleId, $0) })
        let menuSummaries = AppMenuCapabilityCache.shared.summaries()
        let menuSummaryByBundle = Dictionary(uniqueKeysWithValues: menuSummaries.map {
            ($0.bundleIdentifier, $0)
        })
        let skills = SkillStore.shared.skills.filter(\.isEnabled)
        let skillCounts = Dictionary(grouping: skills, by: \.adapterBundleId).mapValues(\.count)
        let mcpCounts = Dictionary(grouping: MCPServerManager.shared.servers.flatMap { server in
            server.bundleIds.map { (bundleId: $0, server: server) }
        }, by: \.bundleId).mapValues(\.count)

        var importantBundleIds = Set<String>()
        importantBundleIds.formUnion(runningBundleIds)
        importantBundleIds.formUnion(adapterByBundle.keys)
        importantBundleIds.formUnion(menuSummaryByBundle.keys)
        importantBundleIds.formUnion(skillCounts.keys)
        if let frontmostBundleId { importantBundleIds.insert(frontmostBundleId) }

        let installedByBundle = Dictionary(uniqueKeysWithValues: installed.map { ($0.bundleId, $0) })
        let ordered = importantBundleIds.compactMap { bundleId -> (name: String, bundleId: String)? in
            if let entry = installedByBundle[bundleId] { return (entry.name, bundleId) }
            if let adapter = adapterByBundle[bundleId] { return (adapter.appName, bundleId) }
            if let summary = menuSummaryByBundle[bundleId] { return (summary.appName, bundleId) }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return (FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""), bundleId)
            }
            return nil
        }
        .sorted {
            if $0.bundleId == frontmostBundleId { return true }
            if $1.bundleId == frontmostBundleId { return false }
            let lhsRunning = runningBundleIds.contains($0.bundleId)
            let rhsRunning = runningBundleIds.contains($1.bundleId)
            if lhsRunning != rhsRunning { return lhsRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let mediaInfo = MediaInfoProvider.shared.getNowPlayingSourceInfo()
        let mediaBundleId = mediaInfo.bundleID
        let mediaDisplayName = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let observerMediaApp = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            "- Installed apps indexed: \(installed.count). Running apps indexed: \(runningBundleIds.count).",
            "- Native share routes available for selected files/text/current URL: Messages, Mail, AirDrop, and system share sheet.",
            "- AX/Vision deeper inspection is available only after user approval; ask before reading screen, frontmost UI, selected files, selected text, or page contents unless already attached.",
        ]
        if let frontmostBundleId,
           let frontmost = ordered.first(where: { $0.bundleId == frontmostBundleId }) {
            lines.append("- Frontmost app now: \(frontmost.name) (\(frontmost.bundleId)).")
        }

        lines.append("Running app status snapshot:")
        for app in ordered.prefix(28) {
            var bits: [String] = []
            if app.bundleId == frontmostBundleId { bits.append("frontmost") }
            if runningBundleIds.contains(app.bundleId) { bits.append("running") }
            if let adapter = adapterByBundle[app.bundleId] {
                let actions = adapter.visibleActions.count
                bits.append("\(actions) adapter action\(actions == 1 ? "" : "s")")
                let readers = adapter.contextReaders.count
                if readers > 0 {
                    bits.append("\(readers) adapter reader\(readers == 1 ? "" : "s")")
                }
            }
            if let count = mcpCounts[app.bundleId], count > 0 {
                bits.append("\(count) MCP server\(count == 1 ? "" : "s")")
            }
            if let count = skillCounts[app.bundleId], count > 0 {
                bits.append("\(count) skill\(count == 1 ? "" : "s")")
            }
            if let summary = menuSummaryByBundle[app.bundleId] {
                bits.append("\(summary.recordCount) cached menu command\(summary.recordCount == 1 ? "" : "s")")
            }
            if app.bundleId == mediaBundleId
                || (!mediaDisplayName.isEmpty
                    && mediaDisplayName.localizedCaseInsensitiveContains(app.name))
                || (!observerMediaApp.isEmpty
                    && app.name.localizedCaseInsensitiveContains(observerMediaApp)) {
                let title = (mediaInfo.title ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    bits.append("media \(mediaInfo.playbackRate > 0 ? "playing" : "paused"): \(title)")
                } else {
                    bits.append("media source")
                }
            }
            if runningBundleIds.contains(app.bundleId) {
                bits.append("AX/Vision available with approval")
            }
            guard !bits.isEmpty else { continue }
            lines.append("- \(app.name) (\(app.bundleId)): \(bits.joined(separator: "; ")).")
        }
        return lines
    }

    private func joinedBlock(_ base: String, builtinLines: [String]) -> String {
        if builtinLines.isEmpty { return base }
        if base.isEmpty {
            let header = [
                "## App Tools (available in General Chat)",
                "To call a tool, reply with ONLY one line of JSON and nothing else:",
                "{\"mcp_call\": {\"server\": \"builtin\", \"tool\": \"<tool>\", \"arguments\": { … }}}",
                "After the tool result returns, answer the user's question in plain language.",
                "Use DoraX app/menu/share/adapter capabilities when the user names or implies an app.",
            ]
            return (header + builtinLines).joined(separator: "\n")
        }
        return base + "\n" + builtinLines.joined(separator: "\n")
    }

    private func withInventory(_ base: String, inventoryLines: [String]) -> String {
        guard !inventoryLines.isEmpty else { return base }
        let inventoryBlock = ([
            "## Running App Status Snapshot",
        ] + inventoryLines).joined(separator: "\n")
        guard !base.isEmpty else {
            return inventoryBlock
        }
        return inventoryBlock + "\n\n" + base
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
            // Built-in capability ids (notes.search, calendar.today, …) win over MCP
            // server tools — there is no overlap in practice.
            if CapabilityRegistry.shared.capability(id: tool) != nil {
                let input = arguments.mapValues { value -> String in
                    if let s = value as? String { return s }
                    return "\(value)"
                }
                let plan = AIActionPlan(
                    capability: tool, input: input, explanation: "Requested from AI chat")
                let result = await AIExecutionEngine.shared.executeUnifiedWithApproval(
                    plan, context: .none)
                return ToolCallResult(
                    handled: true,
                    success: result.success,
                    output: result.success
                        ? result.output : "Tool \(tool) failed: \(result.error ?? "Unknown error")",
                    label: "\(tool) via built-in")
            }
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
