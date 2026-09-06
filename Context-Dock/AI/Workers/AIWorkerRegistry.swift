import Combine
import Foundation

/// What is installed, held so a request never has to go and look.
///
/// Discovery is deliberately not here yet. When it arrives it resolves `claude` and `codex`
/// once in the background and writes the result in; what a request does is read this, because
/// scanning the filesystem or spawning a process while someone is typing is how a launcher
/// stops feeling like one.
///
/// Empty until then, which is the honest state: nothing offers a worker yet.
@MainActor
final class AIWorkerRegistry: ObservableObject {
    static let shared = AIWorkerRegistry()

    /// Workers known to be installed. Written by discovery, read by the router.
    @Published private(set) var installed: [AIWorker] = []

    private init() {}

    /// Replaces what is known. Discovery owns the truth; this only holds it.
    func replaceInstalled(_ workers: [AIWorker]) {
        installed = workers.sorted { $0.kind.offerRank < $1.kind.offerRank }
    }

    /// The workers that may be offered for a request, best first — a cached lookup and a pure
    /// decision, with nothing launched.
    func eligible(for query: String) -> [AIWorker] {
        AIWorkerRouter.eligible(for: query, from: installed)
    }
}
