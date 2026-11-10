// AppleLiveDataContext.swift
// Context-Dock
//
// Live data from the built-in Apple apps — Calendar events, Reminders, Notes, Contacts,
// Mail, Messages — plus current weather, as a prompt block.
//
// This is the difference between "I can't see your reminders" and "you have 1 today at
// 3pm". It read nothing from DockCore, but living there meant only the dock could
// use it, so the chat window's Reminders thread had capability lists and no data. Same
// reader, both surfaces.

import AppKit
import Foundation

@MainActor
enum AppleLiveDataContext {

    /// What to search Notes for. "Notes with links" asks for notes that CONTAIN links, and no
    /// note says the word "links", so a subject made only of link words searches for "http".
    nonisolated static func noteSearchTerm(for query: String) -> String {
        let subject = DataSubject.subject(in: query)
        let linkWords: Set<String> = ["link", "links", "url", "urls", "hyperlink", "hyperlinks"]
        let words = subject.split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy(linkWords.contains) ? "http" : subject
    }

    /// Whether the sentence asks for a total. A search returns a bounded page, so the total is
    /// read separately — a provider with no tools cannot call `notes.count` itself.
    nonisolated static func asksForNoteTotal(_ query: String) -> Bool {
        let q = query.lowercased()
        return ["how many", "count ", "number of"].contains(where: q.contains)
    }

    /// The matches as prompt lines. Titles and bodies pass through `NotePreviewRedaction`: this
    /// block goes to the provider, and a note can hold a token or a password.
    nonisolated static func noteLines(_ notes: [[String: Any]]) -> String {
        notes.map { n -> String in
            let title = NotePreviewRedaction.redact((n["title"] as? String) ?? "(untitled)")
            let body = NotePreviewRedaction.redact(String(((n["body"] as? String) ?? "").prefix(120)))
            return body.isEmpty ? "- \(title)" : "- \(title): \(body)"
        }.joined(separator: "\n")
    }

    /// Whether the query asks for Mail inbox context to be pre-fetched into the prompt block.
    nonisolated static func wantsMailContext(_ query: String) -> Bool {
        let q = query.lowercased()
        return ["email", "mail", "e-mail", "inbox", "mailbox", "message from", "subject line"]
            .contains(where: q.contains)
    }

    /// What a Mail sentence asks to search for: a sender ("… from SBI"), or a term that may be
    /// either sender or subject ("search for invoice"), and an optional day.
    struct MailSearchIntent: Equatable {
        let sender: String
        let term: String
        let day: String
        var label: String { sender.isEmpty ? term : "from \(sender)" }
    }

