import Foundation
import Testing

@testable import Context_Dock

/// Part B (owner 2026-10-07): while the board shows a preview, the field sits under the
/// results and the pinned and running apps under the preview.
struct CornerSplitShellTests {
    private func splits(
        visible: Bool = true, general: Bool = false, phase: AppChatPromptPhase = .suggesting,
        clipboard: Bool = false, list: Bool = true, preview: Bool = true
    ) -> Bool {
        CornerSplitShell.splits(
            isVisible: visible, isGeneral: general, phase: phase,
            clipboardBoard: clipboard, resultList: list, hasPreview: preview)
    }

    @Test func resultsWithAPreviewSplitTheShell() {
        #expect(splits())
        #expect(splits(phase: .prompt))
    }

    /// No right-hand column, nothing for the apps to stand under.
    @Test func aListWithoutAPreviewKeepsTheFieldWhole() {
        #expect(!splits(preview: false))
        #expect(!splits(list: false))
    }

    /// The clipboard board always has its preview column.
    @Test func theClipboardBoardSplitsTheShell() {
        #expect(splits(clipboard: true, list: false, preview: false))
    }

    /// A conversation keeps its composer whole; General is its own surface; a docked or
    /// hidden shell has no field to split.
    @Test func onlyAFieldBeingTypedIntoSplits() {
        #expect(!splits(phase: .chat))
        #expect(!splits(phase: .dock))
        #expect(!splits(phase: .mini))
        #expect(!splits(general: true))
        #expect(!splits(visible: false))
    }

    /// The two bottom pieces and the gap between them are exactly the shell, and the field
    /// ends where the board's list column does, less half the gap.
    @Test func theBottomLineFillsTheShell() {
        for shell: CGFloat in [600, 664, 731] {
            let field = CornerSplitShell.fieldWidth(shell: shell)
            let strip = CornerSplitShell.stripWidth(shell: shell)
            #expect(field + CornerSplitShell.gap + strip == shell)
            let list = CornerBoardLayout.listWidth(
                board: shell, preview: .file(URL(fileURLWithPath: "/")))
            #expect(abs(field - (list - CornerSplitShell.gap / 2)) <= 1)
        }
    }

    /// A conversation splits its composer only with the app's panel open and apps to show
    /// (owner 2026-10-07: "show same for chat as well, if user pinned something").
    @Test func aConversationSplitsUnderItsPanel() {
        #expect(CornerSplitShell.splitsChat(phase: .chat, showsLivePanel: true, hasApps: true))
        #expect(!CornerSplitShell.splitsChat(phase: .chat, showsLivePanel: false, hasApps: true))
        #expect(!CornerSplitShell.splitsChat(phase: .chat, showsLivePanel: true, hasApps: false))
        #expect(!CornerSplitShell.splitsChat(phase: .prompt, showsLivePanel: true, hasApps: true))
    }

    /// The chat strip's leading edge is the panel's: the composer's 10-point margin is all
    /// it gives up.
    @Test func theChatStripStandsUnderThePanel() {
        for card: CGFloat in [600, 664] {
            #expect(
                CornerSplitShell.chatStripWidth(card: card)
                    == CornerLivePanelLayout.panelWidth(card: card) - CornerSplitShell.chatInset)
        }
    }
}
