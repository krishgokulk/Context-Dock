import Foundation
import Testing

@testable import Context_Dock

@Suite("GeneralChatSessionStore Pet migration & generic Pet honesty")
@MainActor
struct GeneralChatSessionStoreTests {
    @Test func petScopesLoadAndPersistThroughLegacyDockAppKeys() {
        let suffix = UUID().uuidString
        let bundleA = "com.example.session-a-\(suffix)"
        let bundleB = "com.example.session-b-\(suffix)"
        let petA = AppPetID.app(bundleID: bundleA)
        let petB = AppPetID.app(bundleID: bundleB)
        let scopeA = GeneralChatScope(petID: petA)
        let scopeB = GeneralChatScope(petID: petB)
        defer {
            if let keyA = GeneralChatSessionStore.dockPanelKey(scopeA) {
                AppPanelChatStore.shared.clear(for: keyA)
            }
            if let keyB = GeneralChatSessionStore.dockPanelKey(scopeB) {
                AppPanelChatStore.shared.clear(for: keyB)
            }
        }

        let messagesA = [
            AIChatMessage(role: .user, content: "First Pet question"),
            AIChatMessage(role: .assistant, content: "First Pet answer"),
        ]
        let messagesB = [
            AIChatMessage(role: .user, content: "Second Pet question"),
            AIChatMessage(role: .assistant, content: "Second Pet answer"),
        ]

        GeneralChatSessionStore.save(messagesA, scope: scopeA, title: "Pet A")
        GeneralChatSessionStore.save(messagesB, scope: scopeB, title: "Pet B")

        #expect(
            GeneralChatSessionStore.load(scope: .app(bundleId: bundleA)).map(\.content)
                == messagesA.map(\.content))
        #expect(
            GeneralChatSessionStore.load(scope: scopeB).map(\.content)
                == messagesB.map(\.content))
        #expect(
            GeneralChatSessionStore.load(scope: scopeA).map(\.content)
                == messagesA.map(\.content))
    }

    @Test func selectedGenericPetWithNoRichAdapterScopesHonestly() {
        let genericBundleID = "com.example.generic-pet-\(UUID().uuidString)"
        let model = AppChatPromptModel(
            conversation: AppChatConversation(), globalResultSource: GlobalContextResultSource())
        model.summonGlobalContext()

        model.scopeIntoApp(name: "GenericApp", bundleID: genericBundleID)

        #expect(model.appBundleID == genericBundleID)
        #expect(model.appName == "GenericApp")
        #expect(model.returnsToGlobalScope)
        #expect(model.isAppStepIn)
        #expect(model.adapterActions.isEmpty)
        #expect(model.suggestions.isEmpty)
        #expect(AppChatListCard.placeholder(for: model) == "Ask GenericApp")
    }
}
