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

        /// The coarse classification for a turn that executed a candidate.
        ///
        /// Declared once, here, so the two axes stay related by something readable rather
        /// than by whatever each call site guessed. An API route is an adapter's API, and a
        /// launch is the adapter layer deciding an app is the answer, which is why both sit
        /// under `appAdapter` — the mechanism they used is not lost, it is in
        /// `executionRoute`.
        static func classifying(_ execution: DoraXActionCandidate.ExecutionRoute) -> Route {
            switch execution {
            case .verifiedMenu, .keyboardShortcut, .axFallback: return .appMenu
            case .mcp: return .mcp
            case .cli: return .cli
            case .adapter, .api, .shortcutRunner, .automation, .appLaunch: return .appAdapter
            }
        }
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
    /// What kind of turn this was. Coarse on purpose — it answers "did anything run, and
    /// against what", not "by which mechanism".
    let route: Route
    /// The mechanism, when something executed. Non-nil exactly when a candidate ran.
    ///
    /// Two axes rather than one because `Route` cannot express the executed routes: it has
    /// no case for an app launch, an API call, a Shortcut, a keyboard shortcut or an
    /// accessibility fallback, and folding those into `appAdapter` would throw away the
    /// distinction the authority layer is built on. `DoraXActionCandidate.ExecutionRoute`
    /// already names them, so it is carried rather than re-encoded.
    let executionRoute: DoraXActionCandidate.ExecutionRoute?
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
        executionRoute: DoraXActionCandidate.ExecutionRoute? = nil,
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
        self.executionRoute = executionRoute
        self.status = status
        self.complexity = complexity
        self.taskRunID = taskRunID
        self.receipts = receipts
        self.verification = verification
        self.trace = trace
        self.files = files
    }

    /// The same record, phrased.
    ///
    /// Orchestration knows what ran before it knows how the turn will read: the verification
    /// outcome decides both the receipts and the wording, and the wording is settled several
    /// branches later — one of which re-resolves the request and runs a second action whose
    /// text replaces the first. So the record is built where the facts are and carries the
    /// answer only once the surface has one.
    func withAnswer(_ answer: String) -> Self {
        GeneralChatWorkflowResult(
            answer: answer,
            route: route,
            executionRoute: executionRoute,
            status: status,
            complexity: complexity,
            taskRunID: taskRunID,
            receipts: receipts,
            verification: verification,
            trace: trace,
            files: files)
    }
}
