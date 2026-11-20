import Testing
import Foundation
@testable import Context_Dock

// Tests for Task #153 E5b: proactive token budgeting before on-device dispatch.
//
// FoundationModels sessions require Apple Intelligence hardware and cannot be mocked, so
// these tests cover the observable contract via an injectable OnDeviceTokenCounter.

// MARK: - Test helpers

/// A counter that returns the same value regardless of text — used to force a
/// known outcome (always fits, or never fits until history is empty).
private struct ConstantTokenCounter: OnDeviceTokenCounter {
    let value: Int
    func count(_ text: String) async -> Int { value }
}

/// A counter proportional to text length. Produces deterministic over/under budget
/// outcomes when the test controls the string sizes.
/// tokens = ceil(chars * scale)
private struct ScaledTokenCounter: OnDeviceTokenCounter {
    let scale: Double
    func count(_ text: String) async -> Int { Int(ceil(Double(text.count) * scale)) }
}

private func makeTurns(count: Int, charsEach: Int = 10) -> [ChatMessage] {
    (0..<count).map { i in
        ChatMessage(role: i.isMultiple(of: 2) ? .user : .assistant,
                    content: String(repeating: "x", count: charsEach))
    }
}

// MARK: - Budget constants

struct OnDevicePromptBudgetConstantsTests {

    @Test("windowTokens is 4096")
    func windowTokensIs4096() {
        #expect(OnDevicePromptBudget.windowTokens == 4_096)
    }

    @Test("replyReserve is 1000")
    func replyReserveIs1000() {
        #expect(OnDevicePromptBudget.replyReserve == 1_000)
    }

    @Test("maxPromptTokens equals windowTokens minus replyReserve")
    func maxPromptTokensIsWindowMinusReserve() {
        #expect(OnDevicePromptBudget.maxPromptTokens ==
                OnDevicePromptBudget.windowTokens - OnDevicePromptBudget.replyReserve)
    }

    @Test("reply reserve is strictly preserved — maxPromptTokens < windowTokens")
    func replyReserveStrictlyPreserved() {
        #expect(OnDevicePromptBudget.maxPromptTokens < OnDevicePromptBudget.windowTokens)
    }
}

// MARK: - fittingHistory

struct OnDevicePromptBudgetFittingTests {

    // MARK: Under-budget: history returned unmodified

    @Test("under-budget prompt: history returned unmodified")
    func underBudgetReturnsUnmodified() async {
        let history = makeTurns(count: 4)
        let counter = ConstantTokenCounter(value: OnDevicePromptBudget.maxPromptTokens - 1)
        let result = await OnDevicePromptBudget.fittingHistory(
            systemPrompt: "sys", history: history, message: "msg", counter: counter)
        #expect(result.count == 4)
    }

    @Test("exactly-at-budget prompt: history returned unmodified")
    func atBudgetReturnsUnmodified() async {
        let history = makeTurns(count: 2)
        let counter = ConstantTokenCounter(value: OnDevicePromptBudget.maxPromptTokens)
        let result = await OnDevicePromptBudget.fittingHistory(
            systemPrompt: "sys", history: history, message: "msg", counter: counter)
        #expect(result.count == 2)
    }

    // MARK: Over-budget: oldest turns dropped

    @Test("over-budget: oldest turn dropped, newest kept")
    func overBudgetDropsOldestTurn() async {
        // Scale = 1.0 token per char. System=100, message=100; each turn body=1200 chars.
        // 3 turns assembled: ~100+2+24+1200+1200+1200+labels+100 ≈ 3836 chars → 3836 tokens > 3096
        // 2 turns assembled: ~100+2+24+1200+1200+labels+100 ≈ 2636 chars → 2636 tokens < 3096
        let sys = String(repeating: "s", count: 100)
        let msg = String(repeating: "m", count: 100)
        let history = makeTurns(count: 3, charsEach: 1200)
        let counter = ScaledTokenCounter(scale: 1.0)
        let result = await OnDevicePromptBudget.fittingHistory(
            systemPrompt: sys, history: history, message: msg, counter: counter)
        #expect(result.count == 2)
        // Newest 2 turns are kept.
        #expect(result.first?.content == history[1].content)
        #expect(result.last?.content == history[2].content)
    }

    @Test("over-budget: progressively drops until fits")
    func overBudgetDropsProgressively() async {
        // 5 turns × 1000 chars; at scale 1.0 all 5 assembled ≈ 5000+ chars → over budget
        // 1 turn ≈ 1000+200 = 1200 chars → under budget (3096)
        let sys = String(repeating: "s", count: 50)
        let msg = String(repeating: "m", count: 50)
        let history = makeTurns(count: 5, charsEach: 1000)
        let counter = ScaledTokenCounter(scale: 1.0)
        let result = await OnDevicePromptBudget.fittingHistory(
            systemPrompt: sys, history: history, message: msg, counter: counter)
        // Should keep at most a few turns; the exact count is budget-driven.
        // The important invariant: result is a contiguous suffix of history.
        let resultContents = result.map(\.content)
        let tail = history.suffix(result.count).map(\.content)
        #expect(resultContents == tail, "Result must be a suffix of history")
    }

    @Test("over-budget with every history size: returns empty when nothing fits")
    func overBudgetReturnsEmptyWhenNothingFits() async {
        let history = makeTurns(count: 3)
        // Always over budget regardless of text — empty history is the only escape.
        let counter = ConstantTokenCounter(value: OnDevicePromptBudget.maxPromptTokens + 1)
        let result = await OnDevicePromptBudget.fittingHistory(
            systemPrompt: "sys", history: history, message: "msg", counter: counter)
        #expect(result.isEmpty)
    }

    // MARK: Empty history

    @Test("empty history: returns empty immediately")
    func emptyHistoryReturnsEmpty() async {
        let counter = ConstantTokenCounter(value: 100)
        let result = await OnDevicePromptBudget.fittingHistory(
            systemPrompt: "sys", history: [], message: "msg", counter: counter)
        #expect(result.isEmpty)
    }

    // MARK: assembleForCounting

    @Test("assembleForCounting: no history produces system+message only")
    func assembleNoHistoryOmitsHistoryBlock() {
        let assembled = OnDevicePromptBudget.assembleForCounting(
            system: "sys", history: [], message: "msg")
        #expect(!assembled.contains("Conversation History"))
        #expect(assembled.contains("sys"))
        #expect(assembled.contains("msg"))
    }

    @Test("assembleForCounting: history block uses User/Assistant labels")
    func assembleHistoryUsesRoleLabels() {
        let history = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "hi"),
        ]
        let assembled = OnDevicePromptBudget.assembleForCounting(
            system: "sys", history: history, message: "msg")
        #expect(assembled.contains("User: hello"))
        #expect(assembled.contains("Assistant: hi"))
    }

    // MARK: Default counter (CharacterTokenCounter)

    @Test("CharacterTokenCounter: tokens approximate chars/4")
    func characterCounterApproximation() async {
        let counter = CharacterTokenCounter()
        let text = String(repeating: "a", count: 400)
        let n = await counter.count(text)
        #expect(n == 100, "400 chars / 4 = 100 tokens")
    }

    @Test("CharacterTokenCounter: rounds up for non-multiples of 4")
    func characterCounterRoundsUp() async {
        let counter = CharacterTokenCounter()
        let n = await counter.count("abc")  // 3 chars → (3+3)/4 = 1
        #expect(n == 1)
    }
}
