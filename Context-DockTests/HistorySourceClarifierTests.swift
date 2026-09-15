import Foundation
import Testing

@testable import Context_Dock

struct HistorySourceClarifierTests {
    private let sources = [
        HistorySourceOption(name: "Safari", bundleID: "com.apple.Safari"),
        HistorySourceOption(name: "Tutorini Player", bundleID: "app.tutorini.Tutorini"),
    ]

    @Test func unscopedPersonalHistoryAsksWhichApp() {
        let question = HistorySourceClarifier.questionIfNeeded(
            query: "Play a video from my History",
            namedApp: nil, scopedApp: nil, availableSources: sources)
        #expect(question?.contains("Which app") == true)
        #expect(question?.contains("specific app") == true)
        #expect(question?.contains("Safari") == false)
        #expect(question?.contains("Tutorini Player") == false)
    }

    @Test func crossAppHistoryDoesNotEscapeTheCurrentScope() {
        let question = HistorySourceClarifier.questionIfNeeded(
            query: "Read my Safari history",
            namedApp: ("Safari", "com.apple.Safari"),
            scopedApp: ("Code", "com.microsoft.VSCode"),
            availableSources: sources)
        #expect(question?.contains("scoped to **Code**") == true)
        #expect(question?.contains("**Safari** history") == true)
    }

    @Test func matchingNamedAppNeedsNoClarification() {
        #expect(HistorySourceClarifier.questionIfNeeded(
            query: "Read my Safari history",
            namedApp: ("Safari", "com.apple.Safari"),
            scopedApp: ("Safari", "com.apple.Safari"),
            availableSources: sources) == nil)
    }

    @Test func scopedHistorySourceMayUseItsOwnHistory() {
        #expect(HistorySourceClarifier.questionIfNeeded(
            query: "What did I watch in my history?",
            namedApp: nil,
            scopedApp: ("Tutorini Player", "app.tutorini.Tutorini"),
            availableSources: sources) == nil)
    }

    @Test func ordinaryHistoricalQuestionsAreNotIntercepted() {
        #expect(HistorySourceClarifier.questionIfNeeded(
            query: "Explain the history of artificial intelligence",
            namedApp: nil, scopedApp: nil, availableSources: sources) == nil)
    }

    @Test @MainActor func appNameFollowUpResumesTheOriginalRequest() {
        let surface = "history-test-\(UUID().uuidString)"
        HistorySourceClarificationStore.shared.begin(
            surface: surface,
            originalQuery: "Play How to Build an AI Email Agent from my history")

        let resumed = HistorySourceClarificationStore.shared.resume(
            surface: surface,
            namedApp: ("Tutorini Player", "app.tutorini.Tutorini"))

        #expect(resumed?.contains("Play How to Build an AI Email Agent") == true)
        #expect(resumed?.contains("Tutorini Player") == true)
        #expect(HistorySourceClarificationStore.shared.resume(
            surface: surface,
            namedApp: ("Tutorini Player", "app.tutorini.Tutorini")) == nil)
    }

    @Test func misspelledAppNameGetsOneCloseSuggestion() {
        let match = HistorySourceAppMatcher.closestMatch(in: "tuturine", sources: sources)
        #expect(match?.name == "Tutorini Player")
    }

    @Test func unrelatedNameDoesNotGuessAnApp() {
        #expect(HistorySourceAppMatcher.closestMatch(in: "something else", sources: sources) == nil)
    }

    @Test @MainActor func confirmedSuggestionResumesSavedTask() {
        let surface = "history-confirm-test-\(UUID().uuidString)"
        let tutorini = sources[1]
        HistorySourceClarificationStore.shared.begin(
            surface: surface,
            originalQuery: "Play the email agent video from my history")
        HistorySourceClarificationStore.shared.suggest(surface: surface, app: tutorini)

        let confirmed = HistorySourceClarificationStore.shared.confirmedSuggestion(
            surface: surface, reply: "yes")
        let resumed = HistorySourceClarificationStore.shared.resume(
            surface: surface,
            namedApp: confirmed.map { (name: $0.name, bundleId: $0.bundleID) })

        #expect(confirmed == tutorini)
        #expect(resumed?.contains("Play the email agent video") == true)
        #expect(resumed?.contains("Use Tutorini Player") == true)
    }
}
