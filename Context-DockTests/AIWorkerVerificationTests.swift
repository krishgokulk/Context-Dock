import Foundation
import Testing

@testable import Context_Dock

/// A worker's word is not proof.
///
/// The report comes back as prose from an agent that ran somewhere else. DoraX either checked
/// it against the machine or it did not, and the difference has to reach the user — the app
/// already has the vocabulary for exactly this in AIVerificationStatus, so a delegated turn
/// speaks it rather than inventing a second one.
@Suite("Worker verification")
struct AIWorkerVerificationTests {
    private func task(goal: String = "investigate why the build fails") -> AIWorkerTask {
        AIWorkerTask.bounded(
            goal: goal,
            scope: .app(bundleId: "com.microsoft.VSCode"),
            appName: "Code",
            workspace: URL(fileURLWithPath: "/Users/someone/Developer/Context-Dock"))!
    }

    /// Nothing read back means exactly that, and never "verified".
    @Test func anUncheckedReportIsNotVerified() {
        let outcome = AIWorkerVerification.assess(
            report: "The build fails because the deployment target is wrong.",
            task: task(),
            readings: [])

        #expect(outcome.status == .executorConfirmed)
    }

    /// A reading that agrees with the report is what "verified" is for.
    @Test func aReadingThatAgreesVerifiesIt() {
        let outcome = AIWorkerVerification.assess(
            report: "The deployment target is macOS 26.1.",
            task: task(),
            readings: [.init(subject: "deployment target", value: "macOS 26.1", succeeded: true)])

        #expect(outcome.status == .verified)
    }

    /// A reading that contradicts the report is the case worth catching: the report is wrong
    /// and the user must not be told otherwise.
    @Test func aReadingThatDisagreesFailsVerification() {
        let outcome = AIWorkerVerification.assess(
            report: "The deployment target is macOS 15.0.",
            task: task(),
            readings: [.init(subject: "deployment target", value: "macOS 26.1", succeeded: true)])

        #expect(outcome.status == .unverified)
        #expect(outcome.note.lowercased().contains("does not match"))
    }

    /// A reading that could not be taken is not evidence either way.
    @Test func aReadingThatFailedIsNotEvidence() {
        let outcome = AIWorkerVerification.assess(
            report: "The deployment target is macOS 26.1.",
            task: task(),
            readings: [.init(subject: "deployment target", value: "", succeeded: false)])

        #expect(outcome.status == .notAvailable)
    }

    /// Every delegated turn leaves a receipt, marked as the check rather than the action.
    @Test func theOutcomeCarriesAReceipt() {
        let outcome = AIWorkerVerification.assess(
            report: "Something was found.", task: task(), readings: [])

        #expect(outcome.receipt.isVerification)
        #expect(outcome.receipt.command.contains("worker"))
    }
}
