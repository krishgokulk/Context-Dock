import Foundation
import Testing
@testable import Context_Dock

/// What the app reads back from the machine to check a specialist's report — only the facts
/// the report should have cited, so a true report about something else is not called a lie.
@MainActor
struct AIWorkerReadingsTests {
    private func task(goal: String, bundleID: String? = "com.microsoft.VSCode", path: String? = "/tmp/repo")
        -> AIWorkerTask
    {
        AIWorkerTask(
            goal: goal,
            authority: AIWorkerAuthority(
                scopeDescription: "VS Code",
                allowedPaths: [path].compactMap { $0 }.map { URL(fileURLWithPath: $0) },
                allowedAppBundleIDs: [bundleID].compactMap { $0 },
                allowsWrites: false,
                allowsShell: false),
            domains: [.systemInspection, .repository],
            forbidden: [],
            timeout: 60,
            attemptBudget: 1,
            expectedOutput: "a report",
            requiresVerification: true)
    }

    private var probes: AIWorkerReadings.Probes {
        AIWorkerReadings.Probes(
            appVersion: { $0 == "com.microsoft.VSCode" ? "1.94.2" : nil },
            gitBranch: { $0.path == "/tmp/repo" ? "main" : nil },
            gitHead: { $0.path == "/tmp/repo" ? "abc1234" : nil })
    }

    @Test func aVersionQuestionReadsTheAppVersion() {
        let readings = AIWorkerReadings.take(for: task(goal: "which version of VS Code is installed"), probes: probes)
        #expect(readings == [.init(subject: "VS Code version", value: "1.94.2", succeeded: true)])
    }

    @Test func aRepositoryQuestionReadsBranchAndHead() {
        let readings = AIWorkerReadings.take(for: task(goal: "what branch is this repo on and its last commit"), probes: probes)
        #expect(readings.map(\.subject) == ["branch", "HEAD"])
        #expect(readings.map(\.value) == ["main", "abc1234"])
        let allSucceeded = readings.allSatisfy { $0.succeeded }
        #expect(allSucceeded)
    }

    @Test func anUnrelatedQuestionReadsNothing() {
        // "Why does the build fail" cites neither a version nor a commit; reading those back
        // would flag a correct answer as contradicted.
        let readings = AIWorkerReadings.take(for: task(goal: "why does the build fail with a linker error"), probes: probes)
        #expect(readings.isEmpty)
    }

    @Test func aProbeThatCannotAnswerIsRecordedAsFailed() {
        let readings = AIWorkerReadings.take(for: task(goal: "is this version outdated", bundleID: "com.example.missing"), probes: probes)
        #expect(readings.count == 1)
        #expect(readings[0].succeeded == false)
    }

    @Test func noScopeMeansNoReading() {
        let readings = AIWorkerReadings.take(for: task(goal: "which version is installed", bundleID: nil, path: nil), probes: probes)
        #expect(readings.isEmpty)
    }
}
