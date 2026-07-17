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
}

struct AITypedInvocation: Equatable, Sendable {
    let kind: AITypedInvocationKind
    let capabilityID: String
    let arguments: [String: String]
    let requiresApproval: Bool
}

enum AIVerificationStatus: String, Codable, Sendable {
    case verified
    case unverified
    case notAvailable
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

enum AITypedInvocationResolver {
    static func terminalInvocation(from line: String) -> AITypedInvocation? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let call = root["terminal_call"] as? [String: Any],
            let command = call["command"] as? String,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let purpose = (call["purpose"] as? String) ?? "Run requested command"
        return AITypedInvocation(
            kind: .terminal,
            capabilityID: "terminal.run",
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
}
