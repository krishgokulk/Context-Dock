// SynthesizedScriptTool.swift
// Context-Dock
//
// Tier 2: AI Autonomous Scripting Tool (P13 / Task #368 Phase 2).
//
// Allows the AI provider to inspect an app's scripting dictionary (sdef) and execute
// on-the-fly synthesized AppleScript or JavaScript for Automation (JXA) scripts.
// Every run is sandboxed, enforces AGENT.md safety rules, and presents an approval card.

import AppKit
import Foundation

extension AgentToolRegistry {

    func registerSynthesizedScriptTool() {
        register(
            AgentTool(
                name: "read_app_dictionary",
                description: "Read an app's scripting dictionary (sdef) to inspect scriptable "
                    + "classes, properties, and commands. Use before synthesizing an AppleScript "
                    + "or JXA script to ensure valid object references and command parameters.",
                properties: [
                    "app": [
                        "type": "string",
                        "description": "Optional application name or bundle identifier (e.g. \"Pages\" "
                            + "or \"com.apple.Pages\"). If omitted, uses the current frontmost or scoped app.",
                    ],
                    "query": [
                        "type": "string",
                        "description": "Optional search term to filter classes, properties, or commands.",
                    ],
                ],
                required: []
            ) { arguments, context in
                let app = (arguments["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return await SynthesizedScriptRunner.readDictionary(
                    appInput: app, query: query, scope: context.chatScope, grantedApps: context.grantedApps)
            })

        register(
            AgentTool(
                name: "run_synthesized_script",
                description: "Execute an on-the-fly synthesized AppleScript or JavaScript for "
                    + "Automation (JXA) script to control or query an application. Execution is "
                    + "sandboxed, checks AGENT.md safety rules, and requires user approval on a "
                    + "card. Always provide a clear, honest reason describing what the script will do.",
                properties: [
                    "script": [
                        "type": "string",
                        "description": "The AppleScript or JXA script to execute.",
                    ],
                    "language": [
                        "type": "string",
                        "description": "The scripting language: \"applescript\" or \"jxa\" (default: \"applescript\").",
                    ],
                    "reason": [
                        "type": "string",
                        "description": "One line the user reads on the approval card explaining what the script will do.",
                    ],
                    "app": [
                        "type": "string",
                        "description": "Optional application name or bundle identifier (defaults to frontmost or scoped app).",
                    ],
                ],
                required: ["script", "reason"]
            ) { arguments, context in
                let script = (arguments["script"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let language = (arguments["language"] as? String ?? "applescript").trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = (arguments["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let app = (arguments["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                return await SynthesizedScriptRunner.run(
                    script: script,
                    language: language,
                    reason: reason,
                    appInput: app,
                    scope: context.chatScope,
                    grantedApps: context.grantedApps,
                    userRequest: context.userRequest
                )
            })
    }
}

@MainActor
enum SynthesizedScriptRunner {

    static func resolveApp(
        input: String,
        scope: GeneralChatScope?,
        grantedApps: [String: String]
    ) -> (bundleID: String, appName: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let lower = trimmed.lowercased()
            if let granted = grantedApps[lower] ?? grantedApps.first(where: { $0.key == lower })?.value {
                let name = InstalledApplicationsCatalog.cachedInstalledApps()
                    .first { $0.bundleId.caseInsensitiveCompare(granted) == .orderedSame }?.name ?? trimmed
                return (granted, name)
            }
            if let app = InstalledApplicationsCatalog.cachedInstalledApps().first(where: {
                $0.bundleId.caseInsensitiveCompare(trimmed) == .orderedSame ||
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return (app.bundleId, app.name)
            }
            return (trimmed, trimmed)
        }

        if let scopeBundleID = AgentToolRegistry.scopedBundleID(for: scope), !scopeBundleID.isEmpty {
            let name = InstalledApplicationsCatalog.cachedInstalledApps()
                .first { $0.bundleId.caseInsensitiveCompare(scopeBundleID) == .orderedSame }?.name ?? scopeBundleID
            return (scopeBundleID, name)
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleId = front.bundleIdentifier, !bundleId.isEmpty {
            let name = front.localizedName ?? bundleId
            return (bundleId, name)
        }

        return nil
    }

    static func readDictionary(
        appInput: String,
        query: String,
        scope: GeneralChatScope?,
        grantedApps: [String: String]
    ) async -> AgentToolResult {
        guard let (bundleID, appName) = resolveApp(input: appInput, scope: scope, grantedApps: grantedApps) else {
            return AgentToolResult(
                success: false,
                output: "No application specified and no frontmost app could be determined.",
                displayCommand: "read_app_dictionary(missing)"
            )
        }

        let store = AppDictionaryStore.shared
        var dictionary = store.dictionary(forBundleID: bundleID)
        if dictionary == nil {
            dictionary = await store.ensureScanned(bundleID: bundleID, appName: appName, grants: [bundleID])
        }

        guard let dict = dictionary, !dict.isEmpty else {
            return AgentToolResult(
                success: true,
                output: "\(appName) (\(bundleID)) has no AppleScript scripting dictionary (sdef). "
                    + "Escalate to live menu commands via run_menu_command or UI automation via operate_app instead.",
                displayCommand: "read_app_dictionary(\(appName)) · no sdef"
            )
        }

        let formatted = dict.formattedSummary(query: query)
        return AgentToolResult(
            success: true,
            output: formatted,
            displayCommand: "read_app_dictionary(\(appName)\(query.isEmpty ? "" : ": \(query)"))"
        )
    }

    static func run(
        script: String,
        language: String,
        reason: String,
        appInput: String,
        scope: GeneralChatScope?,
        grantedApps: [String: String],
        userRequest: String
    ) async -> AgentToolResult {
        guard !script.isEmpty else {
            return AgentToolResult(
                success: false,
                output: "No script code provided.",
                displayCommand: "run_synthesized_script(empty)"
            )
        }

        let lang = language.lowercased() == "jxa" ? "jxa" : "applescript"
        let (bundleID, appName) = resolveApp(input: appInput, scope: scope, grantedApps: grantedApps)
            ?? ("unknown", "App")

        // 1. Safety verification against AGENT.md never rules
        if !bundleID.isEmpty && bundleID != "unknown" {
            if let profile = AppAgentProfileStore.shared.profile(forBundleID: bundleID, appName: appName) {
                let scriptLower = script.lowercased()
                for rule in profile.never {
                    let ruleLower = rule.lowercased()
                    if ruleLower.contains("delete") && (scriptLower.contains("delete ") || scriptLower.contains(".delete(")) {
                        return AgentToolResult(
                            success: false,
                            output: "Execution refused: Script may violate safety rule in \(appName)'s AGENT.md: '\(rule)'",
                            displayCommand: "run_synthesized_script(\(appName)) · refused"
                        )
                    }
                }
            }
        }

        // 2. Request user approval
        let scriptPreview = script.count > 300 ? String(script.prefix(300)) + "\n…" : script
        let explanationText = reason.isEmpty
            ? "Run synthesized \(lang) on \(appName):\n\n\(scriptPreview)"
            : "\(reason)\n\n\(scriptPreview)"

        let approved = await AICapabilityApprovalCenter.shared.requestApproval(
            plan: AIActionPlan(
                capability: "appAgent.synthesizedScript",
                input: [
                    "app": appName,
                    "bundleID": bundleID,
                    "language": lang,
                    "script": script,
                ],
                explanation: explanationText
            ),
            capability: AICapability(
                id: "appAgent.synthesizedScript",
                title: "Run synthesized \(lang.capitalized) on \(appName)",
                appBundleID: bundleID,
                inputSchema: .init(fields: []),
                riskLevel: .high,
                runsWithoutAdapter: true,
                executor: { _ in
                    throw AICapabilityError.blocked("Synthesized scripts run through SynthesizedScriptRunner.")
                }
            ),
            context: .appFocused(name: appName, bundleID: bundleID),
            chatScope: scope
        )

        guard approved else {
            return AgentToolResult(
                success: false,
                output: "The user declined to run the synthesized script.",
                displayCommand: "run_synthesized_script(\(appName)) · declined"
            )
        }

        // 3. Execution
        let selection = AXContextReader.shared.current.selectedFilePaths.map(URL.init(fileURLWithPath:))
        let env = AppAgentScript.environment(
            appName: appName, bundleID: bundleID, query: userRequest, selection: selection
        )

        let scriptType: PluginScriptType = lang == "jxa" ? .jxa : .applescript
        let result = await PluginScriptRunner().run(
            type: scriptType,
            script: script,
            env: env,
            timeout: 30,
            workingDirectory: nil
        )

        switch result {
        case .success(let run):
            let output = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let errors = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = run.exitCode == 0
            let cappedOutput = output.count > 50_000 ? String(output.prefix(50_000)) + "\n…[truncated]" : output
            return AgentToolResult(
                success: succeeded,
                output: succeeded
                    ? (cappedOutput.isEmpty ? "Script executed successfully with no output." : cappedOutput)
                    : "Script failed with exit code \(run.exitCode)." + (errors.isEmpty ? "" : "\n\(errors)"),
                displayCommand: "run_synthesized_script(\(appName))",
                exitCode: run.exitCode,
                stdout: run.stdout,
                stderr: run.stderr
            )
        case .failure(let failure):
            return AgentToolResult(
                success: false,
                output: "Script did not run: \(failure.message)",
                displayCommand: "run_synthesized_script(\(appName)) · failed"
            )
        }
    }
}
