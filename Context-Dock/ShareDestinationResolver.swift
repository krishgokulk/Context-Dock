import AppKit
import Foundation

struct ResolvedShareDestination {
    let service: NSSharingService
    let title: String
    let score: Int
}

enum ShareDestinationResolver {
    nonisolated static func resolve(
        query: String,
        items: [Any]
    ) -> ResolvedShareDestination? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !items.isEmpty else { return nil }

        let services = NSSharingService.sharingServices(forItems: items)
        guard !services.isEmpty else { return nil }

        let normalizedQuery = normalizedDestinationText(trimmedQuery)
        guard !normalizedQuery.isEmpty else { return nil }

        var bestMatch: ResolvedShareDestination?
        for service in services {
            let rawTitle = service.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else { continue }
            guard let score = matchScore(query: normalizedQuery, title: rawTitle) else { continue }

            let candidate = ResolvedShareDestination(service: service, title: rawTitle, score: score)
            if let currentBest = bestMatch {
                if candidate.score > currentBest.score {
                    bestMatch = candidate
                }
            } else {
                bestMatch = candidate
            }
        }

        return bestMatch
    }

    nonisolated private static func matchScore(query: String, title: String) -> Int? {
        let canonicalTitle = canonicalDestination(from: title)
        let normalizedTitle = normalizedDestinationText(canonicalTitle)
        guard !normalizedTitle.isEmpty else { return nil }

        let queryVariants = candidatePhrases(for: query)
        let titleVariants = candidatePhrases(for: normalizedTitle) + aliases(for: normalizedTitle)

        var bestScore: Int?
        for queryVariant in queryVariants {
            guard !queryVariant.isEmpty else { continue }
            for titleVariant in titleVariants where !titleVariant.isEmpty {
                let score = scoreVariantMatch(query: queryVariant, title: titleVariant)
                if let score {
                    if let current = bestScore {
                        if score > current { bestScore = score }
                    } else {
                        bestScore = score
                    }
                }
            }
        }

        return bestScore
    }

    nonisolated private static func scoreVariantMatch(query: String, title: String) -> Int? {
        guard !query.isEmpty, !title.isEmpty else { return nil }

        if query == title {
            return 500
        }

        let queryCompact = query.replacingOccurrences(of: " ", with: "")
        let titleCompact = title.replacingOccurrences(of: " ", with: "")

        if queryCompact == titleCompact {
            return 460
        }
        if title.hasPrefix(query) || query.hasPrefix(title) {
            return 360
        }
        if titleCompact.hasPrefix(queryCompact) || queryCompact.hasPrefix(titleCompact) {
            return 330
        }
        if title.contains(query) || query.contains(title) {
            return 260
        }

        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let titleTokens = Set(title.split(separator: " ").map(String.init))
        let overlap = queryTokens.intersection(titleTokens).count
        guard overlap > 0 else { return nil }
        return 140 + overlap * 40
    }

    nonisolated private static func candidatePhrases(for value: String) -> [String] {
        let normalized = normalizedDestinationText(value)
        guard !normalized.isEmpty else { return [] }

        var phrases = [normalized]
        let withoutAppWords = normalized
            .replacingOccurrences(of: "\\b(app|desktop|extension|service|share|sharing)\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !withoutAppWords.isEmpty, withoutAppWords != normalized {
            phrases.append(withoutAppWords)
        }

        return Array(NSOrderedSet(array: phrases)) as? [String] ?? phrases
    }

    nonisolated private static func canonicalDestination(from title: String) -> String {
        title
            .replacingOccurrences(of: "^(add|send|share|open|save|post|copy)\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+(to|with|in)\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func aliases(for normalizedTitle: String) -> [String] {
        switch normalizedTitle {
        case "notes":
            return ["apple notes", "notes app"]
        case "reminders":
            return ["reminders app"]
        case "freeform":
            return ["freeform app"]
        case "shortcuts":
            return ["shortcuts app"]
        case "journal":
            return ["journal app"]
        case "downie":
            return ["send to downie", "downie app"]
        case "sidenotes":
            return ["side notes", "sidenotes app"]
        case "mail":
            return ["email", "apple mail"]
        case "messages":
            return ["imessage", "apple messages"]
        default:
            return []
        }
    }

    nonisolated private static func normalizedDestinationText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
