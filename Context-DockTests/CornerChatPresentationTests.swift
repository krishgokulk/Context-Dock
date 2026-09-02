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

    @Test func hotkeyAlwaysSummonsFrontmostAppChat() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)

        subject.cycle(target: code)
        #expect(subject.mode == .frontmostApp)
        #expect(subject.isVisible)
        #expect(app.appBundleID == "com.microsoft.VSCode")

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
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        general.input = "general draft"
        subject.cycle(target: code)

        #expect(app.query == "app draft")
        #expect(general.input == "general draft")
    }

    @Test func emptyLeftArrowEntersGeneralButTextKeepsCursorOwnership() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)

        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)

        subject.showFrontmostApp(target: code)
        #expect(subject.handleLeftArrow(draft: "editing") == false)
        #expect(subject.mode == .frontmostApp)
    }

    @Test func horizontalSwipeMatchesDockDirectionAndReturnsToLatestApp() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)

        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == false)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.mode == .general)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == false)
        #expect(subject.mode == .general)
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == true)
        #expect(subject.mode == .frontmostApp)
        #expect(subject.appChat.appBundleID == code.bundleID)
    }

    @Test func generalChatShrinksThenHidesAndHoverRestoresIt() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: ""))

        subject.standDown()
        #expect(subject.generalPhase == .mini)
        #expect(subject.isVisible)

        subject.hoverBegan()
        #expect(subject.generalPhase == .expanded)

        subject.hoverEnded()
        subject.standDown()
        subject.standDown()
        #expect(!subject.isVisible)
    }

    @Test func pinAndComposerFocusProtectGeneralChatFromIdleShrink() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: ""))

        subject.toggleGeneralPin()
        subject.standDown()
        #expect(subject.generalPhase == .expanded)

        subject.toggleGeneralPin()
        subject.setGeneralComposerFocused(true)
        subject.standDown()
        #expect(subject.generalPhase == .expanded)
    }
}
