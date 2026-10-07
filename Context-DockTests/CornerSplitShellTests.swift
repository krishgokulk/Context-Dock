import Foundation
import Testing

@testable import Context_Dock

/// Part B (owner 2026-10-07): while the field is open — Global or an app's Context Dock — it
/// stands on the left and the pinned and running apps stand beside it on the right.
@MainActor
struct CornerSplitShellTests {
    private func splits(
        visible: Bool = true, general: Bool = false, phase: AppChatPromptPhase = .suggesting,
        content: Bool = true
    ) -> Bool {
        CornerSplitShell.splits(
            isVisible: visible, isGeneral: general, phase: phase, stripHasContent: content)
    }

    /// Open, the field and the apps are two pieces — with or without a board above.
    @Test func anOpenFieldSplits() {
        #expect(splits())
        #expect(splits(phase: .prompt))
    }

    /// Nothing to put beside the field (no apps, no copy, an empty shelf): it stays whole.
    @Test func nothingBesideTheFieldKeepsItWhole() {
        #expect(!splits(content: false))
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

    /// The apps fit what they hold, between a capsule's worth and half the shell; the field
    /// takes the rest, so the two and the gap are the shell's one width.
    @Test func theBottomLineFillsTheShell() {
        for shell: CGFloat in [600, 664, 731] {
            for apps in [0, 1, 3, 6, 12, 30] {
                for tools in [0, 1, 2] where apps + tools > 0 {
                    let (field, strip) = CornerSplitShell.widths(
                        shell: shell, apps: apps, tools: tools)
                    #expect(field + CornerSplitShell.gap + strip == shell)
                    #expect(strip >= CornerSplitShell.minimumStripWidth)
                    #expect(strip <= (shell / 2).rounded())
                }
            }
        }
    }

    /// With nothing to show the field is the whole shell and the apps take no room.
    @Test func anEmptyStripTakesNoRoom() {
        let (field, strip) = CornerSplitShell.widths(shell: 664, apps: 0, tools: 0)
        #expect(field == 664)
        #expect(strip == 0)
    }

    /// Each icon and each tool widens the apps' piece until it reaches half the shell.
    @Test func theStripGrowsWithWhatItHolds() {
        #expect(CornerSplitStrip.contentWidth(apps: 4, tools: 0)
            > CornerSplitStrip.contentWidth(apps: 3, tools: 0))
        #expect(CornerSplitStrip.contentWidth(apps: 3, tools: 2)
            > CornerSplitStrip.contentWidth(apps: 3, tools: 1))
        #expect(CornerSplitStrip.contentWidth(apps: 0, tools: 1)
            < CornerSplitStrip.contentWidth(apps: 1, tools: 1))
    }

    /// Pinned extensions follow the apps after a hairline (owner 2026-10-07): each one widens
    /// the piece, and the first one also brings its hairline.
    @Test func pinnedExtensionsFollowTheApps() {
        let apps = CornerSplitStrip.contentWidth(apps: 3, tools: 0)
        let one = CornerSplitStrip.contentWidth(apps: 3, pins: 1, tools: 0)
        let two = CornerSplitStrip.contentWidth(apps: 3, pins: 2, tools: 0)
        let hairline = CornerSplitStrip.spacing + 1 + CornerSplitStrip.spacing
        #expect(one == apps + CornerSplitStrip.iconSize + hairline)
        #expect(two == one + CornerSplitStrip.iconSize + CornerSplitStrip.spacing)
        // Pins alone still make a piece beside the field.
        let (field, strip) = CornerSplitShell.widths(shell: 664, apps: 0, pins: 1, tools: 0)
        #expect(strip > 0)
        #expect(field + CornerSplitShell.gap + strip == 664)
    }

    /// A copy shows the clipboard beside the field for three seconds, not seven (owner
    /// 2026-10-07: "only when user copied something, for 3 sec").
    @Test func theCopyIconDwellsThreeSeconds() {
        #expect(ClipboardPanelModel.iconDwell == 3)
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

    /// The result board ends in a foot (Return, ⌘P, ⌘,), and the window reserves it.
    @Test func theResultBoardReservesItsFoot() {
        let bare = AppChatListMetrics.headerHeight + 3 * AppChatListMetrics.rowHeight
            + 2 * AppChatListMetrics.verticalPadding
        #expect(AppChatListMetrics.size(rows: 3).height == bare + AppChatListMetrics.footerHeight)
    }
}
