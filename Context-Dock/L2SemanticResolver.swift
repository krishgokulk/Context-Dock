import Foundation

enum L2SemanticDecision: Equatable {
    case appAction(appName: String, actionPhrase: String)
    case crossApp(targetApp: String, mode: String)
    case terminal(query: String)
    case askUser(options: [String])
    case noMatch
}

@MainActor
final class L2SemanticResolver {
    static let shared = L2SemanticResolver()

    private init() {}

    private struct ResponsePayload: Codable {
        let kind: String
        let appName: String?
        let actionPhrase: String?
        let targetApp: String?
        let mode: String?
        let terminalQuery: String?
        let options: [String]?
        let confidence: Double?
    }

    private struct CandidateAction {
        let appName: String
        let actionName: String
        let score: Int
        let triggers: [String]
    }

    private let crossAppTargets = ["Notes", "Notion", "Bear", "Obsidian", "Messages", "Mail", "Safari", "Reminders"]

    func resolve(query: String, context: UserContext, axContext: AXContext) async -> L2SemanticDecision {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noMatch }

        let provider = AppSettings.shared.createAIProvider()
        let prompt = buildPrompt(query: trimmed, context: context, axContext: axContext)

        do {
            let raw = try await provider.sendQuery(prompt, context: context, conversationHistory: [])
            guard let payload = decodePayload(from: raw) else { return .noMatch }
            return decision(from: payload)
        } catch {
            return .noMatch
        }
    }

    private func buildPrompt(query: String, context: UserContext, axContext: AXContext) -> String {
        let appCandidates = topActionCandidates(for: query)
            .map { "- \($0.appName) -> \($0.actionName) [score:\($0.score)] triggers: \($0.triggers.prefix(4).joined(separator: ", "))" }
            .joined(separator: "\n")

        let crossTargets = crossAppTargets.map { "- \($0)" }.joined(separator: "\n")

        return """
        You are a semantic command resolver for a macOS launcher.
        Your job is to map the user's query to ONE structured routing decision.

        Rules:
        - Prefer deterministic app actions if the query sounds like app command execution.
        - Prefer cross-app when the query is about sending, saving, bookmarking, clipping, or opening the current content in another app.
        - Use terminal only if the user is asking for command-line/system/tool operations rather than app UI actions.
        - If ambiguous, return askUser with 2-4 concise options.
        - If you are not confident, return noMatch.
        - Output JSON only. No markdown. No explanation.

        Allowed JSON schema:
        {
          "kind": "appAction" | "crossApp" | "terminal" | "askUser" | "noMatch",
          "appName": "optional",
          "actionPhrase": "optional",
          "targetApp": "optional",
          "mode": "capture|page|link|bookmark|open|send optional",
          "terminalQuery": "optional",
          "options": ["optional"],
          "confidence": 0.0
        }

        User query:
        \(query)

        UserContext:
        \(context.description)

        AXContext:
        \(axContext.contextSummary)

        Top adapter action candidates:
        \(appCandidates.isEmpty ? "- none" : appCandidates)

        Built-in cross-app targets:
        \(crossTargets)
        """
    }

    private func topActionCandidates(for query: String) -> [CandidateAction] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        var candidates: [CandidateAction] = []
        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            let appScore = tokenOverlap(normalize(adapter.appName), normalizedQuery) * 20
            for action in adapter.actions {
                let nameScore = tokenOverlap(normalize(action.name), normalizedQuery) * 24
                let triggerScore = action.triggers
                    .map { tokenOverlap(normalize($0), normalizedQuery) * 18 }
                    .max() ?? 0
                let score = appScore + nameScore + triggerScore
                guard score > 0 else { continue }

                candidates.append(CandidateAction(
                    appName: adapter.appName,
                    actionName: action.name,
                    score: score,
                    triggers: action.triggers
                ))
            }
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.actionName < rhs.actionName
                }
                return lhs.score > rhs.score
            }
            .prefix(12)
            .map { $0 }
    }

    private func decodePayload(from raw: String) -> ResponsePayload? {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = source.firstIndex(of: "{"),
              let end = source.lastIndex(of: "}") else {
            return nil
        }

        let json = String(source[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResponsePayload.self, from: data)
    }

    private func decision(from payload: ResponsePayload) -> L2SemanticDecision {
        let confidence = payload.confidence ?? 0
        if confidence < 0.55 {
            return .noMatch
        }

        switch payload.kind {
        case "appAction":
            if let appName = nonEmpty(payload.appName), let actionPhrase = nonEmpty(payload.actionPhrase) {
                return .appAction(appName: appName, actionPhrase: actionPhrase)
            }
        case "crossApp":
            if let targetApp = nonEmpty(payload.targetApp) {
                return .crossApp(targetApp: targetApp, mode: nonEmpty(payload.mode) ?? "capture")
            }
        case "terminal":
            if let terminalQuery = nonEmpty(payload.terminalQuery) {
                return .terminal(query: terminalQuery)
            }
        case "askUser":
            if let options = payload.options?.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               !options.isEmpty {
                return .askUser(options: Array(options.prefix(4)))
            }
        default:
            break
        }

        return .noMatch
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalize(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func tokenOverlap(_ lhs: String, _ rhs: String) -> Int {
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        return left.intersection(right).count
    }
}
