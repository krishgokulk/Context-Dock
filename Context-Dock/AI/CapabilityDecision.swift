//
//  CapabilityDecision.swift
//  Context-Dock
//
//  What to do with a ranking: act on it, ask about it, or answer in prose.
//
//  Steps 0.5 and 1 of docs/architecture/FRONTMOST_AGENT.md meet here. The bar is not "is
//  DoraX confident" — confidence alone produces a prompt on every request, which is worse
//  than guessing. It is *what a wrong choice costs*:
//
//    A read that picks the wrong list wastes a sentence.
//    A write that picks the wrong target does not.
//
//  So a write needs a clearer lead than a read before it may proceed without asking.
//
//  This is decided but not yet obeyed. It runs in shadow beside the live routers so the
//  thresholds come from real sentences against a real capability set, rather than from
//  numbers somebody picked.
//

import Foundation

enum CapabilityDecision: Equatable {

    /// One capability clearly leads. Run it — through the usual authority and approval.
    case act(CapabilityIndex.Hit)
    /// Several are too close to separate. Ask, rather than choose for the user.
    case ask([CapabilityIndex.Hit])
    /// The sentence named nothing DoraX can do. Answer it as a question.
    case answer

    /// How much clearer the leader must be before acting without asking.
    ///
    /// A read is cheap to get wrong, so a narrow lead is enough. A write is not, so it
    /// needs a real gap — being nearly right about which thing to delete is not a licence
    /// to delete it.
    private static let readMargin = CapabilityIndex.tieMargin
    private static let writeMargin = 1.0

    static func make(from hits: [CapabilityIndex.Hit]) -> CapabilityDecision {
        guard let top = hits.first else { return .answer }
        guard let second = hits.dropFirst().first else { return .act(top) }

        let margin = top.record.isWrite ? writeMargin : readMargin
        guard top.score - second.score > margin else {
            // Everything within the margin of the leader is a real alternative; anything
            // further back is not worth putting in front of the user.
            let contenders = hits.filter { top.score - $0.score <= margin }
            return .ask(contenders)
        }
        return .act(top)
    }

    /// One line, for the shadow log and for a receipt: what was decided and why.
    var summary: String {
        switch self {
        case .act(let hit):
            return "act \(hit.record.id) score \(String(format: "%.2f", hit.score)) "
                + "on [\(hit.matched.joined(separator: " "))]"
        case .ask(let hits):
            return "ask between " + hits.map(\.record.id).joined(separator: ", ")
        case .answer:
            return "answer in prose — nothing named"
        }
    }
}
