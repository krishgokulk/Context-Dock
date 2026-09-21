// AppAgentScriptTool.swift
// Context-Dock
//
// Running what an app's profile declares.
//
// The last rung of the profile: an app can carry its own scripts, and a chat scoped to that app
// can run them — after the user has approved this one, naming the file and the app on the card.
// Everything about *whether* it may run is decided in `AppAgentScript`; this is the part that
// asks, runs, and reports what came back.

import AppKit
import Foundation

extension AgentToolRegistry {

    func registerAppAgentScriptTool() {
        register(
            AgentTool(
                name: "run_app_script",
                description: "Run one of the scripts this app's profile declares (AGENT.md "
                    + "`scripts:`). Use only a name listed there; the user approves each run. "
                    + "The script is told CD_APP_NAME, CD_BUNDLE_ID, CD_QUERY and, when there "
                    + "is one, CD_SELECTION. Its stdout is the result.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "The script's file name, exactly as the profile declares "
                            + "it — e.g. \"tabs-to-md.sh\". Not a path.",
                    ],
                    "reason": [
                        "type": "string",
                        "description": "One line the user reads on the approval card.",
                    ],
                ],
                required: ["name"]
            ) { arguments, context in
                let name = (arguments["name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = (arguments["reason"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return await AppAgentScriptRunner.run(
                    name: name, reason: reason, scope: context.chatScope,
                    query: context.userRequest)
            })
    }
}

@MainActor
enum AppAgentScriptRunner {

    static func run(
        name: String, reason: String, scope: GeneralChatScope?, query: String
    ) async -> AgentToolResult {
        guard let bundleID = AgentToolRegistry.scopedBundleID(for: scope), !bundleID.isEmpty
        else {
            return AgentToolResult(
                success: false,
                output: "This conversation is not scoped to one app, and a script belongs to an "
                    + "app's profile. Ask in that app's own chat.",
                displayCommand: "run_app_script(\(name))")
        }
        let appName = InstalledApplicationsCatalog.cachedInstalledApps()
            .first { $0.bundleId.caseInsensitiveCompare(bundleID) == .orderedSame }?.name
            ?? bundleID

        let store = AppAgentProfileStore.shared
        guard let profile = store.profile(forBundleID: bundleID, appName: appName) else {
            return AgentToolResult(
                success: false,
                output: "\(appName) has no AGENT.md, so it declares no scripts. Say that rather "
                    + "than looking for a file to run.",
                displayCommand: "run_app_script(\(name))")
        }

        let scriptsRoot = store.fileURL(forBundleID: bundleID)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolved = AppAgentScript.resolve(
            name: name, declared: profile.tools.scripts ?? [], bundleID: bundleID,
            root: scriptsRoot)

        let url: URL
        switch resolved {
        case .success(let found):
            url = found
        case .failure(let refusal):
            return AgentToolResult(
                success: false, output: refusal.message,
                displayCommand: "run_app_script(\(name)) · refused")
        }

        // Approved per run, on the same card every other approval uses. A script is the app's
        // own code, which is a reason to keep it and not a reason to run it unasked.
        let approved = await AICapabilityApprovalCenter.shared.requestApproval(
            plan: AIActionPlan(
                capability: "appAgent.runScript",
                input: ["app": appName, "script": name, "path": url.path],
                explanation: reason.isEmpty
                    ? "Run \(appName)'s own script \(name)."
                    : "Run \(appName)'s own script \(name).\n\n\(reason)"),
            capability: AICapability(
                id: "appAgent.runScript",
                title: "Run \(name)",
                appBundleID: bundleID,
                inputSchema: .init(fields: []),
                riskLevel: .high,
                runsWithoutAdapter: true,
                executor: { _ in
                    throw AICapabilityError.blocked(
                        "App scripts run through AppAgentScriptRunner, not the registry.")
                }),
            context: .appFocused(name: appName, bundleID: bundleID),
            chatScope: scope)
        guard approved else {
            return AgentToolResult(
                success: false,
                output: "The user did not approve \(name). Say so and stop.",
                displayCommand: "run_app_script(\(name)) · declined")
        }

        let selection = AXContextReader.shared.current.selectedFilePaths
            .map(URL.init(fileURLWithPath:))
        let environment = AppAgentScript.environment(
            appName: appName, bundleID: bundleID, query: query, selection: selection)

        // The plugin runner is an actor with no shared instance — one per call is right here
        // too: a script run is a one-shot, and nothing is cached between them.
        let result = await PluginScriptRunner().run(
            type: .scriptFile,
            script: url.lastPathComponent,
            env: environment,
            timeout: 60,
            workingDirectory: url.deletingLastPathComponent().path)

        switch result {
        case .success(let run):
            let output = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let errors = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = run.exitCode == 0
            return AgentToolResult(
                success: succeeded,
                output: succeeded
                    ? (output.isEmpty ? "\(name) ran and printed nothing." : output)
                    : "\(name) exited \(run.exitCode)."
                        + (errors.isEmpty ? "" : "\n\(errors)"),
                displayCommand: "run_app_script(\(appName): \(name))",
                exitCode: run.exitCode,
                stdout: run.stdout,
                stderr: run.stderr)
        case .failure(let failure):
            return AgentToolResult(
                success: false,
                output: "\(name) did not run — \(failure.message)",
                displayCommand: "run_app_script(\(appName): \(name)) · failed")
        }
    }
}
