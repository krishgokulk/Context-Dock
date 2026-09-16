// AgentTurnDiagnostics.swift
// Context-Dock
//
// One line per turn saying whether the model was ever given the chance to act.
//
// A subscription bridge is a proxy someone else wrote. If it forwards the `tools` field, the
// model can call things; if it drops it, the model answers from the prompt in a single round
// and says it cannot see the user's data — which is indistinguishable, from the outside, from
// a model that simply chose not to look. Both produce "1 step" and an apology.
//
// Guessing between those two is how an afternoon disappears. This records what was offered
// and what came back, so the question is settled by reading a log line rather than by
// changing prompts and hoping.

import Foundation
import OSLog

enum AgentTurnDiagnostics {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AgentTurn")

    /// The last turn's shape, for the diagnostics surface to show without digging in logs.
    private(set) nonisolated(unsafe) static var lastSummary: String = "No turn recorded yet."

    static func record(model: String, toolsOffered: Int, rounds: Int, toolCalls: Int) {
        let verdict: String
        if toolsOffered == 0 {
            verdict = "no tools were offered — this path is prompt-only"
        } else if toolCalls == 0 {
            // The interesting case. Either the endpoint ignored the tools, or the model read
            // the question as needing none. The first is a broken provider and the second is
            // a prompting problem, and they are fixed in completely different places.
            verdict =
                "offered \(toolsOffered) tools and called none — either this endpoint drops "
                + "the tools field, or the model judged the question answerable without them"
        } else {
            verdict = "called \(toolCalls) tool\(toolCalls == 1 ? "" : "s") over \(rounds) round\(rounds == 1 ? "" : "s")"
        }
        lastSummary = "\(model): \(verdict)"
        log.notice(
            "turn model=\(model, privacy: .public) tools=\(toolsOffered, privacy: .public) rounds=\(rounds, privacy: .public) calls=\(toolCalls, privacy: .public)")
    }
}
