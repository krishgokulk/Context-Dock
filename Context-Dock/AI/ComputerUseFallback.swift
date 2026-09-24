// ComputerUseFallback.swift
// Context-Dock
//
// Offering to press it, when nothing else could.
//
// Computer Use shipped as something the model asks for — a tool, then also a directive — and
// the owner's chat still ended in "you click it yourself" while naming operate_app as the
// thing it lacked. Asking a model to notice it has run out of routes, and to reach for the
// last one, is asking it to do the job this app's deterministic layer exists to do. Three
// turns in a row proved it does not.
//
// So DoraX decides instead. When an action turn ends having run nothing — no adapter action,
// no CLI, no MCP tool, no worker — and the live menu bar holds exactly one item the request
// names, the offer appears by itself. The user sees the item and one tap. Nothing is read
// from the app's menus until that point: this is the end of the road, not a step on it.

import Foundation

enum ComputerUseFallback {

    /// Whether this turn has run out of everything else.
    ///
    /// Deliberately narrow. A question is never offered a click (a person asking what version
    /// they are on does not want a menu pressed), and a turn where *something* ran is a turn
    /// that had a route — the offer belongs where the alternative is nothing at all.
    static func shouldOffer(
        intent: FrontmostAppTaskPlan.Intent,
        ranAnything: Bool,
        bundleID: String
    ) -> Bool {
        guard intent == .act || intent == .workflow else { return false }
        guard !ranAnything else { return false }
        guard !bundleID.isEmpty, !bundleID.hasPrefix("cli://"), !bundleID.hasPrefix("scope://")
        else { return false }
        return true
    }

    /// The offer itself: resolve the words against the LIVE menu bar and, if one item is
    /// clearly what was asked for, show the approval card and press it.
    ///
    /// Returns nil when there is nothing to offer — no match, no app, or the user's request
    /// names something that is not a menu command at all. Nil means the turn's own answer
    /// stands untouched, which is the right outcome: a card that appears for every failed
    /// action turn would be noise, and noise is how people learn to dismiss approvals.
    @MainActor
    static func offer(
        query: String, bundleID: String, appName: String, scope: GeneralChatScope? = nil
    ) async -> AgentToolResult? {
        let request = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return nil }

        let result = await ComputerUseRunner.run(
            target: request,
            reason: "Nothing else in \(appName) could carry out \"\(request)\".",
            bundleID: bundleID,
            scope: scope)
        // "No enabled menu command matches" is not something to show the user here — they did
        // not ask for Computer Use, DoraX offered it, and an offer that fails is an offer
        // that should never have been made out loud.
        guard result.success || result.declinedByUser else { return nil }
        return result
    }

    /// What the answer says once the offer has been made, in the user's own words rather than
    /// the model's — the model has already finished writing by this point.
    static func note(for result: AgentToolResult) -> String {
        result.success
            ? "\n\n---\n" + result.output
            : "\n\n---\nLeft alone — nothing was pressed."
    }
}

extension AgentToolResult {
    /// The user saw the card and said no. Distinguished from every other failure because it
    /// is the one the user already knows about: they are the one who caused it.
    var declinedByUser: Bool {
        displayCommand.hasSuffix("· declined") || displayCommand.hasSuffix("· not allowed")
    }
}
