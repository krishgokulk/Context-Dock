// ProviderContextUsageStore.swift
// Context-Dock
//
// Per-scope turn context-window usage and budget state (#335).
//
// Display-only: observes per-round metrics from tool loops and provider calls,
// mapping them against ProviderContextBudget for the current scope's turn.
// AIContextBudget measures reference text and AITokenLedger aggregates daily totals;
// this store represents the active turn's actual context window occupancy.
//
// Pure presentation: never modifies routing, budgets, or token accounting.
// Multi-round tool loops update context occupancy from the latest round rather
// than summing across rounds (avoiding summing repeated message history).

import Foundation
import Combine

/// Snapshot of the context-window occupancy for a specific conversation scope turn (#335).
struct ScopeContextUsageSnapshot: Equatable, Sendable {
    let scopeKey: String
    let provider: AIProvider
    let modelName: String
    let compactModel: String
    let usedTokens: Int?
    let maxContextTokens: Int
    let percent: Double?
    let isUnknown: Bool
    let lastUpdated: Date

    init(
        scopeKey: String,
        provider: AIProvider,
        modelName: String,
        compactModel: String? = nil,
        usedTokens: Int?,
        maxContextTokens: Int,
        lastUpdated: Date = Date()
    ) {
        self.scopeKey = scopeKey
        self.provider = provider
        self.modelName = modelName
        self.compactModel = compactModel ?? ProviderContextUsageStore.compactModelName(modelName, provider: provider)
        self.usedTokens = usedTokens
        self.maxContextTokens = max(1, maxContextTokens)
        if let usedTokens, usedTokens >= 0 {
            let pct = (Double(usedTokens) / Double(self.maxContextTokens)) * 100.0
            self.percent = min(100.0, max(0.0, pct))
            self.isUnknown = false
        } else {
            self.percent = nil
            self.isUnknown = true
        }
        self.lastUpdated = lastUpdated
    }

    /// Neutral placeholder snapshot when usage is unavailable or unknown.
    static func neutral(
        scopeKey: String,
        provider: AIProvider,
        modelName: String
    ) -> ScopeContextUsageSnapshot {
        let budget = ProviderContextBudget.budget(for: provider)
        return ScopeContextUsageSnapshot(
            scopeKey: scopeKey,
            provider: provider,
            modelName: modelName,
            usedTokens: nil,
            maxContextTokens: budget.maxContextTokens
        )
    }
}

final class ProviderContextUsageStore: ObservableObject {
    static let shared = ProviderContextUsageStore()

    private let lock = NSLock()
    private var _snapshotsByScope: [String: ScopeContextUsageSnapshot] = [:]

    private init() {}

    /// Returns the context usage snapshot for the given scope, degrading to neutral when unknown.
    func snapshot(for scope: GeneralChatScope?) -> ScopeContextUsageSnapshot {
        let key = scope?.storageKey ?? GeneralChatScope.general.storageKey

        lock.lock()
        if let existing = _snapshotsByScope[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let provider = currentRoutedProvider(for: scope)
        let model = currentRoutedModel(for: provider)

        return ScopeContextUsageSnapshot.neutral(
            scopeKey: key,
            provider: provider,
            modelName: model
        )
    }

    /// Record per-request round metrics for the given scope.
    /// Multi-round tool loops call this per round, which updates the prompt context
    /// fill with the latest round's context tokens (avoiding summing repeated prompts).
    func recordRound(
        scope: GeneralChatScope?,
        provider: AIProvider,
        model: String?,
        inputTokens: Int?,
        outputTokens: Int? = nil
    ) {
        let key = scope?.storageKey ?? GeneralChatScope.general.storageKey
        let effectiveModel: String
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            effectiveModel = model
        } else {
            effectiveModel = currentRoutedModel(for: provider)
        }
        let budget = ProviderContextBudget.budget(for: provider)

        let used: Int?
        if let input = inputTokens {
            used = max(0, input + (outputTokens ?? 0))
        } else {
            used = nil
        }

        let snap = ScopeContextUsageSnapshot(
            scopeKey: key,
            provider: provider,
            modelName: effectiveModel,
            usedTokens: used,
            maxContextTokens: budget.maxContextTokens
        )

        lock.lock()
        _snapshotsByScope[key] = snap
        lock.unlock()

        notifyChange()
    }

