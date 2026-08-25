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

    @Test func theHotkeyOpensTheInputAndStartsTheClock() {
        let model = AppChatPromptModel()

        model.summon(app: "Safari")

        #expect(model.phase == .prompt)
        #expect(model.isStandDownArmed)
        #expect(model.appName == "Safari")
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

    @Test func anUntouchedPromptStandsDown() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")

        model.standDown()

        #expect(model.phase == .hidden)
    }

    /// Half a typed question is worth more than an empty corner, so a prompt with text in
    /// it shrinks to a badge instead of being thrown away.
    @Test func aPromptWithTextInItShrinksRatherThanDiscardingTheQuestion() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()

        model.standDown()

        #expect(model.phase == .mini)
        #expect(model.query == "half a question")
    }

    @Test func reachingForTheBadgeGivesTheQuestionBack() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()
        model.standDown()

        model.hoverBegan()

        #expect(model.phase == .prompt)
        #expect(model.query == "half a question")
    }

    @Test func theBadgeEventuallyGoesToo() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()
        model.standDown()

        model.standDown()

        #expect(model.phase == .hidden)
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
