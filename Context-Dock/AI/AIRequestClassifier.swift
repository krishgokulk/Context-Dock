import Foundation

@MainActor
final class AIRequestClassifier {
    static let shared = AIRequestClassifier()

    private init() {}

    func classify(query: String, hasExplicitContext: Bool) -> AIIntentResolution {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return AIIntentResolution(
                kind: .conversation,
                targetApps: [],
                confidence: 1,
                requiresPlanning: false
            )
        }

        let targetApps = GeneralAIActionResolver.shared
            .namedInstalledApp(in: normalized)
            .map { [$0.name] } ?? []
        let isWorkflow = looksLikeMultiStepWorkflow(normalized)
        let isDeterministic = GeneralAIActionResolver.shared.looksExecutable(normalized)
        let matchesSystemCapability = GlobalCommandCapabilities.hasSemanticMatch(normalized)
        let isScoped = hasExplicitContext || !targetApps.isEmpty || looksLikeScopedTask(normalized)

        if isWorkflow {
            return AIIntentResolution(
                kind: .multiStepWorkflow,
                targetApps: targetApps,
                confidence: 0.86,
                requiresPlanning: true
            )
        }

        if isDeterministic {
            return AIIntentResolution(
                kind: .deterministicAction,
                targetApps: targetApps,
                confidence: 0.9,
                requiresPlanning: false
            )
        }

        // A compact system phrase can be neither a grammatical command nor a question:
        // "dark mode", "volume", a user-authored "focus setup". It is still capability-
        // shaped and must enter discovery instead of falling through to provider chat.
        if matchesSystemCapability {
            return AIIntentResolution(
                kind: .scopedTask,
                targetApps: [],
                confidence: 0.88,
                requiresPlanning: false
            )
        }

        if isScoped {
            return AIIntentResolution(
                kind: .scopedTask,
                targetApps: targetApps,
                confidence: 0.78,
                requiresPlanning: false
            )
        }

        return AIIntentResolution(
            kind: .conversation,
            targetApps: [],
            confidence: 0.92,
            requiresPlanning: false
        )
    }

    private func looksLikeMultiStepWorkflow(_ query: String) -> Bool {
        let workflowVerbs = [
            "find ", "search ", "read ", "summarize", "summarise", "create ",
            "send ", "email ", "share ", "move ", "save ", "upload ", "open ",
            "launch ",
        ]
        let matchedVerbCount = workflowVerbs.reduce(into: 0) { count, verb in
            if query.contains(verb) { count += 1 }
        }
        // A plain "and" between two actions is the commonest way people say "two steps" —
        // "find the newest export and open it" has no "then" and nothing to share, and was
        // classified as a single action, so it was answered with one route that did half
        // the job. A false positive here costs one planner call that returns an empty plan;
        // a false negative silently drops work the user asked for.
        let sequenceSignals = [
            " and then ", " then ", " after that ", " once ", " followed by ", " and ", ", ",
        ]
        if sequenceSignals.contains(where: query.contains), matchedVerbCount >= 2 {
            return true
        }
        return matchedVerbCount >= 2 && containsSharingIntent(query)
    }

    private func looksLikeScopedTask(_ query: String) -> Bool {
        looksLikeAppDataRequest(query)
            || query.contains("this file")
            || query.contains("this document")
            || query.contains("this screenshot")
            || query.contains("this page")
            || query.contains("selected text")
            || query.contains("selected file")
    }

    private func looksLikeAppDataRequest(_ query: String) -> Bool {
        let readSignals = [
            "how many", "list ", "find ", "search ", "latest ", "recent ",
            "history", "status", "what's going on", "whats going on",
        ]
        return readSignals.contains(where: query.contains)
    }

    private func containsSharingIntent(_ query: String) -> Bool {
        ["send ", "email ", "share ", "message ", "airdrop ", "upload "]
            .contains(where: query.contains)
    }
}
