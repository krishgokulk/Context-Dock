import Foundation

/// What a delegated worker may touch, derived from the scope that asked.
///
/// This is the part of the worker layer worth being strict about. Context Dock Chat is bound
/// to one app; a worker delegated from it that can read Mail and the whole home folder has
/// quietly turned that surface into General AI, which is the layer merge this project's first
/// rule forbids. The envelope is therefore a property of the asking scope, not of the request,
/// and never widens because the model asked nicely.
struct AIWorkerAuthority: Equatable {
    /// What the user is told this delegation covers, in their words.
    let scopeDescription: String
    /// Directories the worker may read. Empty means it has been given nowhere to look.
    let allowedPaths: [URL]
    /// Apps it may speak for — one for an app-scoped chat, none anywhere else.
    let allowedAppBundleIDs: [String]
    let allowsWrites: Bool
    let allowsShell: Bool
}

/// One bounded problem handed to a specialist.
///
/// Every field is part of what the user approves: the goal they read, the envelope it runs in,
/// the ceiling it stops at, and the shape of answer it owes back. A worker with no ceiling is a
/// process whose cost nobody can predict, so the budgets are in the contract rather than left
/// to whatever the runtime happens to enforce.
struct AIWorkerTask: Equatable {
    let goal: String
    let authority: AIWorkerAuthority
    let domains: Set<AIWorkerDomain>
    /// Stated rather than implied: this is what the approval card shows and what the prompt to
    /// the worker repeats back.
    let forbidden: [String]
    let timeout: TimeInterval
    let attemptBudget: Int
    let expectedOutput: String
    /// A worker's word is not proof. Set on every task built here; the layer that runs one
    /// reads it back against the machine before the answer is believed.
    let requiresVerification: Bool

    /// Reading, from somewhere specific, and nothing else. A delegation approved to
    /// *investigate* must not come back having changed anything, so writes and shell are off
    /// in the only constructor there is.
    static func bounded(
        goal: String,
        scope: GeneralChatScope,
        appName: String?,
        workspace: URL?
    ) -> AIWorkerTask? {
        // A question is answered by the rung above this one — proposing a read-only command
        // the user approves. Spending minutes of an agent's time on what one curl returns is
        // the mistake the whole ladder exists to avoid.
        guard AIWorkerRouter.isWorkerShaped(goal) else { return nil }
        let domains = AIWorkerRouter.domains(for: goal)
        guard !domains.isEmpty else { return nil }

        let authority: AIWorkerAuthority
        switch scope {
        case .app(let bundleId):
            authority = AIWorkerAuthority(
                scopeDescription: "\(appName ?? bundleId) and \(workspace?.lastPathComponent ?? "no folder")",
                allowedPaths: [workspace].compactMap { $0 },
                allowedAppBundleIDs: [bundleId],
                allowsWrites: false,
                allowsShell: false)
        case .folder(let path):
            // The folder is the promise this thread makes. A worker that reads its parent is
            // answering about somewhere the user did not point at.
            authority = AIWorkerAuthority(
                scopeDescription: URL(fileURLWithPath: path).lastPathComponent,
                allowedPaths: [URL(fileURLWithPath: path)],
                allowedAppBundleIDs: [],
                allowsWrites: false,
                allowsShell: false)
        case .cli(let command):
            authority = AIWorkerAuthority(
                scopeDescription: command,
                allowedPaths: [workspace].compactMap { $0 },
                allowedAppBundleIDs: [],
                allowsWrites: false,
                allowsShell: false)
        case .general, .thread:
            // No app to speak for. General Chat is where a request that needs more than one
            // app belongs, and it still grants no app authority by being general.
            authority = AIWorkerAuthority(
                scopeDescription: workspace?.lastPathComponent ?? "this conversation",
                allowedPaths: [workspace].compactMap { $0 },
                allowedAppBundleIDs: [],
                allowsWrites: false,
                allowsShell: false)
        }

        return AIWorkerTask(
            goal: goal,
            authority: authority,
            domains: domains,
            forbidden: [
                "install, update or delete anything",
                "sudo or any privileged command",
                "change settings, accounts or remote state",
                "read files outside the allowed paths",
                "act on apps other than the ones listed",
            ],
            timeout: 180,
            attemptBudget: 2,
            expectedOutput:
                "What was found, the evidence for it, and the safest next step — as a report, "
                + "not as a change already made.",
            requiresVerification: true)
    }
}
