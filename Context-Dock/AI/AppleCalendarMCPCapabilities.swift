import Foundation

// First-party Apple Calendar capabilities registered in CapabilityRegistry.
// Wraps AppleAppsAPI (EventKit) methods — no AppleScript required.
// Risk levels:
//   calendar.today   → .low  (read-only, no approval)
//   calendar.list    → .low  (read-only, no approval)
//   calendar.search  → .low  (read-only, no approval)
//   calendar.create  → .medium (approval required before writing)

@MainActor
enum AppleCalendarMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerToday(registry)
        registerNext(registry)
        registerList(registry)
        registerSearch(registry)
        registerCreate(registry)
        registerUpdate(registry)
        registerDelete(registry)
    }

    // MARK: - calendar.update

    private static func registerUpdate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.update",
                title: "Update Calendar Event",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: [
                    .init(name: "matchTitle", description: "Title (or part of it) of the event to update", required: true),
                    .init(name: "newTitle", description: "New title", required: false),
                    .init(name: "newStartDate", description: "New start (ISO 8601)", required: false),
                    .init(name: "durationMinutes", description: "New duration in minutes", required: false),
                    .init(name: "location", description: "New location", required: false),
                    .init(name: "notes", description: "New notes", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                guard let match = request.input["matchTitle"], !match.isEmpty else {
                    throw AICapabilityError.missingInput("matchTitle")
                }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                let newStart = request.input["newStartDate"].flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                let newEnd = newStart.flatMap { s -> Date? in
                    guard let mins = Int(request.input["durationMinutes"] ?? "") else { return nil }
                    return s.addingTimeInterval(TimeInterval(max(1, mins) * 60))
                }
                let updated = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: AppleAppsAPI.shared.updateEvent(
                            matchingTitle: match,
                            newTitle: request.input["newTitle"],
                            newStart: newStart, newEnd: newEnd,
                            newLocation: request.input["location"],
                            newNotes: request.input["notes"]))
                    }
                }
                return .init(
                    success: updated != nil,
                    output: updated.map { "Updated event '\($0)'." }
                        ?? "No event matching '\(match)' found in the next few months.")
            }
        )
    }

    // MARK: - calendar.delete

    private static func registerDelete(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.delete",
                title: "Delete Calendar Event",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: [
                    .init(name: "matchTitle", description: "Title (or part of it) of the event to delete", required: true)
                ]),
                riskLevel: .high
            ) { request in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                guard let match = request.input["matchTitle"], !match.isEmpty else {
                    throw AICapabilityError.missingInput("matchTitle")
                }
                let deleted = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: AppleAppsAPI.shared.deleteEvent(matchingTitle: match))
                    }
                }
                return .init(
                    success: deleted != nil,
                    output: deleted.map { "Deleted event '\($0)'." }
                        ?? "No event matching '\(match)' found.")
            }
        )
    }

    // MARK: - calendar.next

    private static func registerNext(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.next",
                title: "Get Next Calendar Event",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                let event = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getNextEvent())
                    }
                }
                guard let ev = event else {
                    return .init(success: true, output: "No upcoming events found.")
                }
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                let title = ev["title"] as? String ?? "Untitled"
                let start = (ev["startDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                let when = start.map { df.string(from: $0) } ?? "?"
                let location = (ev["location"] as? String).flatMap { $0.isEmpty ? nil : " @ \($0)" } ?? ""
                return .init(success: true, output: "Next: \(title) — \(when)\(location)")
            }
        )
    }

    // MARK: - calendar.today

    private static func registerToday(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.today",
                title: "Get Today's Calendar Events",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                let events = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getTodayEvents())
                    }
                }
                if events.isEmpty {
                    return .init(success: true, output: "No events scheduled for today.")
                }
                let df = DateFormatter()
                df.dateStyle = .none
                df.timeStyle = .short
                let lines = events.map { ev -> String in
                    let title = ev["title"] as? String ?? "Untitled"
                    let allDay = ev["isAllDay"] as? Bool ?? false
                    if allDay { return "• \(title) (all day)" }
                    let start = (ev["startDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let end = (ev["endDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let startStr = start.map { df.string(from: $0) } ?? "?"
                    let endStr = end.map { df.string(from: $0) } ?? "?"
                    return "• \(title) (\(startStr)–\(endStr))"
                }
                return .init(success: true, output: "Today's events (\(events.count)):\n\(lines.joined(separator: "\n"))")
            }
        )
    }

    // MARK: - calendar.list

    private static func registerList(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.list",
                title: "List Upcoming Calendar Events",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: [
                    .init(name: "days", description: "Number of days ahead to look (default 7)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                let days = Int(request.input["days"] ?? "7") ?? 7
                let start = Date()
                let end = Calendar.current.date(byAdding: .day, value: max(1, min(days, 90)), to: start) ?? start
                let events = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getEvents(from: start, to: end))
                    }
                }
                if events.isEmpty {
                    return .init(success: true, output: "No events in the next \(days) day(s).")
                }
                let df = DateFormatter()
                df.dateStyle = .short
                df.timeStyle = .short
                let lines = events.prefix(30).map { ev -> String in
                    let title = ev["title"] as? String ?? "Untitled"
                    let allDay = ev["isAllDay"] as? Bool ?? false
                    if allDay {
                        let d = (ev["startDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                        let dStr = d.map { df.string(from: $0) } ?? "?"
                        return "• \(title) — \(dStr) (all day)"
                    }
                    let d = (ev["startDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let dStr = d.map { df.string(from: $0) } ?? "?"
                    return "• \(title) — \(dStr)"
                }
                return .init(success: true, output: "Upcoming events (\(min(events.count, 30)) shown):\n\(lines.joined(separator: "\n"))")
            }
        )
    }

    // MARK: - calendar.search

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.search",
                title: "Search Calendar Events",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Search term matching event title, location, or notes", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                guard let query = request.input["query"], !query.isEmpty else {
                    throw AICapabilityError.missingInput("query")
                }
                let events = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.searchEvents(query: query, limit: 20))
                    }
                }
                if events.isEmpty {
                    return .init(success: true, output: "No events found matching '\(query)'.")
                }
                let df = DateFormatter()
                df.dateStyle = .short
                df.timeStyle = .short
                let lines = events.map { ev -> String in
                    let title = ev["title"] as? String ?? "Untitled"
                    let d = (ev["startDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let dStr = d.map { df.string(from: $0) } ?? "?"
                    let loc = ev["location"] as? String ?? ""
                    return loc.isEmpty ? "• \(title) — \(dStr)" : "• \(title) — \(dStr) @ \(loc)"
                }
                return .init(success: true, output: "Events matching '\(query)' (\(events.count)):\n\(lines.joined(separator: "\n"))")
            }
        )
    }

    // MARK: - calendar.create

    private static func registerCreate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "calendar.create",
                title: "Create Calendar Event",
                appBundleID: "com.apple.iCal",
                inputSchema: .init(fields: [
                    .init(name: "title", description: "Event title", required: true),
                    .init(name: "startDate", description: "Start date/time in ISO 8601 format (e.g. 2026-07-04T14:00:00)", required: true),
                    .init(name: "durationMinutes", description: "Duration in minutes (default 60)", required: false),
                    .init(name: "location", description: "Optional event location", required: false),
                    .init(name: "notes", description: "Optional event notes", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.calendarMCPEnabled else {
                    throw AICapabilityError.blocked("Calendar access is disabled in Settings.")
                }
                guard let title = request.input["title"], !title.isEmpty else {
                    throw AICapabilityError.missingInput("title")
                }
                guard let startStr = request.input["startDate"], !startStr.isEmpty else {
                    throw AICapabilityError.missingInput("startDate")
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                guard let startDate = formatter.date(from: startStr) ?? ISO8601DateFormatter().date(from: startStr) else {
                    return .init(success: false, output: "Invalid startDate format. Use ISO 8601 (e.g. 2026-07-04T14:00:00Z).")
                }
                let minutes = Int(request.input["durationMinutes"] ?? "60") ?? 60
                let endDate = startDate.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
                let location = request.input["location"]
                let notes = request.input["notes"]

                let success = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.createEvent(
                            title: title,
                            startDate: startDate,
                            endDate: endDate,
                            notes: notes,
                            location: location
                        ))
                    }
                }
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                let startFormatted = df.string(from: startDate)
                return .init(
                    success: success,
                    output: success
                        ? "Created event '\(title)' on \(startFormatted) (\(minutes) min)."
                        : "Failed to create event. Grant Calendar access in System Settings › Privacy › Calendars."
                )
            }
        )
    }
}
