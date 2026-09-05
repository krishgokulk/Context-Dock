// SearchCandidateEligibility.swift
// Context-Dock
//
// Which of the launcher's own items are handed to the scorer.
//
// `allItems` is apps, CLI tools, Global Commands and Global Extensions. The scorer used to
// be given `allItems.filter { $0.type == .application || $0.type == .cliTool }`, which drops
// every `.extensionCommand` — the type both Global Commands and Global Extensions carry. An
// item that is never scored is rebuilt into no row, so neither could be selected and neither
// could run.
//
// It read as deliberate and was not: `SearchCandidateKind` has carried an `extensionCommand`
// case with a ranking priority the whole time. The scorer was always meant to rank these; the
// filter never delivered one.
//
// Files, contacts, calendar events and the rest are absent because they arrive through their
// own indexed pipeline and are scored beside these, not from this pool — admitting them here
// would rank the same item twice.

import Foundation

enum SearchCandidateEligibility {

    /// True when an item from `allItems` should be scored against the query.
    ///
    /// Exhaustive on purpose: a new `ResultType` should not quietly inherit an answer.
    static func isSearchable(_ type: SearchResult.ResultType) -> Bool {
        switch type {
        case .application, .cliTool, .extensionCommand:
            return true
        case .shortcut, .file, .folder, .document, .contact, .calendarEvent,
            .reminder, .note, .mail, .photo, .message, .webSearch:
            return false
        }
    }
}
