// SolvedSkillMatch.swift
// Context-Dock
//
// The before-the-model half of a solved skill: does this sentence already have a saved
// answer, and if so, run it.
//
// Matching is deliberately tight. A solved skill replays tool calls with no model in the loop
// to notice that the sentence meant something else, so a loose match is a wrong answer given
// confidently. The request's non-slot words must equal the skill's exactly — same words, same
// app — before the slots are filled from the new sentence and the calls replayed, each through its
// own executor and gates. Any mismatch, or any failure at run time, returns nil so
// the turn falls through to the model, which is the repair path.

import Foundation
import OSLog

enum SolvedSkillMatch {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "SolvedSkill")

    // MARK: - Match (pure)

    /// The skill whose shape this request fits, with its slots filled from the request, or nil.
    nonisolated static func match(
        query: String,
        bundleId: String,
        skills: [SolvedSkill],
        context: SlotDerivationContext = .empty
    ) -> (SolvedSkill, filled: [String: String])?
    {
        guard let derived = SolvedSkillCapture.derive(
            query: query, bundleId: bundleId, context: context) else { return nil }

        for skill in skills where skill.bundleId == bundleId {
            // Same words, nothing looser. A superset or a near-miss would run the recorded
            // calls under a request they do not answer.
            guard skill.nonSlotWords == derived.nonSlotWords else { continue }

            // The same slots too: a sentence that names a day the skill never took would have
            // that day silently ignored.
            guard Set(derived.values.keys) == Set(skill.slots.map(\.name)) else { continue }
            let filled = derived.values
            return (skill, filled)
        }
        return nil
    }

    // MARK: - Replay route (pure)

    /// Which executor a saved call replays through.
    enum ReplayRoute: Equatable {
        /// A registered capability, through `executeWithApproval`.
        case capability
        /// A menu press (H1b rung 3), through the `run_menu_command` tool.
        case menuCommand
        /// An external connector read (H1b rung 1), saved as `server.tool`.
        case mcpTool(server: String, tool: String)
    }

    /// A saved call is one of three things, and only the first is in the capability registry:
    /// sending the other two there threw `unknownCapability` on every replay.
    nonisolated static func replayRoute(for capability: String, isRegistered: Bool) -> ReplayRoute {
        if capability == "run_menu_command" { return .menuCommand }
        if isRegistered { return .capability }
        // Capture writes `server.tool`, or the bare tool when the model named no server.
        guard let dot = capability.lastIndex(of: ".") else {
            return .mcpTool(server: "", tool: capability)
        }
        return .mcpTool(
            server: String(capability[..<dot]),
            tool: String(capability[capability.index(after: dot)...]))
    }

    /// What a replay reaches outside this file. A struct of closures so a test can stand in
    /// for the approval card and the tool handlers.
    struct ReplayEnvironment {
        var isRegistered: @MainActor (_ capabilityID: String) -> Bool
        var mcpToolIsLinked: @MainActor (_ bundleId: String, _ tool: String) async -> Bool
        var approve: @MainActor (AIActionPlan, AICapability, GeneralChatScope) async -> Bool
        /// Runs a registered agent tool's handler directly — not `dispatch`, which would
        /// re-record the call into the collector. Nil when no such tool is registered.
        var runTool: @MainActor (_ name: String, _ arguments: [String: Any], GeneralChatScope)
            async -> AgentToolResult?

        static let live = ReplayEnvironment(
            isRegistered: { CapabilityRegistry.shared.capability(id: $0) != nil },
            mcpToolIsLinked: { bundleId, tool in
                await MCPRuntime.shared.tools(forBundleId: bundleId)
                    .contains { $0.tool.name == tool }
            },
            approve: { plan, capability, scope in
                await AICapabilityApprovalCenter.shared.requestApproval(
                    plan: plan, capability: capability, context: .none, chatScope: scope)
            },
            runTool: { name, arguments, scope in
                await AgentToolRegistry.shared.tool(named: name)?.handler(
                    arguments,
                    AgentToolContext(
                        commandExecutor: { _, _, _ in (false, "", 1) }, chatScope: scope))
            })
    }

    // MARK: - Run (wired)

    /// Replays the skill's calls with the slots filled, each through the gate the model's own
    /// call would meet: a capability through `executeWithApproval` and its read-back, a menu
    /// press through the `run_menu_command` tool (its own plan card, menu authority and window
    /// read-back), an external MCP read through an approval card and then the `run_mcp_tool`
    /// tool (app access, linked-server and read-only checks). Returns the answer, or nil on any
    /// failure or refusal so the caller runs the model instead.
    ///
    /// ponytail: the capability route inlines the scope check and read-back rather than
    /// dispatching `run_capability`; the dispatch output carries model-facing text (#316) and
    /// would re-record into the collector. Reroute through the registry in a follow-up.
    @MainActor
    static func run(
        _ skill: SolvedSkill, filled: [String: String], scope: GeneralChatScope,
        environment: ReplayEnvironment = .live
    ) async -> AppScopedChatService.Answer? {
        // The thread's boundary, as `run_capability` enforces it: a skill never replays
        // under another app's chat.
        guard case .app(let bundleId) = scope, skill.bundleId == bundleId else { return nil }

        var receipts: [DoraXActionReceipt] = []
        var outputs: [String] = []

        for call in skill.toolCalls {
            let input = call.argTemplate.mapValues { template -> String in
                var value = template
                for (slot, fill) in filled {
                    value = value.replacingOccurrences(of: "{\(slot)}", with: fill)
                }
                return value
            }
            guard let output = await replay(
                call, input: input, skill: skill, scope: scope, bundleId: bundleId,
                environment: environment)
            else {
                SolvedSkillStore.shared.markRun(id: skill.id, success: false)
                return nil
            }
            receipts.append(
                DoraXActionReceipt(command: call.capability, output: output, success: true))
            if !output.isEmpty { outputs.append(output) }
        }

        SolvedSkillStore.shared.markRun(id: skill.id, success: true)
        return AppScopedChatService.Answer(
            text: outputs.joined(separator: "\n\n"),
            toolChips: skill.toolCalls.map(\.capability),
            evidenceReceipts: receipts,
            trace: ["Used saved skill (no model)"])
    }

    /// One saved call, through its route. The user-facing output, or nil if it did not run.
    @MainActor
    private static func replay(
        _ call: SolvedSkillToolCall, input: [String: String], skill: SolvedSkill,
        scope: GeneralChatScope, bundleId: String, environment: ReplayEnvironment
    ) async -> String? {
        switch replayRoute(
            for: call.capability, isRegistered: environment.isRegistered(call.capability))
        {
        case .capability:
            let result: AICapabilityExecutionResult
            do {
                result = try await AIExecutionEngine.shared.executeWithApproval(
                    AIActionPlan(
                        capability: call.capability,
                        input: input,
                        explanation: "Saved skill"),
                    context: .none,
                    chatScope: scope,
                    userRequest: skill.queryTemplate)
            } catch {
                log.notice("saved skill run failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            guard result.success else { return nil }
            // Read it back, as the model's path does. A contradicted or unconfirmed read means
            // the saved calls no longer answer the sentence; let the model repair it.
            switch await GeneralAIActionExecutor.shared.verifyCapability(
                id: call.capability, inputValues: input)
            {
            case .verified, .notApplicable: return result.output
            case .contradicted, .unverified: return nil
            }

        case .menuCommand:
            // The tool asks for itself (`approval: .ask`) and reads the windows back, so no
            // second card and no `verifyCapability`, which knows nothing of menu items.
            guard let result = await environment.runTool("run_menu_command", input, scope),
                result.success
            else { return nil }
            // `output` is written for the model (#316); the reading is what the user sees.
            return result.verifiedByReadBack
                ?? result.userFacingAnswer(fallback: "Done — \(input["path"] ?? "menu command").")

        case .mcpTool(let server, let tool):
            // Checked before the card so the user is never asked to approve a call that cannot
            // run: a write (never saved, but the file is editable), or a server since unlinked.
            guard MCPToolSafety.isClearlyReadOnly(name: tool),
                await environment.mcpToolIsLinked(bundleId, tool)
            else { return nil }
            let title = server.isEmpty ? "Read with \(tool)" : "Read \(server) with \(tool)"
            let approved = await environment.approve(
                AIActionPlan(
                    capability: call.capability, input: input,
                    explanation: "Saved skill: \(title.lowercased()), with no model call."),
                AICapability(
                    id: call.capability, title: title, appBundleID: bundleId,
                    inputSchema: .init(fields: []), riskLevel: .medium,
                    executor: { _ in .init(success: true, output: "") }),
                scope)
            guard approved,
                let result = await environment.runTool(
                    "run_mcp_tool", ["server": server, "tool": tool, "arguments": input], scope),
                result.success
            else { return nil }
            // A connector read's output is the data itself, and the read is its own evidence.
            return result.output
        }
    }
}
