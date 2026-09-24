import Foundation

/// The offer to delegate, and the identity of what was chosen.
///
/// Rendered with the same pick-one buttons a route choice uses, because to the person reading
/// it this is the same kind of decision: several things could carry out the request, they
/// differ in consequence, and the app is asking rather than picking. What differs is the cost —
/// a worker is minutes and money — so it is never offered for a question, and never taken
/// without being chosen.
enum AIWorkerOffer {
    /// Marks a choice as a delegation. Without it `pickRoute` would hand the id to the route
    /// resolver, which would match on the words and run something else entirely.
    private static let prefix = "worker:"

    static func isWorkerChoice(_ id: String) -> Bool { id.hasPrefix(prefix) }

    static func worker(for choiceID: String) -> AIWorkerKind? {
        guard isWorkerChoice(choiceID) else { return nil }
        return AIWorkerKind(rawValue: String(choiceID.dropFirst(prefix.count)))
    }

    /// Whether this rung is reached at all.
    ///
    /// A worker costs minutes and money where a linked route costs neither, so the ladder only
    /// arrives here once nothing linked could carry the request out. That ordering was a bare
    /// `sendChoices.isEmpty` at the call site and nothing held it: deleting the condition would
    /// have started offering a specialist alongside routes that already work, and no test would
    /// have failed. It is a function now, for the same reason
    /// `ComputerUseFallback.shouldOffer` is one — the rung below this makes its own ordering
    /// checkable, and this one should too.
    ///
    /// `hasLinkedRoute` is the question "could anything already linked do this", not "did it
    /// succeed". A route that exists and failed is still a route; failing over to a worker
    /// because a command errored would be a different decision, and not this one.
    static func shouldOffer(hasLinkedRoute: Bool, task: AIWorkerTask?, workers: [AIWorker])
        -> Bool
    {
        guard !hasLinkedRoute else { return false }
        guard let task else { return false }  // not work, or outside every specialist's domain
        return !choices(for: task, workers: workers).isEmpty
    }

    static func choices(for task: AIWorkerTask, workers: [AIWorker]) -> [ActionChoice] {
        workers
            .filter { !$0.domains.isDisjoint(with: task.domains) }
            .map { worker in
                ActionChoice(
                    id: prefix + worker.kind.rawValue,
                    title: "Ask \(worker.displayName)",
                    routeLabel: "Specialist",
                    appName: nil)
            }
    }

    /// What the user is agreeing to, said before they agree to it: who would run, where it may
    /// look, and that it reports rather than changes.
    static func explanation(for task: AIWorkerTask, workers: [AIWorker]) -> String {
        let names = workers.map(\.displayName)
        let who = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            : (names.first ?? "no specialist")
        let where_ = task.authority.scopeDescription
        return "No linked route can do this here. \(who) can investigate it read-only, within "
            + "\(where_), and report back — nothing is installed, changed or deleted. Use one?"
    }
}
