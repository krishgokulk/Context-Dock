import Testing
import Foundation
@testable import Context_Dock

// MARK: - Profile definitions

@Suite("ProviderCapabilityProfile definitions")
struct ProviderCapabilityProfileDefinitionTests {

    // API providers that accept a tool schema and can dispatch app actions.
    @Test(arguments: [AIProvider.anthropic, .openAI, .googleGemini, .ollama,
                      .openAICompatible, .kimi, .claudeBridge, .chatGPTBridge])
    func apiProvidersAreFullCapability(provider: AIProvider) {
        let profile = provider.capabilityProfile
        #expect(profile.canExecuteActions, "\(provider) should canExecuteActions")
        #expect(profile.canReadData, "\(provider) should canReadData")
        #expect(profile.supportsApprovalFlow, "\(provider) should supportsApprovalFlow")
        #expect(profile.tier == .full)
    }

    // Subscription / local providers run without DoraX's tool schemas.
    @Test(arguments: [AIProvider.claudeCode, .chatGPTSubscription, .onDevice, .shortcuts])
    func localProvidersAreAnswerOnly(provider: AIProvider) {
        let profile = provider.capabilityProfile
        #expect(!profile.canExecuteActions, "\(provider) should NOT canExecuteActions")
        #expect(!profile.canReadData, "\(provider) should NOT canReadData")
        #expect(!profile.supportsApprovalFlow, "\(provider) should NOT supportsApprovalFlow")
        #expect(profile.tier == .answerOnly)
    }

    @Test func everyProviderHasAProfile() {
        for provider in AIProvider.allCases {
            // Just verifying the switch is exhaustive — if a new case is added without
            // updating capabilityProfile the compiler will warn, but this test documents intent.
            _ = provider.capabilityProfile
        }
    }
}

// MARK: - Well-known profiles

@Suite("ProviderCapabilityProfile well-known instances")
struct ProviderCapabilityProfileWellKnownTests {

    @Test func fullProfileFlags() {
        let p = ProviderCapabilityProfile.full
        #expect(p.canExecuteActions)
        #expect(p.canReadData)
        #expect(p.supportsApprovalFlow)
        #expect(p.tier == .full)
    }

    @Test func readOnlyProfileFlags() {
        let p = ProviderCapabilityProfile.readOnly
        #expect(!p.canExecuteActions)
        #expect(p.canReadData)
        #expect(!p.supportsApprovalFlow)
        #expect(p.tier == .readOnly)
    }

    @Test func answerOnlyProfileFlags() {
        let p = ProviderCapabilityProfile.answerOnly
        #expect(!p.canExecuteActions)
        #expect(!p.canReadData)
        #expect(!p.supportsApprovalFlow)
        #expect(p.tier == .answerOnly)
    }
}

// MARK: - Tier display strings

@Suite("ProviderCapabilityProfile.Tier display strings")
struct ProviderCapabilityProfileTierDisplayTests {

    @Test func tierSymbolsAreNonEmpty() {
        for tier in [ProviderCapabilityProfile.Tier.full, .readOnly, .answerOnly] {
            #expect(!tier.symbol.isEmpty, "\(tier) symbol is empty")
            #expect(!tier.label.isEmpty, "\(tier) label is empty")
            #expect(!tier.shortLabel.isEmpty, "\(tier) shortLabel is empty")
        }
    }

    @Test func fullTierHasExpectedStrings() {
        let tier = ProviderCapabilityProfile.Tier.full
        #expect(tier.symbol == "✦")
        #expect(tier.label.lowercased().contains("full") || tier.label.lowercased().contains("action"))
    }
}

// MARK: - Mutation handoff notice

@Suite("ProviderActionNotice mutation handoff")
struct ProviderActionNoticeMutationHandoffTests {

    @Test(arguments: [AIProvider.claudeCode, .chatGPTSubscription, .onDevice, .shortcuts])
    func handoffNoteOnMutationForAnswerOnlyProvider(provider: AIProvider) throws {
        let note = try #require(
            ProviderActionNotice.mutationHandoffNote(provider: provider, intent: .act))
        #expect(note.contains("can't execute actions") || note.contains("cannot execute"))
        #expect(note.contains("Settings"))
    }

    @Test(arguments: [AIProvider.anthropic, .openAI, .googleGemini])
    func noHandoffNoteForFullProviders(provider: AIProvider) {
        #expect(ProviderActionNotice.mutationHandoffNote(provider: provider, intent: .act) == nil)
    }

    @Test(arguments: [FrontmostAppTaskPlan.Intent.read, .answer])
    func noHandoffNoteForNonMutationIntents(intent: FrontmostAppTaskPlan.Intent) {
        #expect(ProviderActionNotice.mutationHandoffNote(provider: .onDevice, intent: intent) == nil)
    }

    @Test func workflowIntentAlsoTriggersHandoff() throws {
        let note = try #require(
            ProviderActionNotice.mutationHandoffNote(provider: .onDevice, intent: .workflow))
        #expect(!note.isEmpty)
    }
}
