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

    @Test func switchingSpaceTakesThePromptWithIt() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "typed but not sent"

        model.userLeftTheSpace()

        #expect(model.phase == .hidden)
    }

    /// Submitting still sends nothing — but it keeps the question and says so, rather
    /// than swallowing the Enter key and looking broken.
    @Test func submittingReportsThatNothingWasSent() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "what changed here"

        let sent = model.submit()

        #expect(!sent)
        #expect(model.messages.first?.text == "what changed here")
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

    @Test func expandingOpensTheChatSurfaceAndCollapsingReturns() {
        let model = opened()

        model.toggleExpanded()
        #expect(model.phase == .chat)

        model.toggleExpanded()
        #expect(model.phase != .chat)
    }

    /// Enter used to do nothing at all, which reads as broken rather than unfinished.
    @Test func sendingShowsTheQuestionAndSaysTheRouteIsMissing() {
        let model = opened()
        model.query = "why is this slow"

        let sent = model.submit()

        #expect(!sent)
        #expect(model.phase == .chat)
        #expect(model.messages.contains { $0.isFromUser && $0.text == "why is this slow" })
        #expect(model.messages.contains { !$0.isFromUser })
        #expect(model.query.isEmpty)
    }

    @Test func sendingAnEmptyQuestionDoesNothing() {
        let model = opened()

        let sent = model.submit()

        #expect(!sent)
        #expect(model.messages.isEmpty)
        #expect(model.phase != .chat)
    }

    /// A sent question is a conversation the user is in: it must not time out underneath
    /// them the way an untouched prompt does.
    @Test func aConversationDoesNotStandDownToNothing() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()

        model.standDown()

        #expect(model.phase == .mini)
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

    @Test func dismissingDropsTheAttachmentsAndTheConversation() {
        let model = opened()
        model.attach(URL(fileURLWithPath: "/tmp/shot.png"))
        model.query = "q"
        _ = model.submit()

        model.dismiss()

        #expect(model.attachments.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(!model.isPinned)
    }
}
