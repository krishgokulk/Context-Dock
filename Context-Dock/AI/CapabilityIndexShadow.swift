//
//  CapabilityIndexShadow.swift
//  Context-Dock
//
//  Runs the capability index beside the routers that are actually deciding, and writes down
//  where they disagree. It changes nothing.
//
//  This is the migration rule from docs/architecture/FRONTMOST_AGENT.md made real: build
//  the index next to the six existing matchers, compare on real sentences against a real
//  capability set, and retire each matcher only when the index answers its cases at least
//  as well. Deleting six matchers in one commit is how a working launcher becomes a broken
//  one.
//
//  It also exists to settle two numbers that are currently guesses — the score floor and
//  the tie margin. "open" alone scores about 1.01 against a floor of 1.0, which is far too
//  close to leave to somebody's judgement. The log says what real requests actually score.
//
//  Read it with:
//    log show --predicate 'subsystem == "com.krishgokul.ContextDock"
//                          AND category == "CapabilityShadow"' --last 1h --info
//

import Foundation
import OSLog

@MainActor
enum CapabilityIndexShadow {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "CapabilityShadow")

    /// Rebuilt when the capability set changes rather than per request: gathering four
    /// stores on every keystroke would be a cost paid for a log line.
    private static var cached: (records: [CapabilityRecord], builtAt: Date)?
    private static let rebuildAfter: TimeInterval = 120

    private static func index() -> CapabilityIndex {
        if let cached, Date().timeIntervalSince(cached.builtAt) < rebuildAfter {
            return CapabilityIndex(records: cached.records)
        }
        let records = CapabilityCatalog.allRecords()
        cached = (records, Date())
        return CapabilityIndex(records: records)
    }

    /// Record what the index would have done, beside what actually happened.
    ///
    /// `liveChoice` is the live routers' answer in whatever words that path uses — a
    /// capability id, a route label, a domain, or "none". Comparing the two by hand is the
    /// point; a machine-readable verdict would mean deciding now what "agreement" means,
    /// which is the question this is meant to answer.
    static func observe(query: String, liveChoice: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 400 else { return }

        let hits = index().search(trimmed)
        let decision = CapabilityDecision.make(from: hits)
        let ranked = hits.prefix(3)
            .map { "\($0.record.id)=\(String(format: "%.2f", $0.score))" }
            .joined(separator: " ")

        log.notice(
            """
            q=\(trimmed, privacy: .public) \
            live=\(liveChoice, privacy: .public) \
            index=[\(ranked, privacy: .public)] \
            would=\(decision.summary, privacy: .public)
            """)
    }
}
