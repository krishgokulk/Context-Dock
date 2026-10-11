// ComputerUseTool.swift
// Context-Dock
//
// The rung below a verified menu: operating the app the way a person would.
//
// Every other route DoraX takes is something the app published — a capability, an MCP tool, a
// linked CLI, a cached menu command. This one takes the app's own menu bar as it stands *right
// now* and presses an item in it. It exists because the reported failure had no route and a
// perfectly good answer sitting one lazy menu away: VS Code builds its menus on demand, the
// cache was written before it filled them in, and `Code ▸ Check for Updates…` was therefore
// invisible to every layer that reads the cache.
//
// Three properties make this safe enough to offer at all, and all three are load-bearing:
//
//   1. It is off unless the user turned it on for this app (`ComputerUseConsentStore`).
//   2. It reads the LIVE menu bar, opening lazy menus, and presses only what the words name —
//      never the nearest thing (`ComputerUseTargetResolver`).
//   3. It reports what the app looked like before and after, so the user can see what it did
//      rather than read a claim that it worked.

import AppKit
import Foundation

extension AgentToolRegistry {

    func registerComputerUseTool() {
        register(
            AgentTool(
                name: "operate_app",
                description: "Press a menu command in the app this chat is scoped to, using its "
                    + "LIVE menu bar — including menus the app builds only when opened, which "
                    + "never appear in the cached map. Use ONLY when no capability, MCP tool, "
                    + "CLI or cached menu command can do the job, and only after run_menu_command "
                    + "has failed or found nothing. The user is shown the exact item and "
                    + "approves it before anything is pressed; if Computer Use is switched off "
                    + "on this Mac, this says so instead.",
                properties: [
                    "target": [
                        "type": "string",
                        "description": "The command in the app's own words, e.g. "
                            + "\"Check for Updates\". Not a path, not a guess.",
                    ],
                    "reason": [
                        "type": "string",
                        "description": "One line the user will read on the approval card, "
                            + "saying what this achieves.",
                    ],
                ],
                required: ["target"]
            ) { arguments, context in
                let target = (arguments["target"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = (arguments["reason"] as? String ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !target.isEmpty else {
                    return AgentToolResult(
                        success: false, output: "operate_app needs 'target'.",
                        displayCommand: "operate_app")
                }
                return await ComputerUseRunner.run(
                    target: target, reason: reason, scope: context.chatScope)
            })
    }
}

@MainActor
enum ComputerUseRunner {

    static func run(
        target: String, reason: String, scope: GeneralChatScope?
    ) async -> AgentToolResult {
        guard let bundleID = AgentToolRegistry.scopedBundleID(for: scope), !bundleID.isEmpty
        else {
            return AgentToolResult(
                success: false,
                output: "This conversation is not scoped to one app, and operating a screen "
                    + "needs a named app. Ask in that app's own chat.",
                displayCommand: "operate_app(\(target))")
        }
        return await run(target: target, reason: reason, bundleID: bundleID, scope: scope)
    }

    /// The same press, entered by bundle id.
    ///
    /// The provider the owner actually uses — Claude Code — is run with none of DoraX's tools
    /// by design: it answers and the app acts, through the prose directive loop in
    /// `GeneralChatCapabilityHub`. That loop has no `GeneralChatScope`, so a rung reachable
    /// only through `AgentToolContext` is a rung that provider can never climb, which is
    /// exactly what happened: Computer Use shipped and the owner's own chat still said "not in
    /// my menu cache, so I cannot fire it".
    static func run(
        target: String, reason: String, bundleID: String, scope: GeneralChatScope? = nil
    ) async -> AgentToolResult {
        guard !bundleID.isEmpty else {
            return AgentToolResult(
                success: false,
                output: "This conversation is not scoped to one app, and operating a screen "
                    + "needs a named app. Ask in that app's own chat.",
                displayCommand: "operate_app(\(target))")
        }

        let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
        guard let app, app.processIdentifier > 0 else {
            return AgentToolResult(
                success: false,
                output: "That app is not running, so there is nothing to operate. Say so rather "
                    + "than launching it — opening an app is a separate thing to ask for.",
                displayCommand: "operate_app(\(target))")
        }
        let appName = app.localizedName ?? bundleID

        let store = ComputerUseConsentStore.shared
        let mode = store.effectiveMode(for: bundleID)

        // The live menu bar, with lazy menus opened. This is the whole point: the cached map
        // is what said the item did not exist.
        let items = AXMenuReader.shared.refreshAllMenuItemsOpeningLazyMenus(
            for: app.processIdentifier)
        let candidates = flatten(items).map {
            ComputerUseTarget(path: $0.path, isEnabled: $0.isEnabled)
        }
        guard !candidates.isEmpty else {
            return AgentToolResult(
                success: false,
                output: "\(appName)'s menus could not be read. DoraX needs Accessibility "
                    + "permission for this (System Settings → Privacy & Security → "
                    + "Accessibility). Say that plainly rather than trying another way.",
                displayCommand: "operate_app(\(appName))")
        }

        // A refusal that says which kind of refusal it is. "Not found", "greyed out" and
        // "two things match equally" are three different facts about the app, and reporting
        // all of them as absence is how an assistant looks like it understood nothing.
        let resolution = ComputerUseTargetResolver.resolve(phrase: target, among: candidates)
        let chosen: ComputerUseTarget
        switch resolution {
        case .resolved(let target):
            chosen = target

        case .ambiguous(let options):
            let named = options.prefix(4).map(\.display).joined(separator: ", ")
            return AgentToolResult(
                success: false,
                output: "\"\(target)\" describes more than one thing in \(appName) equally "
                    + "well: \(named). Ask which one — pressing either is guessing with extra "
                    + "steps.",
                displayCommand: "operate_app(\(appName): \(target)) · ambiguous")

        case .disabled(let item):
            return AgentToolResult(
                success: false,
                output: "\(appName) has \(item.display), but it is greyed out right now, so "
                    + "the app will not accept it in this state. Say that — it is a fact about "
                    + "the app, not a missing feature.",
                displayCommand: "operate_app(\(appName): \(target)) · disabled")

        case .forbidden(let item):
            return AgentToolResult(
                success: false,
                output: "\(item.display) is on the destructive-and-outbound denylist and is "
                    + "never pressed from here. If the user wants it, it goes through the "
                    + "approval path for that kind of action, not through operate_app.",
                displayCommand: "operate_app(\(appName): \(target)) · forbidden")

        case .noMatch:
            // The refusal the owner called perfect, kept — now with the live list behind it
            // rather than a stale one, so "it is not there" means it is really not there.
            let nearby = candidates
                .filter { $0.isEnabled }
                .prefix(6)
                .map(\.display)
                .joined(separator: ", ")
            return AgentToolResult(
                success: false,
                output: "No enabled menu command in \(appName) matches \"\(target)\" — read "
                    + "live, not from a cache, so it is genuinely absent right now. Nearby "
                    + "items: \(nearby). Do not press something else; say what is there and "
                    + "let the user choose.",
                displayCommand: "operate_app(\(appName): \(target)) · no match")
        }

        // What the app looked like before. A click nobody can see afterwards is a click
        // nobody can check.
        let before = ComputerUseEvidence.describe(app: app)

        // One card, whichever door this is. An app that has never been granted is asked about
        // here — with the exact item named, because "let DoraX operate Code" is a vaguer
        // question than "let DoraX press Code ▸ Check for Updates…", and the vaguer question is
        // the one a user cannot answer well. Approving it grants the cautious tier and carries
        // out this press; it does not then ask again for the same click.
        //
        // This card appears when the master switch is off too, and that is the owner's call
        // (superseding the words-only refusal shipped first): the question a person can answer
        // is "let me click this for you?", asked at the moment it would help, not a sentence
        // naming a settings page they have never opened. Declining is the whole other half —
        // nothing is pressed, nothing is granted, and the turn falls back to telling them how
        // to do it themselves.
        // A single press the user already allowed, spent here. Checked before the standing
        // grant so that "allow once" never quietly becomes "allow always".
        let hadOneShot = store.consumeOneShotGrant(for: bundleID)

        if !mode.canOperate && !hadOneShot {
            let approved = await ComputerUseApproval.requestFirstUse(
                appName: appName, bundleID: bundleID, target: chosen, reason: reason,
                before: before, chatScope: scope)
            guard approved else {
                return AgentToolResult(
                    success: false,
                    output: "The user did not allow DoraX to operate \(appName). Do not press "
                        + "anything and do not ask again. Give them the other way instead, in "
                        + "one line: \(chosen.display), for them to click themselves.",
                    displayCommand: "operate_app(\(appName)) · not allowed")
            }
            store.grantFromChat(for: bundleID)
        } else if mode.requiresApprovalPerStep {
            let approved = await ComputerUseApproval.request(
                appName: appName, bundleID: bundleID, target: chosen, reason: reason,
                before: before, chatScope: scope)
            guard approved else {
                return AgentToolResult(
                    success: false,
                    output: "The user declined \(chosen.display). Do not try another route to "
                        + "the same thing — they said no to the outcome, not to the method.",
                    displayCommand: "operate_app(\(appName): \(chosen.display)) · declined")
            }
        }

        let pressed = AXMenuReader.shared.clickMenuItemReliably(
            path: chosen.path, in: app.processIdentifier)
        guard pressed else {
            return AgentToolResult(
                success: false,
                output: "\(chosen.display) could not be pressed, so nothing happened.",
                displayCommand: "operate_app(\(appName): \(chosen.display)) · failed")
        }

        // Let the app respond before reading it back; a window that has not appeared yet
        // reads as an unchanged app, and "nothing happened" is the one wrong answer here.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let after = ComputerUseEvidence.describe(app: app)

        return AgentToolResult(
            success: true,
            output: """
                Pressed \(chosen.display) in \(appName).

                Before: \(before)
                After: \(after)

                Report what changed between those two readings. If they are identical, say the \
                command ran and nothing visible changed — do not invent an outcome, and do not \
                press anything else to produce one.
                """,
            displayCommand: "operate_app(\(appName): \(chosen.display))")
    }

    private static func flatten(_ items: [AXMenuItem]) -> [AXMenuItem] {
        items.flatMap { item -> [AXMenuItem] in
            item.isLeaf ? [item] : [item] + flatten(item.children)
        }
    }
}

/// What the app looked like, in words, at one moment.
///
/// Deliberately not a screenshot in this slice: a window list is readable in a transcript, is
/// cheap, needs no Screen Recording grant, and answers the question that matters — did a sheet
/// appear, did the window title change. Frames come with the pixel tier, which is where they
/// are the only evidence available.
@MainActor
enum ComputerUseEvidence {
    static func describe(app: NSRunningApplication) -> String {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement], !windows.isEmpty
        else { return "no windows readable" }

        let titles = windows.prefix(8).map { window -> String in
            var titleValue: CFTypeRef?
            let title = AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &titleValue) == .success
                ? (titleValue as? String ?? "") : ""

            var roleValue: CFTypeRef?
            let subrole = AXUIElementCopyAttributeValue(
                window, kAXSubroleAttribute as CFString, &roleValue) == .success
                ? (roleValue as? String ?? "") : ""
            // A sheet is the usual sign that a menu command did something — "Check for
            // Updates" opening a dialog is exactly the outcome being verified.
            let kind = subrole == (kAXDialogSubrole as String)
                || subrole == (kAXSystemDialogSubrole as String) ? " [dialog]" : ""
            return (title.isEmpty ? "(untitled)" : title) + kind
        }
        return "\(windows.count) window\(windows.count == 1 ? "" : "s") — "
            + titles.joined(separator: ", ")
    }
}
