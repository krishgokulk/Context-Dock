// ChatFollowUp.swift
// Context-Dock
//
// The one next step an answer earned, if it earned one.
//
// An assistant that ends every answer with "anything else?" is asking the user to do the
// thinking it was brought in for. But most answers genuinely have no next step, and a
// surface that always shows a suggestion has to invent one — which is worse, because an
// invented next step looks exactly like a considered one.
//
// So follow-ups are derived from what actually ran, not asked of the model. Finding three
// sets of duplicates has an obvious next move; explaining dependency injection does not,
// and gets nothing. Deriving them here also means a follow-up can never propose something
// that did not happen: it is built from the console's record of completed work, so the
// evidence for the suggestion is the same evidence the user can read.

import Foundation

struct ChatFollowUp: Equatable {
    /// What the button says — an action, in the user's words.
    let title: String
    /// What gets asked when it is pressed. A question the user could have typed, so the
    /// conversation reads the same whether they clicked or wrote it.
    let prompt: String
}

extension ChatFollowUp {

    /// At most one suggestion, from the last thing this conversation actually did.
    ///
    /// Only the last action is considered. Offering a follow-up to something three steps
    /// back reads as the assistant having lost its place, and two suggestions at once is a
    /// menu — the point of this is that there is one obvious next move or none.
    @MainActor
    static func suggestion(for scope: GeneralChatScope) -> ChatFollowUp? {
        guard let last = ChatConsoleLog.shared.entries(for: scope).last(where: { !$0.isRunning }),
            last.success
        else { return nil }

        let title = last.title.lowercased()
        let output = last.output

        // Found something to clean up, and said how much. The number is what makes the
        // offer worth making, so it is not offered when the run found nothing.
        if title.contains("duplicate"), !output.contains("No duplicate") {
            return ChatFollowUp(
                title: "Move the extra copies to Trash",
                prompt: "Move the duplicate copies you found to the Trash, keeping one of each.")
        }
        if title.contains("stale"), !output.contains("Nothing in") {
            return ChatFollowUp(
                title: "Show the oldest in Finder",
                prompt: "Show the largest of those untouched files in Finder.")
        }
        if title.contains("foldersize") || title.contains("diskspace") {
            return ChatFollowUp(
                title: "Find what's taking the space",
                prompt: "What are the biggest things in there, and what could I delete?")
        }
        // An app that is now closed is one the user may want back — the only follow-up
        // worth offering after a quit, and only because it is exactly reversible.
        if title.contains("quit"), output.contains("no longer running") {
            let app = last.title
                .replacingOccurrences(of: "(?i)quit ", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty else { return nil }
            return ChatFollowUp(title: "Reopen \(app)", prompt: "Open \(app) again.")
        }
        return nil
    }
}
