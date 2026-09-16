// SurfaceCapabilityContractTests.swift
// Context-DockTests
//
// Todo 8 of docs/superpowers/plans/2026-09-10-agentic-capability-parity.md.
//
// Each surface keeps one job, and each job needs a particular set of things it can reach.
// Nothing asserted that, so a surface could quietly lose its capabilities and the only
// symptom would be a model that "got worse" — the failure of a whole product layer showing
// up as a vague impression. These tests fail loudly instead.
//
// They deliberately test what a surface is *offered*, not how a model uses it: authority is
// ours to guarantee, behaviour is not.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Surface capability contract")
@MainActor
struct SurfaceCapabilityContractTests {

    private var registry: CapabilityRegistry { CapabilityRegistry.shared }

    private func ids(inScope bundleID: String?) -> Set<String> {
        Set(registry.capabilities(for: bundleID).map(\.id))
    }

    // MARK: - Every surface can reach DoraX itself

    @Test("Every scope can read the clipboard, the running apps and DoraX's own skills")
    func theSurfacesOfDoraXAreReachableEverywhere() {
        // Registered with no bundle id precisely so they survive scoping. If one of these
        // ever gains an owner, it disappears from every scoped chat at once.
        for scope in [nil, "com.apple.Safari", "com.apple.finder", "cli://brew"] {
            let available = ids(inScope: scope)
            for id in ["clipboard.read", "skills.list", "skills.read", "system.running_apps"] {
                #expect(available.contains(id), "\(id) missing from scope \(scope ?? "general")")
            }
        }
    }

    @Test("A browser question is answerable from any scope")
    func browserReadsSurviveScoping() {
        for scope in [nil, "com.apple.Safari", "com.apple.finder", "cli://brew"] {
            let available = ids(inScope: scope)
            for id in [
                "browser.currentPage", "browser.tabs", "browser.findInPage",
                "browser.openURL", "browser.history", "browser.bookmarks",
            ] {
                #expect(available.contains(id), "\(id) missing from scope \(scope ?? "general")")
            }
        }
    }

    @Test("A scoped chat sees its own app's capabilities and not another app's")
    func scopingIsRealNotDecorative() {
        // Pick a capability that declares an owner, whichever app that happens to be, so
        // this keeps working as the registry grows.
        guard let owned = registry.all.first(where: {
            !($0.appBundleID ?? "").isEmpty && $0.appBundleID != "com.apple.Safari"
        }) else {
            Issue.record("no app-owned capability is registered — scoping cannot be tested")
            return
        }
        let owner = owned.appBundleID!
        #expect(ids(inScope: owner).contains(owned.id))
        #expect(!ids(inScope: "com.apple.Safari").contains(owned.id))
    }

    // MARK: - Risk is declared honestly

    @Test("Reading is free; changing asks")
    func riskMatchesConsequence() {
        // A read that demands approval trains people to click through sheets; a change that
        // does not is the one that costs them something.
        for capability in registry.all where capability.id.hasPrefix("browser.") {
            #expect(
                !capability.riskLevel.requiresApproval,
                "\(capability.id) is a browser read and must not ask for approval")
        }
        for id in ["clipboard.read", "skills.list", "skills.read", "notifications.list"] {
            #expect(registry.capability(id: id)?.riskLevel == .low, "\(id)")
        }
    }

    // MARK: - A panel reads and does not act

    @Test("A panel's assistant is offered discovery and reading, and nothing that acts")
    func panelToolsAreReadersOnly() {
        let acting: Set<String> = [
            "run_command", "send_keys", "window_control", "run_menu_command",
            "run_adapter_action", "compose_message", "spawn_worker",
        ]
        #expect(PanelAssistant.tools.isDisjoint(with: acting))
        #expect(PanelAssistant.tools.contains("find_capability"))
        #expect(PanelAssistant.tools.contains("run_capability"))
    }

    @Test("A read-only turn refuses a capability that changes something")
    func theReadOnlyGateIsRealAndNotAPromise() {
        // `run_capability` reaches every registered capability by id, so narrowing the tool
        // list is not enough on its own — the panel's prompt says it cannot change things,
        // and this is what makes that true.
        let changing = registry.all.filter { $0.riskLevel.requiresApproval }
        guard let example = changing.first else {
            Issue.record("no approval-gated capability is registered")
            return
        }
        #expect(AgentToolRegistry.changesSomething(capabilityID: example.id))
        for id in ["clipboard.read", "skills.read", "browser.currentPage"] {
            #expect(
                !AgentToolRegistry.changesSomething(capabilityID: id),
                "\(id) is a read and must stay runnable on a reading surface")
        }
        // An id nobody registered falls through to an app adapter's action, and an action
        // is a thing that does something.
        #expect(AgentToolRegistry.changesSomething(capabilityID: "not.a.capability"))
    }

    @Test("The refusal says what happened and what to do instead")
    func theRefusalIsUseful() {
        let refusal = AgentToolRegistry.readsOnlyRefusal(capabilityID: "finder.trash")
        #expect(refusal.contains("finder.trash"))
        #expect(refusal.lowercased().contains("not run"))
        // A dead end that names no way forward is the thing this app exists to avoid.
        #expect(refusal.lowercased().contains("user"))
    }
}
