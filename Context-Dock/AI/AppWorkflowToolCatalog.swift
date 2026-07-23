import Foundation

@MainActor
final class AppWorkflowToolCatalog {
    static let shared = AppWorkflowToolCatalog()

    private init() {}

    func register(in registry: CapabilityRegistry) {
        registerAdapterRunner(in: registry)
        registerMCPTools(in: registry)
        registerAPIInfo(in: registry)
        registerAdapterPackRecommendation(in: registry)
    }

    func promptBlock(for bundleID: String?) -> String {
        let adapters = scopedAdapters(bundleID: bundleID)
        guard !adapters.isEmpty else {
            return """
            App workflow tools:
            - No enabled app adapters are installed for this scope.
            - If user asks to automate an app with no installed action, use adapterpack.recommend.
            """
        }

        var lines: [String] = [
            "App workflow tools:",
            "Selection rule: prefer live MCP tools when linked; if no matching MCP exists, use connected API context; if no API fits, use installed adapter action; if no action exists, use adapterpack.recommend.",
            "Executable capabilities:",
            "- appadapter.run: run installed app adapter action. Inputs: bundleId, actionId, query.",
            "- mcp.call: call linked MCP server tool. Inputs: bundleId, server, tool, argumentsJSON.",
            "- mcp.listTools: list linked MCP tools for app. Inputs: bundleId.",
            "- api.connectionInfo: inspect connected API metadata for app. Inputs: bundleId.",
            "- adapterpack.recommend: recommend importing/creating adapter pack for missing workflow. Inputs: bundleId, appName, workflow.",
            "",
            "Installed app automation:",
        ]

        for adapter in adapters.prefix(60) {
            let bundle = adapter.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            let appName = adapter.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let mcps = MCPServerManager.shared.servers(forBundleId: bundle)
            let apis = APIConnectionStore.shared.connections(for: bundle)
            let preferred: String = {
                if !mcps.isEmpty { return "MCP" }
                if apis.contains(where: { $0.status == .connected }) { return "API" }
                if !adapter.actions.isEmpty { return "Adapter action" }
                return "Adapter pack needed"
            }()

            lines.append("- \(appName) (\(bundle)) | preferred=\(preferred)")
            if !mcps.isEmpty {
                lines.append("  MCP: \(mcps.map { $0.name }.joined(separator: ", "))")
            }
            if !apis.isEmpty {
                let apiNames = apis.map { "\($0.name) [\($0.status.rawValue)]" }.joined(separator: ", ")
                lines.append("  API: \(apiNames)")
            }
            if adapter.actions.isEmpty {
                lines.append("  Actions: none installed")
            } else {
                for action in adapter.actions.prefix(16) {
                    let triggerText = action.triggers.prefix(8).joined(separator: ", ")
                    let desc = action.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = desc.isEmpty ? "" : " — \(desc)"
                    let triggers = triggerText.isEmpty ? "" : " | triggers=\(triggerText)"
                    lines.append("  Action: id=\(action.id) name=\(action.name) type=\(action.type.rawValue)\(triggers)\(suffix)")
                }
                if adapter.actions.count > 16 {
                    lines.append("  Action: +\(adapter.actions.count - 16) more installed")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func generalChatPromptBlock(query: String, liveBundleID: String?) -> String {
        var lines: [String] = [
            "General Chat app workflow access:",
            "General Chat may answer questions about any installed app adapter and may use app-scoped adapter actions, linked MCP servers, API connection metadata, and saved frontmost-app chat history when relevant.",
            "Do not claim secrets or private API tokens are available; API connection metadata only describes linked services.",
            promptBlock(for: nil),
        ]

        let globalTools = globalToolsPromptBlock()
        if !globalTools.isEmpty { lines.append(globalTools) }

        let history = relevantAppChatHistory(query: query, liveBundleID: liveBundleID)
        if !history.isEmpty {
            lines.append("Saved frontmost-app chat history:")
            lines.append(contentsOf: history)
        }

        return lines.joined(separator: "\n\n")
    }

    /// Surface DoraX Global Commands and pinned CLI tools to General Chat so it can
    /// suggest them by name and drive CLI tools via terminal commands (with approval).
    private func globalToolsPromptBlock() -> String {
        var lines: [String] = []

        let commands = SystemCommandsRegistry.shared.commands.filter { $0.isEnabled }
        if !commands.isEmpty {
            lines.append(
                "DoraX Global Commands the user can run (suggest by name when relevant):")
            for command in commands.prefix(40) {
                let keywords = command.keywords
                    .filter {
                        !$0.hasPrefix("provider:") && !$0.hasPrefix("preset:")
                            && !$0.hasPrefix("presets:") && !$0.hasPrefix("refresh:")
                            && !$0.hasPrefix("query:")
                    }
                    .prefix(4)
                    .joined(separator: ", ")
                let kw = keywords.isEmpty ? "" : " — keywords: \(keywords)"
                lines.append("- \(command.name): \(command.description)\(kw)")
            }
        }

        let cli = AppSettings.shared.pinnedCLITools.sorted()
        if !cli.isEmpty {
            lines.append(
                "Pinned CLI tools you may drive with terminal commands (the user approves each run): "
                    + cli.joined(separator: ", ") + ".")
        }

        return lines.joined(separator: "\n")
    }

    private func scopedAdapters(bundleID: String?) -> [AppAdapter] {
        let enabled = AppAdapterManager.shared.adapters.filter { $0.isEnabled }
        guard let bundleID, !bundleID.isEmpty else {
            return enabled.sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        }
        let exact = enabled.filter { $0.bundleId == bundleID }
        // A scoped request must never inherit another app's tools. No exact adapter means
        // no adapter capabilities for this scope; only bundle-less built-ins remain.
        return exact
    }

    private func relevantAppChatHistory(query: String, liveBundleID: String?) -> [String] {
        let availableKeys = Set(AppPanelChatStore.shared.allPanelKeys())
        guard !availableKeys.isEmpty else { return [] }

        let queryTerms = Set(
            query
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )

        var candidates: [(score: Int, label: String, key: String, messages: [AIChatMessage])] = []
        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            for key in chatKeys(for: adapter) where availableKeys.contains(key) {
                let messages = AppPanelChatStore.shared.load(for: key)
                guard !messages.isEmpty else { continue }
                let searchable = ([adapter.appName, adapter.bundleId, key] + adapter.actions.flatMap {
                    [$0.name, $0.description] + $0.triggers
                }).joined(separator: " ").lowercased()
                let score = queryTerms.reduce(liveBundleID == adapter.bundleId ? 8 : 0) {
                    $0 + (searchable.contains($1) ? 3 : 0)
                } + min(messages.count, 6)
                candidates.append((score, adapter.appName, key, messages))
            }
        }

        return candidates
            .sorted {
                if $0.score == $1.score { return $0.label < $1.label }
                return $0.score > $1.score
            }
            .prefix(8)
            .map { candidate in
                let chatLines = candidate.messages.suffix(8).map { message -> String in
                    let role: String = {
                        switch message.role {
                        case .user: return "user"
                        case .assistant: return "assistant"
                        case .tool: return "tool"
                        case .approval: return "approval"
                        }
                    }()
                    return "  - \(role): \(String(message.content.prefix(500)))"
                }.joined(separator: "\n")
                return "- \(candidate.label) [\(candidate.key)]\n\(chatLines)"
            }
    }

    private func chatKeys(for adapter: AppAdapter) -> [String] {
        var keys = [
            "dock_app_\(adapter.bundleId)",
            adapter.bundleId,
            adapter.appName.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .joined(),
        ]
        if let appKey = AppSettings.shared.appKey(forBundleID: adapter.bundleId, appName: adapter.appName) {
            keys.append(appKey)
        }
        return Array(NSOrderedSet(array: keys.filter { !$0.isEmpty })) as? [String] ?? keys
    }

    private func registerAdapterRunner(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "appadapter.run",
                title: "Run Installed App Adapter Action",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "bundleId", description: "Target app bundle identifier", required: true),
                    .init(name: "actionId", description: "Installed adapter action id", required: true),
                    .init(name: "query", description: "Optional user text or parameters for adapter variables", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard let bundleId = request.input["bundleId"], !bundleId.isEmpty else {
                    throw AICapabilityError.missingInput("bundleId")
                }
                guard let actionId = request.input["actionId"], !actionId.isEmpty else {
                    throw AICapabilityError.missingInput("actionId")
                }
                guard let adapter = AppAdapterManager.shared.adapter(for: bundleId) else {
                    return .init(success: false, output: "No enabled adapter installed for \(bundleId)")
                }
                guard let action = adapter.actions.first(where: { $0.id == actionId }) else {
                    return .init(success: false, output: "Adapter action not found: \(actionId)")
                }
                let ax = AXContextReader.shared.current
                let query = request.input["query"] ?? ""
                let result = await AppAdapterManager.shared.execute(
                    action,
                    context: ax,
                    targetBundleId: bundleId,
                    query: query
                )
                return .init(success: result.0, output: result.1)
            }
        )
    }

    private func registerMCPTools(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mcp.listTools",
                title: "List Linked MCP Tools For App",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "bundleId", description: "Target app bundle identifier", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard let bundleId = request.input["bundleId"], !bundleId.isEmpty else {
                    throw AICapabilityError.missingInput("bundleId")
                }
                let tools = await MCPRuntime.shared.tools(forBundleId: bundleId)
                guard !tools.isEmpty else {
                    return .init(success: false, output: "No live MCP tools linked to \(bundleId)")
                }
                let output = tools.map { entry in
                    let desc = entry.tool.description.isEmpty ? "" : " — \(entry.tool.description)"
                    return "- server=\(entry.server) tool=\(entry.tool.name)\(desc)"
                }.joined(separator: "\n")
                return .init(success: true, output: output)
            }
        )

