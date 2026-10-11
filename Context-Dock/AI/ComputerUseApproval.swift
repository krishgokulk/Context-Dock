// ComputerUseApproval.swift
// Context-Dock
//
// The card the user answers before DoraX presses anything on their screen.
//
// This is deliberately not a new approval mechanism. DoraX already has one that is wired the
// whole way through: `AICapabilityApprovalCenter` publishes one pending request, the dock draws
// it inline when a chat surface is open, a floating window appears when none is, closing the
// window counts as a refusal, an unanswered card expires after sixty seconds, and an unattended
// MCP run refuses every approval while recording what was asked. A second centre would have to
// re-earn all of that, and the copy that drifts is always the one guarding the newer path.
//
// What Computer Use adds is the *content* of the card: the app, the exact menu path about to be
// pressed, why, and what the app looked like a moment ago. The user should be able to answer
// without trusting the sentence that led here.

import Foundation

@MainActor
enum ComputerUseApproval {

    /// Ask before a single press. Returns false on refusal, on expiry, and during an
    /// unattended run — every one of which means "do not press it".
    static func request(
        appName: String,
        bundleID: String,
        target: ComputerUseTarget,
        reason: String,
        before: String,
        chatScope: GeneralChatScope? = nil
    ) async -> Bool {
        var input = [
            "app": appName,
            "press": target.display,
        ]
        if !before.isEmpty { input["app now"] = before }

        let plan = AIActionPlan(
            capability: capabilityID,
            input: input,
            explanation: explanation(appName: appName, target: target, reason: reason)
        )

        return await AICapabilityApprovalCenter.shared.requestApproval(
            plan: plan,
            capability: capability(appName: appName, bundleID: bundleID),
            context: .appFocused(name: appName, bundleID: bundleID),
            chatScope: chatScope
        )
    }

    /// The door: the first press in an app the user has never granted.
    ///
    /// Asked as one card rather than two — "may DoraX operate this app" followed by "may it
    /// press this item" is the same decision split in half, and the half that arrives first is
    /// the one with no detail in it. Approving grants the cautious tier (`grantFromChat`), which
    /// the card says out loud: a permission the user did not know they were giving is one they
    /// cannot review.
    static func requestFirstUse(
        appName: String,
        bundleID: String,
        target: ComputerUseTarget,
        reason: String,
        before: String,
        chatScope: GeneralChatScope? = nil
    ) async -> Bool {
        var input = [
            "app": appName,
            "press": target.display,
            "then": "DoraX may operate \(appName), asking you before each step",
        ]
        if !before.isEmpty { input["app now"] = before }

        var explanation = "DoraX has not operated \(appName) before. Allowing this presses "
            + "\(target.display) now, the way you would."
        if !reason.isEmpty { explanation += "\n\n" + reason }
        explanation += "\n\nIt also turns Computer Use on for \(appName) at its most cautious "
            + "setting, so you are asked before every later step. Change or revoke it in "
            + "Settings → AI → Computer Use, or on this app's Access page."

        let plan = AIActionPlan(
            capability: capabilityID, input: input, explanation: explanation)

        return await AICapabilityApprovalCenter.shared.requestApproval(
            plan: plan,
            capability: capability(
                appName: appName, bundleID: bundleID, title: "Let DoraX Operate \(appName)"),
            context: .appFocused(name: appName, bundleID: bundleID),
            chatScope: chatScope
        )
    }

    static let capabilityID = "computerUse.pressMenuItem"

    private static func explanation(appName: String, target: ComputerUseTarget, reason: String)
        -> String
    {
        // Say what the click is, in the app's own words, before saying why. The reason comes
        // from the model and the path comes from the app — the user needs the one they can
        // check first.
        let what = "DoraX will press \(target.display) in \(appName), the way you would."
        guard !reason.isEmpty else { return what }
        return what + "\n\n" + reason
    }

    /// A capability that exists to describe this press on the card, not to carry it out.
    ///
    /// The press happens in `ComputerUseRunner` after this returns true, because it has to read
    /// the live menu bar and the app's state on either side of the click. The executor here is
    /// therefore never called; it throws rather than silently succeeding, so a future caller
    /// that routes this through the registry fails loudly instead of reporting a click that
    /// never happened.
    private static func capability(
        appName: String, bundleID: String, title: String? = nil
    ) -> AICapability {
        AICapability(
            id: capabilityID,
            title: title ?? "Operate \(appName)",
            appBundleID: bundleID,
            inputSchema: AICapabilityInputSchema(fields: []),
            // High, not critical: destructive and outbound items are refused outright by
            // `ComputerUseTargetResolver`, so nothing that reaches this card can send or
            // delete. What is left still happens on someone's screen without the app having
            // published the route, which is more than medium.
            riskLevel: .high,
            selectionSafety: .unsafe,
            runsWithoutAdapter: true,
            executor: { _ in
                throw AICapabilityError.blocked(
                    "Computer Use presses are carried out by ComputerUseRunner, not through the "
                        + "capability registry."
                )
            }
        )
    }
}
