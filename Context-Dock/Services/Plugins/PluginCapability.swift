// Context-Dock
//
// A plugin action, described as one of the app's own capabilities. This exists so a plugin
// goes through `AICapabilityApprovalCenter` — the app's single approval surface — rather than
// growing a second sheet beside it, and so the harness can later offer a plugin's `tools` the
// same way it offers everything else.
//
// `runsWithoutAdapter` is the existing flag for a capability that executes itself; the file
// tools already use it. A plugin has no adapter, and claiming one would both hide it from
// every chat and misdescribe how it dispatches.

import Foundation

enum PluginCapability {
    /// `plugin.<pluginID>.<action>` — namespaced, so two plugins declaring `toggle` are two
    /// capabilities rather than one that shadows the other.
    static func id(pluginID: String, action: String) -> String { "plugin.\(pluginID).\(action)" }

    /// The two risk vocabularies meet here and nowhere else. A plugin's `read` is the
    /// registry's `low` (the level that does not require approval); everything above it lands
    /// on a level that does.
    ///
    /// `.critical` is deliberately never produced. `AICapabilityRiskLevel.requiresApproval` is
    /// `self == .medium || self == .high` — critical is NOT in it — so mapping a plugin's
    /// highest risk there would make its most dangerous actions the only ones that skip the
    /// gate on any path that asks the level rather than asking us. Losing the distinction
    /// between a plugin's `medium` and `high` costs a shade of wording on one card; the
    /// alternative costs the gate.
    static func riskLevel(_ risk: PluginRisk) -> AICapabilityRiskLevel {
        switch risk {
        case .read: return .low
        case .low: return .medium
        case .medium, .high: return .high
        }
    }

    static func make(named name: String, manifest: PluginManifest) -> AICapability? {
        guard let action = manifest.actions[name] else { return nil }
        return AICapability(
            id: id(pluginID: manifest.id, action: name),
            title: "\(manifest.name): \(action.title ?? name)",
            appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: [
                AICapabilityInputField(
                    name: "value",
                    description: "What this action acts on — a row id, a control's value, or nothing.",
                    required: false)
            ]),
            riskLevel: riskLevel(action.risk),
            runsWithoutAdapter: true,
            executor: { request in
                let value = request.input["value"].map { PluginValue.string($0) }
                let result = await PluginRuntime.shared.run(
                    PluginActionRequest(name: name, value: value),
                    manifest: manifest, inputs: PluginInputs(), skipApproval: true)
                switch result {
                case .success(let output):
                    return AICapabilityExecutionResult(success: true, output: output)
                case .failure(let failure):
                    return AICapabilityExecutionResult(success: false, output: failure.message)
                }
            })
    }

    /// What the approval card says will happen. The plugin is named because "run toggle" tells
    /// nobody whose toggle it is.
    static func plan(for request: PluginActionRequest, manifest: PluginManifest) -> AIActionPlan {
        var input: [String: String] = [:]
        if let value = request.value {
            input["value"] = value.stringValue ?? String(describing: value)
        }
        let action = manifest.actions[request.name]
        let what = action?.title ?? request.name
        return AIActionPlan(
            capability: id(pluginID: manifest.id, action: request.name),
            input: input,
            explanation: "\(manifest.name) wants to run \"\(what)\".")
    }

    /// The provider `PluginRuntime` asks before anything above read runs. Installed once, at
    /// launch, so a surface cannot forget to install it and get a plugin that silently does
    /// nothing — the default refusal is the floor under that, not the plan.
    @MainActor
    static func installApprovalProvider(on runtime: PluginRuntime = .shared) {
        runtime.approvalProvider = { request, action, manifest in
            guard let capability = make(named: request.name, manifest: manifest) else { return false }
            return await AICapabilityApprovalCenter.shared.requestApproval(
                plan: plan(for: request, manifest: manifest),
                capability: capability,
                context: .none)
        }
    }
}
