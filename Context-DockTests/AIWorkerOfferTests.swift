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

    // MARK: - The rung's place in the ladder

    /// A worker costs minutes and money; a linked route costs neither. The specialist rung is
    /// only reached once nothing linked could carry the request out, and this is the test that
    /// was missing while that ordering lived as a bare `sendChoices.isEmpty` at the call site —
    /// deleting it would have started offering a specialist beside routes that already work,
    /// and the suite would have stayed green.
    @Test func aRequestSomethingLinkedCanDoNeverReachesASpecialist() throws {
        let task = try #require(task())

        #expect(
            AIWorkerOffer.shouldOffer(
                hasLinkedRoute: true, task: task, workers: [claudeCode, codex]) == false)
    }

    @Test func nothingLinkedAndRealWorkReachesIt() throws {
        let task = try #require(task())

        #expect(
            AIWorkerOffer.shouldOffer(
                hasLinkedRoute: false, task: task, workers: [claudeCode, codex]))
    }

    /// `AIWorkerTask.bounded` returns nil for a question, or for work outside every
    /// specialist's domain. Either way there is nothing to delegate, and the rung is skipped
    /// rather than offering a specialist that cannot help.
    @Test func withoutABoundedTaskThereIsNothingToOffer() {
        #expect(
            AIWorkerOffer.shouldOffer(
                hasLinkedRoute: false, task: nil, workers: [claudeCode, codex]) == false)
    }

    @Test func aSpecialistIsNotOfferedWhenNoneIsInstalled() throws {
        let task = try #require(task())

        #expect(AIWorkerOffer.shouldOffer(hasLinkedRoute: false, task: task, workers: []) == false)
    }

    /// The ordering question is "could anything linked do this", not "did it work". A route
    /// that exists and failed is still a route; falling through to a worker because a command
    /// errored is a different decision and is not this one.
    @Test func aRouteThatExistsOutranksASpecialistEvenForWorkTheSpecialistFits() throws {
        let task = try #require(task())

        #expect(task.domains.contains(.build))
        #expect(
            AIWorkerOffer.shouldOffer(
                hasLinkedRoute: true, task: task, workers: [codex]) == false)
    }
}
