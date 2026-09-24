import Foundation
import Testing

@testable import Context_Dock

// The permission model for Computer Use — decision `fe47daa8`.
//
// Two layers, because one is not enough in either direction: a single global switch is how an
// app nobody meant to automate gets driven, and per-app settings alone leave no one place to
// stop everything after watching a click go wrong.
//
// Everything here is the *gate*, not the clicking. A gate is exactly the part that must be
// true before anyone looks at a screenshot, so it is the part that gets tests.

@MainActor
struct ComputerUseConsentTests {

    /// Each test gets its own defaults suite: these run in parallel and all write the same key.
    private func store() -> ComputerUseConsentStore {
        ComputerUseConsentStore(
            defaults: UserDefaults(suiteName: "computeruse.test.\(UUID().uuidString)")!)
    }

    private let code = "com.microsoft.VSCode"

    @Test func nothingIsOperatedByDefault() {
        // Off for the machine and off for every app. A screen is not something to opt out of.
        let store = store()
        #expect(!store.isMasterEnabled)
        #expect(store.mode(for: code) == .off)
        #expect(store.effectiveMode(for: code) == .off)
    }

    @Test func theMasterSwitchOverrulesEveryApp() {
        // The kill switch has to work from one place, immediately, without hunting for the row
        // that granted the app — which is what a user does right after a click goes wrong.
        let store = store()
        store.setMode(.autoInTask, for: code)
        #expect(store.effectiveMode(for: code) == .off, "master off means no app is operated")

        store.isMasterEnabled = true
        #expect(store.effectiveMode(for: code) == .autoInTask)
    }

    @Test func enablingOneAppLeavesTheRestOff() {
        // The failure this two-layer model exists to prevent: a Mail window driven because
        // Code was enabled.
        let store = store()
        store.isMasterEnabled = true
        store.setMode(.askEachStep, for: code)
        #expect(store.effectiveMode(for: code) == .askEachStep)
        #expect(store.effectiveMode(for: "com.apple.mail") == .off)
    }

    @Test func theInChatDoorGrantsTheCautiousTierOnly() {
        // One tap in a conversation may grant "ask me each step". It may never grant the tier
        // that stops asking — that is a Settings decision, made deliberately, not a tap taken
        // mid-task to get unblocked.
        let store = store()
        store.isMasterEnabled = true
        store.grantFromChat(for: code)
        #expect(store.effectiveMode(for: code) == .askEachStep)
    }

    @Test func theInChatDoorTurnsOnTheMasterSwitchWithIt() {
        // Otherwise the tap appears to do nothing: the app is granted, the master switch is
        // off, and the next turn refuses for a reason the user thought they had just answered.
        let store = store()
        store.grantFromChat(for: code)
        #expect(store.isMasterEnabled)
        #expect(store.effectiveMode(for: code) == .askEachStep)
    }

    @Test func aGrantSurvivesRestart() {
        let suite = "computeruse.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = ComputerUseConsentStore(defaults: defaults)
        first.isMasterEnabled = true
        first.setMode(.askEachStep, for: code)

        let second = ComputerUseConsentStore(defaults: defaults)
        #expect(second.isMasterEnabled)
        #expect(second.effectiveMode(for: code) == .askEachStep)
    }

    @Test func revokingPutsAnAppBackToOff() {
        let store = store()
        store.isMasterEnabled = true
        store.setMode(.autoInTask, for: code)
        store.setMode(.off, for: code)
        #expect(store.effectiveMode(for: code) == .off)
    }

    @Test func bundleIdentifiersAreMatchedCaseInsensitively() {
        // Bundle ids reach us from the running app, the installed catalogue and stored config,
        // and those three do not always agree on case.
        let store = store()
        store.isMasterEnabled = true
        store.setMode(.askEachStep, for: code)
        #expect(store.effectiveMode(for: "com.microsoft.vscode") == .askEachStep)
    }

    @Test func everyStepIsApprovedUnlessTheTaskItselfWasApproved() {
        // The difference between the two live tiers, stated once so the executor cannot drift:
        // `autoInTask` removes the per-step prompt and never the per-task one.
        #expect(ComputerUseMode.askEachStep.requiresApprovalPerStep)
        #expect(!ComputerUseMode.autoInTask.requiresApprovalPerStep)
        #expect(ComputerUseMode.autoInTask.requiresApprovalPerTask)
        #expect(ComputerUseMode.askEachStep.requiresApprovalPerTask)
        #expect(!ComputerUseMode.off.canOperate)
    }
}
