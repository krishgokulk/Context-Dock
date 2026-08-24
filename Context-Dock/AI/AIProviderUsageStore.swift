// AIProviderUsageStore.swift
// Context-Dock
//
// Live API rate-limit / usage for the user's configured providers, parsed from
// the response headers each provider returns (Anthropic `anthropic-ratelimit-*`,
// OpenAI/compatible `x-ratelimit-*`). This is the only usage data these APIs
// expose — remaining requests/tokens for the current window + when it resets.
//
// Subscription plans are a different question with a worse answer. A bridge fronting Claude
// Pro or ChatGPT Plus strips the upstream rate-limit headers, so a *successful* request
// carries no quota information at all — measured, not assumed. The plan says nothing about
// how much is left until the moment it says there is none left, and that refusal does carry
// the two facts worth having: which plan, and when it resets. So subscription usage here is
// exactly that: known-exhausted until a stated time, or nothing. No percentage bar is drawn
// for a denominator DoraX cannot see.

import Combine
import Foundation

struct AIProviderUsage: Identifiable, Codable {
    let id: String  // host
    var providerName: String
    var remainingRequests: Int?
    var limitRequests: Int?
    var remainingTokens: Int?
    var limitTokens: Int?
    var resetText: String?
    var capturedAt: Date
}

/// A subscription plan that has run out, and when it comes back.
struct AISubscriptionQuota: Identifiable, Codable {
    /// AIProvider raw value — the plan belongs to the provider, not to a host, because two
    /// providers share one bridge host.
    let id: String
    var providerName: String
    /// "pro", "plus" — as the bridge reported it, when it reported one.
    var planType: String?
    var resetsAt: Date
    var capturedAt: Date

    var isExhausted: Bool { resetsAt > Date() }
}

@MainActor
final class AIProviderUsageStore: ObservableObject {
    static let shared = AIProviderUsageStore()

    @Published private(set) var usage: [AIProviderUsage] = []
    @Published private(set) var subscriptionQuotas: [AISubscriptionQuota] = []

