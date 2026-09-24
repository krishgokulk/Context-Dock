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

    /// ← steps into General Chat from either scope and → steps back to that scope — the
    /// Dock's ←/→ toggle (§4b W4), so a keyboard trip is never one-way.
    @Test func theArrowRouteBetweenModesRunsBothWays() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.frontmostTargetProvider = { nil }
        subject.showFrontmostApp(target: code)

        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)
        #expect(subject.handleLeftArrow(draft: "") == false)
        #expect(subject.handleRightArrow(draft: "") == true)
        #expect(subject.mode == .frontmostApp)

        subject.showGlobalContext()
        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)
        #expect(subject.handleRightArrow(draft: "") == true)
        #expect(subject.mode == .globalContext)
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
        // No live frontmost app: this test is about drafts surviving a walk, and the real
        // read answers with whatever owns the menu bar while the suite runs (#30).
        subject.frontmostTargetProvider = { nil }

        subject.cycle(target: code)
        app.query = "app draft"
        // App → General, one swipe right.
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: "") == true)
        #expect(subject.mode == .general)
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
        #expect(subject.mode == .general)

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

    /// Swipe right into General Chat from either scope, and any sideways swipe back to the
    /// scope it came from — the Dock's toggle. A swipe left outside General does nothing.
    @Test func horizontalSwipeMatchesDockDirectionAndReturnsToLatestApp() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.frontmostTargetProvider = { nil }
        subject.showFrontmostApp(target: code)

        #expect(subject.handleHorizontalSwipe(deltaX: -90) == false)
        #expect(subject.handleHorizontalSwipe(deltaX: 90) == true)
        #expect(subject.mode == .general)
        #expect(subject.handleHorizontalSwipe(deltaX: -90) == true)
        #expect(subject.mode == .frontmostApp)
        #expect(subject.appChat.appBundleID == code.bundleID)

        subject.showGlobalContext()
        #expect(subject.handleHorizontalSwipe(deltaX: 90) == true)
        #expect(subject.mode == .general)
        // Either direction leaves General, as in the Dock.
        #expect(subject.handleHorizontalSwipe(deltaX: 90) == true)
        #expect(subject.mode == .globalContext)
    }

    /// ↑/↓ and vertical swipes move between the layers: Global Context above the frontmost
    /// app, and General Chat left the way it was entered.
    @Test func theLayerKeysMoveBetweenGlobalAndTheApp() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.frontmostTargetProvider = { nil }
        subject.showFrontmostApp(target: code)

        #expect(subject.handleLayerKey(up: true) == true)
        #expect(subject.mode == .globalContext)
        #expect(subject.handleLayerKey(up: true) == false)
        #expect(subject.handleLayerKey(up: false) == true)
        #expect(subject.mode == .frontmostApp)
        // Nothing below the app until the Media Dock moves into the corner.
        #expect(subject.handleLayerKey(up: false) == false)

        _ = subject.handleLeftArrow(draft: "")
        #expect(subject.handleLayerKey(up: false) == true)
        #expect(subject.mode == .frontmostApp)
    }

    @Test func generalChatShrinksThenHidesAndHoverRestoresIt() {
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel())
        subject.showFrontmostApp(target: code)
        #expect(subject.handleHorizontalSwipe(deltaX: 90, draft: ""))
        #expect(subject.mode == .general)

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
