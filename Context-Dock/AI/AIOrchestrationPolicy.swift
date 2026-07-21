import Foundation

enum AIOrchestrationMode: String, Codable, Sendable {
    case generalChat
    case frontmostAppChat
}

enum AICapabilityScope: String, Codable, Sendable {
    case systemWide
    case currentApp
}

enum AIRequestKind: String, Codable, Sendable {
    case conversation
    case deterministicAction
    case scopedTask
    case multiStepWorkflow
}

enum AICapabilityKind: String, Codable, Hashable, Sendable {
    case appAction
    case appData
    case fileContent
    case sharing
    case workflow
}

struct AIIntentResolution: Equatable, Sendable {
    let kind: AIRequestKind
    let targetApps: [String]
    let requiredCapabilityKinds: Set<AICapabilityKind>
    let confidence: Double
    let requiresPlanning: Bool
}

struct AIOrchestrationPolicy: Equatable, Sendable {
    let mode: AIOrchestrationMode
    let capabilityScope: AICapabilityScope
    let permitsCrossAppExecution: Bool
    let permitsPlanning: Bool
    let automaticallyIncludesFrontmostContext: Bool
    let maximumWorkflowSteps: Int

    static let generalChat = AIOrchestrationPolicy(
        mode: .generalChat,
        capabilityScope: .systemWide,
        permitsCrossAppExecution: true,
        permitsPlanning: true,
        automaticallyIncludesFrontmostContext: false,
        maximumWorkflowSteps: 8
    )

    static let frontmostAppChat = AIOrchestrationPolicy(
        mode: .frontmostAppChat,
        capabilityScope: .currentApp,
        permitsCrossAppExecution: false,
        permitsPlanning: true,
        automaticallyIncludesFrontmostContext: true,
        maximumWorkflowSteps: 4
    )

    func includesLiveContext(explicitlyRequested: Bool) -> Bool {
        automaticallyIncludesFrontmostContext || explicitlyRequested
    }

    func allowsCrossAppExecution(explicitlyRequested: Bool) -> Bool {
        permitsCrossAppExecution || explicitlyRequested
    }
}
