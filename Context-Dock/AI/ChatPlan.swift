// ChatPlan.swift
// Context-Dock
//
// Several capabilities, in order, for a request no single app can carry out.
//
// "Find the PDF I downloaded yesterday and email it to Sarah" is three capabilities in
// three apps. A single-shot route cannot express it, and a free-running tool loop can
// express it only by improvising — inventing a step, or claiming one it never ran.
//
// A plan is the middle ground: the model orders steps, but may only order steps that were
// resolved as real beforehand. Anything it names that is not in that list is rejected
// rather than attempted. Execution is sequential, each step's output is available to the
// next, approval gates are untouched, and a failed step stops the plan instead of letting
// later steps run on a false premise.

import Foundation
import OSLog

struct ChatPlanStep: Identifiable, Equatable {
    let id = UUID()
    /// The resolved route this step runs. Never a free-text command.
    let route: ChatRoute
    /// Why this step is in the plan, in the user's terms — shown while it runs.
    let purpose: String
}

struct ChatPlan: Equatable {
    var steps: [ChatPlanStep]
    /// One line describing the whole plan, for the surface to show before it starts.
    var summary: String

    /// A plan longer than this is almost always the model looping rather than reasoning,
    /// and each step is a real action on the user's machine.
    static let maxSteps = 5
}

struct ChatPlanStepResult: Identifiable, Equatable {
    let id: UUID
    let step: ChatPlanStep
    let success: Bool
    let output: String
    /// What changed on the machine afterwards, for steps that change things.
    let verification: String?
}

