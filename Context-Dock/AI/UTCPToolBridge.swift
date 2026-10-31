//  UTCPToolBridge.swift
//  Context-Dock
//
//  Bridges UTCP tool definitions and manuals into DoraX's AgentToolRegistry.
//  Enforces safety governance (read vs write risk, outbound privacy gating,
//  and recent write deduplication) while dispatching directly via UTCPDirectExecutor.

import Foundation

@MainActor
final class UTCPToolBridge {
    static let shared = UTCPToolBridge()

    private var registeredToolsByGroup: [String: Set<String>] = [:]

    private init() {}

    /// Converts a UTCPToolDefinition into an executable AgentTool for provider tool loops.
    static func makeAgentTool(
        definition: UTCPToolDefinition,
        prefix: String? = nil,
        baseURL: URL? = nil,
        apiKey: String? = nil,
        defaultHeaders: [String: String]? = nil
    ) -> AgentTool {
        let toolName: String = {
            guard let prefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty else {
                return definition.name
            }
            let cleanPrefix = prefix.lowercased().replacingOccurrences(of: "-", with: "_")
            if definition.name.lowercased().hasPrefix(cleanPrefix) {
                return definition.name
            }
            return "\(cleanPrefix)_\(definition.name)"
        }()

        return AgentTool(
            name: toolName,
            description: definition.description,
            properties: definition.schemaPropertiesForProvider,
            required: definition.requiredParameters
        ) { arguments, context in
            let displayCommand = "\(toolName) \(arguments.keys.sorted().joined(separator: ", "))"

            // 1. Prevent duplicate write loops
            if definition.safety == .write {
                let stringArgs = arguments.mapValues { "\($0)" }
                if RecentCapabilityWrites.alreadyRan(toolName, input: stringArgs) {
                    return AgentToolResult(
                        success: true,
                        output: "This write was already executed recently. Returning previous successful result.",
                        displayCommand: displayCommand
                    )
                }
            }

            // 2. Outbound gate check when turn is carrying private local data
            if let turn = context.turn {
                let registry = AgentToolRegistry.shared
                let target: OutboundGate.Target = {
                    switch definition.execution {
                    case .http:
                        return OutboundGate.Target(
                            kind: .fetch,
                            host: baseURL?.host,
                            label: "make a web request to \(baseURL?.host ?? "an external API")"
                        )
                    case .cli:
                        return OutboundGate.Target(
                            kind: .shell,
                            host: nil,
                            label: "run a CLI tool that may access the network"
                        )
                    }
                }()

                if let stopped = await registry.gateOutbound(
                    target: target,
                    what: "UTCP tool: \(toolName)",
                    turn: turn,
                    chatScope: context.chatScope
                ) {
                    return stopped
                }
            }

            // 3. Direct execution
            let (success, output): (Bool, String)
            switch definition.execution {
            case .http(let httpExec):
                guard let effectiveBaseURL = baseURL else {
                    return AgentToolResult(
                        success: false,
                        output: "UTCP error: Missing base URL for HTTP execution.",
                        displayCommand: displayCommand
                    )
                }
                (success, output) = await UTCPDirectExecutor.shared.executeHTTP(
                    execution: httpExec,
                    baseURL: effectiveBaseURL,
                    apiKey: apiKey,
                    defaultHeaders: defaultHeaders,
                    arguments: arguments
                )

            case .cli(let cliExec):
                (success, output) = await UTCPDirectExecutor.shared.executeCLI(
                    execution: cliExec,
                    arguments: arguments
                )
            }

            // 4. Record successful writes to deduplication cache
            if success && definition.safety == .write {
                let stringArgs = arguments.mapValues { "\($0)" }
                RecentCapabilityWrites.record(toolName, input: stringArgs)
            }

            // 5. Audit taint tracking if turn token is present
            if let turn = context.turn {
                await AgentToolRegistry.shared.taint.record(
                    toolName: toolName,
                    arguments: arguments,
                    output: output,
                    succeeded: success,
                    turn: turn
                )
            }

            return AgentToolResult(
                success: success,
                output: output,
                displayCommand: displayCommand
            )
        }
    }

    /// Registers all tools in a UTCPManual to AgentToolRegistry under an optional namespace prefix.
    @discardableResult
    func register(
        manual: UTCPManual,
        groupKey: String,
        prefix: String? = nil,
        apiKey: String? = nil
    ) -> [String] {
        let baseURL: URL? = {
            if let baseStr = manual.protocols.http?.baseURL {
                return URL(string: baseStr)
            }
            return nil
        }()

        var registeredNames: [String] = []
        for def in manual.tools {
            let tool = Self.makeAgentTool(
                definition: def,
                prefix: prefix,
                baseURL: baseURL,
                apiKey: apiKey,
                defaultHeaders: manual.protocols.http?.defaultHeaders
            )
            AgentToolRegistry.shared.register(tool)
            registeredNames.append(tool.name)
        }

        var existing = registeredToolsByGroup[groupKey] ?? []
        existing.formUnion(registeredNames)
        registeredToolsByGroup[groupKey] = existing

        return registeredNames
    }

    /// Unregisters all tools associated with a group key.
    func unregisterGroup(_ groupKey: String) {
        guard let toolNames = registeredToolsByGroup.removeValue(forKey: groupKey) else { return }
        for name in toolNames {
            AgentToolRegistry.shared.unregister(name)
        }
    }
}
