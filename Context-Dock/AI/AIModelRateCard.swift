// AIModelRateCard.swift
// Context-Dock
//
// What a model costs, according to the only source that can be trusted about it: the user.
//
// The token ledger deliberately shipped without prices. A table baked into the app is wrong
// the day a provider changes its pricing page, and a wrong cost shown confidently is worse
// than no cost — someone chooses a cheaper model on a number DoraX made up two releases ago.
//
// So rates are entered, not assumed. Nothing is shown until the user has told DoraX what they
// pay, and what is shown is arithmetic on their own figure and the providers' own counts. If
// a model has no rate, its row shows tokens and no money rather than a guess.

import Combine
import Foundation

/// Dollars per million tokens, as published on a provider's pricing page.
struct AIModelRate: Codable, Equatable {
    /// Cost of input tokens, per million.
    var inputPerMillion: Double
    /// Cost of output tokens, per million.
    var outputPerMillion: Double
    /// Cost of input served from the provider's prompt cache, per million. Usually a small
    /// fraction of the input rate; left nil when a provider does not price it separately.
    var cachedInputPerMillion: Double?

    func cost(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double {
        let million = 1_000_000.0
        let input = Double(inputTokens) / million * inputPerMillion
        let output = Double(outputTokens) / million * outputPerMillion
        // A provider that does not price cache reads separately bills them as input; that is
        // the conservative reading, and it never understates what the user paid.
        let cachedRate = cachedInputPerMillion ?? inputPerMillion
        let cached = Double(cachedInputTokens) / million * cachedRate
        return input + output + cached
    }
}

@MainActor
final class AIModelRateCard: ObservableObject {
    static let shared = AIModelRateCard()

    /// Keyed by model id, lowercased. Not by provider: the same model reached through an
    /// API key and through a subscription bridge costs different things, but the model id is
    /// what the user recognises on a pricing page, and a bridge's own row can be added under
    /// whatever id that bridge reports.
    @Published private(set) var rates: [String: AIModelRate] = [:]

    private let persistenceKey = "AIModelRateCard.rates.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
            let saved = try? JSONDecoder().decode([String: AIModelRate].self, from: data)
        else { return }
        rates = saved
    }

    func rate(forModel model: String) -> AIModelRate? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = rates[key] { return exact }
        // A dated model id ("claude-sonnet-4-5-20250929") should match the rate entered for
        // the family. Longest prefix wins, so a specific entry still beats a general one.
        return rates
            .filter { key.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    func set(_ rate: AIModelRate?, forModel model: String) {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        if let rate {
            rates[key] = rate
        } else {
            rates.removeValue(forKey: key)
        }
        persist()
    }

    /// What a ledger entry cost, or nil when the user has not said what that model costs.
    func cost(for entry: AITokenUsageEntry) -> Double? {
        guard let rate = rate(forModel: entry.model) else { return nil }
        return rate.cost(
            inputTokens: entry.inputTokens,
            cachedInputTokens: entry.cachedInputTokens,
            outputTokens: entry.outputTokens)
    }

    /// Today's spend across the models that have rates, and whether any model did not.
    ///
    /// The second half matters: a total that silently omits an unpriced model is a total the
    /// user will read as complete.
    func todaySpend() -> (amount: Double, hasUnpriced: Bool) {
        var total = 0.0
        var missing = false
        for entry in AITokenLedger.shared.today {
            if let cost = cost(for: entry) {
                total += cost
            } else {
                missing = true
            }
        }
        return (total, missing)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rates) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }
}

extension Double {
    /// Small amounts are the normal case for a launcher answering short questions, and
    /// "$0.00" for four cents of usage reads as free. Cents below a dollar, dollars above.
    var compactUSD: String {
        if self < 1 {
            return String(format: "%.0f¢", self * 100)
        }
        return String(format: "$%.2f", self)
    }
}
