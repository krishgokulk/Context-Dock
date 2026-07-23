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

    static func register(in registry: CapabilityRegistry) {
        registerToday(registry)
        registerOverdue(registry)
        registerList(registry)
        registerCreate(registry)
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
                    let due = (r["dueDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let dueStr = due.map { " (due \(df.string(from: $0)))" } ?? ""
                    return "• \(title)\(dueStr)"
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
                    guard let dueDateStr = r["dueDate"] as? String,
                          let dueDate = ISO8601DateFormatter().date(from: dueDateStr) else {
                        return "• \(title)"
                    }
                    let tag = dueDate < now ? " ⚠️ overdue" : ""
                    return "• \(title) — due \(df.string(from: dueDate))\(tag)"
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
                    if let dueDateStr = r["dueDate"] as? String,
                       let dueDate = ISO8601DateFormatter().date(from: dueDateStr) {
                        return "• \(title) — due \(df.string(from: dueDate))"
                    }
                    return "• \(title)"
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
