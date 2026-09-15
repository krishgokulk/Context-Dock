// AppChatSelectionScope.swift
// Context-Dock
//
// What the corner's question will carry besides the question: the selection in the app it is
// scoped to.
//
// The dock has always shown this. The corner did not read selection at all, so a question
// asked over highlighted text looked identical to one asked over nothing — and the user had
// no way to tell which of the two they were about to send.
//
// Read from `AXContextReader`, the same snapshot the turn itself is built from, so the chip
// cannot claim a selection the turn will not carry.

import AppKit
import Foundation

/// A selection, described the way the user would describe it.
struct AppChatSelectionScope: Equatable {
    enum Kind: Equatable {
        case text(characters: Int)
        case files(count: Int)
    }

    let kind: Kind

    var icon: String {
        switch kind {
        case .text: return "text.cursor"
        case .files: return "doc.on.doc"
        }
    }

    /// Short enough for a chip in a 372-point field.
    var label: String {
        switch kind {
        case .text(let characters):
            return characters == 1 ? "1 char" : "\(characters) chars"
        case .files(let count):
            return count == 1 ? "1 file" : "\(count) files"
        }
    }

    /// The selection in `context`, but only when it belongs to the app the corner is about.
    ///
    /// The corner opening is itself an app switch, and the reader's snapshot can be of
    /// something else entirely — so a selection is only shown when the snapshot and the
    /// scope agree on which app they are talking about. Anything else would attribute one
    /// app's highlighted text to another app's question.
    static func from(context: AXContext, scopedTo bundleID: String) -> AppChatSelectionScope? {
        guard !bundleID.isEmpty, context.bundleId == bundleID else { return nil }

        if !context.selectedFilePaths.isEmpty {
            return AppChatSelectionScope(kind: .files(count: context.selectedFilePaths.count))
        }
        let text = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        return AppChatSelectionScope(kind: .text(characters: text.count))
    }
}