        registry.register(
            AICapability(
                id: "mcp.call",
                title: "Call Linked MCP Tool",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "bundleId", description: "Target app bundle identifier", required: true),
                    .init(name: "server", description: "Linked MCP server name", required: true),
                    .init(name: "tool", description: "MCP tool name", required: true),
                    .init(name: "argumentsJSON", description: "JSON object for MCP tool arguments", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard let bundleId = request.input["bundleId"], !bundleId.isEmpty else {
                    throw AICapabilityError.missingInput("bundleId")
                }
                guard let server = request.input["server"], !server.isEmpty else {
                    throw AICapabilityError.missingInput("server")
                }
                guard let tool = request.input["tool"], !tool.isEmpty else {
                    throw AICapabilityError.missingInput("tool")
                }
                let arguments = Self.jsonObject(request.input["argumentsJSON"] ?? "")
                let output = try await MCPRuntime.shared.callTool(
                    bundleId: bundleId,
                    server: server,
                    tool: tool,
                    arguments: arguments
                )
                return .init(success: true, output: output)
            }
        )
    }

    private func registerAPIInfo(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "api.connectionInfo",
                title: "Inspect App API Connections",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "bundleId", description: "Target app bundle identifier", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard let bundleId = request.input["bundleId"], !bundleId.isEmpty else {
                    throw AICapabilityError.missingInput("bundleId")
                }
                let connections = APIConnectionStore.shared.connections(for: bundleId)
                guard !connections.isEmpty else {
                    return .init(success: false, output: "No API connection linked to \(bundleId)")
                }
                let lines = connections.map { conn in
                    "- \(conn.name): \(conn.baseURL) [\(conn.status.rawValue)] permissions=\(conn.permissions)"
                }
                return .init(success: true, output: lines.joined(separator: "\n"))
            }
        )
    }

    private func registerAdapterPackRecommendation(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "adapterpack.recommend",
                title: "Recommend Adapter Pack For Missing Workflow",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "bundleId", description: "Target app bundle identifier", required: false),
                    .init(name: "appName", description: "Target app name", required: true),
                    .init(name: "workflow", description: "User workflow to automate", required: true),
                ]),
                riskLevel: .low
            ) { request in
                let appName = request.input["appName"] ?? "this app"
                let bundleId = request.input["bundleId"] ?? ""
                let workflow = request.input["workflow"] ?? ""
                let bundleSuffix = bundleId.isEmpty ? "" : " (\(bundleId))"
                return .init(
                    success: true,
                    output: """
                    No installed MCP/API/adapter action directly handles this workflow.
                    Recommended next step: import or create an adapter pack for \(appName)\(bundleSuffix).
                    Workflow to encode: \(workflow)
                    Pack should include one focused action, not a generic control panel.
                    """
                )
            }
        )
    }

    private static func jsonObject(_ raw: String) -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
