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
// rather than attempted. Approval gates are untouched, and a failed step stops the plan
// instead of letting later steps run on a false premise.
//
// Steps declare which earlier steps they need, so the plan is a DAG rather than a list:
// "find the file" and "look up the contact" both run while the send that needs both waits.
// Overlap is allowed only for work that stays off the screen, because this orchestrates
// one physical Mac session — see ChatPlanStep.isConcurrencySafe.

import Foundation
import OSLog

struct ChatPlanStep: Identifiable, Equatable {
    let id = UUID()
    /// The resolved route this step runs. Never a free-text command.
    let route: ChatRoute
    /// Why this step is in the plan, in the user's terms — shown while it runs.
    let purpose: String
    /// Indices of the earlier steps whose results this one needs.
    ///
    /// A list is a graph in which every step depends on the one before it, which is what
    /// this was: "find the file" and "find the contact" were run one after the other
    /// because they were written in that order, not because either needed the other.
    /// Restricted to earlier indices, so a plan is a DAG by construction and no cycle
    /// check is needed.
    var dependsOn: [Int] = []

    /// Whether this step can overlap with another. False for anything that touches the
    /// screen.
    ///
    /// DoraX orchestrates one physical Mac session, not isolated cloud functions. Two
    /// menu commands running at once fight over which app is frontmost and which window
    /// has focus, and the loser silently acts on the wrong thing. Only work that stays off
    /// the screen — a subprocess, an MCP call, a model turn — and changes nothing may
    /// overlap.
    var isConcurrencySafe: Bool {
        guard route.isReadOnly else { return false }
        switch route.kind {
        case .cli, .mcpTool, .model: return true
        case .menuCommand, .adapterAction, .skill: return false
        }
    }
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

            If this request needs several of them, reply with ONLY this JSON:
            {"plan":[{"id":"<exact id>","purpose":"<why, one short line>","after":[<step numbers this one needs>]}],"summary":"<one line>"}

