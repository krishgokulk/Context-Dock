import Testing
import Foundation
@testable import Context_Dock

// MARK: - H1c: captureIfEligible returns skill info so surfaces can show Saved/Offer rows (#408)
//
// Pure: a synthesized Answer and tool calls in, a CaptureOutcome out. No provider, no disk.

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
        let outcome = SolvedSkillCapture.captureIfEligible(
            query: "unread mail from SBI today",
            scope: .app(mail),
            answer: verifiedAnswer(),
            toolCalls: [readCall()])
        #expect(outcome.savedSkill != nil)
        #expect(outcome.pendingWriteSkillOffer == nil)
    }

    @Test func savedSkillQueryTemplateContainsSlots() throws {
        let outcome = SolvedSkillCapture.captureIfEligible(
            query: "unread mail from SBI today",
            scope: .app(mail),
            answer: verifiedAnswer(),
            toolCalls: [readCall()])
        let skill = try #require(outcome.savedSkill)
        #expect(skill.queryTemplate.contains("{sender}") || skill.queryTemplate.contains("{day}"))
    }

    // MARK: - Write path

    @Test func writeEligibleTurnReturnsPendingOffer() {
        let outcome = SolvedSkillCapture.captureIfEligible(
            query: "archive mail from SBI today",
            scope: .app(mail),
            answer: verifiedAnswer(),
            toolCalls: [writeCall()])
        #expect(outcome.pendingWriteSkillOffer != nil)
        #expect(outcome.savedSkill == nil)
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

    // MARK: - Non-app scope

    @Test func nonAppScopeReturnsEmptyOutcome() {
        let outcome = SolvedSkillCapture.captureIfEligible(
            query: "unread mail from SBI today",
            scope: .global,
            answer: verifiedAnswer(),
            toolCalls: [readCall()])
        #expect(outcome.savedSkill == nil)
        #expect(outcome.pendingWriteSkillOffer == nil)
    }

    // MARK: - Unverified read-back

    @Test func unverifiedReadBackProducesNeitherOutcome() {
        let noVerification = AppScopedChatService.Answer(
            text: "Done", toolChips: [],
            evidenceReceipts: [
                DoraXActionReceipt(command: "mail.search", output: "3 messages", success: true)
            ])
        let outcome = SolvedSkillCapture.captureIfEligible(
            query: "unread mail from SBI today",
            scope: .app(mail),
            answer: noVerification,
            toolCalls: [readCall()])
        #expect(outcome.savedSkill == nil)
        #expect(outcome.pendingWriteSkillOffer == nil)
    }
}
