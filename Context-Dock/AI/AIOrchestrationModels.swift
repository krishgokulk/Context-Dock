import Foundation

struct AISelectionSnapshot: Equatable, Sendable {
    let text: String?
    let files: [URL]
    let pageURL: String?

    var isEmpty: Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && files.isEmpty
            && pageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}

enum AIConversationScope: Equatable, Sendable {
    case general
    case selection(AISelectionSnapshot)
    case contextDock(bundleID: String, appName: String)
}

struct AIOrchestrationRequest {
    let providerRequest: AIRequest
    let scope: AIConversationScope
    let policy: AIOrchestrationPolicy
    let providerSelection: AIProviderSelection
    let contextPrompt: String
}

struct AIOrchestrationResponse {
    let text: String
    let providerSelection: AIProviderSelection
    let invocations: [AITypedInvocation]
}

enum AITypedInvocationKind: String, Codable, Sendable {
    case share
    case capability
    case mcp
    case terminal
    case adapterAction
}

struct AITypedInvocation: Equatable, Sendable {
    let kind: AITypedInvocationKind
    let capabilityID: String
    let arguments: [String: String]
    let requiresApproval: Bool
}

enum AIVerificationStatus: String, Codable, Sendable {
    case verified
    /// The registered executor reported success, but no independent read-back exists.
    case executorConfirmed
    case unverified
    case notAvailable

    var displayName: String {
        switch self {
        case .verified: "Verified"
        case .executorConfirmed: "Executor confirmed (not independently verified)"
        case .unverified: "Verification failed"
        case .notAvailable: "Verification unavailable"
        }
    }
}

struct AIUnifiedExecutionResult: Equatable, Sendable {
    let capabilityID: String
    let success: Bool
    let output: String
    let sideEffects: [String]
    let verification: AIVerificationStatus
    let error: String?
}

@MainActor
final class AIOrchestrationEngine {
    static let shared = AIOrchestrationEngine()

    private init() {}

    func submit(_ request: AIOrchestrationRequest) async throws -> AIOrchestrationResponse {
        try CapabilityAuthorizationGate.validate(request)
        let text = try await AIProviderRouter.shared.sendPrepared(
            request: request.providerRequest,
            provider: request.providerSelection.effectiveProvider,
            contextPrompt: request.contextPrompt
        )
        return AIOrchestrationResponse(
            text: text,
            providerSelection: request.providerSelection,
            invocations: []
        )
    }
}

enum CapabilityAuthorizationError: LocalizedError {
    case policyMismatch
    case missingSelection
    case crossAppDenied(expected: String, received: String)
    case selectionTargetDenied(String)

    var errorDescription: String? {
        switch self {
        case .policyMismatch: return "The conversation scope does not match its execution policy."
        case .missingSelection: return "Selection Chat requires explicit selected content."
        case .crossAppDenied(let expected, let received):
            return "This chat is scoped to \(expected); \(received) is outside that scope."
        case .selectionTargetDenied(let received):
            return "Selection Chat cannot read from or execute against \(received)."
        }
    }
}

/// Code-enforced surface boundary. Prompts still explain scope to the model, but this gate
/// is the authority: malformed/mismatched requests never reach any provider or tool parser.
enum CapabilityAuthorizationGate {
    static func validate(_ request: AIOrchestrationRequest) throws {
        switch request.scope {
        case .general:
            guard request.policy.mode == .generalChat,
                  request.policy.capabilityScope == .systemWide else {
                throw CapabilityAuthorizationError.policyMismatch
            }
        case .selection(let selection):
            guard !selection.isEmpty, request.policy.mode == .generalChat else {
                throw selection.isEmpty
                    ? CapabilityAuthorizationError.missingSelection
                    : CapabilityAuthorizationError.policyMismatch
            }
        case .contextDock:
            guard request.policy.mode == .frontmostAppChat,
                  request.policy.capabilityScope == .currentApp,
                  !request.policy.permitsCrossAppExecution else {
                throw CapabilityAuthorizationError.policyMismatch
            }
        }
    }

    static func validateTarget(bundleID: String?, scope: AIConversationScope) throws {
        guard let bundleID, !bundleID.isEmpty else { return }
        switch scope {
        case .general:
            return
        case .selection:
            // Selection Chat may transform/share its explicit payload through dedicated UI,
            // but a provider may never turn it into an implicit app reader or executor.
            throw CapabilityAuthorizationError.selectionTargetDenied(bundleID)
        case .contextDock(let scopedBundleID, let appName):
            guard bundleID == scopedBundleID else {
                throw CapabilityAuthorizationError.crossAppDenied(
                    expected: appName, received: bundleID)
            }
        }
    }

    static func validatePlan(_ plan: AIActionPlan, scope: AIConversationScope) throws {
        let registeredBundle = CapabilityRegistry.shared.capability(id: plan.capability)?.appBundleID
        let suppliedBundle = plan.input["bundleId"] ?? plan.input["bundleID"]
        try validateTarget(bundleID: suppliedBundle ?? registeredBundle, scope: scope)
        if case .selection = scope,
           plan.capability != "system.share" {
            throw CapabilityAuthorizationError.selectionTargetDenied(plan.capability)
        }
    }

