import Foundation

enum AIApprovalKind: String, Sendable {
    case capability
    case generalAction
    case terminal
    case adapter
    case privacy
    case sharing
}

struct AIApprovalPresentationRequest: Identifiable, Sendable {
    let id: UUID
    let kind: AIApprovalKind
    let title: String
    let summary: String
    let riskLabel: String
    let preview: String?
}

protocol AIApprovalPresentable {
    var approvalPresentation: AIApprovalPresentationRequest { get }
}

extension AICapabilityApprovalCenter.PendingApproval: AIApprovalPresentable {
    var approvalPresentation: AIApprovalPresentationRequest {
        AIApprovalPresentationRequest(
            id: id,
            kind: .capability,
            title: capability.title,
            summary: plan.explanation,
            riskLabel: capability.riskLevel.rawValue,
            preview: plan.input.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        )
    }
}

extension GeneralAIActionApprovalCenter.PendingApproval: AIApprovalPresentable {
    var approvalPresentation: AIApprovalPresentationRequest {
        AIApprovalPresentationRequest(
            id: id,
            kind: .generalAction,
            title: candidate.title,
            summary: candidate.routeLabel,
            riskLabel: candidate.riskLevel.rawValue,
            preview: candidate.inputValues.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        )
    }
}

extension TerminalAIBridge.PendingCommand: AIApprovalPresentable {
    var approvalPresentation: AIApprovalPresentationRequest {
        AIApprovalPresentationRequest(
            id: id,
            kind: .terminal,
            title: "Run Terminal Command",
            summary: purpose,
            riskLabel: classification.riskLevel.displayName,
            preview: command
        )
    }
}

extension AdapterActionRequest: AIApprovalPresentable {
    var approvalPresentation: AIApprovalPresentationRequest {
        AIApprovalPresentationRequest(
            id: id,
            kind: .adapter,
            title: action.name,
            summary: "Run with \(adapter.appName)",
            riskLabel: action.isDestructive ? "high" : "medium",
            preview: action.description
        )
    }
}

extension AIPrivacyApprovalCenter.PendingApproval: AIApprovalPresentable {
    var approvalPresentation: AIApprovalPresentationRequest {
        AIApprovalPresentationRequest(
            id: id,
            kind: .privacy,
            title: "Send Private Context",
            summary: "Send context to \(provider.displayName)",
            riskLabel: "privacy",
            preview: contextDescription
        )
    }
}
