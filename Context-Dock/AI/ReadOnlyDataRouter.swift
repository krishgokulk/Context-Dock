// ReadOnlyDataRouter.swift
// Context-Dock
//
// Whether a message is asking to read one of the user's personal data sources.
//
// Pure string work, and it used to sit on LauncherView — a view with four hundred @State
// properties, which meant the one decision that routes a request between "read this" and
// "do this" could not be exercised without standing up the whole surface. It decided wrong
// for `create a reminder "call mum" today at 5pm`, answering "You have no open reminders",
// and nothing could have caught that but a person typing it.
//
// The view still asks the same question through the same method name. It just no longer
// owns the answer.

import Foundation

enum ReadOnlyDataDomain: String, Equatable {
    case messages, mail, calendar, reminders, contacts, notes, photos
    var displayName: String {
        switch self {
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .notes: return "Notes"
        case .photos: return "Photos"
        }
    }
    /// macOS-style one-line justification shown under the approval prompt.
    var approvalSubtitle: String {
        switch self {
        case .messages: return "DoraX will read your unread messages to answer this request."
        case .mail: return "DoraX will read your Mail to answer this request."
        case .calendar: return "DoraX will read your upcoming events."
        case .reminders: return "DoraX will read your reminders."
        case .contacts: return "DoraX will read your contacts to answer this request."
        case .notes: return "DoraX will read your notes to answer this request."
        case .photos: return "DoraX will read photo metadata to answer your request."
        }
    }
}

@MainActor
enum ReadOnlyDataRouter {

    /// Classify a message as a read-only request against one personal-data source, or nil.
    /// Requires BOTH a data-source keyword AND a read/possessive signal so plain questions
    /// ("what is email?") don't trip it. Never runs AX or the provider — pure string match.
    static func domain(for query: String) -> ReadOnlyDataDomain? {
        let q = query.lowercased()
        let readSignals = [
            "my ", "any ", "unread", "recent", "upcoming", "do i have", "did i",
            "show ", "show me", "find ", "lookup ", "look up ", "get ", "list ",
            "check ", "what's on", "whats on", "how many", "this week", "today",
            "tomorrow", "latest",
        ]
        guard readSignals.contains(where: q.contains) else { return nil }
        // A read signal is not proof of a read. `create a reminder "call sujith" today at
        // 5pm` carries "today", names the reminders domain, and was answered "You have no
        // open reminders" — the write never ran, and the reply was about the wrong thing
        // entirely. Anything that also asks for a change belongs to executable routing.
        guard !GeneralAIActionResolver.shared.requestsChange(q) else { return nil }
        if looksLikeContactInfoLookup(q) {
            return .contacts
        }
        let map: [(ReadOnlyDataDomain, [String])] = [
            (.messages, ["message", "imessage", "text from", "texts", "unread text"]),
            (.contacts, ["contact", "phone number", "email address of"]),
            (.mail, ["email", "mail", "inbox"]),
            (.calendar, ["calendar", "event", "meeting", "schedule", "appointment"]),
            (.reminders, ["reminder", "to-do", "todo", "task"]),
            (.notes, ["note about", "notes about", "my note", "my notes"]),
            (.photos, ["photo", "picture", "screenshot", "image of mine"]),
        ]
        for (domain, keywords) in map where keywords.contains(where: q.contains) {
            return domain
        }
        return nil
    }

    private static func looksLikeContactInfoLookup(_ q: String) -> Bool {
        let wantsContactField = [
            " contact", "contacts", "phone", "number", "mobile", "email", "mail id",
            "email id", "address book",
        ].contains { q.contains($0) }
        guard wantsContactField else { return false }

        // Mailbox queries should stay in Mail. A person-info query like
        // "show salmankhan email" has no mailbox noun/action, so route to Contacts.
        let mailboxSignals = [
            "inbox", "unread", "latest email", "recent email", "emails from",
            "mail from", "message from", "subject", "attachment", "newsletter",
        ]
        if mailboxSignals.contains(where: q.contains) { return false }

        let personLookupSignals = [
            "show ", "find ", "lookup ", "look up ", "get ", "what is ", "what's ",
            "whats ", "who is ", "contact info", "email of", "phone of",
        ]
        return personLookupSignals.contains(where: q.contains)
    }
}
