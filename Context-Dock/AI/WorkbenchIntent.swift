// WorkbenchIntent.swift
// Context-Dock
//
// The three things the user says while iterating on their own project, and what each one
// means.
//
//   "test it"                 → build, and if it built, launch and capture
//   "save that as Test DoraX" → keep the plan that just ran, under a name
//   "run Test DoraX"          → run that plan again
//
// Recognition is deterministic phrase matching, not a model call, for the same reason
// ClaudeCodeBridge.shouldHandle is: these run real commands on the user's machine, and a
// probabilistic decision about whether "test it" meant *that* is not a decision worth
// making at this altitude. Deliberately narrow — anything not clearly one of the three
// falls through to ordinary routing, which is the safe direction to be wrong in.
//
// Note this adds no surface. "Test it" is a sentence typed into the chat that already
// exists; there is no Workflow mode, because the work is a runtime layer under the
// surfaces rather than another place to be.

import Foundation
import OSLog

@MainActor
enum WorkbenchIntent {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "Workbench")

    enum Intent: Equatable {
        /// Build the current project, then show what it looks like running.
        case test
        case save(name: String)
        case run(name: String)
        /// "still too tall" — an observation about what the user is looking at, made while
        /// DoraX is holding evidence of it. Goes to the coding agent with that evidence
        /// attached rather than to the chat's own model, which cannot see any of it.
        case report(observation: String)
    }

    /// The last plan that ran to completion, so "save that" has a referent. Only successful
    /// plans are offered: a recipe is a sequence known to work, not one that was attempted.
    private(set) static var lastSuccessfulPlan: (plan: ChatPlan, query: String)?

    static func rememberSuccessfulPlan(_ plan: ChatPlan, query: String) {
        lastSuccessfulPlan = (plan, query)
    }

    // MARK: - Recognition

    static func intent(in query: String) -> Intent? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let name = firstCapture(
            in: lower,
            pattern: #"^(?:save|remember|keep)\s+(?:that|this|it)\s+as\s+(.+?)[.!]?$"#)
        {
            return .save(name: name)
        }

        if let name = firstCapture(
            in: lower, pattern: #"^(?:run|do|replay)\s+(?:the\s+)?(.+?)\s*(?:again)?[.!]?$"#),
            WorkflowRecipeStore.shared.named(name) != nil
        {
            // Gated on the name existing: without that, "run the build" would be claimed
            // here and never reach the routing that can actually resolve it.
            return .run(name: name)
        }

        let testPhrases = [
            #"^test it[.!]?$"#, #"^test this[.!]?$"#,
            #"^build and test( it)?[.!]?$"#, #"^build (?:and )?run( it)?[.!]?$"#,
        ]
        if testPhrases.contains(where: {
            lower.range(of: $0, options: .regularExpression) != nil
        }) {
            return .test
        }

        // An observation only counts as one while there is something to show for it. Both
        // conditions matter: the phrasing keeps ordinary questions out, and the evidence
        // check means that when there is nothing to attach, this falls through to normal
        // routing instead of sending the agent a complaint with no subject.
        let observationPhrases = [
            #"^(?:it'?s |that'?s |the .+ is )?still\b"#,
            #"^fix (?:it|that|this)\b"#,
            #"^(?:it |that )?(?:still )?looks (?:wrong|off|broken|bad)\b"#,
        ]
        if observationPhrases.contains(where: {
            lower.range(of: $0, options: .regularExpression) != nil
        }), hasFreshEvidence {
            return .report(observation: query.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    /// Whether anything is being held that would make a report worth sending.
    private static var hasFreshEvidence: Bool {
        guard let root = ProjectContextResolver.shared.workingProjectRoot() else {
            return false
        }
        return WorkbenchEvidence.shared.buildFailure(for: root) != nil
            || WorkbenchEvidence.shared.capture(for: root) != nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let captured = String(text[range]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : captured
    }

    // MARK: - Carrying it out

    struct Outcome {
        let text: String
        let chips: [String]
    }

    static func handle(_ intent: Intent, scope: GeneralChatScope) async -> Outcome {
        switch intent {
        case .save(let name):
            return save(as: name)
        case .run(let name):
            guard let recipe = WorkflowRecipeStore.shared.named(name) else {
                return Outcome(text: "I don't have a workflow called “\(name)”.", chips: [])
            }
            let result = await WorkflowRecipeRunner.run(recipe)
            return Outcome(text: result.text, chips: result.chips)
        case .test:
            return await test(scope: scope)
        case .report(let observation):
            return await report(observation, scope: scope)
        }
    }

    /// Hands the observation to Claude Code with whatever DoraX is holding.
    private static func report(_ observation: String, scope: GeneralChatScope) async
        -> Outcome
    {
        guard let result = await AgentHandoff.send(observation: observation, scope: scope)
        else {
            return Outcome(
                text: "I couldn't tell which project that's about.", chips: [])
        }
        return Outcome(
            text: result.text,
            chips: result.toolsRan.map { "\($0) via Claude Code" })
    }

    private static func save(as name: String) -> Outcome {
        guard let last = lastSuccessfulPlan else {
            return Outcome(
                text:
                    "There's no finished workflow to save yet. Ask for something that takes "
                    + "several steps, then save it once it has run.",
                chips: [])
        }
        let recipe = WorkflowRecipe(name: name, query: last.query, plan: last.plan)
        WorkflowRecipeStore.shared.save(recipe)
        let steps = recipe.steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.purpose) — `\($0.element.title)`" }
            .joined(separator: "\n")
        return Outcome(
            text: "Saved as **\(name)**.\n\n\(steps)\n\nSay “run \(name)” to do it again.",
            chips: [])
    }

    /// Build, and if it built, show what it looks like running.
    ///
    /// Stops at a failed build rather than launching anyway. Launching the last good binary
    /// after a failed build is how someone spends twenty minutes testing a fix that was
    /// never compiled — the exact loop this is here to shorten.
    private static func test(scope: GeneralChatScope) async -> Outcome {
        guard let root = ProjectContextResolver.shared.workingProjectRoot() else {
            return Outcome(
                text: "I couldn't tell which project to test. Open it in your editor first.",
                chips: [])
        }
        let name = (root as NSString).lastPathComponent

        log.notice("test: building \(name, privacy: .public)")
        // Through the approval gate, never around it. project.build runs a script out of
        // the user's own repository; "test it" being two words does not make it a smaller
        // thing to consent to than the same command typed out.
        let build: AICapabilityExecutionResult
        do {
            build = try await AIExecutionEngine.shared.executeWithApproval(
                AIActionPlan(
                    capability: "project.build",
                    input: ["path": root],
                    explanation: "Build \(name)"),
                context: .none)
        } catch AICapabilityError.approvalRequired {
            return Outcome(text: "Left the build alone.", chips: [])
        } catch {
            return Outcome(
                text: "I couldn't start the build: \(error.localizedDescription)", chips: [])
        }

        guard build.success else {
            return Outcome(
                text: """
                    \(build.output)

                    Say what you want done about it — I'll hand the failure and your \
                    working tree to Claude Code.
                    """,
                chips: ["project.build"])
        }

        return Outcome(
            text: """
                \(build.output)

                Run it and get to the state you want to look at, then say what's wrong — \
                I'll pass a capture and the build state to Claude Code.
                """,
            chips: ["project.build"])
    }
}
