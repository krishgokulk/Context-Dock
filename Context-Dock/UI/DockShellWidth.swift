// DockShellWidth.swift
// Context-Dock
//
// The one width every Corner surface is drawn at (#189).
//
// Global Context, every app's Context Dock, General Chat and the boards above them used to
// take three different widths: Global grew with the running apps and the pins, an app's
// field fitted its own bar, and General stood at a card's width. Switching between them
// looked like the window changing rather than the subject. Now there is one number, set by
// the launcher's own width: Spotlight's, the size the Dock already is (owner 2026-10-05:
// "the perfect size of Raycast / Spotlight"). Running apps live in a fixed-width pill that
// scrolls, a long prompt grows the field upward, and switching mode only cross-fades what
// is inside.

import AppKit
import CoreGraphics

enum DockShellWidth {
    /// The launcher's width: Spotlight's, and the Dock's (`LauncherView.expandedDockWidth`
    /// reads this), so the two shells are one size. Wide enough for an app's field — its
    /// chip, text and bar — with room to spare.
    static let base: CGFloat = 660

    /// What one more pin costs: one dock icon and the gap after it — what the strip draws
    /// for it.
    static var pinSpan: CGFloat { AppChatPromptMetrics.dockIconSize + AppChatPromptMetrics.dockIconGap }

    /// The launcher's width, whatever is pinned — until the pins alone would not fit beside
    /// the magnifier, one app and the shelf. Then it grows by one pin's span per pin, because
    /// a pin is never dropped. Capped at the screen budget.
    ///
    /// Pure: counts in, width out. `pins` is every pin the strip draws — pinned apps and the
    /// rest alike, since each takes one slot. `pinnedExtraWidth` is what a pinned plugin's
    /// bar widget takes beyond its one icon. Running apps are deliberately not an input.
    static func width(pins: Int, pinnedExtraWidth: CGFloat = 0, screenBudget: CGFloat) -> CGFloat {
        typealias M = AppChatPromptMetrics
        let pinsNeed = M.dockSearchStubSpan + 2 * M.dockInset + pinSpan  // magnifier, one app
            + M.dockDividerSpan + CGFloat(max(0, pins)) * pinSpan + max(0, pinnedExtraWidth)
            + M.dockDividerSpan + M.dockIconSize  // the shelf
        let grown = max(base, pinsNeed)
        // Never below the base, even on a budget smaller than it: a tiny display still
        // draws the whole field and lets the strip's row overflow instead.
        return min(grown, max(base, screenBudget))
    }

    /// The same number read from a composed row: only its pins count.
    static func width(for composition: DockStripComposition, screenBudget: CGFloat) -> CGFloat {
        width(
            pins: composition.pinnedAppCount + composition.otherPins.count,
            pinnedExtraWidth: composition.widgetExtraWidth, screenBudget: screenBudget)
    }

    /// The width right now, from the user's pins on the screen the corner is on. What every
    /// surface reads — Global's strip and field, an app's Context Dock, General Chat and
    /// the boards above them.
    @MainActor
    static var current: CGFloat { DockStripPlan.shellWidth }
}

/// How tall a field stands for what is typed in it (#189): one line, then two, then three,
/// then the text scrolls inside. The width never changes; the field grows from its bottom
/// edge, so its baseline stays where it was.
enum DockFieldLines {
    static let maximum = 3

    /// One line of the fields' 14-point medium text.
    static let lineHeight: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14, weight: .medium)))

    /// How many lines a text view of this height holds, between one and `maximum`. Rounded,
    /// so a few points of inset either way do not tip it into the next line.
    static func lines(measuredTextHeight height: CGFloat) -> Int {
        guard height.isFinite, height > 0 else { return 1 }
        return min(maximum, max(1, Int((height / lineHeight).rounded())))
    }

    /// What the field adds to its one-line height for `lines` lines.
    static func extraHeight(lines: Int) -> CGFloat {
        CGFloat(min(maximum, max(1, lines)) - 1) * lineHeight
    }

    /// The field's height for `lines` lines, from its one-line height.
    static func fieldHeight(base: CGFloat, lines: Int) -> CGFloat {
        base + extraHeight(lines: lines)
    }
}
