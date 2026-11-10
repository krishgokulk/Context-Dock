// ProviderContextUsageChipTests.swift
// Context-DockTests
//
// Tests for Provider / context usage chip and store (#335).

import Foundation
import Testing
@testable import Context_Dock

private func runOnMain<T>(_ block: () -> T) -> T {
    if Thread.isMainThread {
        return block()
    } else {
        return DispatchQueue.main.sync(execute: block)
    }
}

struct ProviderContextUsageChipTests {

    @Test func initialSnapshotIsNeutralAndUnknown() {
        runOnMain {
            let store = ProviderContextUsageStore.shared
            store.clearAll()

            let scope = GeneralChatScope.app(bundleId: "com.apple.Safari")
            let snapshot = store.snapshot(for: scope)

            #expect(snapshot.isUnknown)
            #expect(snapshot.usedTokens == nil)
            #expect(snapshot.percent == nil)
            #expect(snapshot.maxContextTokens > 0)
        }
    }

    @Test func singleRoundRecordsAccurateContextFillAgainstBudget() {
        runOnMain {
            let store = ProviderContextUsageStore.shared
            store.clearAll()

            let scope = GeneralChatScope.app(bundleId: "com.apple.Safari")
            let provider = AIProvider.anthropic
            let budget = ProviderContextBudget.budget(for: provider)
            #expect(budget.maxContextTokens == 200_000)

            // Record a single round of 20,000 input tokens + 2,000 output tokens = 22,000 tokens
            store.recordRound(
                scope: scope,
                provider: provider,
                model: "claude-3-5-sonnet-20241022",
                inputTokens: 20_000,
                outputTokens: 2_000
            )

            let snapshot = store.snapshot(for: scope)
            #expect(!snapshot.isUnknown)
            #expect(snapshot.usedTokens == 22_000)
            #expect(snapshot.maxContextTokens == 200_000)
            // 22,000 / 200,000 = 11.0%
            #expect(snapshot.percent == 11.0)
            #expect(snapshot.compactModel == "Sonnet 3.5")
        }
    }

    @Test func multiRoundToolLoopAvoidsSummingRepeatedPrompts() {
        runOnMain {
            let store = ProviderContextUsageStore.shared
            store.clearAll()

            let scope = GeneralChatScope.general
            let provider = AIProvider.openAI
            let budget = ProviderContextBudget.budget(for: provider)
            #expect(budget.maxContextTokens == 128_000)

            // Round 1 sends initial prompt: 1,500 prompt tokens, 50 output tokens
            store.recordRound(
                scope: scope,
                provider: provider,
                model: "gpt-4o-mini",
                inputTokens: 1_500,
                outputTokens: 50
            )

            let snap1 = store.snapshot(for: scope)
            #expect(snap1.usedTokens == 1_550)

            // Round 2 includes the same prompt + tool result: 2,400 prompt tokens, 100 output tokens.
            // MUST NOT be 1,550 + 2,500 = 4,050! It must represent current-turn context fill: 2,500.
            store.recordRound(
                scope: scope,
                provider: provider,
                model: "gpt-4o-mini",
                inputTokens: 2_400,
                outputTokens: 100
            )

            let snap2 = store.snapshot(for: scope)
            #expect(snap2.usedTokens == 2_500)
            #expect(snap2.usedTokens != 4_050)
            // 2,500 / 128,000 ~= 1.953%
            #expect(snap2.percent != nil)
            #expect(abs(snap2.percent! - (2500.0 / 128000.0 * 100.0)) < 0.001)
        }
    }

    @Test func scopeChangesRemainIsolatedAndNeutralWhenUnvisited() {
        runOnMain {
            let store = ProviderContextUsageStore.shared
            store.clearAll()

            let safariScope = GeneralChatScope.app(bundleId: "com.apple.Safari")
            let finderScope = GeneralChatScope.app(bundleId: "com.apple.Finder")

            // Record usage in Safari
            store.recordRound(
                scope: safariScope,
                provider: .anthropic,
                model: "claude-3-7-sonnet-20250219",
                inputTokens: 10_000
            )

            let safariSnap = store.snapshot(for: safariScope)
            #expect(!safariSnap.isUnknown)
            #expect(safariSnap.usedTokens == 10_000)

            // Finder has not run a turn yet — must remain neutral, not inherit Safari's usage
            let finderSnap = store.snapshot(for: finderScope)
            #expect(finderSnap.isUnknown)
            #expect(finderSnap.usedTokens == nil)
            #expect(finderSnap.percent == nil)
        }
    }

    @Test func turnStartClearsStaleUsageForScope() {
        runOnMain {
            let store = ProviderContextUsageStore.shared
            store.clearAll()

            let scope = GeneralChatScope.app(bundleId: "com.apple.Mail")

            // Prior turn completed with usage
            store.recordRound(
                scope: scope,
                provider: .googleGemini,
                model: "gemini-2.0-flash",
                inputTokens: 50_000
            )

            let priorSnap = store.snapshot(for: scope)
            #expect(priorSnap.usedTokens == 50_000)

            // Starting a new turn clears stale usage so old percentage does not linger
            store.startTurn(scope: scope, provider: .googleGemini, model: "gemini-2.0-flash")

            let newTurnSnap = store.snapshot(for: scope)
            #expect(newTurnSnap.isUnknown)
            #expect(newTurnSnap.usedTokens == nil)
            #expect(newTurnSnap.percent == nil)
        }
    }

    @Test func compactModelNameFormatting() {
        #expect(ProviderContextUsageStore.compactModelName("claude-3-7-sonnet-20250219") == "Sonnet 3.7")
        #expect(ProviderContextUsageStore.compactModelName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ProviderContextUsageStore.compactModelName("claude-3-5-haiku-20241022") == "Haiku 3.5")
        #expect(ProviderContextUsageStore.compactModelName("gemini-2.0-flash") == "Flash 2.0")
        #expect(ProviderContextUsageStore.compactModelName("gemini-1.5-pro") == "Pro 1.5")
        #expect(ProviderContextUsageStore.compactModelName("gpt-4o-mini") == "GPT-4o mini")
        #expect(ProviderContextUsageStore.compactModelName("gpt-4o") == "GPT-4o")
        #expect(ProviderContextUsageStore.compactModelName("kimi-k2.5") == "Kimi k2.5")
        #expect(ProviderContextUsageStore.compactModelName("", provider: .onDevice) == "Apple Intelligence")
    }

    @Test func percentClampingAndUnknownDegradation() {
        runOnMain {
            let store = ProviderContextUsageStore.shared
            store.clearAll()

            let scope = GeneralChatScope.cli(command: "git")
            // Unknown input
            store.recordRound(scope: scope, provider: .ollama, model: "llama3", inputTokens: nil)
            let unknownSnap = store.snapshot(for: scope)
            #expect(unknownSnap.isUnknown)
            #expect(unknownSnap.percent == nil)

            // Exceeded budget clamp test: 10,000 tokens on 8,192 budget clamps to 100.0%
            store.recordRound(scope: scope, provider: .ollama, model: "llama3", inputTokens: 10_000)
            let clampedSnap = store.snapshot(for: scope)
            #expect(clampedSnap.percent == 100.0)
        }
    }
}
