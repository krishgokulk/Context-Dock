import Testing
import Foundation
@testable import Context_Dock

// MARK: - A proposed app action becomes an adapter action
//
// The dock and the corner share one conversation and one engine. When the model proposes an
// app action, the message carries `hasInstallButton` and the dock draws an Install card that
// calls `installFromProposal`. The corner constructed the same message view with no install
// callback, so the same proposal — same message, same flag — had nowhere to become an
// adapter action. The user created one in the corner and nothing offered to keep it.
//
// The installer was a method on LauncherView, reading `l2.*` for its scope and appending its
// confirmation to `l2.chatMessages`. Only those two things were dock-specific. This is the
// rest, lifted so both surfaces call it with their own scope.

struct AdapterActionProposalInstallerTests {

    private func proposal(
        name: String = "Clean Build Folder",
        scriptType: String = "bash",
        triggers: [(String, String)] = [("keyword", "clean")],
        icon: String? = nil
    ) -> ExtensionProposalData {
        ExtensionProposalData(
            type: "extension", name: name, description: "Removes DerivedData",
            scriptType: scriptType, script: "rm -rf ~/Library/Developer/Xcode/DerivedData",
            layer: "contextdock",
            triggers: triggers.map { .init(type: $0.0, value: $0.1) },
            icon: icon)
    }

    // MARK: - Identity

    /// The id is derived from the name, so installing the same proposal twice updates one
    /// action rather than adding a second beside it.
    @Test func theIDIsStableAndDerivedFromTheName() {
        let action = AdapterActionProposalInstaller.action(from: proposal(name: "Clean Build Folder"))
        #expect(action.id == "ai.clean-build-folder")
        #expect(AdapterActionProposalInstaller.action(from: proposal(name: "Clean Build Folder")).id
            == action.id)
    }

    @Test func punctuationDoesNotLeakIntoTheID() {
        let action = AdapterActionProposalInstaller.action(from: proposal(name: "Open: Today's Notes!"))
        #expect(action.id == "ai.open-todays-notes")
    }

    // MARK: - Findability

    /// Triggers are the declared ones plus every word of the name, lowercased and deduplicated,
    /// so the action answers to how the user will actually ask for it.
    @Test func triggersCombineDeclaredWordsAndTheName() {
        let action = AdapterActionProposalInstaller.action(
            from: proposal(name: "Clean Build Folder", triggers: [("keyword", "Clean"), ("keyword", "purge")]))
        #expect(Set(action.triggers) == ["clean", "build", "folder", "purge"])
        // Sorted, so two installs of the same proposal compare equal.
        #expect(action.triggers == action.triggers.sorted())
    }

    // MARK: - Shape

    @Test func scriptTypeMapsToTheAdapterType() {
        #expect(AdapterActionProposalInstaller.action(from: proposal(scriptType: "applescript")).type == .applescript)
        #expect(AdapterActionProposalInstaller.action(from: proposal(scriptType: "jxa")).type == .jxa)
        #expect(AdapterActionProposalInstaller.action(from: proposal(scriptType: "bash")).type == .shell)
        #expect(AdapterActionProposalInstaller.action(from: proposal(scriptType: "zsh")).type == .shell)
    }

    /// A script the model wrote runs nothing until a person has seen it. Approval is not
    /// optional for AI-authored actions, whatever the proposal says.
    @Test func anAIAuthoredActionAlwaysAsksFirst() {
        #expect(AdapterActionProposalInstaller.action(from: proposal()).requiresApproval)
    }

    @Test func itIsFiledUnderAIWorkflowsWithAFallbackIcon() {
        let plain = AdapterActionProposalInstaller.action(from: proposal(icon: nil))
        #expect(plain.category == "AI Workflows")
        #expect(plain.icon == "sparkles")
        #expect(AdapterActionProposalInstaller.action(from: proposal(icon: "hammer")).icon == "hammer")
    }

    // MARK: - Telling the user

    /// The confirmation names the action and the app, and says why it matters: next time
    /// the app matches this before asking the model to write another one.
    @Test func theConfirmationNamesTheActionAndTheApp() {
        let text = AdapterActionProposalInstaller.confirmation(actionName: "Clean Build Folder", appName: "Xcode")
        #expect(text.contains("Clean Build Folder"))
        #expect(text.contains("Xcode"))
    }
}
