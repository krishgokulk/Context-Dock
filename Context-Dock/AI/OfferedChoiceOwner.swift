// OfferedChoiceOwner.swift
// Context-Dock
//
// Which store owns the choice the user just tapped.
//
// Two paths offer a pick-one card in an app chat, and each remembers what it offered in its
// own place: the pre-model resolver keeps DoraXActionCandidates in
// LauncherView.pendingActionCandidates, while the in-turn route offer keeps ChatRoutes in
// AppScopedChatService.pendingRoutesByScope. The corner's handler asked only the second, so a
// card from the first could never run — "Use Code" answered "That route is no longer
// available" every time, which reads to the user as a bug in the action rather than in the
// wiring behind the button.
//
// Pure, so the rule can be stated once and checked without a view.

import Foundation

enum OfferedChoiceOwner: Equatable {
    /// A DoraXActionCandidate the resolver offered before the model ran.
    case candidate
    /// A ChatRoute offered during the turn.
    case route
    /// Neither store has it: the thread outlived the offer.
    case gone

    /// The candidate store is asked first because it is the one the card was built from.
    static func decide(
        id: String, candidateIDs: [String], routeIDs: [String]
    ) -> OfferedChoiceOwner {
        if candidateIDs.contains(id) { return .candidate }
        if routeIDs.contains(id) { return .route }
        return .gone
    }
}
