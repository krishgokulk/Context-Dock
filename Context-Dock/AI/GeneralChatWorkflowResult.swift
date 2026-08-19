import Foundation

/// Surface-neutral result of one General Chat turn.
///
/// The compact dock and the full General Chat window intentionally remain separate UI
/// surfaces, but they must not invent separate meanings for "what ran".  This value is the
/// contract between orchestration and presentation: either surface can turn it into its
/// existing `AIChatMessage` without owning routing, execution, or verification state.
///
/// Conversation storage is deliberately absent. `GeneralChatSessionStore` continues to own
/// general, app-focused, and combined-app threads; this type describes one completed turn.
struct GeneralChatWorkflowResult {
    enum Route: String {
        case conversation
        case liveState
        case memory
        case selection
        case localCapability
        case globalCommand
        case appAdapter
        case appMenu
        case mcp
        case cli
        case providerTools
        case providerAnswer
    }

    enum Status: String {
        case completed
        case failed
        case cancelled
        case interrupted
    }

    enum Verification: String {
        case verified
        case executorConfirmed
        case unavailable
        case failed
    }

    let answer: String
    let route: Route
    let status: Status
    let complexity: TaskComplexityRoute
    let taskRunID: UUID?
    let receipts: [DoraXActionReceipt]
    let verification: Verification
    let trace: [String]
    let files: [URL]

    init(
        answer: String,
        route: Route,
        status: Status = .completed,
        complexity: TaskComplexityRoute = .direct,
        taskRunID: UUID? = nil,
        receipts: [DoraXActionReceipt] = [],
        verification: Verification = .unavailable,
        trace: [String] = [],
        files: [URL] = []
    ) {
        self.answer = answer
        self.route = route
        self.status = status
        self.complexity = complexity
        self.taskRunID = taskRunID
        self.receipts = receipts
        self.verification = verification
        self.trace = trace
        self.files = files
    }
}
