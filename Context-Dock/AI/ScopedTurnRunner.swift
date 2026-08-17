// ScopedTurnRunner.swift
// Context-Dock
//
// One agent turn, run the same way wherever it was asked from.
//
// The dock and the chat window each had their own copy of this stage: build an executor,
// pick how many tool rounds the request is worth, run the loop, then check the answer against
// what actually ran. Two copies is how they drifted — the dock verified its answers and the
// window did not, the window understood only shell commands and the dock understood the whole
// typed-invocation protocol. A user asking the same question of the same app got different
// behaviour depending on which window they happened to be in.
//
// What stays surface-specific is the prompt: the dock knows what is frontmost right now, the
// window knows what a thread is scoped to. What must not be surface-specific is what happens
// to the answer, and that is what lives here.

import Foundation
import OSLog

@MainActor
enum ScopedTurnRunner {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "ScopedTurn")

    struct Outcome {
        /// The answer, after any correction or verification pass has had its say.
        var text: String
        /// Everything that actually ran, with its real output. The receipts, not the story.
        var executed: [AIProviderService.ExecutedCommand]
        /// MCP tools reached through the executor, for the chips.
        var mcpToolsRan: [String]
        /// A second model's read of whether the answer actually satisfies the request.
        /// Only produced for the subjective work where it means anything — drafting,
        /// summarising, planning — never for "did this command run".
        var subjectiveEvaluation: SubjectiveEvaluation?
    }

    /// What the turn is being run against. Assembled by the surface, because only the
    /// surface knows whether "this app" means the frontmost one or a thread's own.
    struct Scope {
        var chatScope: GeneralChatScope
        var bundleId: String
        var appName: String
        /// Set for a `cli://` scope: the one executable this chat may run.
        var cliTool: String?
        /// What the model is answering about, for the provider's own context builder.
        var userContext: UserContext
    }

    static func run(
        query: String,
        systemPrompt: String,
        scope: Scope,
        provider: AIProvider,
        apiKey: String?,
        history: [ChatMessage],
        imageAttachments: [URL] = [],
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)? = nil,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> Outcome {

        let executorBuilder = ScopedCommandExecutor(
            configuration: .init(
                scope: scope.chatScope,
                bundleId: scope.bundleId,
                appName: scope.appName,
                cliTool: scope.cliTool),
            onStatus: onStatus)
        let executor = executorBuilder()

        // How many rounds this request is worth. A one-line question does not need nine tool
        // iterations, and a chained request cut off at five reports half a job as a finished
        // one.
        let complexity = TaskComplexityRouter.route(query)
        log.notice("turn \(complexity.rawValue, privacy: .public) scope=\(scope.chatScope.storageKey, privacy: .public)")
        onStatus?(
            scope.cliTool.map { "Working out the right \($0) command…" }
                ?? (complexity == .direct
                    ? "Answering…" : "Choosing the best available capability…"))

        // The prompt goes in the system slot and the question goes in the message slot.
        // The dock used to send the whole assembled prompt in *both*, which paid for every
        // menu path, every help page and every context block twice per turn.
        var (text, executed) = try await AIProviderService.shared.sendWithTools(
            query,
            context: scope.userContext,
            provider: provider,
            apiKey: apiKey,
            conversationHistory: history,
            commandExecutor: executor,
            maxIterations: complexity.maxToolIterations,
            additionalSystemPrompt: [systemPrompt, complexity.instruction]
                .filter { !$0.isEmpty }.joined(separator: "\n\n"),
            imageAttachments: imageAttachments,
            chatScope: scope.chatScope,
            onStream: onStream
        )

        // Did it do what it says it did?
        //
        // An answer reporting an action nobody performed is the most damaging thing a chat
        // on someone's Mac can produce. These passes deliberately do not stream: their text
        // replaces the answer rather than continuing it.
        if !Task.isCancelled,
            AgentAnswerVerifier.claimsUnperformedWork(answer: text, executed: executed)
        {
            onStatus?("Checking that actually happened…")
            if let (corrected, extra) = try? await AIProviderService.shared.sendWithTools(
                AgentAnswerVerifier.correctionPrompt(
                    originalQuery: query, answer: text, executed: executed),
                context: scope.userContext, provider: provider, apiKey: apiKey,
                conversationHistory: history, commandExecutor: executor,
                additionalSystemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                chatScope: scope.chatScope)
            {
                text = corrected
                executed += extra
            }
        }

        if !Task.isCancelled,
            AgentAnswerVerifier.claimsUnverifiedWork(answer: text, executed: executed)
        {
            onStatus?("Verifying the result…")
            if let (verified, extra) = try? await AIProviderService.shared.sendWithTools(
                AgentAnswerVerifier.verificationPrompt(originalQuery: query, answer: text),
                context: scope.userContext, provider: provider, apiKey: apiKey,
                conversationHistory: history, commandExecutor: executor,
                additionalSystemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                chatScope: scope.chatScope)
            {
                text = verified
                executed += extra
            }
        }

        // The user named the check themselves ("…and confirm it is gone"). Running it is not
        // optional politeness; it is the request.
        if !Task.isCancelled,
            AgentAnswerVerifier.explicitVerificationIsMissingOrMismatched(
                query: query, executed: executed)
        {
            onStatus?("Checking the requested criterion…")
            if let verification = await AgentAnswerVerifier.executeRequiredVerification(
                query: query, commandExecutor: executor)
            {
                text = verification.answer
                executed.append(verification.receipt)
            }
        }

        if !Task.isCancelled,
            AgentAnswerVerifier.explicitExecutionIsMissing(query: query, executed: executed)
        {
            onStatus?("Running the requested command…")
            if let repair = await AgentAnswerVerifier.executeMissingExplicitContract(
                query: query, executed: executed, commandExecutor: executor)
            {
                text = repair.answer
                executed += repair.additions
            }
        }

        // A separate reader, with no tools and no stake in the answer, asked whether the
        // answer is any good. Self-review by the model that wrote it is worth little; this
        // gate costs a call only on the requests where judgement is the deliverable.
        var evaluation: SubjectiveEvaluation?
        if !Task.isCancelled, FreshResultEvaluator.shouldEvaluate(query) {
            onStatus?("Reviewing result independently…")
            evaluation = await FreshResultEvaluator.evaluate(
                request: query, result: text, evidence: executed,
                provider: provider, apiKey: apiKey)
        }

        return Outcome(
            text: text, executed: executed, mcpToolsRan: executorBuilder.mcpToolsRan,
            subjectiveEvaluation: evaluation)
    }
}
