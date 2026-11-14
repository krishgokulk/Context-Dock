import Testing
import Foundation
@testable import Context_Dock

// MARK: - H1c: captureIfEligible returns skill info so surfaces can show Saved/Offer rows (#408)
//
// Pure: a synthesized Answer and tool calls in, a CaptureOutcome out. No provider, no disk.

@MainActor
struct SavedSkillUXTests {

    private let mail = "com.apple.mail"

    private func readCall() -> SolvedSkillToolCall {
        SolvedSkillToolCall(
            capability: "mail.search",
            argTemplate: ["sender": "SBI", "day": "today", "unread": "true"],
            isReadOnly: true)
    }

    private func writeCall() -> SolvedSkillToolCall {
        SolvedSkillToolCall(
            capability: "mail.archive",
            argTemplate: ["sender": "SBI", "day": "today"],
            isReadOnly: false)
    }

    private func verifiedAnswer(text: String = "Done") -> AppScopedChatService.Answer {
        AppScopedChatService.Answer(
            text: text, toolChips: [],
            evidenceReceipts: [
                DoraXActionReceipt(command: "mail.search", output: "3 messages", success: true),
                DoraXActionReceipt(
                    command: "verify_outcome", output: "confirmed", success: true,
                    isVerification: true),
            ])
    }

    // MARK: - Read path

    @Test func readEligibleTurnReturnsSavedSkill() {
        let skill = SolvedSkillCapture.build(
            query: "unread mail from SBI today",
            answer: verifiedAnswer(),
            toolCalls: [readCall()],
            bundleId: mail,
            verifiedReadBack: true)
        #expect(skill != nil)
    }

    @Test func savedSkillQueryTemplateContainsSlots() throws {
        let skill = try #require(SolvedSkillCapture.build(
            query: "unread mail from SBI today",
            answer: verifiedAnswer(),
            toolCalls: [readCall()],
            bundleId: mail,
            verifiedReadBack: true))
        #expect(skill.queryTemplate.contains("{sender}") || skill.queryTemplate.contains("{day}"))
    }

    // MARK: - Write path

    @Test func writeEligibleTurnReturnsPendingOffer() {
        let offer = SolvedSkillCapture.buildWriteOffer(
            query: "archive mail from SBI today",
            answer: verifiedAnswer(),
            toolCalls: [writeCall()],
            bundleId: mail,
            verifiedReadBack: true)
        #expect(offer != nil)
    }

    @Test func buildWriteOfferSkipsReadOnlyGuard() {
        let offer = SolvedSkillCapture.buildWriteOffer(
            query: "archive mail from SBI today",
            answer: verifiedAnswer(),
            toolCalls: [writeCall()],
            bundleId: mail,
            verifiedReadBack: true)
        #expect(offer != nil)
    }

    @Test func buildWriteOfferReturnsNilWhenNoReplayCalls() {
        let offer = SolvedSkillCapture.buildWriteOffer(
            query: "archive mail from SBI today",
            answer: verifiedAnswer(),
            toolCalls: [],
            bundleId: mail,
            verifiedReadBack: true)
        #expect(offer == nil)
    }

    // MARK: - Non-app scope (build requires a bundleId; empty string guards it)

    @Test func nonAppScopeProducesNoSkill() {
        let skill = SolvedSkillCapture.build(
            query: "unread mail from SBI today",
            answer: verifiedAnswer(),
            toolCalls: [readCall()],
            bundleId: "",
            verifiedReadBack: true)
        #expect(skill == nil)
    }

    // MARK: - Unverified read-back

    @Test func unverifiedReadBackProducesNoSkill() {
        let noVerification = AppScopedChatService.Answer(
            text: "Done", toolChips: [],
            evidenceReceipts: [
                DoraXActionReceipt(command: "mail.search", output: "3 messages", success: true)
            ])
        let skill = SolvedSkillCapture.build(
            query: "unread mail from SBI today",
            answer: noVerification,
            toolCalls: [readCall()],
            bundleId: mail,
            verifiedReadBack: false)
        #expect(skill == nil)
    }
}
