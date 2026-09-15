import Foundation
import Testing

@testable import Context_Dock

/// Offering a specialist, and never taking the decision.
@MainActor
@Suite("Worker offer")
struct AIWorkerOfferTests {
    private let claudeCode = AIWorker(
        kind: .claudeCode,
        executablePath: URL(fileURLWithPath: "/bin/claude"),
        domains: [.coding, .repository, .build, .test, .systemInspection])
    private let codex = AIWorker(
        kind: .codex,
        executablePath: URL(fileURLWithPath: "/bin/codex"),
        domains: [.coding, .repository, .build, .test, .systemInspection])

    private func task() -> AIWorkerTask? {
        AIWorkerTask.bounded(
            goal: "investigate why the build fails",
            scope: .app(bundleId: "com.microsoft.VSCode"),
            appName: "Code",
            workspace: URL(fileURLWithPath: "/Users/someone/Developer/Context-Dock"))
    }

    @Test func eachInstalledSpecialistIsOfferedByName() throws {
        let task = try #require(task())
        let choices = AIWorkerOffer.choices(for: task, workers: [claudeCode, codex])

        #expect(choices.map(\.title) == ["Ask Claude Code", "Ask Codex"])
    }

    /// The id has to say which worker, or picking one runs whatever the route resolver
    /// happens to match on the words instead.
    @Test func theChoiceIdentifiesTheWorkerItRuns() throws {
        let task = try #require(task())
        let choice = try #require(
            AIWorkerOffer.choices(for: task, workers: [codex]).first)

        #expect(AIWorkerOffer.worker(for: choice.id) == .codex)
        #expect(AIWorkerOffer.isWorkerChoice(choice.id))
    }

    /// An ordinary route id must not be mistaken for a delegation.
    @Test func anOrdinaryRouteIsNotAWorkerChoice() {
        #expect(!AIWorkerOffer.isWorkerChoice("menuCommand:com.apple.finder:View > Show Sidebar"))
        #expect(AIWorkerOffer.worker(for: "menuCommand:whatever") == nil)
    }

    @Test func nothingIsOfferedWhenNothingIsInstalled() throws {
        let task = try #require(task())
        #expect(AIWorkerOffer.choices(for: task, workers: []).isEmpty)
    }

    /// The card says what it will and will not do, in the user's words, before they pick.
    @Test func theOfferStatesItsBoundary() throws {
        let task = try #require(task())
        let sentence = AIWorkerOffer.explanation(for: task, workers: [claudeCode]).lowercased()

        #expect(sentence.contains("read"))
        #expect(sentence.contains("code"))
    }
}
