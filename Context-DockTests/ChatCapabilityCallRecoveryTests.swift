import Foundation
import Testing

@testable import Context_Dock

/// Issue 146: a Finder chat that resolved `finder.copyFiles` ended in "couldn't carry it out
/// on this surface" and a spinner that never stopped.
///
/// Two causes, both pinned here:
///   1. the Dock / Corner final-text recovery had no case for a capability call, so a call
///      the model wrote as text never ran (and the surface replaced it with the fallback);
///   2. the empty bubble reserved for a streaming answer was itself turned into that fallback.
///
/// Every test owns its collaborators — the registry lookup and the executor are closures —
/// so none of them drives the process-wide `AIExecutionEngine`, opens an approval card, or
/// touches a file.
@MainActor
struct ChatCapabilityCallRecoveryTests {

    private let copyFiles = (title: "Copy Finder Files", requiredInputs: ["destination"])

    private func lookup(_ id: String) -> (title: String, requiredInputs: [String])? {
        id == "finder.copyFiles" ? copyFiles : nil
    }

    /// Records every plan the executor was asked to run.
    private final class Spy {
        var plans: [AIActionPlan] = []
    }

    // MARK: - The call is parsed the way the surfaces parse it

    @Test func anIdAsKeyCallIsACapabilityInvocation() {
        let text = #"{"finder.copyFiles": {"destination": "/Users/me/Documents"}}"#
        let invocation = AITypedInvocationResolver.invocation(from: text)
        #expect(invocation?.kind == .capability)
        #expect(invocation?.capabilityID == "finder.copyFiles")
        #expect(invocation?.arguments["destination"] == "/Users/me/Documents")
        // The reason the surface refuses to print it.
        #expect(ChatAnswerSanitizer.isProtocolOnly(text))
    }

    // MARK: - A resolved call runs

    @Test func aResolvedCallRunsThroughTheExecutorAndSaysWhatHappened() async {
        let spy = Spy()
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles",
            arguments: ["destination": "/tmp/dest"],
            query: "copy these to dest",
            scope: .contextDock(bundleID: "com.apple.finder", appName: "Finder"),
            lookup: lookup,
            execute: { plan in
                spy.plans.append(plan)
                return AICapabilityExecutionResult(success: true, output: "Copied 2 items.")
            })

