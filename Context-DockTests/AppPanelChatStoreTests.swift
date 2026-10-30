import Foundation
import Testing

@testable import Context_Dock

@Suite("AppPanelChatStore Pet switching")
@MainActor
struct AppPanelChatStoreTests {
    @Test func existingDockAppHistoryAppearsAfterPetSelectionAndSurvivesPetSwitching() {
        let suffix = UUID().uuidString
        let bundleA = "com.example.pet-a-\(suffix)"
        let bundleB = "com.example.pet-b-\(suffix)"
        let keyA = "dock_app_\(bundleA)"
        let keyB = "dock_app_\(bundleB)"
        defer {
            AppPanelChatStore.shared.clear(for: keyA)
            AppPanelChatStore.shared.clear(for: keyB)
        }

        let seedA = [
            AIChatMessage(role: .user, content: "Summarise my Safari tabs"),
            AIChatMessage(role: .assistant, content: "You have 3 tabs open."),
        ]
        let seedB = [
            AIChatMessage(role: .user, content: "Check unread Mail"),
            AIChatMessage(role: .assistant, content: "2 unread messages."),
        ]
        AppPanelChatStore.shared.save(seedA, for: keyA)
        AppPanelChatStore.shared.save(seedB, for: keyB)

        let conversation = AppChatConversation()
        let model = AppChatPromptModel(
            conversation: conversation, globalResultSource: GlobalContextResultSource())
        model.summonGlobalContext()

        // Select Pet A: existing dock_app_<bundleID> history is detected and loads on openChat().
        model.scopeIntoApp(name: "Pet A", bundleID: bundleA)
        #expect(model.hasSavedChat)
        #expect(model.openChat())
        #expect(conversation.messages.map(\.content) == seedA.map(\.content))

        // Persist Pet A's active session and switch to Pet B.
        AppPanelChatStore.shared.saveSession(conversation.messages, for: keyA)
        model.scopeIntoApp(name: "Pet B", bundleID: bundleB)
        #expect(model.hasSavedChat)
        #expect(model.openChat())
        #expect(conversation.messages.map(\.content) == seedB.map(\.content))

        // Switch back to Pet A without clearing AppChatConversation first: Pet A's history
        // survives Pet A -> Pet B -> Pet A.
        AppPanelChatStore.shared.saveSession(conversation.messages, for: keyB)
        model.scopeIntoApp(name: "Pet A", bundleID: bundleA)
        #expect(model.hasSavedChat)
        #expect(model.openChat())
        #expect(conversation.messages.map(\.content) == seedA.map(\.content))
    }
}
