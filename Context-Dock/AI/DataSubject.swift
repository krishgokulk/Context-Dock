//
//  DataSubject.swift
//  Context-Dock
//
//  What the sentence is actually looking for.
//
//  Siri, asked "find my bookmarks note and summarise that", searched Notes, found three
//  candidates and asked which one. DoraX listed fifteen recent notes, because it chose its
//  search term like this:
//
//      let nameGuess = query.split(separator: " ").map(String.init)
//          .filter { $0.first?.isUppercase ?? false }
//          .max(by: { $0.count < $1.count }) ?? ""
//
//  The term was whichever capitalised word was longest. Typed in lower case there is no
//  term at all, so the search never ran — with "bookmarks" sitting in the sentence, unused.
//  Two words of a name lost the shorter half, too.
//
//  This is not the interesting half of what Siri does. Apple's assistant can enumerate
//  another app's entities because those apps declare them to the system; DoraX cannot, and
//  reaches Apple's apps through AppleAppsAPI and everything else through adapters. That
//  difference is real and not fixable here. Choosing the right word to search for is.
//

import Foundation

enum DataSubject {

    /// Words that say what to do, or where to look, rather than what to look for.
    private static let notSubject: Set<String> = [
        // asking
        "find", "show", "list", "get", "open", "search", "look", "lookup", "fetch",
        "read", "check", "tell", "give", "pull", "bring", "please", "me", "my", "our",
        "your", "the", "a", "an", "and", "or", "that", "this", "these", "those", "it",
        "them", "for", "of", "in", "on", "at", "to", "from", "with", "about", "any",
        "all", "some", "what", "whats", "which", "where", "who", "is", "are", "do",
        "does", "did", "can", "could", "would", "you", "i",
        // doing something with what was found
        // "review" and "summary" are left in: they are nouns far more often than verbs in
        // the name of a thing — "quarterly review notes" is a name, and stripping it left
        // half of one. A stray "review my notes" searching for "review" costs a read.
        "summarise", "summarize", "explain", "send", "share", "print", "copy",
        // where to look — the domain, not the subject
        "note", "notes", "reminder", "reminders", "task", "tasks", "todo",
        "calendar", "event", "events", "meeting", "appointment", "email", "emails",
        "mail", "inbox", "message", "messages", "photo", "photos", "picture",
        "pictures", "contact", "contacts", "file", "files", "document", "documents",
        // when, not what
        "today", "todays", "tomorrow", "yesterday", "week", "month", "year", "recent",
        "latest", "last", "upcoming", "now",
    ]

    /// The subject of the request — the words left once the instruction and the domain are
    /// taken out. Empty when the sentence names no subject ("show my notes"), which is the
    /// signal to list recent items rather than to search for nothing.
    static func subject(in query: String) -> String {
        let words = query
            .lowercased()
            .replacingOccurrences(of: "'s", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !notSubject.contains($0) }
        return words.joined(separator: " ")
    }
}