    /// Words `DataSubject` leaves in that are still not a name or a topic in a Mail sentence.
    private static let notAMailTerm: Set<String> = [
        "mails", "unread", "new", "sender", "subject", "up", "there", "have", "has", "got",
        "get", "sent", "received", "attachment", "attachments", "titled", "regarding",
        "morning", "afternoon", "evening", "tonight", "ago", "since", "before", "after",
        "earlier", "anything", "something", "how", "many", "much",
        "window", "app", "application", "menu", "menus", "command", "commands",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    /// The search a Mail sentence names, or nil when it names none (the recent inbox is the
    /// answer then). A provider with no tool protocol cannot call `search_mail`; without this,
    /// "look for emails from SBI" was answered from the twelve newest headers, none of them
    /// from SBI, as "a full Mail search wasn't readable".
    ///
    /// A sender is whatever follows "from". A free term is taken only from a look-up sentence
    /// ("search …", "look for …") or after "about": a question such as "how many emails did I
    /// get this morning?" names no term, and searching for "morning" would report a false
    /// "no matches". A write ("reply to the mail from Sarah") is never a search.
    static func mailSearchIntent(for query: String) -> MailSearchIntent? {
        guard !ScopedRecordRead.hasExplicitAction(query) else { return nil }
        let lower = query.lowercased()
        let day = lower.contains("today") ? "today" : lower.contains("yesterday") ? "yesterday" : ""
        func term(_ text: String, maxWords: Int) -> String? {
            let words = DataSubject.subject(in: text).split(separator: " ").map(String.init)
                .filter { !notAMailTerm.contains($0) }
            // The words are searched as one phrase, so more than a few is a description that
            // no header contains word for word.
            return words.isEmpty || words.count > maxWords ? nil : words.joined(separator: " ")
        }
        if let from = lower.range(of: #"\bfrom\s+"#, options: .regularExpression) {
            var tail = String(lower[from.upperBound...])
            // An address is the sender as written; splitting it on punctuation loses it.
            if let first = tail.split(separator: " ").first, first.contains("@") {
                let address = first.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;:<>\"'"))
                return MailSearchIntent(sender: address, term: "", day: day)
            }
            for stop in [" and ", " then ", " about ", " regarding ", " with ", " that ", " who ", " whose "] {
                if let cut = tail.range(of: stop) { tail = String(tail[..<cut.lowerBound]) }
            }
            return term(tail, maxWords: 4).map { MailSearchIntent(sender: $0, term: "", day: day) }
        }
        let isLookUp = lower.range(
            of: #"\b(search|find|list|look for|look up|lookup)\b|\b(about|regarding)\s"#,
            options: .regularExpression) != nil
        guard isLookUp else { return nil }
        return term(lower, maxWords: 2).map { MailSearchIntent(sender: "", term: $0, day: day) }
    }

    /// A Mail search typed in Mail's own chat. It is answered in the transcript from a headless
    /// read (the prefetch below); no shortcut may drive Mail's window for it (owner, 2026-10-10).
    static func isInScopeMailSearch(_ query: String, scopedBundleId: String) -> Bool {
        scopedBundleId.lowercased() == "com.apple.mail" && mailSearchIntent(for: query) != nil
    }

    /// The filters for a `mail.search` / `search_mail` call. The `query` input is not always a
    /// bare term: the scoped route (`ChatRouteResolver.execute`) puts the user's whole sentence
    /// in it, so "search mail from uel" was searched for verbatim and matched nothing. A
    /// sentence is read with `mailSearchIntent`; anything else goes to
    /// `MailAutomation.searchFilters`. An explicit sender, subject or day always wins.
    static func mailSearchFilters(query: String, sender: String, subject: String, day: String)
        -> (sender: String, subject: String, any: String, day: String)
    {
        if sender.isEmpty, subject.isEmpty, let intent = mailSearchIntent(for: query) {
            return (intent.sender, "", intent.term, day.isEmpty ? intent.day : day)
        }
        let filters = MailAutomation.searchFilters(query: query, sender: sender, subject: subject)
        return (filters.sender, filters.subject, filters.any, day)
    }

    /// The prompt block for a mailbox search that already ran. Nil when the mailbox could not
    /// be read — that is not "no matches", and the caller falls back to the recent inbox.
    static func mailSearchBlock(label: String, summary: String) -> String? {
        var lines = summary.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("Mailbox: ") else { return nil }
        let mailbox = String(first.dropFirst("Mailbox: ".count))
        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty || body == "Mail context could not be read." { return nil }
        if body == "No matching messages found." {
            return "## Mail — no messages match \"\(label)\" in the \(mailbox) mailbox. The search "
                + "ran (sender and subject were checked for exactly that text); say that nothing "
                + "matched \"\(label)\" there, not that the search could not be run. If "
                + "\"\(label)\" is not what the user meant, answer from the rest of this data."
        }
        return "## Mail — search matches for \"\(label)\" (\(mailbox) mailbox, already searched):\n"
            + UntrustedContent.fenced(body, from: "Mail message headers")
            + "\nThese are the search results; answer from them. Only headers are listed."
            // mail.read resolves an id in the inbox only.
            + (mailbox.lowercased().contains("inbox")
                ? " To read a message's text, call mail.read with an Id from this list." : "")
    }

    /// - Parameter scopeBundleId: the app the chat is scoped to. In Mail's own chat a search
    ///   sentence need not say "mail" ("search from SBI") to be about the mailbox.
    static func appleAppsContextBlock(for query: String, scopeBundleId: String? = nil) async
        -> String
    {
        let q = query.lowercased()
        let api = AppleAppsAPI.shared
        var blocks: [String] = []

        let iso = ISO8601DateFormatter()
        let human = DateFormatter()
        human.dateFormat = "EEE d MMM yyyy, h:mm a"
        func fmt(_ isoString: Any?) -> String {
            guard let s = isoString as? String, let d = iso.date(from: s) else { return "" }
            return human.string(from: d)
        }

        let wantsEvents =
            ["event", "calendar", "meeting", "appointment", "schedule", "agenda", "busy",
             "free time", "plan", "tomorrow", "today", "this week", "next week", "coming week",
             "weekend"].contains { q.contains($0) }
        if wantsEvents {
            // Span the whole current month (incl. earlier days) through the next ~2 months so
            // "this month", "this week", and specific-date questions all resolve accurately.
            let cal = Calendar.current
            let monthStart =
                cal.date(from: cal.dateComponents([.year, .month], from: Date()))
                ?? cal.startOfDay(for: Date())
            let start = min(monthStart, cal.date(byAdding: .day, value: -7, to: Date()) ?? monthStart)
            let end = cal.date(byAdding: .day, value: 60, to: cal.startOfDay(for: Date())) ?? Date()
            let events = api.getEvents(from: start, to: end)
            if events.isEmpty {
                blocks.append("## Calendar (this month → next 60 days): no events.")
            } else {
                // Cap at 30 — on-device Foundation Models has a small context window; a huge
                // event dump overflows it and the model returns nothing.
                let lines = events.prefix(30).map { ev -> String in
                    let title = (ev["title"] as? String) ?? "(untitled)"
                    let when =
                        (ev["isAllDay"] as? Bool ?? false)
                        ? "All day \(fmt(ev["startDate"]))" : fmt(ev["startDate"])
                    let loc = (ev["location"] as? String).map { " @ \($0)" } ?? ""
                    return "- \(when): \(title)\(loc)"
                }.joined(separator: "\n")
                blocks.append(
                    "## Calendar (this month → next 60 days) — real events:\n\(lines)")
            }
        }

        if ["reminder", "todo", "to-do", "to do", "due"].contains(where: q.contains) {
            let reminders = api.getReminders(limit: 30)
            if reminders.isEmpty {
                blocks.append("## Reminders: none open.")
            } else {
                let lines = reminders.prefix(30).map { r -> String in
                    let title = (r["title"] as? String) ?? "(untitled)"
                    let due = fmt(r["dueDate"])
                    return due.isEmpty ? "- \(title)" : "- \(title) (due \(due))"
                }.joined(separator: "\n")
                blocks.append("## Reminders — open items:\n\(lines)")
            }
        }

        if ["contact", "phone number", "email of", "number of", "call ", "phone of"]
            .contains(where: q.contains)
        {
            let contacts = await ContactSearchManager.shared.rankedContacts(matching: query, limit: 12)
            if !contacts.isEmpty {
                let lines = contacts.prefix(10).map { c -> String in
                    var parts = [c.fullName.isEmpty ? "(no name)" : c.fullName]
                    if !c.nickname.isEmpty { parts.append("aka \(c.nickname)") }
                    if !c.organizationName.isEmpty { parts.append(c.organizationName) }
                    if !c.primaryPhone.isEmpty { parts.append("📞 \(c.primaryPhone)") }
                    if !c.primaryEmail.isEmpty { parts.append("✉️ \(c.primaryEmail)") }
                    return "- " + parts.joined(separator: " — ")
                }.joined(separator: "\n")
                blocks.append("## Contacts — best full-database matches:\n\(lines)")
            }
        }

        if ["photo", "picture", "screenshot"].contains(where: q.contains) {
            let photos = api.getRecentPhotos(limit: 10)
            if !photos.isEmpty {
                blocks.append("## Photos — \(photos.count) recent items in the library.")
            }
        }

        if ["note", "notes"].contains(where: q.contains) {
            // The search term used to be whichever capitalised word was longest, so a
            // sentence typed in lower case had no term at all and this listed recent notes
            // instead of searching — with the subject sitting in the sentence, unused.
            // "find my bookmarks note and summarise that" is the reported case.
            let subject = noteSearchTerm(for: query)
            let notes =
                subject.isEmpty ? api.getNotes(limit: 15) : api.searchNotes(query: subject)
            if asksForNoteTotal(query), AppSettings.shared.noteMCPEnabled,
                let total = try? await AppleNotesMCPServer.shared.noteCount()
            {
                blocks.append("## Notes — total: \(total) notes in total.")
            }
            if !notes.isEmpty {
                let lines = noteLines(Array(notes.prefix(15)))
                blocks.append("## Notes — matches:\n\(lines)")
            }
        }

        // A named sender or term is searched for here, before the model, so the answer is
        // grounded for every provider — including the ones that cannot call search_mail.
        var mailSearchFoundMatches = false
        let mailIntent = mailSearchIntent(for: query)
        let wantsMail = wantsMailContext(q)
            || (scopeBundleId?.lowercased() == "com.apple.mail" && mailIntent != nil)
        // Only when Mail is already running: a read never launches an app.
        if wantsMail, AppSettings.shared.mailMCPEnabled,
            AppleAppsAPI.isRunning("com.apple.mail"), let intent = mailIntent
        {
            let summary = await Task.detached(priority: .userInitiated) {
                MailAutomation.mailboxSnapshot(
                    senderContains: intent.sender, anyContains: intent.term,
                    relativeDay: intent.day, limit: 15)
            }.value
            if let block = mailSearchBlock(label: intent.label, summary: summary) {
                blocks.append(block)
                mailSearchFoundMatches = block.contains("search matches for")
            }
        }

        if wantsMail, !mailSearchFoundMatches {
            let emails = api.getRecentEmails(limit: 12)
            // Headers only. Bodies are never in this block, so say where they are: without
            // the pointer the model answered "body not returned" and asked the user to open
            // the message by hand.
            let bodyPointer =
                "Only headers are listed here. To read a message's text, call mail.read (the "
                + "newest message, or an id from this list); mail.currentMessage reads the one "
                + "selected in Mail. Never ask the user to open a message so you can read it."
            if !emails.isEmpty {
                let lines = emails.prefix(12).map { e -> String in
                    let subject = (e["subject"] as? String) ?? "(no subject)"
                    let sender = (e["sender"] as? String) ?? ""
                    let unread = (e["read"] as? Bool ?? true) ? "" : " [unread]"
                    let id = (e["id"] as? String).flatMap { $0.isEmpty ? nil : " [id \($0)]" } ?? ""
                    return "- \(subject) — \(sender)\(unread)\(id)"
                }.joined(separator: "\n")
                blocks.append("## Mail — recent inbox:\n\(lines)\n\(bodyPointer)")
            } else if !AppleAppsAPI.isRunning("com.apple.mail") {
                blocks.append(
                    "## Mail: not running. mail.read still reads the newest message (it starts "
                        + "Mail in the background); do not say mail cannot be read.")
            }
        }

        if ["playing", "song", "music", "track", "now playing"].contains(where: q.contains) {
            let music = api.getMusicInfo()
            let title = (music["title"] as? String) ?? ""
            if !title.isEmpty {
                let artist = (music["artist"] as? String) ?? ""
                let state = (music["state"] as? String) ?? ""
                blocks.append(
                    "## Music — \(state.isEmpty ? "" : "\(state): ")\(title)"
                        + (artist.isEmpty ? "" : " by \(artist)"))
            }
        }

        if ["tab", "tabs", "safari"].contains(where: q.contains) {
            let tabs = api.getAllTabs()
            if !tabs.isEmpty {
                let lines = tabs.prefix(20).map { t -> String in
                    let title = (t["title"] as? String) ?? ""
                    let url = (t["url"] as? String) ?? ""
                    return "- \(title.isEmpty ? url : title) (\(url))"
                }.joined(separator: "\n")
                blocks.append("## Safari — open tabs:\n\(lines)")
            }
        }

        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n")
            + "\n\nAnswer the user's question directly and concisely from this real data. Do NOT"
            + " add text telling the user to open an app — the UI shows an 'Open in <App>' button"
            + " automatically."
    }

    static func appleAppsAndWeatherContext(for query: String, scopeBundleId: String? = nil)
        async -> String
    {
        var block = await appleAppsContextBlock(for: query, scopeBundleId: scopeBundleId)
        let ql = query.lowercased()
        if ["weather", "temperature", "forecast", "rain", "raining", "sunny", "humid",
            "how hot", "how cold", "degrees"].contains(where: ql.contains)
        {
            let place: String? = {
                guard let range = ql.range(of: " in ") else { return nil }
                let tail = query[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
                return tail.isEmpty ? nil : tail
            }()
            if let weather = await WeatherService.currentSummary(place: place) {
                let w = "## Weather — real current conditions:\n\(weather)"
                block = block.isEmpty ? w : block + "\n\n" + w
            }
        }
        return block
    }
}
