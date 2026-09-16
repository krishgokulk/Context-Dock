// AppleLiveDataContext.swift
// Context-Dock
//
// Live data from the built-in Apple apps — Calendar events, Reminders, Notes, Contacts,
// Mail, Messages — plus current weather, as a prompt block.
//
// This is the difference between "I can't see your reminders" and "you have 1 today at
// 3pm". It read nothing from LauncherView, but living there meant only the dock could
// use it, so the chat window's Reminders thread had capability lists and no data. Same
// reader, both surfaces.

import AppKit
import Foundation

@MainActor
enum AppleLiveDataContext {

    static func appleAppsContextBlock(for query: String) async -> String {
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
            let subject = DataSubject.subject(in: query)
            let notes =
                subject.isEmpty ? api.getNotes(limit: 15) : api.searchNotes(query: subject)
            if !notes.isEmpty {
                let lines = notes.prefix(15).map { n -> String in
                    let title = (n["title"] as? String) ?? "(untitled)"
                    let body = ((n["body"] as? String) ?? "").prefix(120)
                    return body.isEmpty ? "- \(title)" : "- \(title): \(body)"
                }.joined(separator: "\n")
                blocks.append("## Notes — matches:\n\(lines)")
            }
        }

        if ["email", "mail", "inbox", "message from"].contains(where: q.contains) {
            let emails = api.getRecentEmails(limit: 12)
            if !emails.isEmpty {
                let lines = emails.prefix(12).map { e -> String in
                    let subject = (e["subject"] as? String) ?? "(no subject)"
                    let sender = (e["sender"] as? String) ?? ""
                    let unread = (e["read"] as? Bool ?? true) ? "" : " [unread]"
                    return "- \(subject) — \(sender)\(unread)"
                }.joined(separator: "\n")
                blocks.append("## Mail — recent inbox:\n\(lines)")
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

    static func appleAppsAndWeatherContext(for query: String) async -> String {
        var block = await appleAppsContextBlock(for: query)
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
