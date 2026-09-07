import Foundation
import EventKit

// First-party Apple Reminders capabilities registered in CapabilityRegistry.
// Wraps AppleAppsAPI (EventKit) for reads; uses EKEventStore directly for richer creates.
// Risk levels:
//   reminders.today  → .low  (read-only)
//   reminders.list   → .low  (read-only)
//   reminders.create → .medium (writes data; requires approval)

@MainActor
enum AppleRemindersMCPCapabilities {

    // MARK: - Priority, in words
    //
    // EventKit stores priority as a number with banded meaning — 0 unset, 1–4 high, 5 medium,
    // 6–9 low. Rendering the number is useless to a model asked for "the low-priority ones",
    // which is half of why that request was unanswerable.

    nonisolated static func priorityLabel(_ priority: Int) -> String? {
        switch priority {
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return nil
        }
    }

    nonisolated static func priorityValue(for name: String) -> Int? {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        case "none", "": return 0
        default: return nil
        }
    }

    /// The titles a bulk edit will touch, as the model wrote them.
    ///
    /// Pure and tested, because this is where a bulk edit quietly becomes the wrong set of
    /// records — an empty fragment from a trailing comma would otherwise match the first
    /// reminder in the store.
    nonisolated static func titles(from raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "• title — due 3 Apr, 09:00 · low" — priority only when it is set.
    nonisolated static func describe(title: String, due: String?, priority: Int) -> String {
        var line = "• \(title)"
        if let due, !due.isEmpty { line += " — due \(due)" }
        if let band = priorityLabel(priority) { line += " · \(band) priority" }
        return line
    }

    static func register(in registry: CapabilityRegistry) {
        registerToday(registry)
        registerUpdate(registry)
        registerOverdue(registry)
        registerList(registry)
        registerCreate(registry)
        registerComplete(registry)
        registerDelete(registry)
    }

    // MARK: - reminders.update

    private static func registerUpdate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.update",
                title: "Reschedule or Reprioritise Reminders",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: [
                    .init(
                        name: "titles",
                        description:
                            "Comma-separated titles of the reminders to change. Name them "
                            + "explicitly — call reminders.list or reminders.today first and "
                            + "resolve which ones the user meant, so the approval names them.",
                        required: true),
                    .init(
                        name: "dueDate",
                        description: "New due date in ISO 8601 (e.g. 2026-09-08T09:00:00)",
                        required: false),
                    .init(
                        name: "priority",
                        description: "New priority: high, medium, low, or none",
                        required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                let wanted = titles(from: request.input["titles"] ?? "")
                guard !wanted.isEmpty else {
                    throw AICapabilityError.missingInput("titles")
                }
                let dueRaw = request.input["dueDate"] ?? ""
                let due = dueRaw.isEmpty ? nil : ISO8601DateFormatter().date(from: dueRaw)
                if !dueRaw.isEmpty, due == nil {
                    throw AICapabilityError.missingInput("dueDate in ISO 8601")
                }
                let priorityRaw = request.input["priority"] ?? ""
                let priority = priorityRaw.isEmpty ? nil : priorityValue(for: priorityRaw)
                if !priorityRaw.isEmpty, priority == nil {
                    throw AICapabilityError.missingInput("priority: high, medium, low or none")
                }
                guard due != nil || priority != nil else {
                    throw AICapabilityError.missingInput("dueDate or priority — nothing to change")
                }

                let observed = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            returning: AppleAppsAPI.shared.rescheduleReminders(
                                titles: wanted, dueDate: due, priority: priority))
                    }
                }
                guard !observed.isEmpty else {
                    return .init(
                        success: false,
                        output: "Nothing was changed — no open reminder matched "
                            + wanted.map { "'\($0)'" }.joined(separator: ", ") + ".")
                }

                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let lines = observed.map { row in
                    describe(
                        title: row.title,
                        due: row.dueDate.map { formatter.string(from: $0) },
                        priority: row.priority)
                }
                // Reported from the read-back, so a reminder whose save was refused is absent
                // here rather than described as changed.
                var output = "Changed \(observed.count) of \(wanted.count):\n"
                    + lines.joined(separator: "\n")
                if observed.count < wanted.count {
                    let changed = Set(observed.map(\.title))
                    let missed = wanted.filter { want in
                        !changed.contains { $0.lowercased().contains(want.lowercased()) }
                    }
                    if !missed.isEmpty {
                        output += "\n\nNot found: " + missed.joined(separator: ", ")
                    }
                }
                return .init(success: true, output: output)
            }
        )
    }

    // MARK: - reminders.complete

    private static func registerComplete(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.complete",
                title: "Complete a Reminder",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: [
                    .init(name: "matchTitle", description: "Title (or part) of the reminder to mark done", required: true)
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                guard let match = request.input["matchTitle"], !match.isEmpty else {
                    throw AICapabilityError.missingInput("matchTitle")
                }
                let done = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: AppleAppsAPI.shared.completeReminder(matchingTitle: match))
                    }
                }
                return .init(
                    success: done != nil,
                    output: done.map { "Marked '\($0)' as complete." }
                        ?? "No open reminder matching '\(match)' found.")
            }
        )
    }

    // MARK: - reminders.delete

    private static func registerDelete(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.delete",
                title: "Delete a Reminder",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: [
                    .init(name: "matchTitle", description: "Title (or part) of the reminder to delete", required: true)
                ]),
                riskLevel: .high
            ) { request in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                guard let match = request.input["matchTitle"], !match.isEmpty else {
                    throw AICapabilityError.missingInput("matchTitle")
                }
                let deleted = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: AppleAppsAPI.shared.deleteReminder(matchingTitle: match))
                    }
                }
                return .init(
                    success: deleted != nil,
                    output: deleted.map { "Deleted reminder '\($0)'." }
                        ?? "No open reminder matching '\(match)' found.")
            }
        )
    }

    // MARK: - reminders.overdue

    private static func registerOverdue(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.overdue",
                title: "Get Overdue Reminders",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                let items = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getOverdueReminders())
                    }
                }
                if items.isEmpty {
                    return .init(success: true, output: "Nothing overdue — you're caught up.")
                }
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                let lines = items.prefix(30).map { r -> String in
                    let title = r["title"] as? String ?? "Untitled"
                    let due = (r["dueDate"] as? String)
                        .flatMap { ISO8601DateFormatter().date(from: $0) }
                    return describe(
                        title: title, due: due.map { df.string(from: $0) },
                        priority: r["priority"] as? Int ?? 0)
                }
                return .init(
                    success: true,
                    output: "Overdue reminders (\(items.count)):\n\(lines.joined(separator: "\n"))")
            }
        )
    }

    // MARK: - reminders.today

    private static func registerToday(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.today",
                title: "Get Today's Reminders",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                let all = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getReminders(limit: 100))
                    }
                }
                let cal = Calendar.current
                let now = Date()
                let startOfDay = cal.startOfDay(for: now)
                let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
                let todayAndOverdue = all.filter { r in
                    guard let dueDateStr = r["dueDate"] as? String,
                          let dueDate = ISO8601DateFormatter().date(from: dueDateStr)
                    else { return false }
                    return dueDate < endOfDay
                }
                if todayAndOverdue.isEmpty {
                    return .init(success: true, output: "No reminders due today or overdue.")
                }
                let df = DateFormatter()
                df.dateStyle = .short
                df.timeStyle = .short
                let lines = todayAndOverdue.map { r -> String in
                    let title = r["title"] as? String ?? "Untitled"
                    let dueDate = (r["dueDate"] as? String)
                        .flatMap { ISO8601DateFormatter().date(from: $0) }
                    let line = describe(
                        title: title, due: dueDate.map { df.string(from: $0) },
                        priority: r["priority"] as? Int ?? 0)
                    guard let dueDate, dueDate < now else { return line }
                    return line + " ⚠️ overdue"
                }
                return .init(success: true, output: "Due today/overdue (\(todayAndOverdue.count)):\n\(lines.joined(separator: "\n"))")
            }
        )
    }

    // MARK: - reminders.list

    private static func registerList(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.list",
                title: "List Active Reminders",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "Maximum reminders to return (default 20)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                let limit = Int(request.input["limit"] ?? "20") ?? 20
                let reminders = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getReminders(limit: max(1, min(limit, 100))))
                    }
                }
                if reminders.isEmpty {
                    return .init(success: true, output: "No active reminders.")
                }
                let df = DateFormatter()
                df.dateStyle = .short
                df.timeStyle = .short
                let lines = reminders.map { r -> String in
                    let title = r["title"] as? String ?? "Untitled"
                    let due = (r["dueDate"] as? String)
                        .flatMap { ISO8601DateFormatter().date(from: $0) }
                        .map { df.string(from: $0) }
                    // Priority was in the data all along and never rendered, which is why
                    // "the low-priority ones" had nothing to match on.
                    return describe(title: title, due: due, priority: r["priority"] as? Int ?? 0)
                }
                return .init(success: true, output: "Active reminders (\(reminders.count)):\n\(lines.joined(separator: "\n"))")
            }
        )
    }

    // MARK: - reminders.create

    private static func registerCreate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "reminders.create",
                title: "Create Reminder",
                appBundleID: "com.apple.reminders",
                inputSchema: .init(fields: [
                    .init(name: "title", description: "Reminder title", required: true),
                    .init(name: "dueDate", description: "Optional due date in ISO 8601 format (e.g. 2026-07-05T09:00:00)", required: false),
                    .init(name: "notes", description: "Optional notes", required: false),
                    .init(name: "listName", description: "Optional reminder list name (uses default if omitted)", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.remindersMCPEnabled else {
                    throw AICapabilityError.blocked("Reminders access is disabled in Settings.")
                }
                guard let title = request.input["title"], !title.isEmpty else {
                    throw AICapabilityError.missingInput("title")
                }
                let dueDateStr = request.input["dueDate"]
                let notes = request.input["notes"]
                let listName = request.input["listName"]

                let success = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleRemindersMCPCapabilities.createReminder(
                            title: title,
                            dueDateString: dueDateStr,
                            notes: notes,
                            listName: listName
                        ))
                    }
                }
                var msg = success
                    ? "Created reminder '\(title)'"
                    : "Failed to create reminder. Grant Reminders access in System Settings › Privacy › Reminders."
                if success, let dueDateStr, !dueDateStr.isEmpty,
                   let dueDate = ISO8601DateFormatter().date(from: dueDateStr) {
                    let df = DateFormatter()
                    df.dateStyle = .medium
                    df.timeStyle = .short
                    msg += " due \(df.string(from: dueDate))"
                }
                if success { msg += "." }
                return .init(success: success, output: msg)
            }
        )
    }

    // MARK: - EventKit create helper (runs on background thread)

    private nonisolated static func createReminder(
        title: String,
        dueDateString: String?,
        notes: String?,
        listName: String?
    ) -> Bool {
        let store = EKEventStore()
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(to: .reminder) { ok, _ in
            granted = ok
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        guard granted else { return false }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes

        if let listName, !listName.isEmpty,
           let list = store.calendars(for: .reminder).first(where: { $0.title.lowercased() == listName.lowercased() }) {
            reminder.calendar = list
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        if let dueDateString, !dueDateString.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            if let date = formatter.date(from: dueDateString) ?? ISO8601DateFormatter().date(from: dueDateString) {
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.dueDateComponents = comps
            }
        }

        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }
}
