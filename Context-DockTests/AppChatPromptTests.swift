import Combine
import Foundation
import Testing

@testable import Context_Dock

/// The corner prompt: a hotkey opens an input in the shared shell, and it stands down the
/// same way every other corner surface does.
@MainActor
struct AppChatPromptTests {
    @Test func itShowsNothingUntilTheHotkeyAsksForIt() {
        #expect(AppChatPromptModel().phase == .hidden)
    }

    /// Launching shows what this app can actually do, the way Siri opens with
    /// suggestions rather than a blank line.
    @Test func launchingOpensOnTheAppsOwnSuggestions() {
        let model = AppChatPromptModel()

        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [
                .init(icon: "bolt.fill", title: "New Window", kind: .action),
                .init(icon: "brain", title: "Code", kind: .skill),
            ],
            summary: "5 actions · 2 skills · 1 built-in tools · 3 cli tools")

        #expect(model.phase == .suggesting)
        #expect(model.isStandDownArmed)
        #expect(model.appName == "Code")
        #expect(model.suggestions.count == 2)
        #expect(model.capabilitySummary.hasPrefix("5 actions"))
    }

    @Test func anAppWithNothingToSuggestOpensAsAPlainInput() {
        let model = AppChatPromptModel()

        model.summon(app: "Safari")

        #expect(model.phase == .prompt)
        #expect(model.suggestions.isEmpty)
    }

    /// Typing is attention. A prompt must not vanish mid-sentence.
    @Test func typingPutsTheClockBack() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")

        model.query = "why is this slow"
        model.queryChanged()

        #expect(model.phase == .prompt)
        #expect(model.isStandDownArmed)
    }

    /// Idle shrinks to the app's own icon — the surface stays identifiable as being
    /// about that app rather than becoming a generic dot.
    @Test func anIdlePromptShrinksToTheAppIcon() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        model.standDown()

        #expect(model.phase == .mini)
        #expect(model.appBundleID == "com.apple.Safari")
    }

    /// A half-written question survives the shrink; it is the thing worth keeping.
    @Test func shrinkingKeepsAnUnfinishedQuestion() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()

        model.standDown()

        #expect(model.phase == .mini)
        #expect(model.query == "half a question")
    }

    @Test func reachingForTheIconGivesTheQuestionBack() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()
        model.standDown()

        model.hoverBegan()

        #expect(model.phase == .prompt)
        #expect(model.query == "half a question")
    }

    /// Coming back to an untouched prompt should show the suggestions again, not a blank
    /// field the user has to guess at.
    @Test func reachingForTheIconWithNothingTypedRestoresTheSuggestions() {
        let model = AppChatPromptModel()
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        model.standDown()

        model.hoverBegan()

        #expect(model.phase == .suggesting)
    }

    @Test func theIconEventuallyGoesToo() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.standDown()

        model.standDown()

        #expect(model.phase == .hidden)
    }

    /// Typing is a question, not a browse: the suggestion list gets out of the way.
    @Test func typingCollapsesTheSuggestionsIntoAPlainInput() {
        let model = AppChatPromptModel()
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")

        model.query = "why"
        model.queryChanged()

        #expect(model.phase == .prompt)
    }

    @Test func clearingTheFieldBringsTheSuggestionsBack() {
        let model = AppChatPromptModel()
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        model.query = "why"
        model.queryChanged()

        model.query = ""
        model.queryChanged()

        #expect(model.phase == .suggesting)
    }

    @Test func dismissingClearsTheQuestion() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "something"

        model.dismiss()

        #expect(model.phase == .hidden)
        #expect(model.query.isEmpty)
    }

    @Test func switchingFrontmostAppKeepsThePromptAndUpdatesItsScope() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Safari", bundleID: "com.apple.Safari")
        model.query = "typed but not sent"

        model.frontmostAppDidChange(
            app: "Code",
            bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")

        #expect(model.phase == .suggesting)
        #expect(model.appName == "Code")
        #expect(model.appBundleID == "com.microsoft.VSCode")
        #expect(model.query.isEmpty)
        #expect(model.suggestions.map(\.title) == ["New Window"])
    }

    /// This is the frontmost app chat: the question is asked and answered here.
    @Test func sendingOpensTheConversationHere() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")
        model.query = "what changed here"

        _ = model.submit()

        #expect(model.phase == .chat)
        // The runtime notification observer owns the shared transcript. This model owns
        // the hand-off and surface transition, which are synchronous and testable here.
        #expect(model.query.isEmpty)
    }

    /// Opening in the dock is still offered for when the corner is too small.
    @Test func openingInTheDockClosesTheCorner() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        model.openInDock()

        #expect(model.phase == .hidden)
    }
}

