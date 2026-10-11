import Foundation

/// Carries out a capability call the model wrote as text, or says exactly why it did not run.
///
/// A model that is handed a capability id sometimes answers with `{"finder.copyFiles": {…}}`
/// instead of calling the tool. The surface must never show that JSON, so it either runs the
/// call or reports it. Until this existed the window ran it (inline, in `AppScopedChatService`)
/// and the Dock / Corner did not: their final-text recovery handled menu, adapter and
/// operate-app calls and returned nothing for a capability, so the bubble was replaced by "I
/// worked out what to run but couldn't carry it out on this surface" — no reason, and nothing
/// run. One function now serves every surface, so a fix lands once.
///
/// The call goes through the same executor every other capability uses
/// (`AIExecutionEngine.executeWithApproval`), so a risky capability still raises its approval
/// card and a refused one still names its reason. It does not go through
/// `AgentToolRegistry.dispatch`, where the outbound gate lives, so `run` asks the gate itself
/// before executing a send-like capability: the turn that wrote the call is over, so its taint
/// is unknown and read as "touched everything" (fail closed).
@MainActor
enum ChatCapabilityCallRecovery {
    struct Outcome: Equatable {
        /// What replaces the JSON in the transcript. Never empty, never protocol.
        let text: String
        /// Whether the capability actually ran and reported success.
        let succeeded: Bool
        /// The raw output, for the console record. Empty when nothing ran.
        let output: String
    }

    /// Runs `capabilityID` with `arguments`.
    ///
    /// - `scope` is the authorisation boundary (`CapabilityAuthorizationGate`): a frontmost-app
    ///   chat may not run another app's capability from a line of text.
    static func run(
        capabilityID: String,
        arguments: [String: String],
        query: String,
        context: UserContext,
        scope: AIConversationScope,
        chatScope: GeneralChatScope?
    ) async -> Outcome {
        await run(
            capabilityID: capabilityID,
            arguments: arguments,
            query: query,
            scope: scope,
            lookup: { id in
                CapabilityRegistry.shared.capability(id: id).map { capability in
                    (
                        title: capability.title,
                        requiredInputs: capability.inputSchema.fields
                            .filter(\.required).map(\.name)
                    )
                }
            },
            outboundGate: { id, input in
                let registry = AgentToolRegistry.shared
                guard let target = OutboundGate.capabilityTarget(
                    id: id, input: input, lookups: registry.outboundLookups)
                else { return nil }
                return await registry.gateOutbound(
                    target: target, what: "run_capability: \(id)", turn: nil,
                    chatScope: chatScope)
            },
            execute: { plan in
                try await AIExecutionEngine.shared.executeWithApproval(
                    plan, context: context, chatScope: chatScope, userRequest: query)
            })
    }

    /// The decision with its collaborators passed in, so a test owns its own registry and
    /// executor instead of driving the process-wide ones.
    ///
    /// - `lookup` returns the capability's display title and the inputs it cannot run
    ///   without, or nil when it is not registered.
    /// - `outboundGate` is the host's outbound check for (capability id, input): nil lets the
    ///   call go ahead, a result stops it. The real entry point always supplies it; a test that
    ///   is not about the gate may leave it out.
    static func run(
        capabilityID: String,
        arguments: [String: String],
        query: String,
        scope: AIConversationScope,
        lookup: (String) -> (title: String, requiredInputs: [String])?,
        outboundGate: ((String, [String: String]) async -> AgentToolResult?)? = nil,
        execute: (AIActionPlan) async throws -> AICapabilityExecutionResult
    ) async -> Outcome {
        let id = capabilityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return Outcome(
                text: "I tried to run something but didn't name what.",
                succeeded: false, output: "")
        }
        guard let found = lookup(id) else {
            // An id nothing registered. Left alone the JSON was stripped as scaffolding and
            // the user got an empty bubble — which reads as the app having nothing to say.
            return Outcome(
                text: "I tried to run `\(id)`, which isn't a capability on this Mac.",
                succeeded: false, output: "")
        }

        let displayTitle = found.title

        // Checked before the approval card is raised: asking the user to approve a copy that
        // has nowhere to copy to teaches them the card means nothing, and the executor would
        // only fail on it afterwards. This is the case a sentence like "resume 2026 folder"
        // produces — a call with no destination.
        let missing = found.requiredInputs.filter {
            (arguments[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !missing.isEmpty {
            return Outcome(
                text: "\(displayTitle) needs \(Self.list(missing)) before it can run, and "
                    + "\(missing.count == 1 ? "that wasn't" : "those weren't") in the request. "
                    + "Tell me \(missing.count == 1 ? "it" : "them") and I'll run it.",
                succeeded: false, output: "")
        }

        let plan = AIActionPlan(
            capability: id, input: arguments, explanation: "Requested in chat: \(query)")
        do {
            try CapabilityAuthorizationGate.validatePlan(plan, scope: scope)
            if let stopped = await outboundGate?(id, arguments) {
                if stopped.deniedByUser {
                    return Outcome(
                        text: "\(displayTitle) wasn't approved, so nothing ran.",
                        succeeded: false, output: "")
                }
                return Outcome(
                    text: "\(displayTitle) didn't run — \(stopped.output)",
                    succeeded: false, output: stopped.output)
            }
            let result = try await execute(plan)
            if result.success {
                return Outcome(
                    text: result.output.isEmpty ? "Done — \(displayTitle)." : result.output,
                    succeeded: true, output: result.output)
            }
            let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(
                text: reason.isEmpty
                    ? "\(displayTitle) didn't run."
                    : "\(displayTitle) didn't run — \(reason)",
                succeeded: false, output: result.output)
        } catch is CancellationError {
            // The user pressed stop. Not a failure to explain, and not a reason to leave the
            // turn open: the caller still ends it, with an answer that says nothing ran.
            return Outcome(
                text: "Stopped — \(displayTitle) did not run.", succeeded: false, output: "")
        } catch let error as AICapabilityError {
            if case .approvalRequired = error {
                // A "no" is an answer, not a failure: nothing changed, and saying so is the
                // whole report.
                return Outcome(
                    text: "\(displayTitle) wasn't approved, so nothing ran.",
                    succeeded: false, output: "")
            }
            return Outcome(
                text: "\(displayTitle) didn't run — \(error.localizedDescription)",
                succeeded: false, output: "")
        } catch {
            return Outcome(
                text: "\(displayTitle) didn't run — \(error.localizedDescription)",
                succeeded: false, output: "")
        }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "a \(names[0])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