    static func validateInvocation(_ invocation: AITypedInvocation, scope: AIConversationScope) throws {
        let bundleID = invocation.arguments["bundleId"] ?? invocation.arguments["bundleID"]
        if invocation.kind == .share {
            // The share sheet receives only the explicit selection payload and still asks
            // for user confirmation; it does not grant source-app read access.
            return
        }
        if case .selection = scope {
            throw CapabilityAuthorizationError.selectionTargetDenied(invocation.capabilityID)
        }
        try validateTarget(bundleID: bundleID, scope: scope)
    }
}

enum AITypedInvocationResolver {
    /// Decode every provider-authored execution directive into one typed representation.
    /// Legacy JSON field names remain accepted as wire compatibility only; no caller may
    /// execute their dictionaries directly.
    static func invocation(from text: String) -> AITypedInvocation? {
        if let terminal = terminalInvocation(from: text) { return terminal }
        for root in jsonObjects(in: text) {
            // Run an installed app-adapter action (menu command, deep link, shortcut,
            // script) by id. The executor looks up the action and gates approval from its
            // own requiresApproval/isDestructive flags.
            if let call = root["adapter_call"] as? [String: Any],
                let actionId = (call["actionId"] as? String) ?? (call["action"] as? String),
                !actionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var args: [String: String] = ["actionId": actionId]
                if let b = (call["bundleId"] as? String) ?? (call["app"] as? String), !b.isEmpty {
                    args["bundleId"] = b
                }
                if let q = call["query"] as? String { args["query"] = q }
                return AITypedInvocation(
                    kind: .adapterAction, capabilityID: "adapter.run",
                    arguments: args, requiresApproval: false)
            }

            if let call = root["mcp_call"] as? [String: Any],
               let tool = call["tool"] as? String {
                var arguments: [String: String] = [
                    "server": (call["server"] as? String) ?? "",
                    "bundleId": (call["bundleId"] as? String)
                        ?? (call["app"] as? String) ?? "",
                ]
                if let values = call["arguments"] as? [String: Any],
                   let encoded = try? JSONSerialization.data(withJSONObject: values),
                   let json = String(data: encoded, encoding: .utf8) {
                    arguments["argumentsJSON"] = json
                }
                return AITypedInvocation(
                    kind: .mcp, capabilityID: tool, arguments: arguments,
                    requiresApproval: !MCPToolSafety.isClearlyReadOnly(name: tool))
            }

            if let call = root["capability_call"] as? [String: Any],
               let capability = call["capability"] as? String {
                let values = (call["arguments"] as? [String: Any]) ?? [:]
                return AITypedInvocation(
                    kind: .capability,
                    capabilityID: capability,
                    arguments: values.mapValues { String(describing: $0) },
                    requiresApproval: true)
            }

            if let call = root["app_chat_history"] as? [String: Any],
               let app = (call["bundleId"] as? String) ?? (call["app"] as? String) {
                return AITypedInvocation(
                    kind: .capability,
                    capabilityID: "app.chatHistory.read",
                    arguments: ["bundleId": app],
                    requiresApproval: false)
            }
        }
        return nil
    }

    static func terminalInvocation(from line: String) -> AITypedInvocation? {
        guard let root = jsonObjects(in: line).first,
            let call = root["terminal_call"] as? [String: Any],
            let command = call["command"] as? String,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let purpose = (call["purpose"] as? String) ?? "Run requested command"
        return AITypedInvocation(
            kind: .terminal,
            capabilityID: "terminal.runCommand",
            arguments: ["command": command, "purpose": purpose],
            requiresApproval: true
        )
    }

    static func shareInvocation(
        query: String,
        responseText: String,
        hasSelection: Bool
    ) -> AITypedInvocation? {
        guard hasSelection else { return nil }
        let normalized = query.lowercased()
        guard ["send ", "share ", "email ", "message ", "airdrop "]
            .contains(where: normalized.contains)
        else { return nil }

        let destinations: [(needles: [String], name: String)] = [
            (["mail", "email"], "Mail"),
            (["messages", "message", "imessage"], "Messages"),
            (["notes", "note"], "Notes"),
            (["reminders", "reminder"], "Reminders"),
            (["airdrop"], "AirDrop"),
            (["freeform"], "Freeform"),
        ]
        guard let destination = destinations.first(where: { entry in
            entry.needles.contains(where: normalized.contains)
        })?.name else { return nil }
        return AITypedInvocation(
            kind: .share,
            capabilityID: "system.share",
            arguments: ["destination": destination, "text": responseText],
            requiresApproval: true
        )
    }

    private static func jsonObjects(in text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let open = text[cursor...].firstIndex(of: "{") else { break }
            var depth = 0
            var inString = false
            var escaped = false
            var end: String.Index?
            var i = open
            while i < text.endIndex {
                let char = text[i]
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = inString
                } else if char == "\"" {
                    inString.toggle()
                } else if !inString {
                    if char == "{" {
                        depth += 1
                    } else if char == "}" {
                        depth -= 1
                        if depth == 0 {
                            end = text.index(after: i)
                            break
                        }
                    }
                }
                i = text.index(after: i)
            }
            guard let end else { break }
            let slice = String(text[open..<end])
            if let data = slice.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                objects.append(root)
            }
            cursor = end
        }
        return objects
    }
}
