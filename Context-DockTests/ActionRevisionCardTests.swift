import Testing
import Foundation
@testable import Context_Dock

// MARK: - A revision is approved on the same card, and replaces
//
// B3 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// The Install card already exists on both surfaces — the dock and the corner — and both
// route it through AdapterActionProposalInstaller. A revision is that card with a different
// promise: this does not add an action, it changes one that already runs. The identity is
// what makes it true. An AI-authored action's id is derived from its name; an action
// authored by the "teach it" rung has an id of its own, so a revision has to carry the id it
// replaces or it would install a second action under a new one.

struct ActionRevisionCardTests {

    private func existing(id: String = "authored.1a2b3c4d") -> AdapterAction {
        AdapterAction(
            id: id, name: "Minimise after a delay", icon: "sparkles",
            description: "Minimises the front window after a pause",
            triggers: ["minimise", "delay"], type: .shell,
            script: "sleep {{value}}; osascript -e 'minimise'",
            requiresApproval: true, valueLabel: "seconds", valueDefault: "300")
    }

    private func revision(of action: AdapterAction) -> WorkflowAuthor.Proposal {
        WorkflowAuthor.Proposal(
            name: action.name, summary: "Minimises, then mutes", kind: .shell,
            script: "sleep {{value}}; osascript -e 'minimise'; osascript -e 'set volume 0'",
            triggers: ["minimise", "mute"], bundleID: "com.apple.finder", appName: "Finder",
            isDestructive: false, valueLabel: "seconds", valueDefault: "300")
    }

    // MARK: - Identity

    /// The card's proposal carries the id it replaces, so approving changes the action the
    /// user already has instead of installing a second one under a new id.
    @MainActor @Test func theCardCarriesTheIDItReplaces() {
        let data = AdapterActionProposalInstaller.proposalData(
            for: revision(of: existing()), replacing: existing())
        #expect(data.replacesActionId == "authored.1a2b3c4d")
        let installed = AdapterActionProposalInstaller.action(from: data)
        #expect(installed.id == "authored.1a2b3c4d")
    }

    /// An ordinary proposal — nothing to replace — keeps the derivation it always had.
    @Test func anOrdinaryProposalKeepsItsDerivedID() {
        let plain = ExtensionProposalData(
            type: "extension_proposal", name: "Clean Build Folder", description: "",
            scriptType: "bash", script: "rm -rf ~/x", layer: "contextdock", triggers: [])
        #expect(AdapterActionProposalInstaller.action(from: plain).id == "ai.clean-build-folder")
    }

    /// The revision keeps what the action already declared, so the saved action stays
    /// adjustable after it is changed.
    @MainActor @Test func theRevisionKeepsTheValue() {
        let data = AdapterActionProposalInstaller.proposalData(
            for: revision(of: existing()), replacing: existing())
        let installed = AdapterActionProposalInstaller.action(from: data)
        #expect(installed.valueLabel == "seconds")
        #expect(installed.valueDefault == "300")
        #expect(installed.value(for: "minimise after 10 min and then mute") == "600")
    }

    /// The triggers the action already answered to survive a revision. Losing them would
    /// leave the user with an action they can no longer summon the way they always have.
    @MainActor @Test func theRevisionKeepsTheOldTriggersToo() {
        let data = AdapterActionProposalInstaller.proposalData(
            for: revision(of: existing()), replacing: existing())
        let installed = AdapterActionProposalInstaller.action(from: data)
        #expect(Set(["minimise", "delay", "mute"]).isSubset(of: Set(installed.triggers)))
    }

    // MARK: - What it says

    /// The card must not say "saved" when it means "replaced" — approving a replacement is
    /// a different decision from approving an addition.
    @Test func theConfirmationOfAReplacementSaysReplaced() {
        let text = AdapterActionProposalInstaller.confirmation(
            actionName: "Minimise after a delay", appName: "Finder",
            valueLabel: "seconds", valueDefault: "300", replaced: true)
        #expect(text.lowercased().contains("updated") || text.lowercased().contains("replaced"))
        #expect(!text.contains("another workflow"))
        #expect(text.lowercased().contains("different number"))
    }

    /// An install still reads exactly as it did.
    @Test func theConfirmationOfAnInstallIsUnchanged() {
        let text = AdapterActionProposalInstaller.confirmation(
            actionName: "Clean Build Folder", appName: "Xcode")
        #expect(text.contains("saved to"))
    }
}
