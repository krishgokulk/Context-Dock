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
                requiredCapabilityKinds: [],
                confidence: 1,
                requiresPlanning: false
            )
        }

        let targetApps = GeneralAIActionResolver.shared
            .namedInstalledApp(in: normalized)
            .map { [$0.name] } ?? []
        let isWorkflow = looksLikeMultiStepWorkflow(normalized)
        let isDeterministic = GeneralAIActionResolver.shared.looksExecutable(normalized)
        let isScoped = hasExplicitContext || !targetApps.isEmpty || looksLikeScopedTask(normalized)

        if isWorkflow {
            var kinds: Set<AICapabilityKind> = [.workflow]
            if hasExplicitContext { kinds.insert(.fileContent) }
            if containsSharingIntent(normalized) { kinds.insert(.sharing) }
            if !targetApps.isEmpty { kinds.insert(.appAction) }
            return AIIntentResolution(
                kind: .multiStepWorkflow,
                targetApps: targetApps,
                requiredCapabilityKinds: kinds,
                confidence: 0.86,
                requiresPlanning: true
            )
        }

        if isDeterministic {
            var kinds: Set<AICapabilityKind> = [.appAction]
            if containsSharingIntent(normalized) { kinds.insert(.sharing) }
            return AIIntentResolution(
                kind: .deterministicAction,
                targetApps: targetApps,
                requiredCapabilityKinds: kinds,
                confidence: 0.9,
                requiresPlanning: false
            )
        }

        if isScoped {
            var kinds: Set<AICapabilityKind> = []
            if hasExplicitContext { kinds.insert(.fileContent) }
            if !targetApps.isEmpty || looksLikeAppDataRequest(normalized) {
                kinds.insert(.appData)
            }
            return AIIntentResolution(
                kind: .scopedTask,
                targetApps: targetApps,
                requiredCapabilityKinds: kinds,
                confidence: 0.78,
                requiresPlanning: false
            )
        }

        return AIIntentResolution(
            kind: .conversation,
            targetApps: [],
            requiredCapabilityKinds: [],
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
        let sequenceSignals = [" and then ", " then ", " after that ", " once ", " followed by "]
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
