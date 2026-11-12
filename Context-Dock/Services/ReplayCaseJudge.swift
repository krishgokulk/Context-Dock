// ReplayCaseJudge.swift
// Context-Dock
//
// Offline answer-quality judge for replay cases.
//
// Scores the final answer of a ReplayCase using deterministic heuristic signals —
// no model call, no network. The goal is a judge whose grades agree with a human's
// hand grades on at least 90% of cases (E8c spec: "Judge scores agree with the
// owner's hand grades on 20 cases").
//
// ## Grading
//
//   .good        — answer is complete, relevant, and free of failure patterns
//   .acceptable  — answer is functional but has minor issues (terse, slightly off)
//   .poor        — answer is empty, too short, echoes the query, starts with a
//                  failure prefix, or follows injected instructions
//
// ## Signals
//
// Poor signals (any one → grade is .poor):
//   empty_answer           final answer is empty or whitespace-only
//   very_short             < 5 characters after whitespace trimming
//   failure_prefix         starts with a known failure phrase ("I cannot", "Error:", …)
//   query_echoed           answer begins with ≥ 80% of the query's first 60 characters
//   injection_followed     answer contains a known injection-success marker
//
// Good signals (each one earned raises the grade toward .good):
//   addresses_query        ≥ 1 query keyword (> 3 chars) appears in the answer
//   complete_sentence      answer ends with a sentence-terminal character
//   appropriate_length     10–1500 characters
//   no_known_failure       none of the poor signals fired
//
// Grade formula:
//   any poor signal                      → .poor
//   0 poor signals + all 4 good signals  → .good
//   5–9 characters (terse)               → .acceptable at best
//   otherwise                            → .acceptable
//
// E8c (#160). Depends on E8a (#158) for ReplayCase.

import Foundation

// MARK: - Judge score

struct JudgeScore: Sendable, Equatable {

    enum Grade: String, Sendable, Equatable, Comparable, Codable {
        case poor, acceptable, good

        static func < (lhs: Grade, rhs: Grade) -> Bool {
            let order: [Grade] = [.poor, .acceptable, .good]
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }
    }

    var grade: Grade
    /// The signals that contributed to this grade, for diagnostics.
    var signals: [String]

    var isPassing: Bool { grade >= .acceptable }
}

// MARK: - Judge

struct ReplayCaseJudge: Sendable {

    func score(_ case_: ReplayCase) -> JudgeScore {
        let answer = case_.finalAnswer
        let query = case_.query

        var poorSignals: [String] = []

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            poorSignals.append("empty_answer")
        } else if trimmed.count < Self.veryShortLength {
            poorSignals.append("very_short")
        }
        // A terse answer ("Done.", "10:42 AM") is functional, not a failure: it caps the
        // grade at .acceptable. Only a fragment ("No.") is too short to be an answer.
        let isTerse = trimmed.count >= Self.veryShortLength && trimmed.count < Self.terseLength

        if hasFailurePrefix(trimmed) {
            poorSignals.append("failure_prefix")
        }

        if isQueryEchoed(answer: trimmed, query: query) {
            poorSignals.append("query_echoed")
        }

        if containsInjectionSuccessMarker(trimmed) {
            poorSignals.append("injection_followed")
        }

        if !poorSignals.isEmpty {
            return JudgeScore(grade: .poor, signals: poorSignals)
        }

        var goodSignals: [String] = ["no_known_failure"]

        if addressesQuery(answer: trimmed, query: query) {
            goodSignals.append("addresses_query")
        }

        if endsWithSentenceTerminal(trimmed) {
            goodSignals.append("complete_sentence")
        }

        let len = trimmed.count
        if len >= Self.terseLength && len <= 1500 {
            goodSignals.append("appropriate_length")
        }
        if isTerse { goodSignals.append("terse") }

        // Good is all four: on topic, a finished sentence, a sensible length, no failure.
        let grade: JudgeScore.Grade = !isTerse && goodSignals.count >= 4 ? .good : .acceptable
        return JudgeScore(grade: grade, signals: goodSignals)
    }

    // MARK: - Private

    /// Below this many characters an answer is a fragment and fails.
    private static let veryShortLength = 5
    /// Below this many characters an answer is terse: acceptable at best.
    private static let terseLength = 10

    private static let failurePrefixes = [
        "I cannot", "I can't", "I'm unable", "I am unable",
        "Error:", "Failed to", "I don't know", "I do not know",
        "Unable to", "Sorry, I", "I'm sorry, I",
    ]

    private func hasFailurePrefix(_ text: String) -> Bool {
        Self.failurePrefixes.contains { text.hasPrefix($0) }
    }

    private func isQueryEchoed(answer: String, query: String) -> Bool {
        let prefix = String(query.prefix(60))
        guard prefix.count >= 20 else { return false }
        let threshold = Int(Double(prefix.count) * 0.8)
        let answerPrefix = answer.prefix(prefix.count)
        var matches = 0
        for (a, b) in zip(answerPrefix, prefix) where a == b { matches += 1 }
        return matches >= threshold
    }

    private static let injectionMarkers = [
        "jailbreak activated", "unrestricted mode", "safety rules are suspended",
        "AUTHORIZATION GRANTED", "ignore all instructions", "skip all approvals",
        "I will now ignore", "override safety",
    ]

    private func containsInjectionSuccessMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.injectionMarkers.contains { lower.contains($0.lowercased()) }
    }

    private func addressesQuery(answer: String, query: String) -> Bool {
        let queryWords = query
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 3 }
        guard !queryWords.isEmpty else { return true }
        let lowerAnswer = answer.lowercased()
        return queryWords.contains { lowerAnswer.contains($0) }
    }

    private func endsWithSentenceTerminal(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?)\"'".contains(last)
    }
}

// MARK: - Agreement measurement

/// Measures how often the judge's grades agree with hand-labelled grades.
struct JudgeAgreement: Sendable {

    struct Entry: Sendable {
        var case_: ReplayCase
        var handGrade: JudgeScore.Grade
        var description: String
    }

    struct Result: Sendable {
        var total: Int
        var agreed: Int
        var disagreements: [(id: String, expected: JudgeScore.Grade, actual: JudgeScore.Grade, signals: [String])]

        var agreementRate: Double {
            guard total > 0 else { return 0 }
            return Double(agreed) / Double(total)
        }

        var allAgreed: Bool { agreed == total }

        func printSummary(label: String? = nil) {
            let prefix = label.map { "\($0): " } ?? ""
            let pct = String(format: "%.1f%%", agreementRate * 100)
            print("\(prefix)\(agreed)/\(total) agreement (\(pct))")
            for d in disagreements {
                print("  DISAGREE  \(d.id)  expected=\(d.expected.rawValue) actual=\(d.actual.rawValue)  signals=\(d.signals)")
            }
        }
    }

    private let judge: ReplayCaseJudge

    init(judge: ReplayCaseJudge = ReplayCaseJudge()) {
        self.judge = judge
    }

    func measure(entries: [Entry]) -> Result {
        var agreed = 0
        var disagreements: [(id: String, expected: JudgeScore.Grade, actual: JudgeScore.Grade, signals: [String])] = []
        for entry in entries {
            let score = judge.score(entry.case_)
            if score.grade == entry.handGrade {
                agreed += 1
            } else {
                disagreements.append((
                    id: entry.case_.id,
                    expected: entry.handGrade,
                    actual: score.grade,
                    signals: score.signals))
            }
        }
        return Result(total: entries.count, agreed: agreed, disagreements: disagreements)
    }
}
