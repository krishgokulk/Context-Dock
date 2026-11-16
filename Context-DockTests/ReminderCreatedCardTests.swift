import Foundation
import Testing
@testable import Context_Dock

/// `reminders.create` hands the new reminder to the answer as a card row, and reads the
/// due date the way models actually write it.
struct ReminderCreatedCardTests {

    private let london = TimeZone(identifier: "Europe/London")!

    private func components(_ date: Date?) -> DateComponents? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// Both zone-less forms were sent by the model in the hand check and were dropped.
    @Test func zonelessDueDatesAreLocalTime() {
        for text in ["2026-11-16T17:00:00", "2026-11-16T17:00", "2026-11-16 17:00:00", "2026-11-16 17:00"] {
            let parts = components(AppleRemindersMCPCapabilities.parseDueDate(text, timeZone: london))
            #expect(parts?.day == 16 && parts?.hour == 17 && parts?.minute == 0, "\(text)")
        }
    }

    @Test func zonedAndDateOnlyDueDatesParse() {
        let zoned = components(AppleRemindersMCPCapabilities.parseDueDate("2026-11-16T17:00:00Z", timeZone: london))
        #expect(zoned?.hour == 17)
        let dateOnly = components(AppleRemindersMCPCapabilities.parseDueDate("2026-11-16", timeZone: london))
        #expect(dateOnly?.day == 16 && dateOnly?.hour == 0)
        #expect(AppleRemindersMCPCapabilities.parseDueDate("tomorrow at five") == nil)
        #expect(AppleRemindersMCPCapabilities.parseDueDate("  ") == nil)
    }

    @Test func createdRowCarriesDueAndList() {
        let row = AppleRemindersMCPCapabilities.createdRow(
            title: "Call Mom", dueText: "Today at 5:00 PM", listName: "Family")
        #expect(row.kind == .reminder)
        #expect(row.reminderState == .created)
        #expect(row.title == "Call Mom")
        #expect(row.subtitle == "Today at 5:00 PM · Family")
        #expect(row.bundleID == "com.apple.reminders")
    }

    @Test func createdRowWithNoDueOrListHasNoSubtitle() {
        let row = AppleRemindersMCPCapabilities.createdRow(title: "Buy milk", dueText: nil, listName: " ")
        #expect(row.subtitle.isEmpty)
    }

    /// The row reaches the message as a "created" reminder card with its due line.
    @Test func createdRowMapsToACreatedReminderCard() {
        let row = AppleRemindersMCPCapabilities.createdRow(
            title: "Call Mom", dueText: "Today at 5:00 PM", listName: nil)
        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.reminders.count == 1)
        #expect(mapped.reminders.first?.title == "Call Mom")
        #expect(mapped.reminders.first?.detail == "Today at 5:00 PM")
        #expect(mapped.reminders.first?.state == .created)
    }
}
