// DockShortcut.swift
// Context-Dock
//
// The keyword shortcuts in `handleL2Query` run before any model and used to leave no
// trace, so when one claimed a turn the panel still said "Answered without running anything"
// (issue #198, plan §3). Each shortcut that claims a turn now names itself with one step in
// the same trace the tool loop uses — `dockTraceStep` → `L2State.routerTrace` →
// `AppChatConversation.shared.liveSteps`, the list `CornerLivePanel` and the Dock both read.
//
// The line reads "Shortcut: <name> — matched '<rule>'" (plan §3). It is not a new router and
// not a new step mechanism: it only labels a claim the dispatcher already makes. Pure, so the
// Dock and the Corner (both run `handleL2Query`) share it and `DockShortcutTests` pins each
// family's label.

import Foundation

/// One pre-model keyword shortcut that may claim a turn in `handleL2Query`.
enum DockShortcut: String, CaseIterable, Sendable {
    case triggerRule
    case systemCommand
    case githubInstall
    case appFind
    case transformShare
    case finder
    case messages
    case mailboxSearch
    case crossApp
    case appAction
    case appLaunch
    case safariCommand

    /// The name shown in the step ("Shortcut: Mailbox Search — …").
    var displayName: String {
        switch self {
        case .triggerRule: return "Trigger Rule"
        case .systemCommand: return "System Command"
        case .githubInstall: return "GitHub Install"
        case .appFind: return "App Find"
        case .transformShare: return "Transform & Share"
        case .finder: return "Finder"
        case .messages: return "Messages"
        case .mailboxSearch: return "Mailbox Search"
        case .crossApp: return "Cross-App"
        case .appAction: return "App Action"
        case .appLaunch: return "App Launch"
        case .safariCommand: return "Safari Command"
        }
    }

    /// The rule that matched, in the user's own terms — what the sentence had to be for this
    /// shortcut to claim the turn (Task 17: an exact command, not a word sitting in a sentence).
    var matchedRule: String {
        switch self {
        case .triggerRule: return "a saved trigger phrase"
        case .systemCommand: return "a built-in system command"
        case .githubInstall: return "link a GitHub tool"
        case .appFind: return "find … in this app"
        case .transformShare: return "transform this and send it"
        case .finder: return "a Finder folder request"
        case .messages: return "message … to someone"
        case .mailboxSearch: return "search mail …"
        case .crossApp: return "send/open this in another app"
        case .appAction: return "a global app action"
        case .appLaunch: return "open an app"
        case .safariCommand: return "a Safari command"
        }
    }

    /// The one step this shortcut adds to the turn's trace.
    var step: String { "Shortcut: \(displayName) — matched '\(matchedRule)'" }
}
