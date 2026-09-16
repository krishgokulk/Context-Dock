// WorkflowAuthor.swift
// Context-Dock
//
// When nothing on the Mac can do the thing, write something that can — once, with the
// user's approval — and keep it.
//
// Everything else in DoraX picks from what already exists: a menu item, an adapter action,
// an MCP tool, a linked CLI. That is the right default, and it is why the answer to
// "convert this selection to Markdown" was a refusal — no capability does it, so no route
// resolved, and the honest reply was that there is no way to do this here.
//
// A refusal is only honest the first time. The second time the user asks, it is a product
// that has learned nothing from them. So: the model authors a real adapter action for the
// request, the user reads the actual script and approves it, and it is saved to that app's
// adapter. Next time the same request resolves deterministically, through the ordinary
// route resolver, with no model involved at all.
//
// Three rules keep this from being a script-injection feature with a friendly name:
//
// - **Nothing runs before it is read.** The proposal is shown verbatim, as the script that
//   will execute. Approving is approving that text, not a description of it.
// - **Authoring is asked for, never inferred.** It happens when the user says to teach it
//   something, not silently whenever a request fails to resolve. A gap is not consent.
// - **What is saved is what ran.** The action stored is the one approved, so the thing that
//   runs next week is the thing that was read this week.

import AppKit
import Foundation
import OSLog

@MainActor
enum WorkflowAuthor {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "WorkflowAuthor")

    struct Proposal: Equatable {
        let name: String
        let summary: String
        /// `shell` or `applescript`. Nothing else is offered: those two cover the work and
        /// both are readable by someone who does not write code for a living.
        let kind: AdapterActionType
        /// The exact source that will run. Shown to the user unchanged.
        let script: String
        let triggers: [String]
        let bundleID: String
        let appName: String
        /// True when the script does something that cannot be taken back. Drives the red
        /// warning, and is judged from the script rather than from the model's opinion.
        let isDestructive: Bool
    }

    // MARK: - Authoring

    /// Asks the model to write an adapter action for a request nothing could serve.
    ///
    /// The prompt deliberately constrains the shape rather than the content: a name, one
    /// line of purpose, and a script. Anything looser comes back as prose about how the
    /// user might do it themselves, which is the failure this exists to end.
    static func propose(
        request: String, bundleID: String, appName: String
    ) async -> Proposal? {
        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""

        let prompt = """
            The user asked \(appName) to do this, and nothing on their Mac can:

            "\(request)"

            Write one macOS action that does it. Reply with ONLY this JSON:
            {"name":"<short title>","summary":"<one line, what it does>",
             "kind":"shell"|"applescript","script":"<the exact source>",
             "triggers":["<word>","<word>"]}

            Rules:
            - The script must be complete and runnable as written, not a sketch.
            - Available placeholders, substituted before it runs: {{selection}} for the
              selected text, {{file}} for the selected file path, {{clipboard}},
              {{url}} for the current browser URL, {{query}} for what the user typed.
            - Prefer shell. Use applescript only when the job needs to drive \(appName)
              itself.
            - Use only tools that ship with macOS unless the user named one.
            - Do not write anything that deletes, overwrites, or uploads without the work
              being exactly what was asked for.
            - Reply with the JSON and nothing else.
            """

        let raw = try? await AIProviderService.shared.sendMessage(
            prompt, context: .none, provider: provider,
            apiKey: rawKey.isEmpty ? nil : rawKey,
            conversationHistory: [], surfaceScoped: true)
        guard let raw else { return nil }
        guard let range = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
            let data = String(raw[range]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let script = (object["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty, !script.isEmpty
        else {
            log.notice("author: no usable proposal")
            return nil
        }

        let kind: AdapterActionType =
            (object["kind"] as? String)?.lowercased() == "applescript" ? .applescript : .shell
        let triggers = (object["triggers"] as? [String])?
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        return Proposal(
            name: name,
            summary: (object["summary"] as? String) ?? name,
            kind: kind,
            script: script,
            triggers: triggers.isEmpty ? derivedTriggers(from: request) : triggers,
            bundleID: bundleID,
            appName: appName,
            isDestructive: looksDestructive(script))
    }

    /// Judged from the script, not from what the model says about it. A model describing
    /// its own script as safe is not evidence, and this decides whether the approval card
    /// carries a warning.
    static func looksDestructive(_ script: String) -> Bool {
        let lowered = script.lowercased()
        let dangerous = [
            "rm ", "rm -", "rmdir", "mkfs", "dd ", "shutdown", "reboot", "killall",
            "> /dev/", "sudo ", "chmod 777", "curl ", "wget ", "scp ", "osascript -e 'do shell",
            "delete", "erase", "format",
        ]
        return dangerous.contains { lowered.contains($0) }
    }

    /// Words from the request, so the saved action is findable by asking for it the same
    /// way again. Without triggers it is stored but unreachable — a capability the user has
    /// but cannot summon, which is the state this whole exercise started from.
    private static func derivedTriggers(from request: String) -> [String] {
        Array(
            Set(
                request.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                    .filter { $0.count > 3 }
            )
        ).sorted().prefix(6).map { $0 }
    }

    // MARK: - Keeping it

    /// Saves the approved action to the app's adapter, creating the adapter when the app
    /// does not have one yet.
    ///
    /// Saved as `requiresApproval` regardless of what it does. It was written by a model
    /// and read once; the second run deserves the same glance as the first, and an action
    /// that turns out to be wrong is then one refusal away from never running again.
    @discardableResult
    static func save(_ proposal: Proposal) async -> AdapterAction {
        let action = AdapterAction(
            id: "authored.\(UUID().uuidString.prefix(8).lowercased())",
            name: proposal.name,
            icon: proposal.kind == .applescript ? "applescript" : "terminal",
            description: proposal.summary,
            triggers: proposal.triggers,
            category: "Authored",
            type: proposal.kind,
            script: proposal.script,
            requiresApproval: true,
            isDestructive: proposal.isDestructive
        )

        if AppAdapterManager.shared.adapter(for: proposal.bundleID) == nil {
            await AppAdapterManager.shared.createAdapter(
                appName: proposal.appName, bundleId: proposal.bundleID, icon: "app.dashed")
        }
        await AppAdapterManager.shared.appendAction(action, to: proposal.bundleID)
        log.notice(
            "author: saved \(action.name, privacy: .public) to \(proposal.bundleID, privacy: .public)")
        return action
    }

    /// What the user reads before deciding. The script is included in full and unedited —
    /// truncating it here would mean approving something other than what runs.
    static func approvalText(_ proposal: Proposal) -> String {
        var lines = [
            "**\(proposal.name)** — \(proposal.summary)",
            "",
            "Nothing on this Mac could do that, so here is an action that would. "
                + "Read it before approving; it runs exactly as written.",
            "",
            "```\(proposal.kind == .applescript ? "applescript" : "bash")",
            proposal.script,
            "```",
        ]
        if proposal.isDestructive {
            lines.append("")
            lines.append(
                "⚠️ This changes or removes things. Check the paths it touches before "
                    + "approving.")
        }
        lines.append("")
        lines.append(
            "Approving saves it to \(proposal.appName)'s actions and runs it once. "
                + "After that it is an ordinary action — you can edit or delete it in "
                + "Settings → App Adapters.")
        return lines.joined(separator: "\n")
    }
}
