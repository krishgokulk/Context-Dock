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
        /// The one thing about the action that varies, when the model declared one: the
        /// unit its `{{value}}` slot expects, and what runs when the sentence names no
        /// number. Nil for an action with nothing to adjust.
        var valueLabel: String? = nil
        var valueDefault: String? = nil
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

        let raw = try? await AIProviderService.shared.sendMessage(
            prompt(request: request, appName: appName), context: .none, provider: provider,
            apiKey: rawKey.isEmpty ? nil : rawKey,
            conversationHistory: [], surfaceScoped: true)
        guard let raw else { return nil }
        guard let proposal = proposal(
            fromReply: raw, request: request, bundleID: bundleID, appName: appName)
        else {
            log.notice("author: no usable proposal")
            return nil
        }
        return proposal
    }

    /// What the model is asked. Separate from the asking so a test can read it.
    static func prompt(request: String, appName: String) -> String {
        """
        The user asked \(appName) to do this, and nothing on their Mac can:

        "\(request)"

        Write one macOS action that does it. Reply with ONLY this JSON:
        {"name":"<short title>","summary":"<one line, what it does>",
         "kind":"shell"|"applescript","script":"<the exact source>",
         "triggers":["<word>","<word>"],
         "value":{"label":"<unit>","default":"<the number in this request>"}}

        Rules:
        - The script must be complete and runnable as written, not a sketch.
        - Available placeholders, substituted before it runs: {{selection}} for the
          selected text, {{file}} for the selected file path, {{clipboard}},
          {{url}} for the current browser URL, {{query}} for what the user typed.
        - If the request names a quantity that will change next time — a delay, a
          count, a percentage, a size — do not bake it in. Put {{value}} where it goes,
          and declare it in "value": "label" is the unit the script needs there
          ("seconds", "minutes", "percent", "count"), "default" is the number from this
          request in that unit. "minimise after 5 min" → `sleep {{value}}` with
          {"label":"seconds","default":"300"}, so "after 10 min" runs the same action
          with 600. One value per action. Omit "value" when nothing varies.
        - Prefer shell. Use applescript only when the job needs to drive \(appName)
          itself.
        - Use only tools that ship with macOS unless the user named one.
        - Do not write anything that deletes, overwrites, or uploads without the work
          being exactly what was asked for.
        - Reply with the JSON and nothing else.
        """
    }

    /// The proposal in the model's reply, or nil when there is no usable one. Pure, so the
    /// shape of what is accepted can be checked without a provider.
    ///
    /// `fallbackName` is used when the reply names nothing — a revision knows the name
    /// already, and only the script is worth refusing over.
    static func proposal(
        fromReply raw: String, request: String, bundleID: String, appName: String,
        fallbackName: String? = nil
    ) -> Proposal? {
        guard let range = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
            let data = String(raw[range]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let script = (object["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !script.isEmpty
        else { return nil }
        let replyName = (object["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = replyName.isEmpty ? (fallbackName ?? "") : replyName
        guard !name.isEmpty else { return nil }

        let kind: AdapterActionType =
            (object["kind"] as? String)?.lowercased() == "applescript" ? .applescript : .shell
        let triggers = (object["triggers"] as? [String])?
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        // A value with no label is no value: nothing to convert to, and a default without
        // a unit is a number nobody can adjust.
        let value = object["value"] as? [String: Any]
        let valueLabel = (value?["label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasLabel = !(valueLabel ?? "").isEmpty
        let valueDefault: String? = hasLabel
            ? (value?["default"]).flatMap { any -> String? in
                if let s = any as? String { return s.isEmpty ? nil : s }
                if let n = any as? NSNumber { return n.stringValue }
                return nil
            }
            : nil

        return Proposal(
            name: name,
            summary: (object["summary"] as? String) ?? name,
            kind: kind,
            script: script,
            triggers: triggers.isEmpty ? derivedTriggers(from: request) : triggers,
            bundleID: bundleID,
            appName: appName,
            isDestructive: looksDestructive(script),
            valueLabel: hasLabel ? valueLabel : nil,
            valueDefault: valueDefault)
    }

    // MARK: - Revising

    /// Asks the model to change an action the user already has, rather than write a second
    /// one beside it.
    ///
    /// Reached when the request differs from the saved action by more than a value
    /// (`ActionReuse.decide` → `.revise`). The revision keeps the existing name, so its
    /// `stableID` matches and saving replaces; a model free to rename would produce the
    /// duplicate this exists to prevent.
    static func revise(
        existing: AdapterAction, request: String, bundleID: String, appName: String
    ) async -> Proposal? {
        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""

        let raw = try? await AIProviderService.shared.sendMessage(
            revisionPrompt(existing: existing, request: request, appName: appName),
            context: .none, provider: provider,
            apiKey: rawKey.isEmpty ? nil : rawKey,
            conversationHistory: [], surfaceScoped: true)
        guard let raw else { return nil }
        guard let revised = revision(
            fromReply: raw, existing: existing, request: request,
            bundleID: bundleID, appName: appName)
        else {
            log.notice("author: no usable revision")
            return nil
        }
        return revised
    }

    /// What the model is asked in order to change an action. Separate from the asking so a
    /// test can read it.
    static func revisionPrompt(
        existing: AdapterAction, request: String, appName: String
    ) -> String {
        let valueLine = existing.valueLabel.map {
            "\n        The script's {{value}} is a number in \($0); keep it exactly as it is.\n"
        } ?? ""
        return """
        \(appName) already has this action, and the user has now asked for something it
        does not quite do.

        Action: \(existing.name) — \(existing.description)
        Its script:
        \(existing.script ?? "")
        \(valueLine)
        The new request:

        "\(request)"

        Change the script so it does what the request asks. Reply with ONLY this JSON:
        {"summary":"<one line, what it does now>","kind":"shell"|"applescript",
         "script":"<the whole new source>","triggers":["<word>","<word>"],
         "value":{"label":"<unit>","default":"<number>"}}

        Rules:
        - Change only what the request changes. Everything the action already did, it
          still does, unless the request says otherwise.
        - Reply with the whole script, not a patch or a diff.
        - Keep {{value}} where the script has one, and keep its "value" declaration — the
          user adjusts that number by asking, and dropping it takes that away.
        - The placeholders available are the same: {{selection}}, {{file}}, {{clipboard}},
          {{url}}, {{query}}, {{value}}.
        - Do not rename the action.
        - Reply with the JSON and nothing else.
        """
    }

    /// The revision in the model's reply, or nil when there is no usable one.
    ///
    /// The name is the existing one whatever the model says, so the saved action is
    /// replaced rather than joined. The value declaration survives a reply that forgot to
    /// repeat it, as long as the new script still has a slot to fill — dropping it would
    /// quietly take away an adjustment the user has already been told about.
    static func revision(
        fromReply raw: String, existing: AdapterAction, request: String,
        bundleID: String, appName: String
    ) -> Proposal? {
        guard var proposal = proposal(
            fromReply: raw, request: request, bundleID: bundleID, appName: appName,
            fallbackName: existing.name)
        else { return nil }

        let hasSlot = proposal.script.contains("{{value}}")
        let label = hasSlot ? (proposal.valueLabel ?? existing.valueLabel) : nil
        let fallbackDefault = proposal.valueLabel == nil ? existing.valueDefault : proposal.valueDefault

        proposal = Proposal(
            name: existing.name,
            summary: proposal.summary,
            kind: proposal.kind,
            script: proposal.script,
            triggers: proposal.triggers,
            bundleID: bundleID,
            appName: appName,
            isDestructive: proposal.isDestructive,
            valueLabel: label,
            valueDefault: label == nil ? nil : fallbackDefault)
        return proposal
    }

    /// What the user reads before replacing an action they already have. Both scripts, in
    /// full: approving a change means seeing what it was as well as what it becomes.
    static func revisionText(existing: AdapterAction, revised: Proposal) -> String {
        let fence = revised.kind == .applescript ? "applescript" : "bash"
        var lines = [
            "**\(existing.name)** already does most of this, so here it is changed rather "
                + "than a second action beside it. Approving will replace the saved one.",
            "",
            "Now:",
            "```\(fence)",
            existing.script ?? "",
            "```",
            "",
            "Becomes:",
            "```\(fence)",
            revised.script,
            "```",
        ]
        if revised.isDestructive {
            lines.append("")
            lines.append(
                "⚠️ This changes or removes things. Check the paths it touches before "
                    + "approving.")
        }
        if let label = revised.valueLabel {
            let saved = revised.valueDefault.map { "\($0) \(label)" } ?? label
            lines.append("")
            lines.append("It still runs at \(saved), and still takes a different number.")
        }
        return lines.joined(separator: "\n")
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
        let action = action(for: proposal)

        if AppAdapterManager.shared.adapter(for: proposal.bundleID) == nil {
            await AppAdapterManager.shared.createAdapter(
                appName: proposal.appName, bundleId: proposal.bundleID, icon: "app.dashed")
        }
        await AppAdapterManager.shared.appendAction(action, to: proposal.bundleID)
        log.notice(
            "author: saved \(action.name, privacy: .public) to \(proposal.bundleID, privacy: .public)")
        return action
    }

    /// The adapter action a proposal becomes. Pure, so what is saved can be checked
    /// without a store.
    static func action(for proposal: Proposal) -> AdapterAction {
        AdapterAction(
            id: "authored.\(UUID().uuidString.prefix(8).lowercased())",
            name: proposal.name,
            icon: proposal.kind == .applescript ? "applescript" : "terminal",
            description: proposal.summary,
            triggers: proposal.triggers,
            category: "Authored",
            type: proposal.kind,
            script: proposal.script,
            requiresApproval: true,
            isDestructive: proposal.isDestructive,
            valueLabel: proposal.valueLabel,
            valueDefault: proposal.valueDefault
        )
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
        if let label = proposal.valueLabel {
            let saved = proposal.valueDefault.map { "\($0) \(label)" } ?? label
            lines.append("")
            lines.append(
                "It runs at \(saved). Say a different number next time — this same action "
                    + "uses it, instead of writing another one.")
        }
        lines.append("")
        lines.append(
            "Approving saves it to \(proposal.appName)'s actions and runs it once. "
                + "After that it is an ordinary action — you can edit or delete it in "
                + "Settings → App Adapters.")
        return lines.joined(separator: "\n")
    }
}
