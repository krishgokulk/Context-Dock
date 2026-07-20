// AIProviderUsageStore.swift
// Context-Dock
//
// Live API rate-limit / usage for the user's configured providers, parsed from
// the response headers each provider returns (Anthropic `anthropic-ratelimit-*`,
// OpenAI/compatible `x-ratelimit-*`). This is the only usage data these APIs
// expose — remaining requests/tokens for the current window + when it resets.
// Subscription quotas (Claude Pro / ChatGPT Plus) are NOT exposed by any API.

import Combine
import Foundation

struct AIProviderUsage: Identifiable {
    let id: String  // host
    var providerName: String
    var remainingRequests: Int?
    var limitRequests: Int?
    var remainingTokens: Int?
    var limitTokens: Int?
    var resetText: String?
    var capturedAt: Date
}

@MainActor
final class AIProviderUsageStore: ObservableObject {
    static let shared = AIProviderUsageStore()

    @Published private(set) var usage: [AIProviderUsage] = []

    private init() {}

    /// Record rate-limit headers from a provider response, keyed by host.
    nonisolated func record(host: String, headers: [AnyHashable: Any]) {
        func intValue(_ keys: [String]) -> Int? {
            for key in keys {
                if let raw = headers[key] as? String ?? headers[key.lowercased()] as? String,
                    let value = Int(raw.trimmingCharacters(in: .whitespaces))
                {
                    return value
                }
            }
            return nil
        }
        func stringValue(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = headers[key] as? String ?? headers[key.lowercased()] as? String,
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
        guard remainingRequests != nil || remainingTokens != nil else { return }

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
