// Context-DockTests/DockShellWidthTests.swift
//
// One dock width for every Corner surface (#189). Global Context, every app's Context Dock,
// General Chat and the boards above them are drawn at one width, `DockShellWidth`: the
// launcher's — Spotlight's, the Dock's — growing only when the pins alone would not fit.
// Running apps scroll inside a fixed pill; a long prompt grows the field upward to three
// lines, never sideways.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("One dock width")
@MainActor
struct DockShellWidthTests {
    typealias M = AppChatPromptMetrics
    typealias W = DockShellWidth

    /// Roomy enough that the cap never bites unless a test asks it to.
    private let budget: CGFloat = 4000

    // MARK: The width

    @Test("Global, an app's Context Dock and General Chat take one width for the same pins")
    func everySurfaceTakesTheSameWidth() {
        for pins in 0...4 {
            let width = W.width(pins: pins, screenBudget: budget)
            // Global's field open (its strip at rest is compact: see below).
            let globalField = M.size(
                for: .prompt, suggestions: 0, running: 7, pinned: pins, tools: 1,
                promptIcons: M.matchIconBaseCount, fieldHeight: M.dockHeight,
                maximumWidth: budget, shellWidth: width)
            // An app's Context Dock: the fitted field, with and without its bar.
            let appField = M.size(
                for: .prompt, suggestions: 0, fieldHeight: M.dockHeight, fitsContent: true,
                appBarPillWidth: M.appBarFixedPillWidth, shellWidth: width)
            let bareAppField = M.size(
                for: .suggesting, suggestions: 3, fieldHeight: M.dockHeight,
                fitsContent: true, shellWidth: width)
            // An app's conversation.
            let appChat = M.size(for: .chat, suggestions: 0, messages: 3, shellWidth: width)
            for size in [globalField, appField, bareAppField, appChat] {
                #expect(size.width == width, "pins \(pins)")
            }
            // The board over the field takes the field's width.
            #expect(
                AppChatListMetrics.size(rows: 3, width: width).width == globalField.width)
        }
    }

    @Test("General Chat, Global and an app read the one live width")
    func liveSurfacesReadTheOneWidth() {
        let live = W.current
        #expect(live >= W.base)
        #expect(CornerGeneralChatMetrics.size(for: GeneralChatWindowModel()).width == live)
        // A fresh model is Global Context; its board and its shell share the width.
        let global = AppChatPromptModel(conversation: AppChatConversation())
        #expect(M.boardWidth(for: global) == live)
        #expect(M.shellSize(for: global, phase: .dock).width <= live)
        #expect(M.shellSize(for: global, phase: .prompt).width == live)
        global.summon(app: "TextEdit", bundleID: "com.apple.TextEdit")
        #expect(M.boardWidth(for: global) == live)
        #expect(M.shellSize(for: global, phase: .prompt).width == live)
    }

    @Test("The launcher's width holds for a handful of pins, then grows a pin's span per pin, then caps")
    func pinsGrowTheWidthThenCap() {
        // The Dock's bar, inside its 660 window: the two shells' bars are one size.
        #expect(W.base == 600)
        #expect(W.dockWindowWidth == 660)
        #expect(M.fieldHeight(global: true) == 56 && M.fieldHeight(global: false) == 56)
        #expect(W.pinSpan == M.dockIconSize + M.dockIconGap)
        let fixed = (0...30).filter { W.width(pins: $0, screenBudget: budget) == W.base }
        #expect(fixed.first == 0)
        #expect(fixed.count >= 6, "a handful of pins never moves the launcher")
        #expect(fixed == Array(0...(fixed.count - 1)))
        // Past them, a pin is never dropped: one pin's span each.
        let first = fixed.count
        for pins in (first + 1)...(first + 6) {
            #expect(
                W.width(pins: pins, screenBudget: budget)
                    == W.width(pins: pins - 1, screenBudget: budget) + W.pinSpan)
        }
        #expect(W.width(pins: first, screenBudget: budget) > W.base)
        // A bar widget pins wider than an icon, by exactly what it draws beyond one.
        let crowded = first + 2
        #expect(
            W.width(pins: crowded, pinnedExtraWidth: 60, screenBudget: budget)
                == W.width(pins: crowded, screenBudget: budget) + 60)

        let cap = W.width(pins: first + 2, screenBudget: budget) + W.pinSpan / 2
        #expect(W.width(pins: first + 3, screenBudget: cap) == cap)
        #expect(W.width(pins: 80, screenBudget: cap) == cap)
        // Never below the base, however small the screen.
        #expect(W.width(pins: 40, screenBudget: 100) == W.base)
    }

    @Test("Running apps never change the open field's width; at rest the dock fits its icons, up to it")
    func runningAppsDoNotMoveTheShell() {
        let width = W.width(pins: 2, screenBudget: budget)
        var fields: Set<CGFloat> = []
        var previousDock: CGFloat = 0
        for running in 0...30 {
            for tools in 1...3 {
                let layout = M.dockLayout(
                    running: running, pinned: 2, tools: tools, maximumWidth: budget,
                    fieldIcons: M.matchIconBaseCount, shellWidth: width)
                // Compact: exactly what is drawn, and never past the launcher's width —
                // what does not fit is `+N`.
                let drawn = M.dockSearchStubSpan + 2 * M.dockInset
                    + CGFloat(max(1, layout.shownRunning + (layout.overflow > 0 ? 1 : 0)))
                    * (M.dockIconSize + M.dockIconGap) - M.dockIconGap
                    + layout.trailingRegion
                #expect(abs(drawn - layout.width) < 0.001, "running \(running), tools \(tools)")
                #expect(layout.width <= width)
                #expect(layout.shownRunning + layout.overflow == running)
            }
            let dock = M.size(
                for: .dock, suggestions: 0, running: running, pinned: 2, tools: 1,
                maximumWidth: budget, shellWidth: width
            ).width
            #expect(dock >= previousDock, "the resting dock grows with what runs")
            #expect(dock <= width)
            previousDock = dock
            fields.insert(
                M.size(
                    for: .prompt, suggestions: 0, running: running, pinned: 2, tools: 1,
                    promptIcons: M.matchIconBaseCount, maximumWidth: budget,
                    shellWidth: width
                ).width)
        }
        #expect(fields == [width])
        // Few apps: a dock no wider than its icons; many: the launcher's width, at most.
        #expect(
            M.size(
                for: .dock, suggestions: 0, running: 2, pinned: 0, tools: 1,
                maximumWidth: budget, shellWidth: width
            ).width < width)
        // The field's pills are fixed too.
        #expect(AppChatPromptModel.pillFieldCapacity == M.matchIconBaseCount)
        #expect(M.runningPillWidth == M.pillWidth(icons: M.matchIconBaseCount, overflow: true))
    }

    @Test("An app's bar pill fits its icons, up to the cap, past which they scroll")
    func theAppBarPillFitsItsIcons() {
        let one = M.appBarPillWidth(visibleIcons: 1, divider: false)
        #expect(one == M.appBarPillWidth(icons: 1, divider: false))
        var previous: CGFloat = 0
        for icons in 1...12 {
            let width = M.appBarPillWidth(visibleIcons: icons, divider: false)
            #expect(width >= previous)
            #expect(width <= M.appBarFixedPillWidth)
            previous = width
        }
        #expect(M.appBarPillWidth(visibleIcons: 12, divider: true) == M.appBarFixedPillWidth)
    }

    @Test("The shell has room for the app field's chip, text and bar at its base")
    func theBaseHoldsEveryField() {
        // An app's field: the original 372 of chip, text and controls, plus its bar.
        #expect(W.base >= M.width + M.appBarPillSpacing + M.appBarFixedPillWidth)
        // Global's field: the magnifier, the text, the fixed pill and the shelf.
        let shelf = M.dockDividerSpan + M.dockIconSize
        #expect(M.fieldMinimumWidth(icons: M.matchIconBaseCount) + shelf <= W.base)
    }

    // MARK: The field grows upward

    @Test("The field is one line, then two, then three, and stays at three")
    func theFieldGrowsToThreeLines() {
        let line = DockFieldLines.lineHeight
        #expect(line > 10 && line < 30)
        let heights = (1...8).map { lines in
            DockFieldLines.fieldHeight(
                base: M.dockHeight,
                lines: DockFieldLines.lines(measuredTextHeight: CGFloat(lines) * line))
        }
        #expect(heights[0] == M.dockHeight)
        #expect(heights[1] == M.dockHeight + line)
        #expect(heights[2] == M.dockHeight + 2 * line)
        #expect(heights[3...].allSatisfy { $0 == heights[2] })
        // A few points of inset either way are not another line.
        #expect(DockFieldLines.lines(measuredTextHeight: line + 3) == 1)
        #expect(DockFieldLines.lines(measuredTextHeight: 2 * line - 3) == 2)
        #expect(DockFieldLines.lines(measuredTextHeight: 0) == 1)
    }

    @Test("Growing taller never changes the width, in any surface")
    func growingIsUpwardOnly() {
        let width = W.width(pins: 1, screenBudget: budget)
        for lines in 1...5 {
            let global = M.size(
                for: .prompt, suggestions: 0, running: 5, pinned: 1, tools: 1,
                fieldHeight: M.dockHeight, maximumWidth: budget, shellWidth: width,
                fieldLines: lines)
            let app = M.size(
                for: .prompt, suggestions: 0, fieldHeight: M.dockHeight, fitsContent: true,
                shellWidth: width, fieldLines: lines)
            #expect(global.width == width && app.width == width)
            #expect(global.height == DockFieldLines.fieldHeight(base: M.dockHeight, lines: lines))
            #expect(app.height == global.height)
        }
        // General's composer row follows the same rule from the same height.
        #expect(
            CornerGeneralChatMetrics.composerHeight(hasAttachments: false, lines: 3)
                == CornerGeneralChatMetrics.composerHeight(hasAttachments: false)
                    + 2 * DockFieldLines.lineHeight)
    }
}
