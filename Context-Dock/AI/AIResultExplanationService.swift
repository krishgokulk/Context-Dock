import Foundation

@MainActor
final class AIResultExplanationService {
    static let shared = AIResultExplanationService()

    private init() {}

    func explain(
        plan: AIActionPlan,
        result: AICapabilityExecutionResult,
        context: UserContext,
        provider: AIProvider
    ) async -> String {
        let explanationContext: UserContext = result.output.isEmpty
            ? context
            : .textSelected(result.output)
        let request = AIRequest(
            text: """
                Explain this completed capability result to user. Be concise and actionable.
                Capability: \(plan.capability)
                Requested reason: \(plan.explanation)
                Success: \(result.success)
                Output:
                \(String(result.output.prefix(12_000)))
                """,
            context: explanationContext,
            mode: .explainResult,
            source: .contextDock
        )
        do {
            return try await AIProviderRouter.shared.send(request, provider: provider)
        } catch {
            return result.output
        }
    }
}
