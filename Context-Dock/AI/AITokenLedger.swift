// AITokenLedger.swift
// Context-Dock
//
// What the AI actually cost, in the only unit the providers agree on.
//
// Every response carries its token counts and DoraX threw them all away — Anthropic's were
// decoded and written to OSLog, the rest were never decoded at all. So a user running Opus
// through a scoped chat all afternoon had no way to see that a single turn re-sends the whole
// context block per tool round, and no way to compare that against the same question asked of
// a cheaper model. The one number that makes those decisions was the one number the app did
// not keep.
//
// Tokens only, deliberately. A price table is out of date the day a provider changes its
// pricing page, and a wrong cost shown confidently is worse than no cost at all — these are
// counts the providers themselves reported, and they stay counts.

import Combine
import Foundation

struct AITokenUsageEntry: Codable, Identifiable {
    /// provider + model + day, so a model switched mid-afternoon keeps its own line.
    var id: String
    var providerName: String
    var model: String
    var day: Date
    var inputTokens: Int
    /// Input that was served from the provider's prompt cache. Counted separately because
    /// it is billed at a fraction of the price, and because a cache that stops working is
    /// invisible in a total.
    var cachedInputTokens: Int
    var outputTokens: Int
    var requests: Int

    var totalTokens: Int { inputTokens + cachedInputTokens + outputTokens }
}

@MainActor
final class AITokenLedger: ObservableObject {
    static let shared = AITokenLedger()

    @Published private(set) var entries: [AITokenUsageEntry] = []

    private let persistenceKey = "AITokenLedger.entries.v1"
    /// A month is enough to see a trend and small enough to keep in UserDefaults.
    private let retentionDays = 30

    private init() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
            let saved = try? JSONDecoder().decode([AITokenUsageEntry].self, from: data)
        else { return }
        entries = prune(saved)
    }

    /// Files one response's counts. Called from the provider paths, which are the only
    /// places that see them.
    func record(
        provider: AIProvider,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int
    ) {
        guard inputTokens > 0 || outputTokens > 0 || cachedInputTokens > 0 else { return }
        let day = Calendar.current.startOfDay(for: Date())
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(provider.rawValue)|\(cleanModel)|\(Int(day.timeIntervalSince1970))"

        if let index = entries.firstIndex(where: { $0.id == key }) {
            entries[index].inputTokens += inputTokens
            entries[index].cachedInputTokens += cachedInputTokens
            entries[index].outputTokens += outputTokens
            entries[index].requests += 1
        } else {
            entries.append(
                AITokenUsageEntry(
                    id: key,
                    providerName: provider.displayName,
                    model: cleanModel.isEmpty ? provider.shortName : cleanModel,
                    day: day,
                    inputTokens: inputTokens,
                    cachedInputTokens: cachedInputTokens,
                    outputTokens: outputTokens,
                    requests: 1))
        }
        entries = prune(entries)
        persist()
    }

    /// Today's totals, newest-heaviest first — the view most worth having, because it is the
    /// one that answers "what have I spent since this morning".
    var today: [AITokenUsageEntry] {
        let start = Calendar.current.startOfDay(for: Date())
        return entries
            .filter { $0.day == start }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    var todayTotalTokens: Int { today.reduce(0) { $0 + $1.totalTokens } }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }

    private func prune(_ input: [AITokenUsageEntry]) -> [AITokenUsageEntry] {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        return input.filter { $0.day >= Calendar.current.startOfDay(for: cutoff) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }
}

extension Int {
    /// 12_400 → "12.4k". Token counts are read at a glance, not audited to the digit.
    var compactTokenCount: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fk", Double(self) / 1_000)
        }
        return "\(self)"
    }
}