            Rules:
            - Use ids exactly as written above. An id not in the list will be rejected.
            - At most \(ChatPlan.maxSteps) steps.
            - "after" lists the 0-based positions of earlier steps whose RESULTS this step
              needs. Use [] when it needs nothing — two searches that do not read each
              other are both []. Only list a step you genuinely depend on: "find the file"
              and "look up the contact" are independent even though the send that follows
              needs both.
            - Omit "after" entirely if you are unsure; it will be treated as depending on
              the step before it.
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
        for (index, entry) in rawSteps.prefix(ChatPlan.maxSteps).enumerated() {
            guard let id = entry["id"] as? String, let route = byID[id] else {
                // A step naming something that does not exist invalidates the plan rather
                // than being skipped: the model was reasoning about a capability it does
                // not have, so the rest of its order cannot be trusted either.
                log.notice("plan rejected: unknown route id \(String(describing: entry["id"]), privacy: .public)")
                return nil
            }
            // Only earlier steps, so the plan is a DAG whatever the model wrote. Anything
            // else — a forward reference, itself, a number that is not a step — is dropped
            // rather than rejected: the ordering is still usable, and falling back to "the
            // step before" is the behaviour this had before dependencies existed.
            let declared = entry["after"] as? [Int]
            let dependsOn: [Int] = {
                guard let declared else { return index > 0 ? [index - 1] : [] }
                let valid = declared.filter { $0 >= 0 && $0 < index }
                return valid.sorted()
            }()
            steps.append(
                ChatPlanStep(
                    route: route,
                    purpose: entry["purpose"] as? String ?? route.title,
                    dependsOn: dependsOn))
        }
        guard steps.count > 1 else { return nil }
        return ChatPlan(
            steps: steps, summary: object["summary"] as? String ?? "Several steps")
    }

    /// Runs the plan in dependency order, stopping at the first failure.
    ///
    /// Later steps assume earlier ones happened; running them after a failure produces
    /// confident nonsense, which is worse than stopping short and saying where it stopped.
    /// Results come back in the order they ran, so the receipt reads as what happened.
    /// - Parameter authorizedBundleIds: the apps this conversation may act on, lowercased.
    ///   Nil means unchecked, which is right for replaying a saved recipe: its steps were
    ///   authorized when it was recorded, and the thread replaying it may be a different
    ///   one. The chat path always passes a set, because that is where a plan is composed
    ///   fresh from a model's ordering.
    static func run(
        _ plan: ChatPlan, query: String, authorizedBundleIds: Set<String>? = nil
    ) async -> [ChatPlanStepResult] {
        var completed: [Int: ChatPlanStepResult] = [:]
        var order: [Int] = []
        var stopped = false

        // Waves rather than a straight walk. A step becomes runnable when the steps it
        // named have finished; steps that named nothing are runnable immediately, which is
        // what lets two independent searches happen at once instead of one after the
        // other because of the order they were written in.
        while !stopped, completed.count < plan.steps.count {
            let ready = plan.steps.indices.filter { index in
                completed[index] == nil
                    && plan.steps[index].dependsOn.allSatisfy { completed[$0]?.success == true }
            }
            // Nothing runnable and nothing running means the rest depended on a step that
            // failed. Leave them unattempted; the receipt names them.
            guard !ready.isEmpty else { break }

            // Only a wave that is entirely off-screen work runs together. One menu command
            // in it and the whole wave goes one at a time, because the cost of guessing
            // wrong is two apps fighting over the front window.
            let canOverlap = ready.count > 1 && ready.allSatisfy { plan.steps[$0].isConcurrencySafe }
            let wave = canOverlap ? ready : [ready[0]]
            if canOverlap {
                log.notice("wave of \(wave.count, privacy: .public) running together")
            }

            var waveResults: [(index: Int, result: ChatPlanStepResult)] = []
            if wave.count == 1 {
                let index = wave[0]
                waveResults.append(
                    (index,
                     await runStep(
                        at: index, in: plan, query: query, completed: completed,
                        authorizedBundleIds: authorizedBundleIds)))
            } else {
                waveResults = await withTaskGroup(
                    of: (Int, ChatPlanStepResult).self
                ) { group in
                    for index in wave {
                        let snapshot = completed
                        group.addTask { @MainActor in
                            (index,
                             await runStep(
                                at: index, in: plan, query: query, completed: snapshot,
                                authorizedBundleIds: authorizedBundleIds))
                        }
                    }
                    var collected: [(index: Int, result: ChatPlanStepResult)] = []
                    for await pair in group { collected.append((pair.0, pair.1)) }
                    return collected.sorted { $0.index < $1.index }
                }
            }

            for (index, result) in waveResults {
                completed[index] = result
                order.append(index)
                if !result.success { stopped = true }
            }
        }

        return order.compactMap { completed[$0] }
    }

    /// Runs one step: authorization, the route, and the read-back that decides whether it
    /// may be called done.
    private static func runStep(
        at index: Int, in plan: ChatPlan, query: String,
        completed: [Int: ChatPlanStepResult], authorizedBundleIds: Set<String>?
    ) async -> ChatPlanStepResult {
        let step = plan.steps[index]

        // Re-checked here, not only when the plan was built. The catalogue is what the
        // model was allowed to order; this is what it is allowed to run, and the two
        // being the same is an invariant worth asserting rather than assuming.
        if let authorizedBundleIds,
            !authorizedBundleIds.contains(step.route.bundleId.lowercased())
        {
            log.notice(
                "step \(index + 1, privacy: .public) refused: \(step.route.bundleId, privacy: .public) is outside this chat")
            return ChatPlanStepResult(
                id: step.id, step: step, success: false,
                output:
                    "\(step.route.appName) is not part of this conversation, so that step "
                    + "was not run. Attach it to this chat if you want it included.",
                verification: nil)
        }

        let scope = GeneralChatScope.app(bundleId: step.route.bundleId)
        log.notice(
            "step \(index + 1, privacy: .public)/\(plan.steps.count, privacy: .public): \(step.route.title, privacy: .public)")

        let before = ContextResolver.resolve(scope: scope, appName: step.route.appName)
        let rowID = ChatConsoleLog.shared.begin(
            .route,
            title: "step \(index + 1)/\(plan.steps.count) · \(step.route.title)",
            scope: scope)

        // What this step was told, rather than everything that happened. "Email it" needs
        // the search that found "it"; handing it the unrelated branch of the plan as well
        // invites the model to answer about the wrong result.
        let carried = dependencyClosure(of: index, in: plan)
            .compactMap { completed[$0] }
            .filter { !$0.output.isEmpty }
            .map { "\($0.step.route.title): \($0.output.prefix(500))" }
            .joined(separator: "\n")
        let stepQuery = carried.isEmpty ? query : "\(query)\n\nAlready done:\n\(carried)"

        let outcome = await ChatRouteResolver.run(step.route, query: stepQuery)

        var verification: String?
        var succeeded = outcome.success
        if outcome.success, !step.route.isReadOnly {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let after = ContextResolver.resolve(scope: scope, appName: step.route.appName)
            let changes = after.changes(since: before)
            verification = changes.isEmpty
                ? "No observable change." : changes.joined(separator: "\n")

            // A change is not the same as the *right* change. Quitting Safari through its
            // own menu launched Safari to reach the menu, so the verifier truthfully
            // reported "app state: not running → running" — and the step, seeing that
            // something had changed, called itself done. The receipt then showed a tick
            // above a line saying the opposite.
            if let violation = Self.intentViolation(step: step, after: after) {
                verification = violation
                succeeded = false
            }
        }

        ChatConsoleLog.shared.finish(
            rowID,
            output: [outcome.output, verification]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "\n")
                .ifEmpty("(no output)"),
            success: succeeded,
            scope: scope)

        if !succeeded {
            log.notice("plan stopped at step \(index + 1, privacy: .public)")
        }
        return ChatPlanStepResult(
            id: step.id, step: step, success: succeeded,
            output: outcome.output, verification: verification)
    }

    /// Every step this one transitively needs, earliest first.
    private static func dependencyClosure(of index: Int, in plan: ChatPlan) -> [Int] {
        var seen = Set<Int>()
        var stack = plan.steps[index].dependsOn
        while let next = stack.popLast() {
            guard plan.steps.indices.contains(next), seen.insert(next).inserted else { continue }
            stack += plan.steps[next].dependsOn
        }
        return seen.sorted()
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

    /// The end state a step's own words promise, checked against what actually happened.
    ///
    /// Only claims worth checking are checked. "Quit" and "close" say plainly that the app
    /// should not be running afterwards, and that is exactly the case where acting through
    /// the app's own menu can launch it to get there. Everything else returns nil rather
    /// than inventing a criterion it cannot justify.
    static func intentViolation(step: ChatPlanStep, after: ResolvedContext) -> String? {
        let title = step.route.title.lowercased()
        let quits = title.contains("quit") || title.hasPrefix("close ")
        guard quits else { return nil }
        guard after.value("app state") == "running" else { return nil }
        return "\(step.route.appName) is still running — the step said it quit, and it did not."
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
