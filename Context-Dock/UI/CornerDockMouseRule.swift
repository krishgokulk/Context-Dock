// CornerDockMouseRule.swift
// Context-Dock
//
// The shell spans the width of the screen so its strip and cards have room to move, but the
// only part of it that is ever drawn is the cards. Hit-testing alone does not let the rest
// through: a view answering nil stops *our* content reacting, yet the window is still the
// frontmost thing under the pointer, so AppKit hands it the click and the app underneath
// never sees it. That is how a clipboard notice on the corner made the app in front
// unusable (#143). Only `ignoresMouseEvents` lets the click land where it was aimed, so it
// follows the pointer: on while the pointer is off every card, off while it is on one.
//
// The rule lives here, apart from the window, so it can be tested without one.

import CoreGraphics

enum CornerDockMouseRule {
    /// Whether the window should let mouse events through to whatever is beneath it.
    ///
    /// - Parameters:
    ///   - pointer: the pointer in screen coordinates.
    ///   - cards: everything the shell draws or answers for, in screen coordinates.
    ///   - slack: how far outside a card still counts as on it, so an edge-resting pointer
    ///     does not flicker between the two states.
    ///   - autoHidden: the shell is slid away; nothing of it may take a click.
    static func shouldIgnoreMouse(
        pointer: CGPoint, cards: [CGRect], slack: CGFloat, autoHidden: Bool
    ) -> Bool {
        if autoHidden { return true }
        return !cards.contains { $0.insetBy(dx: -slack, dy: -slack).contains(pointer) }
    }
}
