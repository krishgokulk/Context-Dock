import Foundation
import Testing

@testable import Context_Dock

// The Messages adapter's canonical question set.
//
// Messages makes the same promise Mail does and keeps it the same way: there is no send
// capability. messages.compose opens the window through the imessage:// URL scheme, which
// cannot send — the person confirms in the UI. That property is worth pinning, because
// MessagesAutomation also carries a postEnter helper that synthesises Return, and a Return in
// a compose window is a sent message.

@MainActor
struct MessagesAdapterEvalTests {

    private static let bundleId = "com.apple.MobileSMS"

    private func decision(_ query: String) -> AgentSourceDecision {
        AgentSourceAuthority.decide(query: query, scopeBundleId: Self.bundleId)
    }

    // MARK: - Reads must reach a reader

    @Test func questionsAboutTheConversationGroundInALiveRead() {
        for query in [
            "any unread messages?",
            "show me my recent messages",
            "how many unread do i have?",
            "anything from sujith today?",
        ] {
            let d = decision(query)
            #expect(d.primary == .liveState, "\"\(query)\" must reach a reader, got \(d.primary)")
            #expect(!d.allowsMemoryEvidence, "\"\(query)\" must not come from saved memory")
        }
    }

    // MARK: - Changes stay changes

    /// Both verbs name the one capability that acts: messages.compose. A request that reads as
    /// a question is answered from a reader and never opens anything, and never shows the
    /// approval its .medium declaration exists to require.
    @Test func askingToWriteAMessageIsAChange() {
        for query in [
            "send a message to sujith saying i'm running late",
            "compose a message to sujith about dinner",
        ] {
            #expect(
                GeneralAIActionResolver.shared.requestsChange(query),
                "\"\(query)\" asks for messages.compose but reads as a question")
        }
    }

    /// The counterweight. Questions about the same conversation must stay questions.
    @Test func questionsAboutMessagesAreNotChanges() {
        for query in [
            "what did sujith say?",
            "any unread messages?",
            "who do i message most?",
        ] {
            #expect(
                !GeneralAIActionResolver.shared.requestsChange(query),
                "\"\(query)\" only asks")
        }
    }

    // MARK: - Consequence is declared

    @Test func readsAreFreeAndComposeIsGated() {
        let registry = CapabilityRegistry.shared
        for id in ["messages.topContacts", "messages.recent", "messages.search"] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) is a read but asks approval")
        }
        guard let compose = registry.capability(id: "messages.compose") else {
            Issue.record("messages.compose is not registered"); return
        }
        #expect(
            compose.riskLevel.requiresApproval,
            "messages.compose puts text in front of another person and must be approved")
    }

    /// The promise. Messages must not grow a capability that sends — the compose window plus a
    /// person pressing Return is a better guarantee than any approval sheet, and the property
    /// only holds while nothing in the registry can send on its own.
    @Test func noCapabilityCanSendAMessage() {
        let sendish = CapabilityRegistry.shared.all.filter { capability in
            guard capability.appBundleID == Self.bundleId else { return false }
            let name = capability.id.lowercased()
            return name.contains("send") || name.contains("reply")
        }
        #expect(
            sendish.isEmpty,
            "Messages grew a send-shaped capability: \(sendish.map(\.id).joined(separator: ", "))")
    }

    // MARK: - Absence stays a finding

    /// Verbatim from AppleMessagesMCPCapabilities. A search that ran and matched nothing has
    /// answered; so has a reader that found Messages closed and said so.
    @Test func findingNothingIsAnAnswer() {
        for output in [
            "No Messages matched ‘invoice’. ",
            "No conversations could be read. Messages is not open, so ",
        ] {
            #expect(!EvidenceSufficiency.admitsDefeat(output), "\"\(output)\" is a finding")
        }
    }
}
