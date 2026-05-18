import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI intent classifier for search queries.
/// Determines whether a query is a menu action ("close", "save") or an app name ("Safari", "Clock").
/// Classification runs async via Apple Intelligence; result is cached for the session.
/// Caller checks `cachedIntent(for:)` — nil means "not ready yet, use fallback".
final class QueryIntentCache {
    static let shared = QueryIntentCache()
    private init() {}

    private var cache: [String: Bool] = [:]      // query → true=menu, false=app
    private var inFlight: Set<String> = []

    /// Returns cached intent if available. nil = classification not done yet.
    func cachedIntent(for query: String) -> Bool? {
        cache[query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Fire-and-forget: classifies query on-device, updates cache when done.
    /// Next keystroke (same or extended query) will find the result.
    func classify(_ query: String) {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, cache[q] == nil, !inFlight.contains(q) else { return }
        inFlight.insert(q)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let result = await self.classifyOnDevice(q)
                await MainActor.run {
                    if let result { self.cache[q] = result }
                    self.inFlight.remove(q)
                }
            }
        } else {
            inFlight.remove(q)
        }
        #else
        inFlight.remove(q)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func classifyOnDevice(_ q: String) async -> Bool? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: """
                Is "\(q)" a menu command or action (like close, save, quit, undo, find) \
                or an app name (like Safari, Notes, Clock, Slack)?
                Reply with exactly one word: menu or app.
                """)
            return response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("menu")
        } catch {
            return nil
        }
    }
    #endif
}
