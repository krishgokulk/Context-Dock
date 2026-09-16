// AISubscriptionGuard.swift
// Context-Dock
//
// Refuses a request the plan has already said it will not serve.
//
// A subscription bridge reports its quota exactly once — at the moment it runs out, with
// the time it comes back. Before this, that fact was reported to the user and then thrown
// away, so every following question spent a round trip rediscovering it: send, wait, fail,
// read the same message again. The window is often hours long.
//
// So the refusal is answered locally now, from what the plan already told us, and it names
// the way out rather than only the problem — a provider that is configured, is not on the
// spent plan, and can therefore answer right now.

import Foundation

@MainActor
enum AISubscriptionGuard {

    struct Blocked: Error, LocalizedError {
        let provider: AIProvider
        let planType: String?
        let resetsAt: Date
        let alternative: AIProvider?

        var errorDescription: String? {
            let plan = planType.map { " (\($0))" } ?? ""
            let route = alternative.map {
                " Switch to \($0.displayName) in Settings → AI Provider to keep working."
            } ?? " Add another provider in Settings → AI Provider to keep working."
            return "\(provider.displayName)\(plan) is out of quota until "
                + "\(Self.clock(resetsAt)) (\(Self.wait(until: resetsAt)))." + route
        }

        private static func clock(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
            return formatter.string(from: date)
        }

        private static func wait(until date: Date) -> String {
            let seconds = max(0, Int(date.timeIntervalSinceNow))
            if seconds < 60 { return "under a minute" }
            if seconds < 3_600 { return "\(seconds / 60) min" }
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
    }

    /// Throws when the provider's plan is known to be spent. Silent otherwise — including
    /// for every provider that is not a subscription bridge, which is most of them.
    static func check(_ provider: AIProvider) throws {
        guard let quota = AIProviderUsageStore.shared.subscriptionQuota(for: provider) else {
            return
        }
        throw Blocked(
            provider: provider,
            planType: quota.planType,
            resetsAt: quota.resetsAt,
            alternative: alternative(to: provider))
    }

    /// A provider the user has already configured that is not itself out of quota.
    ///
    /// Ordered by what keeps the most working: the other subscription bridge first (it is
    /// paid for and idle), then a keyed API, then whatever runs locally — on-device answers
    /// nothing well but answers, which beats a dead chat.
    static func alternative(to provider: AIProvider) -> AIProvider? {
        let settings = AppSettings.shared
        let store = AIProviderUsageStore.shared
        let candidates: [AIProvider] = [
            .claudeBridge, .chatGPTBridge, .anthropic, .openAI, .googleGemini, .kimi,
            .openAICompatible, .ollama, .onDevice,
        ]
        return candidates.first { candidate in
            candidate != provider
                && settings.isProviderConfigured(candidate)
                && store.subscriptionQuota(for: candidate) == nil
        }
    }
}
