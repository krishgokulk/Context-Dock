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

        // Global Context sits between the two chats, so the walk outward is two steps.
        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .globalContext)
        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)

        #expect(subject.handleRightArrow(draft: "") == true)
        #expect(subject.mode == .globalContext)
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
        #expect(subject.mode == .globalContext)
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
        // No live frontmost app: this test is about drafts surviving a walk, and the real
        // read answers with whatever owns the menu bar while the suite runs (#30).
        subject.frontmostTargetProvider = { nil }

        subject.cycle(target: code)
        app.query = "app draft"
        // App → Global → General, one step per swipe.
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        general.input = "general draft"
        // Swiping back, not the hotkey: the hotkey puts the corner away now.
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == true)
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
        // The field opens plain — no suggestions sheet to close first — so one idle step
        // is the badge.
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

    @Test func globalContextPromptHidingItselfTakesTheShellWithIt() {
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let subject = CornerChatPresentation(
            appChat: app, generalChat: GeneralChatWindowModel())
        subject.showGlobalContext()
        #expect(subject.mode == .globalContext)
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
        #expect(subject.mode == .globalContext)

        subject.showFrontmostApp(target: code)
        #expect(subject.handleLeftArrow(draft: "editing") == false)
        #expect(subject.mode == .frontmostApp)
    }

    @Test func comingBackToTheSameAppKeepsWhatWasTyped() {
        // The real case, and the one worth protecting: you are in an app, swipe to General,
        // swipe back. The app in front has not changed, so the draft is still there. The
        // walk re-resolves the frontmost app by design — this pins that re-resolving to the
        // SAME app is not a reason to lose anything.
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let subject = CornerChatPresentation(appChat: app, generalChat: GeneralChatWindowModel())
        subject.frontmostTargetProvider = { code }

        subject.showFrontmostApp(target: code)
        app.query = "half a question"
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == true)
        #expect(subject.mode == .frontmostApp)
        #expect(app.appBundleID == code.bundleID)
        #expect(app.query == "half a question")
    }

    @Test func steppingIntoAnotherAppTakesYouToThatAppsChat() {
        // The other half of the same rule, also by design: leave the corner, click a
        // different app, come back — you are in THAT app's chat, with its own draft, not
        // still talking to the app you started in.
        let app = AppChatPromptModel(conversation: AppChatConversation())
        let subject = CornerChatPresentation(appChat: app, generalChat: GeneralChatWindowModel())
        subject.frontmostTargetProvider = { code }
        subject.showFrontmostApp(target: code)
        app.query = "for code"

        let other = CornerChatTarget(
            name: "Safari", bundleID: "com.apple.Safari", suggestions: [], summary: "")
        subject.frontmostTargetProvider = { other }
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == true)
        #expect(app.appBundleID == other.bundleID)
        #expect(app.query.isEmpty)

        // And the first app's draft was kept, not discarded — going back finds it.
        subject.frontmostTargetProvider = { code }
        subject.show(.frontmostApp)
        #expect(app.query == "for code")
    }

    @Test func horizontalSwipeMatchesDockDirectionAndReturnsToLatestApp() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.frontmostTargetProvider = { nil }
        subject.showFrontmostApp(target: code)

        // From the app scope there is nothing further right, and one swipe left is one
        // step of the same walk the arrows take.
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == false)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.mode == .globalContext)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.mode == .general)
        // And nothing further left of General.
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == false)
        #expect(subject.handleHorizontalSwipe(deltaX: -90, draft: "") == true)
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
