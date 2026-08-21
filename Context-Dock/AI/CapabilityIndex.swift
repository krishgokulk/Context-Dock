//
//  CapabilityIndex.swift
//  Context-Dock
//
//  One index over everything DoraX can do, and one ranking for "given this sentence, what
//  are the best things I can do about it?"
//
//  Step 1 of docs/architecture/FRONTMOST_AGENT.md. That question had no answer anywhere.
//  Six matchers each scored their own slice with their own rules —
//  AppAdapterCapabilityCatalog by token intersection, ReadOnlyDataRouter by keyword list,
//  GlobalCommandCapabilities by its own score, ChatRouteResolver by kind ranking,
//  resolveTargetApp by position, AppleLiveDataContext by `if q.contains("note")` — and
//  every failure reported this week was two of them disagreeing or none of them firing.
//
//  The ranking is deliberately lexical rather than embedded. It is local, instant, and can
//  be explained to the user in a sentence; a score nobody can reason about is worse than
//  one that is merely adequate, and the bug this replaces was caused by a matcher whose
//  reasoning could not be seen. Embeddings are a refinement to add once this is measured,
//  not the starting point.
//
//  Nothing is wired to this yet, on purpose. It runs beside the existing routers until it
//  answers their cases at least as well; retiring six matchers in one commit is how a
//  working launcher becomes a broken one.
//

import Foundation

/// One thing DoraX can do, from whichever source provides it.
struct CapabilityRecord: Equatable {
    enum Kind: String, Equatable {
        case adapterAction
        case capability
        case cliTool
        case mcpTool
        case skill
        case globalCommand
        case menuCommand
    }

    let id: String
    /// The app this belongs to, as the user would name it. "" for machine-wide commands.
    let app: String
    let kind: Kind
    let title: String
    let description: String
    let keywords: [String]
    /// Whether running it changes something. The decision layer treats a wrong write as
    /// far more expensive than a wrong read.
    let isWrite: Bool

    init(
        id: String, app: String = "", kind: Kind, title: String,
        description: String = "", keywords: [String] = [], isWrite: Bool
    ) {
        self.id = id
        self.app = app
        self.kind = kind
        self.title = title
        self.description = description
        self.keywords = keywords
        self.isWrite = isWrite
    }
}

struct CapabilityIndex {

    struct Hit: Equatable {
        let record: CapabilityRecord
        let score: Double
        /// The query words that actually matched, so a choice can be explained and a
        /// receipt can say why this capability was picked.
        let matched: [String]
    }

    /// Field weights. A word in the title names the thing; the same word in prose merely
    /// mentions it.
    private enum Weight {
        static let title = 3.0
        static let keyword = 2.0
        static let app = 1.5
        static let description = 1.0
    }

    /// Below this, a sentence has not named anything in the index and the honest answer is
    /// prose rather than a guess. "is this page related to our project?" sits here.
    static let floor = 1.0

    /// Two hits this close are a tie, and a tie is a question rather than a choice — the
    /// same test `shouldClarifyBetweenPeers` already applies to app candidates.
    static let tieMargin = 0.05

    private let records: [CapabilityRecord]
    /// term → how many records contain it, for idf.
    private let documentFrequency: [String: Int]

    init(records: [CapabilityRecord]) {
        self.records = records
        var frequency: [String: Int] = [:]
        for record in records {
            for term in Set(Self.terms(in: Self.searchableText(of: record))) {
                frequency[term, default: 0] += 1
            }
        }
        self.documentFrequency = frequency
    }

    /// How much one word is worth. A term in forty capabilities says almost nothing; a term
    /// in two says almost everything. "open" and "social" are common and "contextdock"
    /// matched nothing — which is exactly the signal token-overlap matching discarded.
    func weight(of term: String) -> Double {
        let total = Double(max(records.count, 1))
        let seen = Double(documentFrequency[term.lowercased()] ?? 0)
        return log((total + 1) / (seen + 1)) + 0.1
    }

    func search(_ query: String, limit: Int = 5) -> [Hit] {
        let queryTerms = Set(Self.terms(in: query)).filter { !Self.filler.contains($0) }
        guard !queryTerms.isEmpty else { return [] }

        var hits: [Hit] = []
        for record in records {
            let title = Set(Self.terms(in: record.title))
            let keywords = Set(record.keywords.flatMap { Self.terms(in: $0) })
            let app = Set(Self.terms(in: record.app))
            let description = Set(Self.terms(in: record.description))

            var score = 0.0
            var matched: [String] = []
            for term in queryTerms {
                var best = 0.0
                if title.contains(term) { best = max(best, Weight.title) }
                if keywords.contains(term) { best = max(best, Weight.keyword) }
                if app.contains(term) { best = max(best, Weight.app) }
                if description.contains(term) { best = max(best, Weight.description) }
                guard best > 0 else { continue }
                score += best * weight(of: term)
                matched.append(term)
            }
            guard score >= Self.floor else { continue }
            hits.append(Hit(record: record, score: score, matched: matched.sorted()))
        }

        // Stable: score first, then id, so the same sentence resolves the same way on every
        // launch rather than following dictionary order.
        return Array(
            hits.sorted {
                $0.score == $1.score ? $0.record.id < $1.record.id : $0.score > $1.score
            }.prefix(limit))
    }

    static func isTie(_ lhs: Hit, _ rhs: Hit) -> Bool {
        abs(lhs.score - rhs.score) < tieMargin
    }

    // MARK: - Text

    private static func searchableText(of record: CapabilityRecord) -> String {
        "\(record.title) \(record.description) \(record.keywords.joined(separator: " ")) \(record.app)"
    }

    private static func terms(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// Words that appear in requests and name nothing. Kept small deliberately: an
    /// over-eager stop list is how "new" stops finding "New Window".
    private static let filler: Set<String> = [
        "the", "and", "for", "with", "please", "can", "you", "could", "would", "this",
        "that", "these", "those", "any", "all", "our", "your", "my", "me", "it", "is",
        "are", "was", "were", "does", "did", "do", "in", "on", "at", "to", "of", "from",
    ]
}
