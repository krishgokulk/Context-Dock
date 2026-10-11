// ShortcutsTool.swift
// Context-Dock
//
// `list_shortcuts` and `run_shortcut`: the model's reach into the user's Shortcuts app.
//
// Listing is read-only and needs no approval. Running is a write with side effects, so it always
// asks: the same approval sheet as every other write tool, naming the shortcut and any input.
// The name must exactly match a listed shortcut (checked before the sheet appears, so the user is
// never asked to approve something that cannot run), and an unattended MCP caller is refused
// without asking. One entry point per tool — `runListShortcuts`, `runRunShortcut` — serves the
// in-app agent and the DoraX MCP server. Rules and the process live in ShortcutsService.
//
// Privacy: shortcut names and outputs stay on this Mac unless the model turn already carries
// them; nothing here sends them anywhere. Nothing runs without the user's approval.

import Foundation

extension AgentToolRegistry {

    func registerShortcutsTools() {
        register(
            AgentTool(
                name: "list_shortcuts",
                description: "List the names of the user's shortcuts in the Shortcuts app. "
                    + "Read-only. Call it before run_shortcut, and for \"what shortcuts do I "
                    + "have\".",
                properties: [:],
                required: []
            ) { _, _ in
                let (success, text) = await AgentToolRegistry.runListShortcuts()
                return AgentToolResult(
                    success: success,
                    output: success ? UntrustedContent.fenced(text, from: "the Shortcuts app") : text,
                    displayCommand: "list_shortcuts")
            })

        register(
            AgentTool(
                name: "run_shortcut",
                description: "Run one of the user's shortcuts from the Shortcuts app. The name "
                    + "must match one from list_shortcuts (case does not matter). When the user says "
                    + "\"run make pdf shortcut\", call list_shortcuts first, find the listed name "
                    + "they mean and pass exactly that; if none fits, offer the closest names "
                    + "and do not run anything. This is the tool for \"run <name> shortcut\": "
                    + "never open the Shortcuts app or use its menus for that. The user approves each run "
                    + "and sees the name and any input. Optional 'input' is short text passed "
                    + "to the shortcut. Returns what the shortcut printed (or that it ran with "
                    + "no output) and the exit status; a shortcut that fails is a failed step. "
                    + "Never run a shortcut the user did not ask for.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "The shortcut's name, exactly as list_shortcuts shows it.",
                    ],
                    "input": [
                        "type": "string",
                        "description": "Optional short text input for the shortcut.",
                    ],
                ],
                required: ["name"]
            ) { arguments, context in
                await AgentToolRegistry.runRunShortcut(
                    name: arguments["name"] as? String ?? "",
                    input: arguments["input"] as? String,
                    scope: context.chatScope, attended: true)
            })
    }

    /// The single entry point for listing, for both the in-app tool and the MCP tool.
    static func runListShortcuts(
        runner: @escaping ShortcutsService.Runner = ShortcutsService.systemRunner
    ) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) {
            switch ShortcutsService.allNames(runner: runner) {
            case .success(let names): return (true, ShortcutsService.listReport(names: names))
            case .failure(let refusal): return (false, refusal.localizedDescription)
            }
        }.value
    }

    /// The single entry point for running, for both the in-app tool and the MCP tool.
    ///
    /// `attended` is false for an outside MCP agent: nobody can approve, so nothing runs.
    /// `runner` and `approve` are injected for tests; the defaults are the real `shortcuts` tool
    /// and the shared approval sheet (which itself refuses inside an unattended run).
    @MainActor
    static func runRunShortcut(
        name rawName: String, input rawInput: String?, scope: GeneralChatScope?,
        attended: Bool,
        runner: @escaping ShortcutsService.Runner = ShortcutsService.systemRunner,
        approve: ((AIActionPlan, AICapability) async -> Bool)? = nil
    ) async -> AgentToolResult {
        let requested = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = rawInput?.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = "run_shortcut(\(requested))"

        guard !requested.isEmpty else { return failure(ShortcutsService.Refusal.emptyName, shown) }
        if let input, input.count > ShortcutsService.maxInputCharacters {
            return failure(ShortcutsService.Refusal.inputTooLong, shown)
        }

        guard attended else {
            AICapabilityApprovalCenter.recordUnattendedRefusal(ShortcutsTool.capabilityID)
            return AgentToolResult(
                success: false,
                output: "Running a shortcut needs the user's approval, and this caller is "
                    + "unattended, so nothing ran.",
                displayCommand: shown + " · refused")
        }

        // Refuse an unknown name before asking anyone to approve it.
        let names = await Task.detached(priority: .userInitiated) {
            ShortcutsService.allNames(runner: runner)
        }.value
        let name: String
        switch names {
        case .failure(let refusal): return failure(refusal, shown)
        case .success(let listed):
            guard let exact = ShortcutsService.resolve(requested, in: listed) else {
                return failure(
                    ShortcutsService.Refusal.unknownShortcut(
                        requested, closest: ShortcutsService.closest(to: requested, in: listed)),
                    shown)
            }
            name = exact
        }
        shown = "run_shortcut(\(name))"

        let plan = ShortcutsTool.plan(name: name, input: input)
        let capability = ShortcutsTool.capability()
        let approved: Bool
        if let approve {
            approved = await approve(plan, capability)
        } else {
            approved = await AICapabilityApprovalCenter.shared.requestApproval(
                plan: plan, capability: capability, context: .none, chatScope: scope)
        }
        guard approved else {
            var denied = AgentToolResult(
                success: false,
                output: "The user did not approve running \"\(name)\". Say so and stop.",
                displayCommand: shown + " · declined")
            denied.deniedByUser = true
            return denied
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            ShortcutsService.run(name: name, input: input, runner: runner)
        }.value
        var result = AgentToolResult(
            success: outcome.success,
            // A file path the shortcut prints flows through unchanged, so TurnFileExtractor can
            // draw it as a card.
            output: outcome.text,
            displayCommand: shown)
        result.exitCode = outcome.status
        return result
    }

    private static func failure(_ error: Error, _ shown: String) -> AgentToolResult {
        AgentToolResult(
            success: false, output: error.localizedDescription, displayCommand: shown)
    }
}

/// The approval the sheet shows. High risk: a shortcut can do anything the user has built into
/// it — send messages, move files, call the network — and DoraX cannot see inside it.
enum ShortcutsTool {
    static let capabilityID = "shortcuts.run"

    static func capability() -> AICapability {
        AICapability(
            id: capabilityID,
            title: "Run a shortcut",
            appBundleID: nil,
            inputSchema: .init(fields: []),
            riskLevel: .high,
            runsWithoutAdapter: true,
            executor: { _ in
                throw AICapabilityError.blocked(
                    "Shortcuts are run by run_shortcut, not the registry.")
            })
    }

    static func plan(name: String, input: String?) -> AIActionPlan {
        var fields = ["shortcut": name]
        var explanation = "Run the shortcut \"\(name)\" from the Shortcuts app. DoraX cannot see "
            + "what it does."
        if let input, !input.isEmpty {
            fields["input"] = String(input.prefix(300)) + (input.count > 300 ? "…" : "")
            explanation += "\n\nInput:\n\(input.prefix(300))" + (input.count > 300 ? "…" : "")
        }
        return AIActionPlan(capability: capabilityID, input: fields, explanation: explanation)
    }
}
