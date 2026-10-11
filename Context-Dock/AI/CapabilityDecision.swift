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
    /// Nothing matched what was actually asked, but these came close enough to be worth
    /// naming. Not a menu of answers — a statement that the thing asked for was not found,
    /// with what *is* here beside it.
    ///
    /// "new chat" is the case: five New-something commands, none of them a chat. Offering
    /// them as choices presents wrong options as though one must be right; saying nothing
    /// leaves the user to guess what DoraX can do. Naming them as near misses is the only
    /// honest reading of a half-matched sentence.
    case suggest([CapabilityIndex.Hit])

    /// How much clearer the leader must be before acting without asking.
    ///
    /// A read is cheap to get wrong, so a narrow lead is enough. A write is not, so it
    /// needs a real gap — being nearly right about which thing to delete is not a licence
    /// to delete it.
    private static let readMargin = CapabilityIndex.tieMargin
    private static let writeMargin = 1.0

    /// How much of the sentence the leader has to account for.
    ///
    /// From the first shadow log: "new chat" produced a five-way tie at 10.39 — New Board,
    /// New Automator Document, New Event, New Card, Check Mail — because "new" is in all of
    /// them and nothing in the capability set is about chat. The score was high; the
    /// coverage was half, and the half that matched was the half that meant least.
    ///
    /// A threshold on score would not have caught it, and the first version of this did
    /// not. More than half the meaningful words have to land, or the index found something
    /// adjacent to the request rather than the request.
    private static let minimumCoverage = 0.5

    /// Nobody wants six options. Past three, a question stops being a choice.
    private static let maximumOptions = 3

    /// How close a cheaper capability has to be before cost decides instead of score.
    ///
    /// Wider than the tie margins on purpose, and this is the number that separates the two
    /// cases this rule exists for:
    ///
    /// *Finder, "empty the trash".* `finder.emptyTrash` names the request outright and scores
    /// far above the generic menu item. Nothing else is within the band, so cost never comes
    /// up and it simply runs. Three able paths must not become a question.
    ///
    /// *Claude, "new chat".* The linked `claude` CLI and `File ▸ New Chat` both land in the
    /// band. They differ in surface, so the user is asked — which is the whole report this
    /// came from, where DoraX picked silently and picked wrong.
    ///
    /// The honest justification for asking rather than taking the cheaper one: those two do
    /// not produce the same outcome. A CLI session and a desktop chat window are different
    /// things, and DoraX cannot tell which was meant. Where the outcomes really are the same,
    /// the scores separate and the band never triggers.
    private static let surfaceBand = 3.0

    static func make(from hits: [CapabilityIndex.Hit]) -> CapabilityDecision {
        guard let top = hits.first else { return .answer }
        // Most of the sentence has to be accounted for. Scoring well on one word out of
        // three means something adjacent was found, not the thing asked for — so it is
        // offered as a near miss rather than as an answer.
        guard top.coverage > minimumCoverage else {
            return .suggest(Array(hits.prefix(maximumOptions)))
        }
        guard let second = hits.dropFirst().first else { return .act(top) }

        // Cost, before score. Everything close enough to the leader to be a real alternative
        // is compared on what it costs the user, not on how well it matched — two paths that
        // both do the job and differ in whether the screen is taken is a choice the user
        // makes, not one DoraX makes for them.
        let band = hits.filter { top.score - $0.score <= surfaceBand }
        let surfaces = Set(band.map(\.record.surface))
        if surfaces.count > 1 {
            // Never take an expensive surface while a cheaper one is right there. Ask, with
            // the cheapest first so the default reading is the cheap one.
            let byCost = band.sorted {
                $0.record.surface == $1.record.surface
                    ? $0.score > $1.score
                    : $0.record.surface < $1.record.surface
            }
            return .ask(Array(byCost.prefix(maximumOptions)))
        }

        let margin = top.record.isWrite ? writeMargin : readMargin
        guard top.score - second.score > margin else {
            // Everything within the margin of the leader is a real alternative; anything
            // further back is not worth putting in front of the user.
            let contenders = hits.filter { top.score - $0.score <= margin }
            return .ask(Array(contenders.prefix(maximumOptions)))
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
            // The surfaces are the reason for most asks now, so the line says them.
            return "ask between "
                + hits.map { "\($0.record.id) (\($0.record.surface.costLabel))" }
                    .joined(separator: ", ")
        case .suggest(let hits):
            return "suggest near misses " + hits.map(\.record.id).joined(separator: ", ")
        case .answer:
            return "answer in prose — nothing named"
        }
    }
}
