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
    static func observe(query: String, liveChoice: String, scopedTo app: String? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 400 else { return }

        // Without the scope the comparison is unfair and the log misleads. The first three
        // lines it ever produced included "new tab window", where the live router knew the
        // chat was scoped to Code and the index — asked blind — preferred Safari's New Tab.
        // That is not the index disagreeing; it is the index being asked a different
        // question.
        let hits = index().search(trimmed, scopedTo: app)
        let decision = CapabilityDecision.make(from: hits)
        let ranked = hits.prefix(3)
            .map { "\($0.record.id)=\(String(format: "%.2f", $0.score))" }
            .joined(separator: " ")

        record(
            query: trimmed, live: liveChoice, scope: app, hits: hits, decision: decision)

        log.notice(
            """
            q=\(trimmed, privacy: .public) \
            live=\(liveChoice, privacy: .public) \
            scope=\(app ?? "none", privacy: .public) \
            index=[\(ranked, privacy: .public)] \
            would=\(decision.summary, privacy: .public)
            """)
    }

    // MARK: - The turn, as a graph

    /// One turn written down as nodes, so it can be looked at rather than read.
    ///
    /// A log line says what happened; it does not show the shape of it. "Which app did it
    /// pick, out of what, and why did it stop there" is a question about a path, and a path
    /// is easier to see than to parse.
    private struct TurnGraph: Codable {
        struct Candidate: Codable {
            let id: String
            let app: String
            let kind: String
            let score: Double
            let coverage: Double
            let matched: [String]
            let isWrite: Bool
        }
        let at: Date
        let query: String
        let scope: String
        let liveChoice: String
        let decision: String
        let candidates: [Candidate]
    }

    private static var graphFile: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("turn-graphs.json")
    }

    /// The last twenty turns. Enough to see a pattern, small enough that nobody has to
    /// think about the file.
    private static let keptTurns = 20

    private static func record(
        query: String, live: String, scope: String?,
        hits: [CapabilityIndex.Hit], decision: CapabilityDecision
    ) {
        let graph = TurnGraph(
            at: Date(),
            query: query,
            scope: scope ?? "",
            liveChoice: live,
            decision: decision.summary,
            candidates: hits.prefix(8).map {
                .init(
                    id: $0.record.id, app: $0.record.app, kind: $0.record.kind.rawValue,
                    score: $0.score, coverage: $0.coverage, matched: $0.matched,
                    isWrite: $0.record.isWrite)
            })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var existing = (try? Data(contentsOf: graphFile))
            .flatMap { try? decoder.decode([TurnGraph].self, from: $0) } ?? []
        existing.append(graph)
        if existing.count > keptTurns { existing.removeFirst(existing.count - keptTurns) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(existing).write(to: graphFile, options: .atomic)
    }
}
