// CommandApprovalCard.swift
// Context-Dock
//
// The inline "Run command?" card, and the rule for putting it in the transcript exactly once.
//
// Why a rule is needed: `LauncherView.body` gives `.onReceive` a freshly erased
// `TerminalAIBridge.$pendingApproval` on every evaluation, and a `Published` publisher replays
// its current value to each new subscriber. The handler therefore runs again every time the
// view re-renders while a command is waiting. Appending the card unconditionally made each
// run publish the transcript, re-render the view and run the handler again — an unbounded
// loop on the main thread that left the app unable to quit (#145).
//
// The fix is idempotence, not a throttle: the card takes the pending command's own id, and a
// handler appends it only when no message with that id is in the transcript yet.

import Foundation

enum CommandApprovalCard {
    /// The card for `pending`. Its message id IS the pending command's id, so "is this card
    /// already shown" is an identity check rather than a guess from the command text.
    static func message(for pending: TerminalAIBridge.PendingCommand) -> AIChatMessage {
        message(
            id: pending.id, command: pending.command, purpose: pending.purpose,
            risk: pending.classification.riskLevel.displayName)
    }

    static func message(id: UUID, command: String, purpose: String, risk: String) -> AIChatMessage {
        AIChatMessage(
            id: id, role: .approval, content: command,
            structuredData: "\(purpose)|||/\(risk)")
    }

    /// True when the transcript already carries the card for `id`.
    static func isShown(id: UUID, in messages: [AIChatMessage]) -> Bool {
        messages.contains { $0.id == id }
    }
}
