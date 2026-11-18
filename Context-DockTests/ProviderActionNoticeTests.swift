import Foundation
import Testing

@testable import Context_Dock

/// When the chosen provider cannot act, say so — do not leave the model to explain it.
///
/// Claude Code and Apple's on-device model are run deliberately with none of DoraX's tools:
/// they answer, the app acts. A turn asking for an app action under one of them therefore
/// cannot run one, and the model, having no way to know why, guessed — "my toolset lacks
/// run_menu_command", "not granted this session". Both were attempts to describe a rule nobody
/// had told it.
@Suite("Provider action notice")
struct ProviderActionNoticeTests {
    @Test func aProviderThatCannotActSaysSoOnAnActionRequest() throws {
        let note = try #require(
            ProviderActionNotice.note(provider: .claudeCode, intent: .act))
        #expect(note.contains("Claude Code"))
        #expect(note.contains("AI Providers"))
    }

    /// A question is answerable by any provider, so the notice would only be noise.
    @Test(arguments: [FrontmostAppTaskPlan.Intent.read, .answer])
    func noNoticeWhenNothingHadToRun(intent: FrontmostAppTaskPlan.Intent) {
        #expect(ProviderActionNotice.note(provider: .claudeCode, intent: intent) == nil)
    }

    /// A provider that carries the tools has nothing to explain.
    @Test(arguments: [AIProvider.anthropic, .openAI, .googleGemini])
    func noNoticeWhenTheProviderCanAct(provider: AIProvider) {
        #expect(ProviderActionNotice.note(provider: provider, intent: .act) == nil)
    }

    /// On-device has the same limit and deserves the same sentence, named correctly.
    @Test func onDeviceIsNamedToo() throws {
        let note = try #require(ProviderActionNotice.note(provider: .onDevice, intent: .act))
        #expect(note.contains("On-Device") || note.contains("on-device"))
    }

    /// The notice is suppressed when the turn already produced evidence — it would be
    /// misleading to disclaim capability after tool chips have already appeared.
    @Test func noNoticeWhenEvidenceWasProduced() {
        #expect(
            ProviderActionNotice.note(
                provider: .claudeCode, intent: .act, producedEvidence: true) == nil)
    }

    /// All answer-only providers trigger the notice on act/workflow intents.
    @Test(arguments: [AIProvider.claudeCode, .chatGPTSubscription, .onDevice, .shortcuts])
    func answerOnlyProvidersShowNoticeForActIntent(provider: AIProvider) {
        #expect(ProviderActionNotice.note(provider: provider, intent: .act) != nil)
    }
}
