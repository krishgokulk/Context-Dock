import Foundation
import Testing

@testable import Context_Dock

/// What a delegated worker is allowed to touch.
///
/// This is the part of the worker layer worth being strict about. A worker delegated from a
/// chat scoped to one app, that can read Mail and the whole home folder, has quietly turned
/// Context Dock Chat into General AI — the layer merge this project's own rule forbids. So the
/// envelope is derived from the scope that asked, and an envelope wider than its scope is a
/// test failure rather than a code-review note.
@Suite("Worker task contract")
struct AIWorkerTaskTests {
    private let project = URL(fileURLWithPath: "/Users/someone/Developer/Context-Dock")

    @Test func anAppScopedTaskReachesOnlyThatApp() throws {
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate why the build fails",
                scope: .app(bundleId: "com.microsoft.VSCode"),
                appName: "Code",
                workspace: project))

        #expect(task.authority.allowedAppBundleIDs == ["com.microsoft.VSCode"])
        #expect(task.authority.allowedPaths == [project])
    }

    @Test func aFolderScopedTaskReachesOnlyThatFolder() throws {
        let folder = URL(fileURLWithPath: "/Users/someone/Developer/scripts")
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "debug why the build script here fails",
                scope: .folder(path: folder.path),
                appName: nil,
                workspace: project))

        #expect(task.authority.allowedPaths == [folder])
        #expect(task.authority.allowedAppBundleIDs.isEmpty)
    }

    /// Reading is the default and writing is not: a delegation the user approved to
    /// *investigate* must not come back having changed things.
    @Test func nothingIsWritableOrShellableByDefault() throws {
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate the failing test",
                scope: .app(bundleId: "com.microsoft.VSCode"),
                appName: "Code",
                workspace: project))

        #expect(!task.authority.allowsWrites)
        #expect(!task.authority.allowsShell)
        #expect(task.requiresVerification)
    }

    /// Budgets are part of the contract, not a runtime afterthought: a worker with no ceiling
    /// is a process the user cannot predict the cost of.
    @Test func everyTaskCarriesACeiling() throws {
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate the failing test",
                scope: .app(bundleId: "com.microsoft.VSCode"),
                appName: "Code",
                workspace: project))

        #expect(task.timeout > 0)
        #expect(task.attemptBudget >= 1)
        #expect(!task.expectedOutput.isEmpty)
    }

    /// Work a specialist has no claim on is not delegated either. "Find the duplicate
    /// invoices" is file work, and DoraX's own finder capabilities do it — a coding agent is
    /// not the answer to every task that happens to be hard.
    @Test func workOutsideEverySpecialistDomainIsNotDelegated() {
        #expect(
            AIWorkerTask.bounded(
                goal: "sort the duplicate invoices into folders",
                scope: .folder(path: "/Users/someone/Documents/Invoices"),
                appName: nil,
                workspace: nil) == nil)
    }

    /// A question is not work, so it never becomes a task — the rung above answers it.
    @Test func aQuestionIsNotDelegated() {
        #expect(
            AIWorkerTask.bounded(
                goal: "is there a newer version available",
                scope: .app(bundleId: "com.microsoft.VSCode"),
                appName: "Code",
                workspace: project) == nil)
    }

    /// General Chat is where a request that needs more than one app belongs. A task built
    /// there grants no app authority of its own — it has no app to speak for.
    @Test func aGeneralScopedTaskSpeaksForNoApp() throws {
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "refactor the parser into two files",
                scope: .general,
                appName: nil,
                workspace: project))

        #expect(task.authority.allowedAppBundleIDs.isEmpty)
        #expect(task.authority.allowedPaths == [project])
    }

    /// The forbidden list is stated, not implied: it is what the approval card shows and what
    /// the prompt to the worker repeats.
    @Test func whatItMayNotDoIsWrittenDown() throws {
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate why the build fails",
                scope: .app(bundleId: "com.microsoft.VSCode"),
                appName: "Code",
                workspace: project))

        let forbidden = task.forbidden.joined(separator: " ").lowercased()
        #expect(forbidden.contains("sudo"))
        #expect(forbidden.contains("install"))
        #expect(forbidden.contains("delete"))
    }
}