// MARK: - Controls

@MainActor
struct AppChatControlsTests {
    private func opened() -> AppChatPromptModel {
        let model = AppChatPromptModel()
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")
        return model
    }

    /// Pinning is the user saying "stay". Nothing times it out after that.
    @Test func pinningStopsTheStandDown() {
        let model = opened()

        model.togglePin()

        #expect(model.isPinned)
        #expect(!model.isStandDownArmed)
    }

    @Test func aPinnedPromptIgnoresTheClockEntirely() {
        let model = opened()
        model.togglePin()

        model.standDown()

        #expect(model.phase != .hidden)
        #expect(model.phase != .mini)
    }

    @Test func unpinningPutsTheClockBack() {
        let model = opened()
        model.togglePin()

        model.togglePin()

        #expect(!model.isPinned)
        #expect(model.isStandDownArmed)
    }

    /// Sending is a real hand-off now, so it reports true — unlike before, when nothing
    /// was sent and the prompt had to say so.
    @Test func sendingReportsThatItWentSomewhere() {
        let model = opened()
        model.query = "why is this slow"

        #expect(model.submit())
    }

    /// A second Enter while the first is still running must not start a second turn.
    @Test func askingAgainMidAnswerIsIgnored() {
        let model = opened()
        AppChatConversation.shared.isLoading = true
        defer { AppChatConversation.shared.isLoading = false }
        model.query = "second"

        #expect(!model.submit())
    }

    /// The corner is another view of the dock conversation. A dock-side update must
    /// invalidate this model so SwiftUI redraws the transcript and live activity.
    @Test func sharedConversationUpdatesRefreshTheCorner() {
        let model = opened()
        var didRefresh = false
        let observation = model.objectWillChange.sink { didRefresh = true }
        defer { observation.cancel() }

        AppChatConversation.shared.liveSteps = ["Checking capabilities"]
        defer { AppChatConversation.shared.liveSteps = [] }

        #expect(didRefresh)
        #expect(model.liveSteps == ["Checking capabilities"])
    }

    @Test func dockRouteTraceFeedsTheSharedCornerActivity() {
        var state = L2State()

        state.routerTrace = ["Planning the minimum evidence route"]
        defer { state.routerTrace = [] }

        #expect(
            AppChatConversation.shared.liveSteps
                == ["Planning the minimum evidence route"])
    }

    @Test func sendingAnEmptyQuestionDoesNothing() {
        let model = opened()

        let sent = model.submit()

        #expect(!sent)
        #expect(model.phase != .hidden)
    }

    /// Conversation history does not make the corner immortal. Leaving it lets the same
    /// idle lifecycle as the launch suggestions shrink it back to the app icon.
    @Test func aConversationShrinksAfterThePointerLeaves() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()

        model.hoverEnded()
        model.standDown()

        #expect(model.phase == .mini)
    }

    @Test func aConversationStaysOpenWhileThePointerIsInside() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()
        model.hoverBegan()

        model.standDown()

        #expect(model.phase == .chat)
    }

    @Test func comingBackToAConversationReopensIt() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()
        model.standDown()

        model.hoverBegan()

        #expect(model.phase == .chat)
    }

    @Test func attachmentsAreListedAndRemovable() {
        let model = opened()
        let file = URL(fileURLWithPath: "/tmp/shot.png")

        model.attach(file)
        #expect(model.attachments == [file])

        model.detach(file)
        #expect(model.attachments.isEmpty)
    }

    @Test func attachingTheSameFileTwiceKeepsOneCopy() {
        let model = opened()
        let file = URL(fileURLWithPath: "/tmp/shot.png")

        model.attach(file)
        model.attach(file)

        #expect(model.attachments.count == 1)
    }

    @Test func dismissingDropsTheAttachmentsAndThePin() {
        let model = opened()
        model.attach(URL(fileURLWithPath: "/tmp/shot.png"))
        model.togglePin()

        model.dismiss()

        #expect(model.attachments.isEmpty)
        #expect(!model.isPinned)
    }
}
