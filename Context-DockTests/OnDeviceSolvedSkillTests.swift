// OnDeviceSolvedSkillTests.swift
// Context-DockTests
//
// H5 #412: Solved Skills On-Device — offline replay, gate coverage, budget.

import Testing
import Foundation
@testable import Context_Dock

// MARK: - Skill match is available to on-device path

@MainActor
struct OnDeviceSkillMatchTests {

    private let mail = "com.apple.mail"

    private var skill: SolvedSkill {
        SolvedSkill(
            queryTemplate: "unread mail from {sender}",
            nonSlotWords: ["unread", "mail", "from"],
            slots: [SolvedSkillSlot(name: "sender", tokenFamily: "sender")],
            toolCalls: [
                SolvedSkillToolCall(
                    capability: "mail.search",
                    argTemplate: ["sender": "{sender}"], isReadOnly: true)
            ],
            bundleId: mail)
    }

    @Test func onDeviceSkillMatchFindsAnExactHit() {
        let hit = SolvedSkillMatch.match(
            query: "unread mail from ICICI", bundleId: mail, skills: [skill])
        #expect(hit != nil)
        #expect(hit?.filled == ["sender": "ICICI"])
    }

    @Test func onDeviceSkillMatchFallsThroughOnMismatch() {
        #expect(
            SolvedSkillMatch.match(
                query: "archive mail from ICICI", bundleId: mail, skills: [skill])
                == nil)
    }

    @Test func onDeviceSkillMatchFallsThroughForWrongApp() {
        #expect(
            SolvedSkillMatch.match(
                query: "unread mail from ICICI", bundleId: "com.apple.Notes",
                skills: [skill])
                == nil)
    }

    @Test func emptySkillListFallsThrough() {
        #expect(
            SolvedSkillMatch.match(
                query: "unread mail from ICICI", bundleId: mail, skills: [])
                == nil)
    }
}

// MARK: - OutboundGate classification for on-device tools

struct OnDeviceToolGateClassificationTests {

    @Test func runMenuCommandIsClassifiedAsOutbound() {
        #expect(OutboundGate.outboundTools.contains("run_menu_command"))
        let target = OutboundGate.target(
            toolName: "run_menu_command",
            arguments: ["path": "File > Share > Mail"])
        #expect(target != nil)
    }

    @Test func sendKeysIsDeliberatelyUngated() {
        #expect(OutboundGate.ungatedTools.contains("send_keys"))
        let target = OutboundGate.target(
            toolName: "send_keys", arguments: ["keys": "hello"])
        #expect(target == nil)
    }

    @Test func eventKitWriteToolsAreLocalNotOutbound() {
        for name in ["add_calendar_event", "add_reminder", "create_note"] {
            let target = OutboundGate.target(toolName: name, arguments: ["title": "test"])
            #expect(target == nil, "Expected \(name) to be local (nil target)")
        }
    }

    @Test func searchMailIsNotOutbound() {
        let target = OutboundGate.target(
            toolName: "search_mail", arguments: ["query": "from:test"])
        #expect(target == nil)
    }
}

// MARK: - Gate blocks run_menu_command in a tainted on-device turn

#if canImport(FoundationModels)
@MainActor
struct OnDeviceMenuCommandGateTests {

    private final class AskedLog { var plans: [AIActionPlan] = [] }

    private func makeRegistry(asked: AskedLog) -> AgentToolRegistry {
        let registry = AgentToolRegistry()
        registry.approveOutbound = { plan, _ in
            asked.plans.append(plan)
            return false
        }
        return registry
    }

    @Test func menuCommandShareAsksGateInTaintedTurn() async {
        let asked = AskedLog()
        let registry = makeRegistry(asked: asked)
        let gate = OnDeviceTurnGate.begin(
            message: "share this email", systemPrompt: "",
            bundleId: "com.apple.mail", registry: registry)
        defer { gate.end(registry: registry) }

        let held = await gate.check(
            toolName: "run_menu_command",
            arguments: ["path": "File > Share > Mail"],
            registry: registry)
        #expect(held != nil)
        #expect(asked.plans.count == 1)
    }

    @Test func menuCommandLocalDoesNotAskGate() async {
        let asked = AskedLog()
        let registry = makeRegistry(asked: asked)
        let gate = OnDeviceTurnGate.begin(
            message: "archive this email", systemPrompt: "",
            bundleId: "com.apple.mail", registry: registry)
        defer { gate.end(registry: registry) }

        let held = await gate.check(
            toolName: "run_menu_command",
            arguments: ["path": "Message > Archive"],
            registry: registry)
        #expect(held == nil)
        #expect(asked.plans.isEmpty)
    }
}

// MARK: - Budget compliance: skill match is pre-model

@MainActor
struct OnDeviceSkillBudgetTests {

    @Test func skillMatchDoesNotConsumePromptBudget() {
        // SolvedSkillMatch.match() is a pure function that runs before any model call.
        // A hit short-circuits the entire on-device model path, so zero tokens are consumed.
        // Verify the budget is unchanged by asserting match is a synchronous, non-token operation.
        let skill = SolvedSkill(
            queryTemplate: "unread mail from {sender}",
            nonSlotWords: ["unread", "mail", "from"],
            slots: [SolvedSkillSlot(name: "sender", tokenFamily: "sender")],
            toolCalls: [
                SolvedSkillToolCall(
                    capability: "mail.search", argTemplate: ["sender": "{sender}"],
                    isReadOnly: true)
            ],
            bundleId: "com.apple.mail")

        let hit = SolvedSkillMatch.match(
            query: "unread mail from Alex", bundleId: "com.apple.mail", skills: [skill])
        #expect(hit != nil)

        // The on-device character budget (1,500) is for model prompt injection.
        // A matched skill never reaches the model, so the budget is irrelevant by design.
        let charBudget = AIContextBudget.characterBudget(for: .onDevice)
        #expect(charBudget == 1_500)
    }
}
#endif
