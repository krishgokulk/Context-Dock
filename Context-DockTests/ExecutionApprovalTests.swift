import Testing
import Foundation
@testable import Context_Dock

// MARK: - The approval contract
//
// `GeneralAIActionExecutor.execute` used to assume its caller had already asked the user.
// That assumption was true of exactly one caller — General AI Chat, which raises its own
// route-specific card — and was written down in a comment three call sites deep:
//
//     // General Chat already showed its own approval.
//     action.requiresApproval = false
//
// It was a property of one caller stated as a property of the executor. Any second surface
// routed through it inherited "already approved" for free, silently, with no diagnostic —
// which is precisely what the audit's §10b (Context Dock through the shared executor) was
// about to do.
//
// These tests guard the replacement: an `approval:` argument with no default, so a caller
// must state where the user's yes came from, and an `.ask` case that actually gates.

@MainActor
struct ExecutionApprovalTests {

    private func freshKey() -> String { "test.approval.\(UUID().uuidString)" }

    // MARK: - The gate

    /// The whole point. A caller that has not asked must not get through.
    @Test func askWithNoStandingGrantMustPrompt() {
        let key = freshKey()
        #expect(GeneralAIActionExecutor.requiresPrompt(.ask, permissionKey: key))
    }

    /// "Always Allow" is a real prior yes from this user for this exact key, so `.ask`
    /// stops asking. This is the branch every General AI call site already implements
    /// by hand; it now lives in one place.
    @Test func askHonoursAStandingGrant() {
        let key = freshKey()
        GeneralAIActionApprovalStore.allowAlways(key)
        defer { GeneralAIActionApprovalStore.revoke(key) }
        #expect(!GeneralAIActionExecutor.requiresPrompt(.ask, permissionKey: key))
    }

    /// A standing grant is scoped to one permission key, never to the app or the route.
    @Test func standingGrantDoesNotLeakToAnotherAction() {
        let granted = freshKey()
        let other = freshKey()
        GeneralAIActionApprovalStore.allowAlways(granted)
        defer { GeneralAIActionApprovalStore.revoke(granted) }
        #expect(GeneralAIActionExecutor.requiresPrompt(.ask, permissionKey: other))
    }

    /// A caller that already showed the user a card is not asked twice — that was the
    /// original (correct) behaviour for General AI, and it must survive the refactor.
    @Test func grantedNeverPromptsAgain() {
        let key = freshKey()
        for source in ExecutionApproval.GrantSource.allCases {
            #expect(!GeneralAIActionExecutor.requiresPrompt(.granted(source), permissionKey: key))
        }
    }

    // MARK: - Saying where the yes came from

    /// Every grant source has to name itself in the audit trail. A caller that claims a
    /// yes it did not collect is then visible after the fact, in `AIAuditHistory`, rather
    /// than being indistinguishable from one that did.
    @Test func everyGrantSourceIsAuditable() {
        var seen = Set<String>()
        for source in ExecutionApproval.GrantSource.allCases {
            let label = source.auditLabel
            #expect(!label.isEmpty)
            #expect(!seen.contains(label))
            seen.insert(label)
        }
        #expect(seen.count == ExecutionApproval.GrantSource.allCases.count)
    }

    /// `.ask` has no source until the user answers, so it must not pretend to have one.
    @Test func askHasNoGrantSourceUntilAnswered() {
        #expect(ExecutionApproval.ask.grantSource == nil)
        #expect(ExecutionApproval.granted(.approvalCard).grantSource == .approvalCard)
    }

    // MARK: - Cancelled is not failed

    /// The four call sites each print their own "Cancelled — nothing was executed."
    /// For the gate to move inside the executor, a refusal has to come back
    /// distinguishable from a route that ran and failed — otherwise declining an action
    /// reads to the user as DoraX trying and breaking.
    @Test func cancelledIsDistinguishableFromFailure() {
        let cancelled = GeneralAIActionResult.cancelled(routeLabel: "Menu")
        #expect(!cancelled.success)
        #expect(cancelled.wasCancelled)

        let failed = GeneralAIActionResult(success: false, message: "Adapter action failed.")
        #expect(!failed.success)
        #expect(!failed.wasCancelled)
    }

    /// A successful run is never cancelled, and nothing sets that flag by accident.
    @Test func successCarriesNoCancellation() {
        let ok = GeneralAIActionResult(success: true, message: "Ran it.")
        #expect(!ok.wasCancelled)
    }

    /// The cancellation message names the route the user declined, so a chat transcript
    /// with several offers in it says which one was turned down.
    @Test func cancellationNamesWhatWasDeclined() {
        let cancelled = GeneralAIActionResult.cancelled(routeLabel: "AppleScript")
        #expect(cancelled.message.contains("AppleScript"))
    }
}
