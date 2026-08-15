import Foundation
import Combine

/// A small, provider-free benchmark for the retrieval stage used by General Chat.
///
/// This deliberately evaluates the production prompt evidence rather than a second search
/// implementation. A probe names a query and text expected in one of the retrieved rows;
/// the result records rank, hit@k and latency. Keeping the run local makes it cheap enough
/// to establish a baseline before adding a more complicated retrieval architecture.
struct RetrievalEvaluationResult: Codable, Identifiable {
    let id: UUID
    let runAt: Date
    let query: String
    let expectedText: String
    let matchedRow: String?
    let rank: Int?
    let resultCount: Int
    let latencyMilliseconds: Double

    var hitAt5: Bool { rank.map { $0 <= 5 } ?? false }
    var reciprocalRank: Double { rank.map { 1.0 / Double($0) } ?? 0 }
}

@MainActor
final class RetrievalEvaluationStore: ObservableObject {
    static let shared = RetrievalEvaluationStore()

    @Published private(set) var results: [RetrievalEvaluationResult] = []

    private let fileURL = ContextDockStore.root.appendingPathComponent(
        "retrieval-evaluations.json", isDirectory: false)

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([RetrievalEvaluationResult].self, from: data) {
            results = decoded
        }
    }

    @discardableResult
    func run(query: String, expectedText: String) -> RetrievalEvaluationResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = ContinuousClock.now
        let rows = Self.evidenceRows(from: GeneralChatLocalEvidence.promptLines(query: query))
        let elapsed = start.duration(to: .now)
        let needle = expected.lowercased()
        let matchIndex = needle.isEmpty ? nil : rows.firstIndex {
            $0.lowercased().contains(needle)
        }
        let result = RetrievalEvaluationResult(
            id: UUID(),
            runAt: Date(),
            query: query,
            expectedText: expected,
            matchedRow: matchIndex.map { rows[$0] },
            rank: matchIndex.map { $0 + 1 },
            resultCount: rows.count,
            latencyMilliseconds: Self.milliseconds(elapsed)
        )
        results.insert(result, at: 0)
        results = Array(results.prefix(50))
        persist()
        return result
    }

    func clear() {
        results = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    var hitRateAt5: Double {
        guard !results.isEmpty else { return 0 }
        return Double(results.filter(\.hitAt5).count) / Double(results.count)
    }

    var meanReciprocalRank: Double {
        guard !results.isEmpty else { return 0 }
        return results.map(\.reciprocalRank).reduce(0, +) / Double(results.count)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Prompt evidence rows use `  1. value`, resetting within each source section.
    /// Flattening in emitted order gives one deterministic rank over what the model sees.
    private static func evidenceRows(from lines: [String]) -> [String] {
        lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(of: "."),
                  trimmed[..<dot].allSatisfy(\.isNumber) else { return nil }
            let value = trimmed[trimmed.index(after: dot)...]
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
