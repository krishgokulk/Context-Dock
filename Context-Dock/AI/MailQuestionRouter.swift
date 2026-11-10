// MailQuestionRouter.swift
// Context-Dock
//
// Whether a message typed into a Mail-scoped chat is asking about the mailbox.
//
// Question *shape* says the sentence is asking something. Mailbox *subject* says it is asking
// about mail. Keeping the two halves separate lets a Mail-scoped chat answer greetings ("hi
// hello?", "how are you?", "what's 2+2?") conversationally while grounding real mailbox
// questions ("any unread mail?", "who sent this message?", "what's the subject line?") in live
// Mail readers (`mail.recent`, `mail.read`, `mail.search`, `mail.unread`, `mail.currentMessage`).

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

    /// Whether a sentence in the Mail scope is asking a question about the mailbox's records
    /// (as opposed to a greeting like "hi hello?" or a write command like "delete this email").
    static func isMailboxQuestion(_ query: String) -> Bool {
        isQuestionShaped(query) && mentionsMailbox(query)
    }
}