        #expect(outcome.succeeded)
        #expect(outcome.text == "Copied 2 items.")
        #expect(spy.plans.count == 1)
        #expect(spy.plans.first?.capability == "finder.copyFiles")
        #expect(spy.plans.first?.input["destination"] == "/tmp/dest")
        #expect(spy.plans.first?.explanation.contains("copy these to dest") == true)
    }

    @Test func aSilentSuccessStillSaysDone() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "/tmp"],
            query: "q", scope: .general, lookup: lookup,
            execute: { _ in AICapabilityExecutionResult(success: true, output: "") })
        #expect(outcome.text == "Done — Copy Finder Files.")
    }

    // MARK: - A call that cannot run says why, by name

    @Test func aCallWithNoDestinationNamesTheMissingPieceAndNeverRaisesApproval() async {
        // "can you resume 2026 folder for me?" → the model wrote the call with no inputs.
        let spy = Spy()
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: [:],
            query: "can you resume 2026 folder for me?",
            scope: .contextDock(bundleID: "com.apple.finder", appName: "Finder"),
            lookup: lookup,
            execute: { plan in
                spy.plans.append(plan)
                return AICapabilityExecutionResult(success: true, output: "")
            })

        #expect(!outcome.succeeded)
        #expect(spy.plans.isEmpty, "approval must not be asked for a call that cannot run")
        #expect(outcome.text.contains("Copy Finder Files"))
        #expect(outcome.text.contains("destination"))
        #expect(!ChatAnswerSanitizer.isProtocolOnly(outcome.text))
    }

    @Test func aBlankInputCountsAsMissing() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "  "],
            query: "q", scope: .general, lookup: lookup,
            execute: { _ in AICapabilityExecutionResult(success: true, output: "") })
        #expect(!outcome.succeeded)
        #expect(outcome.text.contains("destination"))
    }

    @Test func anUnregisteredIdIsNamedAndNothingRuns() async {
        let spy = Spy()
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.summon", arguments: [:], query: "q", scope: .general,
            lookup: lookup,
            execute: { plan in
                spy.plans.append(plan)
                return AICapabilityExecutionResult(success: true, output: "")
            })
        #expect(spy.plans.isEmpty)
        #expect(outcome.text.contains("finder.summon"))
        #expect(outcome.text.contains("isn't a capability"))
    }

    @Test func aBlankIdSaysSo() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "  ", arguments: [:], query: "q", scope: .general,
            lookup: lookup, execute: { _ in AICapabilityExecutionResult(success: true, output: "") })
        #expect(outcome.text == "I tried to run something but didn't name what.")
    }

    @Test func aDeclinedApprovalIsReportedAsDeclinedNotAsAFailure() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "/tmp"],
            query: "q", scope: .general, lookup: lookup,
            execute: { _ in throw AICapabilityError.approvalRequired("Copy Finder Files") })
        #expect(!outcome.succeeded)
        #expect(outcome.text == "Copy Finder Files wasn't approved, so nothing ran.")
    }

    @Test func anExecutorFailureCarriesItsReason() async {
        let failed = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "/nope"],
            query: "q", scope: .general, lookup: lookup,
            execute: { _ in
                AICapabilityExecutionResult(
                    success: false, output: "Destination folder does not exist: /nope")
            })
        #expect(failed.text == "Copy Finder Files didn't run — Destination folder does not exist: /nope")

        let thrown = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "/tmp"],
            query: "q", scope: .general, lookup: lookup,
            execute: { _ in throw AICapabilityError.blocked("Outside the chat's folder.") })
        #expect(thrown.text == "Copy Finder Files didn't run — Outside the chat's folder.")
    }

    @Test func everyOutcomeIsAnAnswerNeverProtocol() async {
        // The caller replaces the bubble with `text` and then ends the turn; an empty or
        // JSON text here would put the old fallback straight back.
        let cases: [(String, [String: String], Bool)] = [
            ("finder.copyFiles", ["destination": "/tmp"], true),
            ("finder.copyFiles", [:], true),
            ("nope", [:], true),
            ("", [:], true),
        ]
        for (id, args, succeeds) in cases {
            let outcome = await ChatCapabilityCallRecovery.run(
                capabilityID: id, arguments: args, query: "q", scope: .general, lookup: lookup,
                execute: { _ in AICapabilityExecutionResult(success: succeeds, output: "") })
            #expect(!outcome.text.isEmpty, "\(id)")
            #expect(!ChatAnswerSanitizer.isProtocolOnly(outcome.text), "\(id)")
        }
    }

    // MARK: - Scope still holds

    @Test func aFrontmostAppChatCannotRunAnotherAppsCapabilityFromText() async {
        // finder.copyFiles belongs to Finder; a Safari chat must not run it because the
        // model wrote a line of JSON.
        let spy = Spy()
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "/tmp"],
            query: "q", scope: .contextDock(bundleID: "com.apple.Safari", appName: "Safari"),
            lookup: lookup,
            execute: { plan in
                spy.plans.append(plan)
                return AICapabilityExecutionResult(success: true, output: "")
            })
        #expect(spy.plans.isEmpty)
        #expect(!outcome.succeeded)
        #expect(outcome.text.contains("scoped to Safari"))
    }

    @Test func theFinderChatItselfMayRunItsOwnCapability() async {
        let spy = Spy()
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "finder.copyFiles", arguments: ["destination": "/tmp"],
            query: "q", scope: .contextDock(bundleID: "com.apple.finder", appName: "Finder"),
            lookup: lookup,
            execute: { plan in
                spy.plans.append(plan)
                return AICapabilityExecutionResult(success: true, output: "ok")
            })
        #expect(spy.plans.count == 1)
        #expect(outcome.succeeded)
    }

    // MARK: - The empty bubble a turn reserves is not a failure

    @Test func aStreamingPlaceholderStaysEmptyUntilTheModelSpeaks() {
        let placeholder = AIChatMessage(
            role: .assistant, content: "", isStreamingPlaceholder: true)
        #expect(placeholder.content.isEmpty)

        // The surface appends each token to what is there. Appended to the old fallback
        // sentence the answer began with "I worked out what to run…".
        let streamed = AIChatMessage(
            id: placeholder.id, role: .assistant, content: placeholder.content + "Sure")
        #expect(streamed.content == "Sure")
    }

    @Test func aFinishedEmptyAnswerStillSaysSomethingHappened() {
        #expect(AIChatMessage(role: .assistant, content: "").content
            == ChatAnswerSanitizer.protocolFallback)
        #expect(AIChatMessage(role: .assistant, content: "   \n").content
            == ChatAnswerSanitizer.protocolFallback)
    }

    @Test func aSettledCallIsStillNeverShownAsAnAnswer() {
        let message = AIChatMessage(
            role: .assistant, content: #"{"finder.copyFiles": {}}"#)
        #expect(message.content == ChatAnswerSanitizer.protocolFallback)
    }

    @Test func aUserMessageIsNeverRewritten() {
        #expect(AIChatMessage(role: .user, content: "").content.isEmpty)
    }
}
