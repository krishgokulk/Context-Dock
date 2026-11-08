// ReplayRunner.swift
// Context-Dock
//
// Loads replay cases, applies rules, and prints a pass rate.
//
// Usage — one call prints the pass rate before and after a change:
//
//   let cases = store.loadAll()
//   let report = ReplayRunner.run(cases: cases, suite: MySuite.rules)
//   report.printSummary()
//   // → 18/20 passed (90.0%)  2 failed  0 skipped
//
// A `RuleSuite` pairs each case ID with the rules that apply to it,
// plus a set of "universal" rules that every case must satisfy.
//
// E8b (#159). Depends on E8a (#158) for ReplayCase.

import Foundation

// MARK: - Rule binding

/// One rule bound to a specific case (by ID), or nil to apply to every case.
struct BoundRule: Sendable {
    var caseID: String?
    var rule: any ReplayCaseRule

    static func always(_ rule: any ReplayCaseRule) -> BoundRule {
        BoundRule(caseID: nil, rule: rule)
    }

    static func forCase(_ id: String, _ rule: any ReplayCaseRule) -> BoundRule {
        BoundRule(caseID: id, rule: rule)
    }
}

// MARK: - Per-case result

struct CaseRuleResult: Sendable {
    var caseID: String
    var ruleName: String
    var result: RuleResult
}

// MARK: - Run report

/// The result of running all rules against all cases.
struct RunReport: Sendable {
    let results: [CaseRuleResult]

    var total: Int { results.filter { !$0.result.isSkipped }.count }
    var passed: Int { results.filter { $0.result.isPassing }.count }
    var failed: Int { results.filter { $0.result.isFailing }.count }
    var skipped: Int { results.filter { $0.result.isSkipped }.count }

    var passRate: Double {
        guard total > 0 else { return 0 }
        return Double(passed) / Double(total)
    }

    var failures: [CaseRuleResult] { results.filter { $0.result.isFailing } }

    /// Prints a one-line summary plus any failures.
    ///
    ///     18/20 passed (90.0%)  2 failed  0 skipped
    ///     FAIL  case-id-1  tool_called(open_url): Expected tool 'open_url' to be called…
    func printSummary(label: String? = nil) {
        let prefix = label.map { "\($0): " } ?? ""
        let pct = String(format: "%.1f%%", passRate * 100)
        print("\(prefix)\(passed)/\(total) passed (\(pct))  \(failed) failed  \(skipped) skipped")
        for f in failures {
            if case .fail(let reason) = f.result {
                print("  FAIL  \(f.caseID)  \(f.ruleName): \(reason)")
            }
        }
    }

    /// Whether all non-skipped rules passed.
    var allPassed: Bool { failed == 0 }
}

// MARK: - Replay runner

enum ReplayRunner {

    /// Runs every bound rule against the matching cases and returns a report.
    static func run(cases: [ReplayCase], rules: [BoundRule]) -> RunReport {
        var results: [CaseRuleResult] = []
        for case_ in cases {
            let applicable = rules.filter { $0.caseID == nil || $0.caseID == case_.id }
            for bound in applicable {
                let result = bound.rule.check(case_)
                results.append(CaseRuleResult(
                    caseID: case_.id,
                    ruleName: bound.rule.name,
                    result: result))
            }
        }
        return RunReport(results: results)
    }

    /// Convenience: run against all cases in a store directory.
    static func run(store: ReplayCaseStore, rules: [BoundRule]) -> RunReport {
        run(cases: store.loadAll(), rules: rules)
    }
}

// MARK: - Retrieval metrics

/// Hit-at-K and MRR computed from the resolved context items of a replay case.
///
/// These measure how well the context retrieval found the relevant item.
/// The fixture annotates which `ContextItem.kind` values were relevant; the
/// metrics score how early they appear in `resolvedContext`.
enum RetrievalMetrics {

    /// Whether `relevant` appears in the top-K context items.
    static func hitAtK(case_: ReplayCase, relevantKind: String, k: Int) -> Bool {
        let top = case_.resolvedContext.prefix(k)
        return top.contains { $0.kind == relevantKind }
    }

    /// Reciprocal rank of the first item matching `relevantKind` in `resolvedContext`.
    /// Returns nil when the kind is absent.
    static func reciprocalRank(case_: ReplayCase, relevantKind: String) -> Double? {
        guard let idx = case_.resolvedContext.firstIndex(where: { $0.kind == relevantKind })
        else { return nil }
        return 1.0 / Double(idx + 1)
    }

    /// Mean Reciprocal Rank across a set of cases.
    static func mrr(cases: [ReplayCase], relevantKind: String) -> Double {
        let ranks = cases.compactMap { reciprocalRank(case_: $0, relevantKind: relevantKind) }
        guard !ranks.isEmpty else { return 0 }
        return ranks.reduce(0, +) / Double(ranks.count)
    }

    /// Hit@K rate across a set of cases.
    static func hitAtKRate(cases: [ReplayCase], relevantKind: String, k: Int) -> Double {
        guard !cases.isEmpty else { return 0 }
        let hits = cases.filter { hitAtK(case_: $0, relevantKind: relevantKind, k: k) }.count
        return Double(hits) / Double(cases.count)
    }
}
