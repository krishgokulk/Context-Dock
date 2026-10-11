// LauncherKeyHandlers.swift
// Context-Dock
//
// The dock's key handling, as one modifier instead of eleven chained ones.
//
// The second half of the same compiler problem `LauncherApprovalSubscriptions` addresses,
// and it exists for the same reason: `contentKeyHandlersView` ended in `.onExitCommand`
// followed by ten `.onKeyPress` calls, each wrapping its input in another opaque type. After
// the subscriptions came out of `LauncherView.body`, this is what the compiler printed while
// aborting — `View extension.onKeyPress(_:action:)` nested into itself, over and over.
//
// A `ViewModifier` is nominal, so the eleven layers move inside this struct's own body, which
// is a different function to lower. No `AnyView`, no erasure, no change to what runs: the
// handlers are the same closures, in the same order, and SwiftUI still sees eleven
// modifiers — it just sees them one level down.
//
// Order is load-bearing and is fixed here rather than at the call site. SwiftUI delivers a
// key press to the innermost matching handler first, and several of these return `.ignored`
// deliberately so a later one can take the press. Reordering the properties of this struct
// does nothing; reordering the calls in `body` changes behaviour.
import SwiftUI

struct LauncherKeyHandlers: ViewModifier {
    let onExitCommand: () -> Void
    let onUpArrow: () -> KeyPress.Result
    let onDownArrow: () -> KeyPress.Result
    let onSpace: () -> KeyPress.Result
    let onY: (KeyPress) -> KeyPress.Result
    let onReturn: () -> KeyPress.Result
    let onTab: () -> KeyPress.Result
    let onEscape: () -> KeyPress.Result
    let onDelete: () -> KeyPress.Result
    let onLeftArrow: () -> KeyPress.Result
    let onRightArrow: () -> KeyPress.Result

    func body(content: Content) -> some View {
        content
            .onExitCommand(perform: onExitCommand)
            .onKeyPress(.upArrow, action: onUpArrow)
            .onKeyPress(.downArrow, action: onDownArrow)
            .onKeyPress(.space, action: onSpace)
            .onKeyPress(keys: [.init("y")], phases: .down, action: onY)
            .onKeyPress(.return, action: onReturn)
            .onKeyPress(.tab, action: onTab)
            .onKeyPress(.escape, action: onEscape)
            .onKeyPress(.delete, action: onDelete)
            .onKeyPress(.leftArrow, action: onLeftArrow)
            .onKeyPress(.rightArrow, action: onRightArrow)
    }
}
