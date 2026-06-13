// EventKitTools.swift
// Context-Dock
//
// FoundationModels Tool wrappers for Calendar, Reminders, Contacts, Photos, and Notes.
// All implementations delegate to AppleAppsAPI.shared which manages EKEventStore,
// CNContactStore, and PHPhotoLibrary with their existing permission flows.
// Available in both global chat mode and context-dock mode for any frontmost app.

#if canImport(FoundationModels)
import FoundationModels
import Foundation
import AppKit

// MARK: - GetCalendarEventsTool

@available(macOS 26.0, *)
struct GetCalendarEventsTool: Tool {
    let name = "get_calendar_events"
    let description = """
        Read calendar events. Supported filters:
        • "today" — events today
        • "tomorrow" — events tomorrow
        • "week" — events this week
        • "search:<query>" — find events by title, location, or notes
        Always call this before answering any question about the user's schedule.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Filter: 'today', 'tomorrow', 'week', or 'search:<query>' to find events matching text.")
        var filter: String

        init() { self.filter = "today" }
    }

    func call(arguments: Arguments) async throws -> String {
        let filter = arguments.filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if filter.hasPrefix("search:") {
            let query = String(filter.dropFirst("search:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let events = AppleAppsAPI.shared.searchEvents(query: query, limit: 20)
            if events.isEmpty { return "No calendar events found matching '\(query)'." }
            return Self.format(events: events)
        }

        let cal = Calendar.current
        let now = Date()

        let events: [[String: Any]]
        switch filter {
        case "tomorrow":
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let endOfTomorrow = cal.date(byAdding: .day, value: 1, to: tomorrow)!
            events = AppleAppsAPI.shared.getEvents(from: tomorrow, to: endOfTomorrow)
        case "week":
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart)!
            events = AppleAppsAPI.shared.getEvents(from: weekStart, to: weekEnd)
        default:
            events = AppleAppsAPI.shared.getTodayEvents()
        }

        if events.isEmpty { return "No calendar events for \(filter)." }
        return Self.format(events: events)
    }

    private static func format(events: [[String: Any]]) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateStyle = .short
        timeFmt.timeStyle = .short
        let isoFmt = ISO8601DateFormatter()
        return events.map { ev in
            let title = ev["title"] as? String ?? "Untitled"
            let start = (ev["startDate"] as? String).flatMap { isoFmt.date(from: $0) }.map { timeFmt.string(from: $0) } ?? ""
            let end = (ev["endDate"] as? String).flatMap { isoFmt.date(from: $0) }.map { timeFmt.string(from: $0) } ?? ""
            let loc = (ev["location"] as? String).map { " @ \($0)" } ?? ""
            let isAllDay = ev["isAllDay"] as? Bool ?? false
            let timeStr = isAllDay ? "all day" : (start.isEmpty ? "" : "\(start) – \(end)")
            return "• \(title)\(loc) [\(timeStr)]"
        }.joined(separator: "\n")
    }
}

// MARK: - AddCalendarEventTool

@available(macOS 26.0, *)
struct AddCalendarEventTool: Tool {
    let name = "add_calendar_event"
    let description = "Create a new calendar event. Provide title, start time in ISO8601 (e.g. 2026-06-09T16:00:00), optional duration in minutes (default 60), optional location, and optional notes."

    @Generable
    struct Arguments {
        @Guide(description: "Event title.")
        var title: String

        @Guide(description: "Start time in ISO8601 format, e.g. 2026-06-09T16:00:00.")
        var startISO8601: String

        @Guide(description: "Duration in minutes. Default 60.")
        var durationMinutes: Int

        @Guide(description: "Optional location.")
        var location: String

        @Guide(description: "Optional notes.")
        var notes: String

        init() {
            self.title = ""
            self.startISO8601 = ISO8601DateFormatter().string(from: Date())
            self.durationMinutes = 60
            self.location = ""
            self.notes = ""
        }
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "❌ Event title is required." }

        guard let startDate = Self.parseDate(arguments.startISO8601) else {
            return "❌ Could not parse start time '\(arguments.startISO8601)'. Use ISO8601 format, e.g. 2026-06-09T16:00:00."
        }

        let duration = max(1, arguments.durationMinutes)
        let endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))
        let loc: String? = arguments.location.isEmpty ? nil : arguments.location
        let notes: String? = arguments.notes.isEmpty ? nil : arguments.notes

        let success = AppleAppsAPI.shared.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: notes,
            location: loc
        )

        if success {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return "✅ Created '\(title)' at \(fmt.string(from: startDate))."
        }
        return "❌ Failed to create calendar event. Grant Calendar access in System Settings > Privacy & Security."
    }

    private static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - GetRemindersTool

@available(macOS 26.0, *)
struct GetRemindersTool: Tool {
    let name = "get_reminders"
    let description = "List reminders. Use filter 'all' for all incomplete reminders, 'overdue' for past-due items, or 'today' for reminders due today."

    @Generable
    struct Arguments {
        @Guide(description: "Filter: 'all', 'overdue', or 'today'. Default: all.")
        var filter: String

        @Guide(description: "Maximum number of reminders to return. Default 20.")
        var limit: Int

        init() { self.filter = "all"; self.limit = 20 }
    }

    func call(arguments: Arguments) async throws -> String {
        let filter = arguments.filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let limit = max(1, min(arguments.limit, 100))

        var reminders: [[String: Any]]
        switch filter {
        case "overdue":
            reminders = AppleAppsAPI.shared.getOverdueReminders()
        default:
            reminders = AppleAppsAPI.shared.getReminders(limit: filter == "today" ? 200 : limit)
        }

        if filter == "today" {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            let isoFmt = ISO8601DateFormatter()
            reminders = reminders.filter { r in
                guard let s = r["dueDate"] as? String, let d = isoFmt.date(from: s)
                else { return false }
                return d >= today && d < tomorrow
            }
        }

        if reminders.isEmpty { return "No reminders for filter '\(filter)'." }

        let isoFmt = ISO8601DateFormatter()
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .short
        dateFmt.timeStyle = .short

        return reminders.prefix(limit).map { r in
            let title = r["title"] as? String ?? "Untitled"
            var line = "• \(title)"
            if let s = r["dueDate"] as? String, let d = isoFmt.date(from: s) {
                line += " (due \(dateFmt.string(from: d)))"
            }
            if let notes = r["notes"] as? String, !notes.isEmpty {
                line += " — \(notes)"
            }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - AddReminderTool

@available(macOS 26.0, *)
struct AddReminderTool: Tool {
    let name = "add_reminder"
    let description = "Create a new reminder with a title. Opens Reminders — user sees it immediately."

    @Generable
    struct Arguments {
        @Guide(description: "Reminder title.")
        var title: String

        init() { self.title = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "❌ Reminder title required." }
        let success = AppleAppsAPI.shared.createReminder(title: title)
        return success
            ? "✅ Reminder created: '\(title)'"
            : "❌ Failed to create reminder. Grant Reminders access in System Settings > Privacy & Security."
    }
}

// MARK: - SearchContactsTool

@available(macOS 26.0, *)
struct SearchContactsTool: Tool {
    let name = "search_contacts"
    let description = "Search the user's Contacts by name, email, or phone. Returns name, email, and phone number for each match."

    @Generable
    struct Arguments {
        @Guide(description: "Name, email address, phone, or company to search for.")
        var query: String

        init() { self.query = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "❌ Provide a search query." }

        let contacts = AppleAppsAPI.shared.searchContacts(query: query)
        if contacts.isEmpty { return "No contacts found for '\(query)'." }

        return contacts.prefix(10).map { c in
            let name = c["fullName"] as? String ?? (c["name"] as? String ?? "Unknown")
            var parts = [name]
            if let email = c["email"] as? String, !email.isEmpty { parts.append(email) }
            if let phone = c["phone"] as? String, !phone.isEmpty { parts.append(phone) }
            return "• " + parts.joined(separator: " | ")
        }.joined(separator: "\n")
    }
}

// MARK: - SearchPhotosTool

@available(macOS 26.0, *)
struct SearchPhotosTool: Tool {
    let name = "search_photos"
    let description = "Search the user's Photos library by filename keyword. Returns filename and date. Useful when the user asks about a specific photo or says 'find photos of X'."

    @Generable
    struct Arguments {
        @Guide(description: "Keyword, subject, or filename substring to search in Photos.")
        var query: String

        @Guide(description: "Maximum number of results. Default 10.")
        var limit: Int

        init() { self.query = ""; self.limit = 10 }
    }

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = AppleAppsAPI.shared.searchPhotos(query: query, limit: max(1, min(arguments.limit, 30)))
        if photos.isEmpty { return "No photos found\(query.isEmpty ? "" : " for '\(query)'"  )." }

        let isoFmt = ISO8601DateFormatter()
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .none

        return photos.map { p in
            let filename = p["filename"] as? String ?? "Photo"
            let dateStr = (p["created"] as? String).flatMap { isoFmt.date(from: $0) }.map { dateFmt.string(from: $0) } ?? ""
            let fav = (p["favorite"] as? Bool == true) ? " ★" : ""
            return "• \(filename)\(fav)\(dateStr.isEmpty ? "" : " (\(dateStr))")"
        }.joined(separator: "\n")
    }
}

// MARK: - SearchNotesTool

@available(macOS 26.0, *)
struct SearchNotesTool: Tool {
    let name = "search_notes"
    let description = "Search Apple Notes by keyword. Returns note title and a short content preview. Use when the user asks about notes they wrote."

    @Generable
    struct Arguments {
        @Guide(description: "Keyword or phrase to search in note titles and content. Leave empty to list recent notes.")
        var query: String

        init() { self.query = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes: [[String: Any]] = query.isEmpty
            ? AppleAppsAPI.shared.getNotes(limit: 10)
            : AppleAppsAPI.shared.searchNotes(query: query)

        if notes.isEmpty { return query.isEmpty ? "No recent notes found." : "No notes found for '\(query)'." }

        return notes.prefix(10).map { n in
            let title = n["title"] as? String ?? "Untitled"
            let body = (n["body"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let preview = body.isEmpty ? "" : ": \(String(body.prefix(100)))…"
            return "• \(title)\(preview)"
        }.joined(separator: "\n")
    }
}

// MARK: - CreateNoteTool

@available(macOS 26.0, *)
struct CreateNoteTool: Tool {
    let name = "create_note"
    let description = "Create a new note in Apple Notes with a title and body. Use when the user asks to save, write down, or note something."

    @Generable
    struct Arguments {
        @Guide(description: "Note title.")
        var title: String

        @Guide(description: "Note body content.")
        var body: String

        init() { self.title = ""; self.body = "" }
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = arguments.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return "❌ Provide a title or body for the note." }
        let success = AppleAppsAPI.shared.createNote(
            title: title.isEmpty ? "New Note" : title,
            body: body
        )
        return success ? "✅ Note '\(title.isEmpty ? "New Note" : title)' created in Notes." : "❌ Failed to create note."
    }
}

#endif // canImport(FoundationModels)
