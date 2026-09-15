// MailQuestionRouter.swift
// Context-Dock
//
// Whether a message typed into a Mail-scoped chat is asking about the mailbox.
//
// The Mail scope refused to answer "hi hello?" — it replied "Attach Mail context with the +
// button first, then ask again." The test was `rawScopedQuery.contains("?")`, so every
// question was a mail question: "how are you?", "what's 2+2?", any greeting with a question
// mark. A scope is not supposed to stop being a chat.
//
// The two halves were being conflated. Question *shape* says the sentence is asking something.
// Mailbox *subject* says it is asking about mail. Demanding attached context needs both; a
// question already sitting on an attached message needs only the first, because "who sent
// this?" names no mail noun and is obviously about the message on screen.
//
// Pure string work, extracted from LauncherView for the reason ReadOnlyDataRouter was: a view
// with four hundred @State properties cannot be stood up in a test, so the decision that
// silences the chat could not be exercised at all.

import Foundation

enum MailQuestionRouter {

    /// The sentence is asking something, whatever it is about.
    static func isQuestionShaped(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("?") { return true }
        let questionPrefixes = [
            "is", "are", "do", "does", "did", "have", "has", "what", "which", "who", "when",
            "where", "why", "how", "can", "could", "would", "should", "any", "show me",
            "tell me",
        ]
        if questionPrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") })
        {
            return true
        }
        return normalized.contains("any mail")
            || normalized.contains("any mails")
            || normalized.contains("there any")
    }

    /// The sentence is about the mailbox — it names mail, or something only mail has.
    ///
    /// Deliberately about nouns rather than question words. A greeting, a maths question and a
    /// request for a joke are all questions, and none of them wants the inbox read.
    static func mentionsMailbox(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let nouns = [
            "mail", "email", "e-mail", "inbox", "mailbox", "message", "sender", "sent",
            "unread", "attachment", "subject line", "reply", "replies", "draft", "junk",
            "spam", "archive", "flagged", "cc", "bcc", "recipient", "thread",
        ]
        if nouns.contains(where: normalized.contains) { return true }
        // "from Sarah" and "about the invoice" are how people name a message without using a
        // mail word at all. Only counted when the sentence is also asking something, so a
        // passing mention in a longer instruction does not drag the whole turn into Mail.
        if isQuestionShaped(normalized) {
            return normalized.contains("from ") || normalized.contains("who wrote")
        }
        return false
    }

    /// Whether the chat should stop and ask the user to attach Mail context.
    ///
    /// Both halves, and only when nothing is attached yet. Getting this wrong in the
    /// permissive direction is what made the Mail scope decline to say hello.
    static func needsAttachedMailContext(
        query: String, isMailContextAttached: Bool
    ) -> Bool {
        guard !isMailContextAttached else { return false }
        return isQuestionShaped(query) && mentionsMailbox(query)
    }
}
