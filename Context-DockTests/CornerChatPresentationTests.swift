import Testing

@testable import Context_Dock

@MainActor
struct CornerChatPresentationTests {
    private var code: CornerChatTarget {
        CornerChatTarget(
            name: "Code",
            bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
    }

    @Test func hotkeyCyclesHiddenToAppToGeneralToApp() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)

        subject.cycle(target: code)
        #expect(subject.mode == .frontmostApp)
        #expect(subject.isVisible)
        #expect(app.appBundleID == "com.microsoft.VSCode")

        subject.cycle(target: code)
        #expect(subject.mode == .general)
        #expect(subject.isVisible)

        subject.cycle(target: code)
        #expect(subject.mode == .frontmostApp)
        #expect(subject.isVisible)
    }

    @Test func switchingModesPreservesIndependentDrafts() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)

        subject.cycle(target: code)
        app.query = "app draft"
        subject.cycle(target: code)
        general.input = "general draft"
        subject.cycle(target: code)

        #expect(app.query == "app draft")
        #expect(general.input == "general draft")
    }
}
