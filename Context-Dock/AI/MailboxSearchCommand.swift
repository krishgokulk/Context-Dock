// MailboxSearchCommand.swift
// Context-Dock
//
// When Mail's Mailbox Search shortcut may take a turn before any model reads it (issue #195).
//
// Typed in Mail App Chat, "check my recent mail from Gokula kannan J and do what it says"
// clicked Edit › Find › Mailbox Search and typed "check my recent gokula kannan j and do what
// it says" into Mail's search field. The old test was word presence: "from" made any sentence
// a sender search. The panel then said nothing had run.
//
// This is Task 17's rule ("exact command or the model", `ScopedRoutePolicy`) for the one
// keyword shortcut that skipped it. The shortcut claims the turn only when the sentence IS
// the search command and its value — a search verb first, optionally the mail noun and one
// field word, then a short term or a quoted one, and nothing after it:
//
//     search mail from SBI            → Mailbox Search, sender "SBI"
//     find mail from SBI today        → the model (a date is a filter Mailbox Search can't take)
//     check my recent mail from … and do what it says → the model
//
// Like `ExactCommand`, a value rides along with its command; a second clause, a date, a
// qualifier or a long description does not. Everything else goes to the model, which has
// `mail.search(sender:)` and `mail.read` and can do what the sentence actually asks.
//
// Pure, so the Dock and the Corner (both run `handleL2Query`) share it and
// `MailboxSearchCommandTests` pins it.

import Foundation

enum MailboxSearchCommand {

    enum Field: Equatable, Sendable {
        case any, sender, subject, attachment
    }

    struct Parsed: Equatable, Sendable {
        /// What goes into Mail's search field, in the user's own casing.
        let term: String
        let field: Field
    }

    /// The longest unquoted term that is still a search value rather than a description.
    static let maxTermWords = 4

    /// Verbs that make the sentence a search command, longest first.
    private static let verbs: [[String]] = [
        ["search", "for"], ["look", "for"], ["look", "up"], ["search"], ["lookup"], ["find"],
    ]

    /// What may sit between the verb and the value: "search *my inbox* for …".
    private static let scopeWords: Set<String> = [
        "my", "the", "in", "through", "all", "mail", "mails", "email", "emails", "mailbox",
        "inbox",
    ]

    /// The one field word allowed before the value.
    private static let fieldWords: [String: Field] = [
        "from": .sender, "sender": .sender, "subject": .subject, "titled": .subject,
        "attachment": .attachment, "attachments": .attachment,
        "for": .any, "about": .any, "with": .any,
    ]

    /// Words that make the "value" a request: a date or qualifier (a filter the search field
    /// cannot take), a second clause, or a second field.
    private static let requestWords: Set<String> = [
        // dates and qualifiers
        "today", "yesterday", "tomorrow", "tonight", "recent", "recently", "latest", "newest",
        "oldest", "last", "this", "past", "week", "month", "year", "unread", "new", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "morning",
        "afternoon", "evening", "ago", "since", "before", "after",
        // a second clause
        "and", "then", "or", "but", "that", "which", "who", "whose", "what", "where", "when",
        "if", "it", "says", "say", "said", "do", "reply", "read", "open", "summarize", "tell",
        "show", "check",
        // a second field
        "from", "sender", "subject", "about", "to",
    ]

    /// The search this sentence commands, or nil when the model should take the turn.
    static func claims(_ sentence: String) -> Parsed? {
        guard !MailQuestionRouter.isQuestionShaped(sentence) else { return nil }
        return parse(sentence)
    }

    static func parse(_ sentence: String) -> Parsed? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A quoted value is taken whole: `search mail for "invoice and receipt"`.
        var quoted: String?
        var commandPart = trimmed
        if let open = trimmed.firstIndex(where: { "\"“".contains($0) }) {
            let rest = trimmed[trimmed.index(after: open)...]
            guard let close = rest.firstIndex(where: { "\"”".contains($0) }) else { return nil }
            let after = rest[rest.index(after: close)...]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard after.isEmpty else { return nil }
            quoted = String(rest[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            commandPart = String(trimmed[..<open])
        }

        var words = commandPart
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" && $0 != "@" && $0 != "." }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        var lowered: [String] { words.map { $0.lowercased() } }

        if lowered.first == "please" { words.removeFirst() }

        guard let verb = verbs.first(where: { lowered.starts(with: $0) }) else { return nil }
        words.removeFirst(verb.count)

        while let first = lowered.first, scopeWords.contains(first) { words.removeFirst() }

        var field = Field.any
        if let first = lowered.first, let named = fieldWords[first] {
            field = named
            words.removeFirst()
            // "search mail for subject payslip": a generic word, then the real field.
            if named == .any, let next = lowered.first, let real = fieldWords[next], real != .any {
                field = real
                words.removeFirst()
            }
        }

        if let quoted {
            guard words.isEmpty, !quoted.isEmpty else { return nil }
            return Parsed(term: quoted, field: field)
        }

        guard !words.isEmpty, words.count <= maxTermWords,
            !lowered.contains(where: requestWords.contains)
        else { return nil }
        return Parsed(term: words.joined(separator: " "), field: field)
    }
}
