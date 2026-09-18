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

        // The kill switch, before anything is read or pressed. It is answered in words rather
        // than with a card on purpose: a master switch that a chat can talk the user out of in
        // one tap is not a kill switch, and "off here means off everywhere" is what the setting
        // promises. The per-app door below is a different question, asked only once the user
        // has already decided the feature may exist.
        let store = ComputerUseConsentStore.shared
        guard store.isMasterEnabled else {
            return AgentToolResult(
                success: false,
                output: "Computer Use is switched off on this Mac, so DoraX may not operate "
                    + "\(appName). Tell the user it is off and where it lives — Settings → AI → "
                    + "Computer Use — and do not describe the task as impossible; it is "
                    + "unapproved, which is different.",
                displayCommand: "operate_app(\(appName): \(target)) · switched off")
        }
        let mode = store.mode(for: bundleID)

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

        guard let chosen = ComputerUseTargetResolver.best(matching: target, among: candidates)
        else {
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
                    + "live, not from a cache, so it is genuinely absent or greyed out right "
                    + "now. Nearby items: \(nearby). Do not press something else; say what is "
                    + "there and let the user choose.",
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
        if !mode.canOperate {
            let approved = await ComputerUseApproval.requestFirstUse(
                appName: appName, bundleID: bundleID, target: chosen, reason: reason,
                before: before, chatScope: scope)
            guard approved else {
                return AgentToolResult(
                    success: false,
                    output: "The user did not allow DoraX to operate \(appName). Say so plainly "
                        + "and stop — do not look for another way to press the same thing.",
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