    private let persistenceKey = "AIProviderUsageStore.snapshots.v1"
    private let quotaKey = "AIProviderUsageStore.subscriptionQuotas.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: quotaKey),
            let saved = try? JSONDecoder().decode([AISubscriptionQuota].self, from: data)
        {
            // A window that has already passed is not news. Dropped on load so a quota from
            // last week never greets the user as current.
            subscriptionQuotas = saved.filter(\.isExhausted)
        }
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
            let saved = try? JSONDecoder().decode([AIProviderUsage].self, from: data)
        else { return }
        usage = saved.sorted { $0.providerName < $1.providerName }
    }

    /// Files a plan as spent until `resetsAt`. Called from the one place that sees the
    /// refusal — the HTTP layer — so every surface learns it at once.
    func recordSubscriptionExhausted(
        provider: AIProvider, planType: String?, resetsAt: Date
    ) {
        let quota = AISubscriptionQuota(
            id: provider.rawValue,
            providerName: provider.displayName,
            planType: planType,
            resetsAt: resetsAt,
            capturedAt: Date())
        subscriptionQuotas.removeAll { $0.id == quota.id }
        subscriptionQuotas.append(quota)
        subscriptionQuotas.sort { $0.providerName < $1.providerName }
        persistQuotas()
    }

    /// The plan's state right now, dropping any window that has since reset.
    func subscriptionQuota(for provider: AIProvider) -> AISubscriptionQuota? {
        subscriptionQuotas.first { $0.id == provider.rawValue && $0.isExhausted }
    }

    /// Clears windows that have elapsed. Called by the surfaces that display them, so a
    /// countdown reaching zero removes the row instead of sitting at "resets in 0m".
    func pruneElapsedQuotas() {
        let live = subscriptionQuotas.filter(\.isExhausted)
        guard live.count != subscriptionQuotas.count else { return }
        subscriptionQuotas = live
        persistQuotas()
    }

    private func persistQuotas() {
        guard let data = try? JSONEncoder().encode(subscriptionQuotas) else { return }
        UserDefaults.standard.set(data, forKey: quotaKey)
    }

    /// Record rate-limit headers from a provider response, keyed by host.
    nonisolated func record(host: String, headers: [AnyHashable: Any]) {
        // HTTP header names are case-insensitive. `HTTPURLResponse.allHeaderFields` commonly
        // supplies title-cased keys (for example `X-RateLimit-Remaining-Requests`), while direct
        // dictionary subscripting is case-sensitive. Normalize once before reading any quota.
        let normalizedHeaders: [String: String] = headers.reduce(into: [:]) { result, entry in
            let key = String(describing: entry.key).lowercased()
            result[key] = String(describing: entry.value)
        }
        func intValue(_ keys: [String]) -> Int? {
            for key in keys {
                if let raw = normalizedHeaders[key.lowercased()],
                    let value = Int(raw.trimmingCharacters(in: .whitespaces))
                {
                    return value
                }
            }
            return nil
        }
        func stringValue(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = normalizedHeaders[key.lowercased()],
                    !raw.isEmpty
                {
                    return raw
                }
            }
            return nil
        }

        let remainingRequests = intValue([
            "anthropic-ratelimit-requests-remaining", "x-ratelimit-remaining-requests",
        ])
        let limitRequests = intValue([
            "anthropic-ratelimit-requests-limit", "x-ratelimit-limit-requests",
        ])
        let remainingTokens = intValue([
            "anthropic-ratelimit-tokens-remaining", "x-ratelimit-remaining-tokens",
        ])
        let limitTokens = intValue([
            "anthropic-ratelimit-tokens-limit", "x-ratelimit-limit-tokens",
        ])
        let reset = stringValue([
            "anthropic-ratelimit-requests-reset", "anthropic-ratelimit-tokens-reset",
            "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens",
        ])

        // Nothing useful in these headers — skip (e.g. a local/Ollama endpoint).
        guard remainingRequests != nil || limitRequests != nil
            || remainingTokens != nil || limitTokens != nil
        else { return }

        let snapshot = AIProviderUsage(
            id: host,
            providerName: Self.displayName(forHost: host),
            remainingRequests: remainingRequests,
            limitRequests: limitRequests,
            remainingTokens: remainingTokens,
            limitTokens: limitTokens,
            resetText: reset.map(Self.humanizeReset),
            capturedAt: Date()
        )

        Task { @MainActor in
            if let idx = self.usage.firstIndex(where: { $0.id == host }) {
                self.usage[idx] = snapshot
            } else {
                self.usage.append(snapshot)
            }
            self.usage.sort { $0.providerName < $1.providerName }
            if let data = try? JSONEncoder().encode(self.usage) {
                UserDefaults.standard.set(data, forKey: self.persistenceKey)
            }
        }
    }

    private nonisolated static func displayName(forHost host: String) -> String {
        switch host {
        case let h where h.contains("anthropic"): return "Claude (Anthropic)"
        case let h where h.contains("openai"): return "OpenAI"
        case let h where h.contains("generativelanguage") || h.contains("googleapis"):
            return "Gemini"
        case let h where h.contains("groq"): return "Groq"
        case let h where h.contains("mistral"): return "Mistral"
        default: return host
        }
    }

    /// Turn an ISO-8601 reset timestamp or a "1m30s"/"30s" duration into "resets in …".
    private nonisolated static func humanizeReset(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) {
            let seconds = max(0, Int(date.timeIntervalSinceNow))
            return "resets in \(formatSeconds(seconds))"
        }
        // OpenAI returns durations like "1m30s" / "6m0s" / "30s".
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("s") || trimmed.hasSuffix("m") {
            return "resets in \(trimmed)"
        }
        if let seconds = Int(trimmed) {
            return "resets in \(formatSeconds(seconds))"
        }
        return "resets \(trimmed)"
    }

    private nonisolated static func formatSeconds(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
