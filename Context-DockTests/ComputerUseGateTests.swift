import Foundation
import Testing

@testable import Context_Dock

// Where operate_app is offered, and where it is not.
//
// The press itself needs a real app and a real screen, so it is verified by hand. What can be
// checked here is the boundary around it: a tool a model can see is a tool it treats as
// available, so "which turns are shown operate_app" is a permission question, not a UI one.

@MainActor
struct ComputerUseGateTests {

    @Test func anActionTurnIsOfferedTheTool() {
        // The reported case: "update this app" in a Code scope, where nothing published can do
        // it. Without the tool in the turn's list the model cannot reach the rung at all,
        // whatever the user has granted.
        let plan = FrontmostAppTaskPlan.make(
            query: "update this app", bundleId: "com.microsoft.VSCode",
            appName: "Visual Studio Code")
        #expect(plan.allowedToolNames.contains("operate_app"))
    }

    @Test func aQuestionTurnIsNotOfferedTheTool() {
        // Questions get readers. Asking what version is installed must not put a tool that
        // presses menu items in front of the model.
        let plan = FrontmostAppTaskPlan.make(
            query: "what version am I on", bundleId: "com.microsoft.VSCode",
            appName: "Visual Studio Code")
        #expect(!plan.allowedToolNames.contains("operate_app"))
    }

    @Test func theToolFilterAlsoWithholdsItFromAQuestion() {
        // The second gate, which the plan cannot see: a query that only asks has its action
        // tools stripped after the plan granted them. operate_app belongs in that set — it was
        // added to it precisely because it is the most consequential member.
        let asked = AgentToolRegistry.shared.toolNamesAvailable(for: "what version am I on")
        #expect(!asked.contains("operate_app"))
        let told = AgentToolRegistry.shared.toolNamesAvailable(for: "update this app")
        #expect(told.contains("operate_app"))
    }

    @Test func theToolIsRegistered() {
        // It is reachable by name, so a turn that asks for it gets the real thing rather than
        // falling through to "no such tool" — the failure that looks like a refusal.
        #expect(AgentToolRegistry.shared.tool(named: "operate_app") != nil)
    }

    @Test func aToolLessProviderCanReachTheRungByDirective() {
        // The provider the owner actually uses is Claude Code, which is run with none of
        // DoraX's tools by design — it answers and the app acts. Computer Use shipped as a
        // tool only, so their chat still said "not in my menu cache, so I cannot fire it"
        // about an item sitting in the live menu bar. This directive is the path.
        let invocation = AITypedInvocationResolver.invocation(
            from: #"{"operate_app": {"target": "Check for Updates", "reason": "update VS Code"}}"#)
        #expect(invocation?.kind == .operateApp)
        #expect(invocation?.arguments["target"] == "Check for Updates")
        #expect(invocation?.arguments["reason"] == "update VS Code")
        #expect(invocation?.requiresApproval == true)
    }

    @Test func aDirectiveWithNoTargetIsNotADirective() {
        // Half a directive must not resolve to "press something": an empty target reaching the
        // resolver would be matched against every menu item in the app.
        let invocation = AITypedInvocationResolver.invocation(
            from: #"{"operate_app": {"reason": "update it"}}"#)
        #expect(invocation?.kind != .operateApp)
    }

    @Test func theDirectiveCarriesAnAppWhenTheModelNamesOne() {
        let invocation = AITypedInvocationResolver.invocation(
            from: #"{"operate_app": {"target": "Check for Updates", "app": "com.microsoft.VSCode"}}"#)
        #expect(invocation?.arguments["bundleId"] == "com.microsoft.VSCode")
    }

    @Test func aStepRowNamesTheCommandItIsAboutToRun() {
        // "11 steps" told the owner nothing about what their Mac was doing. Each row names the
        // thing — the menu path, the shell command, the item being hunted for — because the
        // mechanism is not what a person watching is deciding about.
        let menu = AITypedInvocationResolver.invocation(
            from: #"{"menu_call": {"path": ["Window", "Minimize"]}}"#)!
        #expect(AppScopedChatService.runningLabel(for: menu) == "Pressing Window ▸ Minimize…")

        let shell = AITypedInvocationResolver.invocation(
            from: #"{"terminal_call": {"command": "code --version", "purpose": "read version"}}"#)!
        #expect(AppScopedChatService.runningLabel(for: shell).contains("code --version"))

        let operate = AITypedInvocationResolver.invocation(
            from: #"{"operate_app": {"target": "Check for Updates"}}"#)!
        #expect(AppScopedChatService.runningLabel(for: operate).contains("Check for Updates"))
    }

    @Test func theMasterSwitchIsWhatTheRunnerReads() {
        // The runner refuses outright when the master switch is off and offers the door only
        // when it is on. Both readings come from the store, and they are deliberately
        // different: `mode(for:)` keeps showing the user's choice in Settings while the switch
        // is off, `effectiveMode(for:)` is what may actually happen.
        let store = ComputerUseConsentStore(
            defaults: UserDefaults(suiteName: "computeruse.gate.\(UUID().uuidString)")!)
        store.setMode(.autoInTask, for: "com.microsoft.VSCode")

        #expect(store.mode(for: "com.microsoft.VSCode") == .autoInTask)
        #expect(store.effectiveMode(for: "com.microsoft.VSCode") == .off)

        store.isMasterEnabled = true
        #expect(store.effectiveMode(for: "com.microsoft.VSCode") == .autoInTask)
    }

    @Test func theDoorLeavesTheAppAtItsMostCautiousTier() {
        // Approving the in-chat card is a tap taken to get unblocked, not a decision to stop
        // being asked. It must never land on autoInTask.
        let store = ComputerUseConsentStore(
            defaults: UserDefaults(suiteName: "computeruse.gate.\(UUID().uuidString)")!)
        store.grantFromChat(for: "com.microsoft.VSCode")

        #expect(store.isMasterEnabled)
        #expect(store.mode(for: "com.microsoft.VSCode") == .askEachStep)
        #expect(store.mode(for: "com.microsoft.VSCode").requiresApprovalPerStep)
    }
}
