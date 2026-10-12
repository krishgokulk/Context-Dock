import Foundation
import Testing

@testable import Context_Dock

/// ⌥⌥ opens the Corner in the middle of the display, like Spotlight: a field that stays a
/// field until it is closed (owner 2026-10-12).
@MainActor
@Suite("Centred Corner")
struct CentredCornerTests {
    @Test func aCentredFieldNeitherFoldsNorShrinksWhenIdle() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.staysOpenWhenIdle = true

        model.standDown()
        model.standDown()

        #expect(model.phase == .prompt)
        #expect(!model.canRestAsDock)
        #expect(!model.foldToDock())
    }

    @Test func atTheBottomItStillFoldsAsBefore() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.autoShrinkEnabled = { true }
        model.summonGlobalContext()

        #expect(model.canRestAsDock)
    }
}
