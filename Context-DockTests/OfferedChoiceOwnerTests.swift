import Testing
import Foundation
@testable import Context_Dock

// MARK: - The button runs the thing that was offered
//
// The corner offered "Use Code · Computer Use · Code → Hide Others" and tapping it answered
// "That route is no longer available." It always would have: the offer and the handler keep
// their pending work in two different places.
//
// A card built by the pre-model resolver carries a DoraXActionCandidate id and is remembered
// in LauncherView.pendingActionCandidates. The corner's tap handler looked the id up in
// AppScopedChatService.pendingRoutesByScope, which only ever holds ChatRoutes registered by a
// different path. Neither store is wrong; asking only one of them is.

struct OfferedChoiceOwnerTests {

    @Test func aResolverCandidateIsRunByTheCandidateHandler() {
        let owner = OfferedChoiceOwner.decide(
            id: "candidate-1", candidateIDs: ["candidate-1"], routeIDs: [])
        #expect(owner == .candidate)
    }

    @Test func aChatRouteIsRunByTheRouteHandler() {
        let owner = OfferedChoiceOwner.decide(
            id: "route-1", candidateIDs: [], routeIDs: ["route-1"])
        #expect(owner == .route)
    }

    /// The candidate store is the one the card was built from, so it answers first when an
    /// id somehow appears in both.
    @Test func theCandidateStoreAnswersFirst() {
        let owner = OfferedChoiceOwner.decide(
            id: "both", candidateIDs: ["both"], routeIDs: ["both"])
        #expect(owner == .candidate)
    }

    /// Genuinely gone — a thread reopened after a restart, say. Saying so is right; saying
    /// so about a card that was offered seconds ago was the bug.
    @Test func anUnknownIDIsGone() {
        let owner = OfferedChoiceOwner.decide(
            id: "stale", candidateIDs: ["a"], routeIDs: ["b"])
        #expect(owner == .gone)
    }
}
