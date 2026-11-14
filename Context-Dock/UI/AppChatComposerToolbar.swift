// AppChatComposerToolbar.swift
// Context-Dock
//
// The App Pet composer's lower row, the way Claude lays out its composer: the text on top,
// and under it who the chat is with and which model answers — the app chip, the provider
// chip (#335) and "+" — so switching provider is one click where the user is already
// typing, not a trip to the header (owner 2026-11-12).
//
// Pure rule, so the view and the tests read one answer. The view itself is drawn by
// `AppChatPromptPill` (it needs that view's private chip and attach menu).

import CoreGraphics

enum AppChatComposerToolbar {
    /// The lower row's height inside the composer, below the field row. The chat card's
    /// height is unchanged (`AppChatPromptMetrics.chatHeight` keeps App and General one
    /// surface); the transcript gives up this much instead.
    static let rowHeight: CGFloat = 34

    /// Whether the composer draws its lower row — and with it, the provider chip moves out of
    /// the header.
    ///
    /// Only an App Pet conversation: the frontmost app's own chat (`phase == .chat`), not a
    /// search field (Global Context, or a tool/command stepped into from it), not the
    /// clipboard board, and not a field with no app behind it. Every other phase keeps the
    /// single Siri-size field row (#432).
    static func shows(
        phase: AppChatPromptPhase,
        isSearchField: Bool,
        isClipboardScope: Bool,
        appBundleID: String
    ) -> Bool {
        phase == .chat && !isSearchField && !isClipboardScope && !appBundleID.isEmpty
    }
}
