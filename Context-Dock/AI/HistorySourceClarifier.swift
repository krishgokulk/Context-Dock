import Foundation

struct HistorySourceOption: Equatable, Identifiable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

@MainActor
final class HistorySourceClarificationStore {
    static let shared = HistorySourceClarificationStore()

    private struct Pending {
        let query: String
        let createdAt: Date
        var suggestedApp: HistorySourceOption?
    }

    private var pendingBySurface: [String: Pending] = [:]
    private let lifetime: TimeInterval = 5 * 60

    func begin(surface: String, originalQuery: String) {
        pendingBySurface[surface] = Pending(
            query: originalQuery, createdAt: Date(), suggestedApp: nil)
    }

    func hasPending(surface: String) -> Bool {
        guard let pending = pendingBySurface[surface] else { return false }
        return Date().timeIntervalSince(pending.createdAt) <= lifetime
    }

    func suggest(surface: String, app: HistorySourceOption) {
        pendingBySurface[surface]?.suggestedApp = app
    }

    func confirmedSuggestion(surface: String, reply: String) -> HistorySourceOption? {
        guard var pending = pendingBySurface[surface], let app = pending.suggestedApp else {
            return nil
        }
        let words = Set(reply.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["yes", "yeah", "yep", "correct", "right", "confirm"]) {
            return app
        }
        if !words.isDisjoint(with: ["no", "nope", "wrong"]) {
            pending.suggestedApp = nil
            pendingBySurface[surface] = pending
        }
        return nil
    }

    func resume(
        surface: String,
        namedApp: (name: String, bundleId: String)?
    ) -> String? {
        guard let pending = pendingBySurface[surface] else { return nil }
        guard Date().timeIntervalSince(pending.createdAt) <= lifetime else {
            pendingBySurface[surface] = nil
            return nil
        }
        guard let namedApp else { return nil }
        pendingBySurface[surface] = nil
        return pending.query + "\nUse \(namedApp.name) as the history source."
    }
}

enum HistorySourceAppMatcher {
    static func closestMatch(
        in reply: String, sources: [HistorySourceOption]
    ) -> HistorySourceOption? {
        let replyWords = reply.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 4 && $0 != "player" && $0 != "application" }
        guard !replyWords.isEmpty else { return nil }

        var ranked: [(distance: Int, length: Int, source: HistorySourceOption)] = []
        for source in sources {
            let sourceWords = source.name.lowercased()
                .split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count >= 4 && $0 != "player" }
            guard let best = replyWords.flatMap({ replyWord in
                sourceWords.map { editDistance(replyWord, $0) }
            }).min() else { continue }
            let comparedLength = max(
                replyWords.map(\.count).max() ?? 0,
                sourceWords.map(\.count).max() ?? 0)
            let allowed = comparedLength <= 6 ? 1 : 2
            guard best <= allowed else { continue }
            ranked.append((best, comparedLength, source))
        }
        return ranked.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.source.name < $1.source.name
        }.first?.source
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

enum HistorySourceClarifier {
    static func questionIfNeeded(
        query: String,
        namedApp: (name: String, bundleId: String)?,
        scopedApp: (name: String, bundleId: String)?,
        availableSources: [HistorySourceOption]
    ) -> String? {
        guard isPersonalHistoryRequest(query) else { return nil }

        if let namedApp {
            if let scopedApp,
                scopedApp.bundleId.caseInsensitiveCompare(namedApp.bundleId) != .orderedSame
            {
                return "This chat is scoped to **\(scopedApp.name)**, but you asked for "
                    + "**\(namedApp.name)** history. Should I use \(namedApp.name) instead?"
            }
            return nil
        }

        if let scopedApp,
            availableSources.contains(where: {
                $0.bundleID.caseInsensitiveCompare(scopedApp.bundleId) == .orderedSame
            })
        {
            return nil
        }

        return "Which app’s history do you mean? Are you looking in a specific app? "
            + "Mention that app and I’ll continue your original request."
    }

    static func isPersonalHistoryRequest(_ query: String) -> Bool {
        let text = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        if text.contains("history"), words.contains("my") {
            return true
        }
        let historyShapes = [
            "my history", "from history", "from my history", "watch history",
            "watched history", "viewing history", "play history", "recently watched",
            "what did i watch", "what have i watched",
        ]
        return historyShapes.contains(where: text.contains)
    }
}
