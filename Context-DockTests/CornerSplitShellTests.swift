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

    /// Global Context's field stands apart from its apps whenever it is open (owner
    /// 2026-10-07: "the search bar separation effect"), with or without a preview.
    @Test func globalAlwaysSplitsWhileOpen() {
        for phase: AppChatPromptPhase in [.prompt, .suggesting] {
            #expect(
                CornerSplitShell.splits(
                    isVisible: true, isGeneral: false, phase: phase, isGlobalScope: true,
                    clipboardBoard: false, resultList: false, hasPreview: false))
        }
        #expect(
            !CornerSplitShell.splits(
                isVisible: true, isGeneral: false, phase: .dock, isGlobalScope: true,
                clipboardBoard: false, resultList: false, hasPreview: false))
        #expect(
            !CornerSplitShell.splits(
                isVisible: true, isGeneral: false, phase: .chat, isGlobalScope: true,
                clipboardBoard: false, resultList: false, hasPreview: false))
    }

    /// Global's apps fit what they hold, between a floor that keeps the tools readable and
    /// half the shell; the field takes the rest, so the two and the gap are the dock's width.
    @Test func globalAppsFitTheirIcons() {
        for shell: CGFloat in [600, 664, 731] {
            for apps in [0, 1, 3, 6, 12, 30] {
                let (field, strip) = CornerSplitShell.widths(
                    shell: shell, isGlobalScope: true, apps: apps)
                #expect(field + CornerSplitShell.gap + strip == shell)
                #expect(strip >= 160)
                #expect(strip <= (shell / 2).rounded())
            }
        }
        #expect(CornerSplitStrip.contentWidth(apps: 4) > CornerSplitStrip.contentWidth(apps: 3))
    }

    /// An app's field still splits at the board's list column.
    @Test func anAppSplitsAtTheListColumn() {
        let (field, strip) = CornerSplitShell.widths(shell: 664, isGlobalScope: false, apps: 3)
        #expect(field == CornerSplitShell.fieldWidth(shell: 664))
        #expect(strip == CornerSplitShell.stripWidth(shell: 664))
    }
}
