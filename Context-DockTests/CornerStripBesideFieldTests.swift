// Context-DockTests/CornerStripBesideFieldTests.swift
import CoreGraphics
import Testing

@testable import Context_Dock

/// Opening Global Context's field keeps the strip's pins — folders, plugin tiles — beside it,
/// at the field's height, instead of taking them away.
struct CornerStripBesideFieldTests {
    private typealias M = AppChatPromptMetrics

    @Test func theOpenFieldWidensByItsPinsAtFieldHeight() {
        let plain = M.size(for: .prompt, suggestions: 0, pinned: 3, stripBesideField: false)
        let beside = M.size(for: .prompt, suggestions: 0, pinned: 3, stripBesideField: true)
        #expect(beside.height == plain.height)
        #expect(beside.width
            == plain.width + M.fieldStripScale * M.pinsBesideFieldSpan(pinned: 3))
        #expect(M.fieldStripScale == M.inputHeight / M.dockHeight)
    }

    @Test func withNothingPinnedTheFieldIsUnchanged() {
        #expect(M.pinsBesideFieldSpan(pinned: 0, tools: 2) == 0)
        #expect(M.size(for: .prompt, suggestions: 0, tools: 2, stripBesideField: true)
            == M.size(for: .prompt, suggestions: 0, tools: 2))
    }

    @Test func aPluginTileIsMeasuredAtItsWidgetWidth() {
        #expect(M.pinsBesideFieldSpan(pinned: 2, pinnedExtraWidth: 60)
            == M.pinsBesideFieldSpan(pinned: 2) + 60)
    }

    @Test func theToolsAreClippedAtTheirHairlineNotShownTwice() {
        // What shows ends one gap after the last pin; everything after — the tools' hairline
        // and icons and the strip's inset — is pushed past the shell's edge.
        let tools = 2
        let hidden = M.toolsBesideFieldOffset(pinned: 1, tools: tools)
        #expect(hidden + M.dockIconGap
            == M.dockDividerSpan + CGFloat(tools) * M.dockIconSize
                + CGFloat(tools - 1) * M.dockIconGap + M.dockInset)
        #expect(M.toolsBesideFieldOffset(pinned: 0, tools: tools) == 0)
        #expect(M.toolsBesideFieldOffset(pinned: 1, tools: 0) == 0)
    }

    @Test func otherPhasesAreNotWidened() {
        for phase in [AppChatPromptPhase.chat, .dock, .mini] {
            #expect(M.size(for: phase, suggestions: 0, pinned: 3, stripBesideField: true)
                == M.size(for: phase, suggestions: 0, pinned: 3))
        }
    }
}