@MainActor
enum ChatPlanRunner {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "ChatPlan")

    /// Asks the model to order the available routes, and accepts only routes it was given.
    ///
    /// The catalogue is built first and passed in; the model chooses from it by id. That
    /// is the whole safety property — a plan can only contain capabilities that already
    /// resolved as real, so a hallucinated step becomes a rejected id rather than an
    /// attempted action.
    static func plan(
        query: String,
        routes: [ChatRoute],
        provider: AIProvider,
        apiKey: String?
    ) async -> ChatPlan? {
        guard routes.count > 1 else { return nil }

        let catalogue = routes.enumerated().map { index, route in
            "\(index). id=\(route.id) | \(route.title) | \(route.appName) | "
                + "\(route.kind.routeLabel)\(route.isReadOnly ? " | read-only" : " | changes things")"
        }.joined(separator: "\n")

        let prompt = """
            The user asked: "\(query)"

            These are the only capabilities available. You may not invent others:
            \(catalogue)

            If this request needs several of them in order, reply with ONLY this JSON:
            {"plan":[{"id":"<exact id>","purpose":"<why, one short line>"}],"summary":"<one line>"}

            Rules:
            - Use ids exactly as written above. An id not in the list will be rejected.
            - At most \(ChatPlan.maxSteps) steps, in the order they must happen.
            - If one capability alone answers the request, reply with {"plan":[]}.
            - Reply with the JSON and nothing else.
            """

        let raw = try? await AIProviderService.shared.sendMessage(
            prompt, context: .none, provider: provider, apiKey: apiKey,
            conversationHistory: [], surfaceScoped: true)
        guard let raw else { return nil }

        guard let range = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
            let data = String(raw[range]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawSteps = object["plan"] as? [[String: Any]],
            !rawSteps.isEmpty
        else { return nil }

        let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        var steps: [ChatPlanStep] = []
        for entry in rawSteps.prefix(ChatPlan.maxSteps) {
            guard let id = entry["id"] as? String, let route = byID[id] else {
                // A step naming something that does not exist invalidates the plan rather
                // than being skipped: the model was reasoning about a capability it does
                // not have, so the rest of its order cannot be trusted either.
                log.notice("plan rejected: unknown route id \(String(describing: entry["id"]), privacy: .public)")
                return nil
            }
            steps.append(
                ChatPlanStep(route: route, purpose: entry["purpose"] as? String ?? route.title))
        }
        guard steps.count > 1 else { return nil }
        return ChatPlan(
            steps: steps, summary: object["summary"] as? String ?? "Several steps")
    }

    /// Runs the plan in order, stopping at the first failure.
    ///
    /// Later steps assume earlier ones happened; running them after a failure produces
    /// confident nonsense, which is worse than stopping short and saying where it stopped.
    /// - Parameter authorizedBundleIds: the apps this conversation may act on, lowercased.
    ///   Nil means unchecked, which is right for replaying a saved recipe: its steps were
    ///   authorized when it was recorded, and the thread replaying it may be a different
    ///   one. The chat path always passes a set, because that is where a plan is composed
    ///   fresh from a model's ordering.
    static func run(
        _ plan: ChatPlan, query: String, authorizedBundleIds: Set<String>? = nil
    ) async -> [ChatPlanStepResult] {
        var results: [ChatPlanStepResult] = []

        for (index, step) in plan.steps.enumerated() {
            // Re-checked here, not only when the plan was built. The catalogue is what the
            // model was allowed to order; this is what it is allowed to run, and the two
            // being the same is an invariant worth asserting rather than assuming.
            if let authorizedBundleIds,
                !authorizedBundleIds.contains(step.route.bundleId.lowercased())
            {
                log.notice(
                    "step \(index + 1, privacy: .public) refused: \(step.route.bundleId, privacy: .public) is outside this chat")
                results.append(
                    ChatPlanStepResult(
                        id: step.id, step: step, success: false,
                        output:
                            "\(step.route.appName) is not part of this conversation, so that "
                            + "step was not run. Attach it to this chat if you want it "
                            + "included.",
                        verification: nil))
                break
            }

            let scope = GeneralChatScope.app(bundleId: step.route.bundleId)
            log.notice(
                "step \(index + 1, privacy: .public)/\(plan.steps.count, privacy: .public): \(step.route.title, privacy: .public)")

            let before = ContextResolver.resolve(scope: scope, appName: step.route.appName)
            let rowID = ChatConsoleLog.shared.begin(
                .route,
                title: "step \(index + 1)/\(plan.steps.count) · \(step.route.title)",
                scope: scope)

            // Earlier output is context for this step: "email it" needs to know what "it"
            // resolved to two steps ago.
            let carried = results
                .filter { !$0.output.isEmpty }
                .map { "\($0.step.route.title): \($0.output.prefix(500))" }
                .joined(separator: "\n")
            let stepQuery = carried.isEmpty
                ? query : "\(query)\n\nAlready done:\n\(carried)"

            let outcome = await ChatRouteResolver.run(step.route, query: stepQuery)

            var verification: String?
            if outcome.success, !step.route.isReadOnly {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let after = ContextResolver.resolve(scope: scope, appName: step.route.appName)
                let changes = after.changes(since: before)
                verification = changes.isEmpty
                    ? "No observable change." : changes.joined(separator: "\n")
            }

            ChatConsoleLog.shared.finish(
                rowID,
                output: [outcome.output, verification]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: "\n")
                    .ifEmpty("(no output)"),
                success: outcome.success,
                scope: scope)

            results.append(
                ChatPlanStepResult(
                    id: step.id, step: step, success: outcome.success,
                    output: outcome.output, verification: verification))

            guard outcome.success else {
                log.notice("plan stopped at step \(index + 1, privacy: .public)")
                break
            }
        }
        return results
    }

    /// Every step ran *and* left something to show for it.
    ///
    /// Stricter than "no step failed" on purpose. This is what decides whether the plan is
    /// announced as done and whether it is offerable as a saved recipe, and a sequence
    /// whose steps changed nothing observable is not one to keep under a name that says it
    /// works.
    static func fullyConfirmed(_ plan: ChatPlan, results: [ChatPlanStepResult]) -> Bool {
        results.count == plan.steps.count
            && results.allSatisfy { $0.success && $0.verification != "No observable change." }
    }

    /// A receipt the user can read without opening the console: what ran, in order, and
    /// where it stopped if it did.
    static func receipt(_ plan: ChatPlan, results: [ChatPlanStepResult]) -> String {
        var lines: [String] = []
        for (index, result) in results.enumerated() {
            // A step that changes things, reports success, and leaves nothing observably
            // different is not a clean tick. The executor's word is that the command ran;
            // it is not evidence the thing happened, and a ✓ next to "nothing observable
            // changed" invites the user to read the first and ignore the second.
            let changedNothing = result.verification == "No observable change."
            let mark = result.success ? (changedNothing ? "?" : "✓") : "✗"
            lines.append("\(mark) \(index + 1). \(result.step.purpose) — `\(result.step.route.title)`")
            if changedNothing {
                lines.append("   ran, but nothing observable changed — treat as unconfirmed")
            }
        }
        if results.count < plan.steps.count {
            let remaining = plan.steps[results.count...].map(\.purpose)
            lines.append("")
            lines.append("Stopped there. Not attempted: " + remaining.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    fileprivate func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