    /// Clear stale usage when starting a new turn.
    func startTurn(scope: GeneralChatScope?, provider: AIProvider? = nil, model: String? = nil) {
        let key = scope?.storageKey ?? GeneralChatScope.general.storageKey
        let effProvider = provider ?? currentRoutedProvider(for: scope)
        let effModel = model ?? currentRoutedModel(for: effProvider)
        let neutralSnap = ScopeContextUsageSnapshot.neutral(scopeKey: key, provider: effProvider, modelName: effModel)

        lock.lock()
        _snapshotsByScope[key] = neutralSnap
        lock.unlock()

        notifyChange()
    }

    /// Explicitly clear a scope (e.g. when conversation is cleared or scope abandoned).
    func clearScope(_ scope: GeneralChatScope) {
        lock.lock()
        _snapshotsByScope.removeValue(forKey: scope.storageKey)
        lock.unlock()

        notifyChange()
    }

    /// Clear all scope snapshots (e.g. for testing or app-wide reset).
    func clearAll() {
        lock.lock()
        _snapshotsByScope.removeAll()
        lock.unlock()

        notifyChange()
    }

    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Routing Helpers

    func currentRoutedProvider(for scope: GeneralChatScope? = nil) -> AIProvider {
        if Thread.isMainThread {
            return AppSettings.shared.selectedAIProvider
        }
        return DispatchQueue.main.sync {
            AppSettings.shared.selectedAIProvider
        }
    }

    func currentRoutedModel(for provider: AIProvider) -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                self.currentRoutedModel(for: provider)
            }
        }

        switch provider {
        case .onDevice:
            return "On-Device"
        case .googleGemini:
            let m = AppSettings.shared.selectedGeminiModel
            return m.isEmpty ? "gemini-2.0-flash" : m
        case .openAI:
            let m = AppSettings.shared.selectedOpenAIModel
            return m.isEmpty ? "gpt-4o-mini" : m
        case .anthropic:
            let m = AppSettings.shared.selectedAnthropicModel
            return m.isEmpty ? AnthropicModelCatalog.defaultModelID : m
        case .claudeCode:
            let m = AppSettings.shared.claudeCodeModel
            return m.isEmpty ? "Sonnet" : m
        case .chatGPTSubscription:
            let m = AppSettings.shared.chatGPTSubscriptionModel
            return m.isEmpty ? "GPT-4o" : m
        case .claudeBridge:
            return "Claude Pro"
        case .chatGPTBridge:
            return "ChatGPT Plus"
        case .ollama:
            let m = AppSettings.shared.selectedOllamaModel
            return m.isEmpty ? "Ollama" : m
        case .openAICompatible:
            let m = AppSettings.shared.openAICompatibleModelID
            return m.isEmpty ? "Compatible" : m
        case .kimi:
            let m = AppSettings.shared.selectedKimiModel
            return m.isEmpty ? "kimi-k2.5" : m
        case .shortcuts:
            return "Shortcuts"
        }
    }

    // MARK: - Model Name Formatting

    nonisolated static func compactModelName(_ raw: String, provider: AIProvider? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return provider?.shortName ?? "AI"
        }
        let lower = trimmed.lowercased()
        if lower.contains("claude-3-7-sonnet") || lower.contains("sonnet-3-7") || lower.contains("sonnet-3.7") {
            return "Sonnet 3.7"
        } else if lower.contains("claude-3-5-sonnet") || lower.contains("sonnet-3-5") || lower.contains("sonnet-3.5") {
            return "Sonnet 3.5"
        } else if lower.contains("claude-3-5-haiku") || lower.contains("haiku-3-5") || lower.contains("haiku-3.5") {
            return "Haiku 3.5"
        } else if lower.contains("claude-3-opus") || lower.contains("opus") {
            return "Opus"
        } else if lower.contains("gemini-2.0-flash") || lower.contains("gemini-2-flash") {
            return "Flash 2.0"
        } else if lower.contains("gemini-1.5-pro") {
            return "Pro 1.5"
        } else if lower.contains("gemini-1.5-flash") {
            return "Flash 1.5"
        } else if lower.contains("gpt-4o-mini") {
            return "GPT-4o mini"
        } else if lower.contains("gpt-4o") {
            return "GPT-4o"
        } else if lower.contains("o1-mini") {
            return "o1-mini"
        } else if lower.contains("o1-preview") || lower == "o1" {
            return "o1"
        } else if lower.contains("o3-mini") {
            return "o3-mini"
        } else if lower.contains("kimi-k2.5") {
            return "Kimi k2.5"
        } else if trimmed.count > 14 {
            return String(trimmed.prefix(12)) + "…"
        }
        return trimmed
    }
}
