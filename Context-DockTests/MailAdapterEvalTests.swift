import Foundation
import Testing

@testable import Context_Dock

// The Mail adapter's canonical question set, plus the one promise Mail makes that no other
// adapter has to: it cannot send.
//
// Mail is the first adapter where the registry is not the whole story. Its actions have
// historically been menu paths rather than capabilities, which is how `Message ▸ Send` came to
// be as ungated as `Window ▸ Minimize` — see IrreversibleMenuConsentTests. The capabilities
// added here are deliberately the read half plus a draft, so that the useful work does not
// depend on DoraX owning the Send button.

@MainActor
struct MailAdapterEvalTests {

    private static let bundleId = "com.apple.mail"

    private func decision(_ query: String) -> AgentSourceDecision {
        AgentSourceAuthority.decide(query: query, scopeBundleId: Self.bundleId)
    }

    // MARK: - Reads must reach a reader

    @Test func questionsAboutTheMailboxGroundInALiveRead() {
        for query in [
            "anything unread?",
            "how many emails do i have today?",
            "show me my recent mail",
            "any messages from sarah?",
        ] {
            let d = decision(query)
            #expect(d.primary == .liveState, "\"\(query)\" must reach a reader, got \(d.primary)")
            #expect(!d.allowsMemoryEvidence, "\"\(query)\" must not come from saved memory")
        }
    }

    // MARK: - Writes must stay writes

    @Test func changesAreNeverClassifiedAsReads() {
        for query in [
            "reply to this with a thank you",
            "forward this to sujith",
            "send this draft",
            "delete this message",
        ] {
            let d = decision(query)
            #expect(d.primary != .liveState, "\"\(query)\" is a change, got \(d.primary)")
        }
    }

    // MARK: - Consequence is declared

    @Test func readsAreFreeAndTheDraftIsGated() {
        let registry = CapabilityRegistry.shared
        for id in ["mail.recent", "mail.search", "mail.currentMessage"] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) is a read but asks approval")
        }
        guard let draft = registry.capability(id: "mail.createDraft") else {
            Issue.record("mail.createDraft is not registered"); return
        }
        #expect(
            draft.riskLevel.requiresApproval,
            "mail.createDraft puts text in a composer and must be approved first")
    }

    // MARK: - The send path exists and always requires approval

    /// mail.send has its own approval design (riskLevel .high, full input schema).
    /// The property worth pinning is not absence — it is that the capability cannot
    /// run without explicit approval.
    @Test func sendMailCapabilityRequiresApproval() {
        guard let cap = CapabilityRegistry.shared.capability(id: "mail.send") else {
            Issue.record("mail.send is not registered"); return
        }
        #expect(cap.riskLevel.requiresApproval, "mail.send must require approval before it runs")
    }

    // MARK: - Absence stays a finding

    @Test func nothingSelectedIsAnAnswer() {
        for output in [
            "No message is selected in Mail (or Mail isn't running).",
            "No recent inbox messages (or Mail isn't running).",
        ] {
            #expect(!EvidenceSufficiency.admitsDefeat(output), "\"\(output)\" is a finding")
        }
    }
}
