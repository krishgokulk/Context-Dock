// CapabilityFallbackClassifier.swift
// Context-Dock
//
// What to do when the word search finds nothing.
//
// Capability discovery scores a query against each capability's id, title and aliases by
// substring. That is fast, deterministic and right nearly always — and when it misses, it
// misses silently and totally. "Did I visit any website today?" scored zero because
// "website" was in no alias list, so the model was told the Mac had no such capability and
// answered that the user had visited nothing. Widening the list fixed that phrasing and
// left the cliff exactly where it was; the same failure has been patched three times, for
// browser vocabulary, for read-versus-do, and for clipboard tense.
//
// A list of words cannot be completed. So when the fast path finds nothing at all, ask the
// on-device model to read the query and pick from the capabilities that exist. It never
// runs anything, never sees more than ids and titles, and never overrides a hit — it is
// only consulted where the alternative is telling the user we cannot do something we can.
//
// Local on purpose: this happens before the user's request has gone anywhere, and sending
// every unmatched question to a cloud provider to be classified would leak more than the
// question itself.

import Foundation
import OSLog

#if canImport(FoundationModels)
    import FoundationModels
#endif

@MainActor
enum CapabilityFallbackClassifier {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "CapabilityFallback")

    /// The model is picking from a list, not reasoning. A few seconds is generous; past
    /// that the user is waiting on a guess and the honest "nothing matched" is better.
    private static let timeout: TimeInterval = 4

    /// Capability ids that plausibly serve `query`, best first. Empty when the model is
    /// unavailable, too slow, or genuinely cannot see a fit — all of which leave the caller
    /// exactly where it was.
    static func pick(
        query: String,
        from candidates: [(id: String, title: String)],
        limit: Int = 4
    ) async -> [String] {
        guard !query.isEmpty, !candidates.isEmpty else { return [] }

        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else { return [] }
            guard case .available = SystemLanguageModel.default.availability else {
                log.notice("on-device model unavailable; no fallback")
                return []
            }

            let catalogue = candidates
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            let instructions = """
                You match a user's request to capabilities on their Mac.

                Reply with ONLY capability ids, most likely first, comma separated, at most \
                \(limit). No prose, no explanation, no ids that are not in the list.
                Reply with NONE if nothing in the list serves the request.
                """
            let prompt = """
                Request: "\(query)"

                Capabilities:
                \(catalogue)
                """

            let known = Set(candidates.map(\.id))
            let answer = await withTimeout(seconds: timeout) {
                let session = LanguageModelSession(instructions: instructions)
                return try? await session.respond(to: prompt).content
            }
            guard let answer else {
                log.notice("fallback timed out")
                return []
            }

            // Only ids it was given. A model naming something plausible-but-absent is the
            // failure this whole layer exists to avoid, so an unknown id is dropped rather
            // than passed on to fail later with a worse message.
            let picked = answer
                .split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" && $0 != "_" }
                .map(String.init)
                .filter { known.contains($0) }
            guard !picked.isEmpty else { return [] }
            log.notice("fallback picked \(picked.joined(separator: ", "), privacy: .public)")
            return Array(picked.prefix(limit))
        #else
            return []
        #endif
    }

    /// Runs `work`, giving up after `seconds`. A classifier that hangs would turn a fast
    /// miss into a slow one, which is worse than the miss.
    private static func withTimeout<T: Sendable>(
        seconds: Double, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
