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

    // MARK: - The promise: no send capability exists

    /// The adapter must not grow a send. Drafting is built on `mailto:`, which has no send
    /// verb, so the capability route cannot send however it is asked — and that property is
    /// only worth anything while nothing else in the registry can either.
    ///
    /// If this fails, someone added a send path: it needs its own approval design, not this
    /// one, and the honest-reporting rule below stops applying.
    @Test func noCapabilityCanSendMail() {
        let sendish = CapabilityRegistry.shared.all.filter { capability in
            guard capability.appBundleID == Self.bundleId else { return false }
            let name = capability.id.lowercased()
            return name.contains("send") || name.contains("reply") || name.contains("forward")
        }
        #expect(
            sendish.isEmpty,
            "Mail grew a send-shaped capability (\(sendish.map(\.id).joined(separator: ", "))) — "
        )
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

    // MARK: - "read my latest mail" gets a body, not just a header (#302)

    /// The regression this issue is about: mail.recent used to return only subject/sender, so
    /// "read my latest mail" could only ever report the header. The newest message now carries
    /// its body through.
    @Test func recentReadsTheLatestMessageBody() {
        let out = AppleMailMCPCapabilities.formatRecent([
            ["subject": "Invoice #42", "sender": "billing@acme.com", "date": "Mon",
             "read": false, "body": "Your payment of $120 is due Friday. Thanks."],
            ["subject": "Lunch?", "sender": "sam@x.com", "date": "Sun", "read": true],
        ])
        #expect(out.contains("Your payment of $120 is due Friday."),
                "the latest message's body must be in the output")
        #expect(out.contains("Invoice #42") && out.contains("billing@acme.com"))
        #expect(out.contains("Lunch?"), "the rest stay as a header list")
    }

    /// Honesty: when the body genuinely didn't come back, say so — never invent one and never
    /// pretend the header is the whole message.
    @Test func recentAdmitsWhenBodyIsMissing() {
        let out = AppleMailMCPCapabilities.formatRecent([
            ["subject": "No body here", "sender": "a@b.com", "date": "Tue", "read": false],
        ])
        #expect(out.contains("No body here"))
        #expect(out.contains("no readable body"),
                "a missing body is reported as a limit, not hidden")
    }

    /// A newsletter can't blow the turn's token budget.
    @Test func recentTruncatesAnOversizeBody() {
        let huge = String(repeating: "x", count: AppleMailMCPCapabilities.recentBodyCap + 500)
        let out = AppleMailMCPCapabilities.formatRecent([
            ["subject": "Big", "sender": "n@news.com", "date": "Wed", "read": true, "body": huge],
        ])
        #expect(out.contains("body truncated"))
        #expect(out.count < huge.count, "the oversize body was capped")
    }

    @Test func recentEmptyStaysTheKnownFinding() {
        #expect(AppleMailMCPCapabilities.formatRecent([])
            == "No recent inbox messages (or Mail isn't running).")
    }
}
