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

    private var safari: CornerChatTarget {
        CornerChatTarget(name: "Safari", bundleID: "com.apple.Safari")
    }

    /// App Chat arrows into General, so General has to arrow back — a keyboard that can
    /// only make the trip one way leaves the user reaching for the mouse to undo it.
    @Test func theArrowRouteBetweenModesRunsBothWays() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)

        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)

        #expect(subject.handleRightArrow(draft: "") == true)
        #expect(subject.mode == .frontmostApp)
    }

    /// With something typed the arrows belong to the text, in both directions.
    @Test func aDraftKeepsTheArrowsInTheField() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)
        _ = subject.handleLeftArrow(draft: "")

        #expect(subject.handleRightArrow(draft: "half a question") == false)
        #expect(subject.mode == .general)
    }

    @Test func theHotkeySummonsFrontmostAppChat() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)

        subject.cycle(target: code)

        #expect(subject.mode == .frontmostApp)
        #expect(subject.isVisible)
        #expect(app.appBundleID == "com.microsoft.VSCode")
    }

    @Test func switchingModesPreservesIndependentDrafts() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let general = GeneralChatWindowModel()
        let subject = CornerChatPresentation(appChat: app, generalChat: general)

        subject.cycle(target: code)
        app.query = "app draft"
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        general.input = "general draft"
        // Swiping back, not the hotkey: the hotkey puts the corner away now.
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == true)

        #expect(subject.mode == .frontmostApp)
        #expect(app.query == "app draft")
        #expect(general.input == "general draft")
    }

    /// The key that opens the corner has to close it. Without this the only way out was to
    /// stop touching it and wait for the idle clock to run down.
    @Test func theHotkeyPutsAnOpenCornerAway() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let subject = CornerChatPresentation(
            appChat: app, generalChat: GeneralChatWindowModel())

        subject.cycle(target: code)
        #expect(subject.isVisible)

        subject.cycle(target: code)

        #expect(!subject.isVisible)
        #expect(app.phase == .hidden)
    }

    /// A badge is the surface on its way out, not the surface. Pressing the hotkey at that
    /// point means "come back", and it comes back pointed at whatever is in front now.
    @Test func theHotkeyBringsBackAShrunkenCorner() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let subject = CornerChatPresentation(
            appChat: app, generalChat: GeneralChatWindowModel())
        subject.cycle(target: code)
        app.standDown()
        #expect(app.phase == .mini)

        subject.cycle(target: safari)

        #expect(subject.isVisible)
        #expect(app.phase.showsInput)
        #expect(app.appBundleID == "com.apple.Safari")
    }

    /// The bug behind the empty card stuck in the corner: App mode runs its own clock, and
    /// when the pill hid itself nothing told the shell, which went on drawing a card sized
    /// for a badge that had gone — and going on answering the mouse there.
    @Test func thePillHidingItselfTakesTheShellWithIt() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let subject = CornerChatPresentation(
            appChat: app, generalChat: GeneralChatWindowModel())
        subject.cycle(target: code)
        #expect(subject.isVisible)

        app.dismiss()

        #expect(!subject.isVisible)
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
