import Testing
@testable import Context_Dock

@MainActor
struct FrontmostMenuFactsTests {
    private let tutoriniPaths = [
        ["File", "Close"],
        ["Playback", "Play/Pause"],
        ["View", "100%"],
        ["Tutorini Player", "Quit Tutorini"],
        ["History", "ALL UPCOMING SUPERHERO MOVIES 2026 (Trailers)"],
        ["History", "Lesa Lesa | Aval Ulaga Azhagi Video Song"],
        ["History", "Clear History"],
    ]

    @Test func watchedQuestionReadsObservedHistoryInsteadOfCommands() {
        let block = AppScopedChatService.menuSnapshotFactBlock(
            query: "what did i watch here before?", appName: "Tutorini Player",
            paths: tutoriniPaths, age: 0)

        #expect(block?.contains("Tutorini Player observed menu data — History") == true)
        #expect(block?.contains("ALL UPCOMING SUPERHERO MOVIES") == true)
        #expect(block?.contains("Lesa Lesa") == true)
        #expect(block?.contains("Clear History") == false)
        #expect(block?.contains("100%") == false)
        #expect(block?.contains("Quit Tutorini") == false)
        #expect(block?.contains("No menu was opened or clicked") == true)
    }

    @Test func directAnswerContainsOnlyTypedHistoryEvidence() {
        let evidence = AppScopedChatService.menuSnapshotEvidence(
            query: "what did i watch here before?", appName: "Tutorini Player",
            paths: tutoriniPaths, age: 0)

        #expect(evidence?.root == "History")
        #expect(evidence?.directAnswer.contains("ALL UPCOMING SUPERHERO MOVIES") == true)
        #expect(evidence?.directAnswer.contains("100%") == false)
        #expect(evidence?.directAnswer.contains("Quit Tutorini") == false)
    }

    @Test func unrelatedQuestionDoesNotPretendMenuCommandsAreFacts() {
        #expect(AppScopedChatService.menuSnapshotFactBlock(
            query: "what is this application for?", appName: "Tutorini Player",
            paths: tutoriniPaths, age: 0) == nil)
    }

    @Test func watchedHistoryRequiresFreshEvidenceAndRejectsMemory() {
        let decision = AgentSourceAuthority.decide(query: "what did i watch here before?")
        #expect(decision.primary == .liveState)
        #expect(decision.requiresFreshRead)
        #expect(!decision.allowsMemoryEvidence)
    }
}
