import Testing
import Foundation
@testable import Context_Dock

// MARK: - The same revision, approved from either chat
//
// C1 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// A revision is offered in whichever chat asked — the dock's frontmost-app chat, the
// corner, or General Chat — and the two are not the same surface. They share one installer
// and one card; what they must not share is a transcript. The app chats post into
// AppChatConversation; General Chat has its own store, and a confirmation appearing in the
// wrong one is a layer merged, not a message misplaced.
//
// General Chat is also not scoped to an app, so the adapter a revision belongs to has to be
// found from the action it replaces rather than assumed from the surface.

struct ActionReuseWiringTests {

    /// Each test builds its own adapter. These run in parallel and in no particular order,
    /// so a test that leaned on another test's saved action failed whenever it happened to
    /// run first — the failure looked like a broken lookup and was a broken test.
    @MainActor
    private func adapterHoldingAnAction(
        bundle: String, actionId: String, script: String = "true"
    ) async {
        let manager = AppAdapterManager.shared
        if manager.adapter(for: bundle) == nil {
            await manager.createAdapter(appName: "Reuse Test", bundleId: bundle, icon: "app")
        }
        await manager.appendAction(
            AdapterAction(
                id: actionId, name: "Reuse Wiring Probe", icon: "sparkles",
                description: "", triggers: ["reusewiringprobe"], type: .shell,
                script: script, requiresApproval: true),
            to: bundle)
    }

    private func revision(
        of actionId: String?, script: String = "echo revised"
    ) -> ExtensionProposalData {
        ExtensionProposalData(
            type: "extension_proposal", name: "Reuse Wiring Probe", description: "",
            scriptType: "bash", script: script, layer: "contextdock",
            triggers: [.init(type: "keyword", value: "reusewiringprobe")],
            replacesActionId: actionId)
    }

    // MARK: - Finding the adapter a revision belongs to

    /// General Chat has no app scope, so "which adapter does this action live in" is
    /// answered from the action's own id — the only thing the card carries.
    @MainActor @Test func theOwningAdapterIsFoundFromTheActionItReplaces() async {
        let bundle = "com.example.reuse-owner"
        await adapterHoldingAnAction(bundle: bundle, actionId: "authored.owner")

        #expect(AdapterActionProposalInstaller.bundleId(owning: "authored.owner") == bundle)
        #expect(AdapterActionProposalInstaller.bundleId(owning: "authored.nothing-here") == nil)
    }

    // MARK: - Where the confirmation goes

    /// Saving from General Chat must not write into the app chats' conversation. `perform`
    /// saves and hands the confirmation back; only `install` posts it to AppChatConversation.
    @MainActor @Test func performingDoesNotPostToTheAppChat() async {
        let bundle = "com.example.reuse-transcript"
        await adapterHoldingAnAction(bundle: bundle, actionId: "authored.transcript")
        let before = AppChatConversation.shared.messages.count

        let message = await AdapterActionProposalInstaller.perform(
            revision(of: "authored.transcript"), bundleId: bundle, appName: "Reuse Test")

        #expect(AppChatConversation.shared.messages.count == before)
        #expect(message.content.contains("Reuse Wiring Probe"))
        // A revision says it replaced rather than added, wherever it is shown.
        #expect(message.content.lowercased().contains("updated"))
    }

    /// An empty scope is not a reason to fail when the proposal says which action it
    /// replaces: the adapter is found from the action, and the revision saves.
    @MainActor @Test func aRevisionWithNoScopeFindsItsOwnAdapter() async {
        let bundle = "com.example.reuse-unscoped"
        await adapterHoldingAnAction(bundle: bundle, actionId: "authored.unscoped")

        let message = await AdapterActionProposalInstaller.perform(
            revision(of: "authored.unscoped"), bundleId: "", appName: "")
        #expect(!message.isError)

        let saved = AppAdapterManager.shared.adapter(for: bundle)?
            .actions.first { $0.id == "authored.unscoped" }
        #expect(saved?.script == "echo revised")
        // Saved to the app it belongs to, named as the user knows it — not "This App".
        #expect(message.content.contains("Reuse Test"))
    }

    /// An ordinary proposal with no scope and nothing to replace still has nowhere to go,
    /// and says so rather than saving into an adapter it picked itself.
    @MainActor @Test func anUnscopedInstallStillRefuses() async {
        let message = await AdapterActionProposalInstaller.perform(
            revision(of: nil), bundleId: "", appName: "")
        #expect(message.isError)
    }
}
