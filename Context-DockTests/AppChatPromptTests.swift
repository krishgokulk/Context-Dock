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

    /// Submitting is the one thing not wired up yet, so it must not pretend to work.
    @Test func submittingIsNotConnectedYetAndSaysSo() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "what changed here"

        let sent = model.submit()

        #expect(!sent)
        #expect(model.phase == .prompt)
    }
}
