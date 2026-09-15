import Foundation
import Testing

@testable import Context_Dock

/// Which specialist, for which request, and in what order.
///
/// The decision has to be a value question: a worker costs minutes and money, so choosing one
/// must be testable without installing either agent or spawning anything.
@Suite("Worker routing")
struct AIWorkerRoutingTests {
    private let claudeCode = AIWorker(
        kind: .claudeCode,
        executablePath: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        domains: [.coding, .repository, .build, .test, .systemInspection])
    private let codex = AIWorker(
        kind: .codex,
        executablePath: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        domains: [.coding, .repository, .build, .test, .systemInspection])

    // MARK: - Is this work for a specialist at all?

    /// A worker is reached when the request is *work*, not when a capability is merely
    /// missing. "Is there a newer version" is a question, and questions are answered by the
    /// approvable-command rung one step above — spawning an agent for minutes to learn what a
    /// curl returns in a moment is the failure this gate exists to prevent.
    @Test(arguments: [
        "is there a newer version available",
        "what is my current version",
        "how do I open a file here",
        "summarise this page",
    ])
    func aQuestionIsNotWorkForASpecialist(query: String) {
        #expect(!AIWorkerRouter.isWorkerShaped(query))
    }

    @Test(arguments: [
        "fix this compile error",
        "investigate why the build fails",
        "refactor this file into two",
        "write tests for the parser",
        "debug why the app crashes on launch",
    ])
    func realWorkIsWorkForASpecialist(query: String) {
        #expect(AIWorkerRouter.isWorkerShaped(query))
    }

    // MARK: - Eligibility

    @Test func nothingInstalledOffersNothing() {
        #expect(AIWorkerRouter.eligible(for: "fix this compile error", from: []).isEmpty)
    }

    @Test func aQuestionOffersNothingEvenWhenBothAreInstalled() {
        #expect(
            AIWorkerRouter.eligible(
                for: "is there a newer version available",
                from: [claudeCode, codex]
            ).isEmpty)
    }

    @Test func codingWorkOffersEveryInstalledSpecialist() {
        let offered = AIWorkerRouter.eligible(for: "fix this compile error", from: [claudeCode, codex])
        #expect(offered.count == 2)
    }

    /// A worker that does not claim the domain is not offered for it. Workers are
    /// specialists; treating them as universal is how one gets used for everything.
    @Test func aWorkerOutsideItsDomainIsNotOffered() {
        let researchOnly = AIWorker(
            kind: .codex,
            executablePath: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            domains: [.systemInspection])
        let offered = AIWorkerRouter.eligible(for: "write tests for the parser", from: [researchOnly])
        #expect(offered.isEmpty)
    }

    /// Order must not depend on dictionary iteration or install order: the same request
    /// offers the same first choice every time, or the button under the user's cursor moves.
    @Test func orderIsStable() {
        let one = AIWorkerRouter.eligible(for: "refactor this file into two", from: [codex, claudeCode])
        let two = AIWorkerRouter.eligible(for: "refactor this file into two", from: [claudeCode, codex])
        #expect(one.map(\.kind) == two.map(\.kind))
    }

    // MARK: - Domains

    @Test func domainsAreReadFromTheRequest() {
        #expect(AIWorkerRouter.domains(for: "write tests for the parser").contains(.test))
        #expect(AIWorkerRouter.domains(for: "investigate why the build fails").contains(.build))
        #expect(AIWorkerRouter.domains(for: "refactor this file into two").contains(.coding))
    }

    /// Work with no recognisable domain is not handed to a specialist on a guess.
    @Test func unrecognisedWorkClaimsNoDomain() {
        #expect(AIWorkerRouter.domains(for: "organise my sock drawer").isEmpty)
    }
}
