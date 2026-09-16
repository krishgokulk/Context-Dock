import Foundation
import Testing

@testable import Context_Dock

// Rescheduling reminders, and the approval shape a bulk edit takes.
//
// "move the low-priority ones to tomorrow" was unanswerable twice over: no capability changed a
// due date, and priority was never rendered, so the subject of the sentence could not even be
// identified. Both are issue #3.
//
// The approval shape is the part worth pinning. A bulk edit could be one sheet per reminder or
// one sheet for the request; one per record trains people to click through approvals, which is
// the failure CapabilityContractTests already warns about. So reminders.update takes the titles
// explicitly — the model resolves them with a free reminders.list read first — and one call
// changes all of them behind one sheet that names each one.

@MainActor
struct RemindersRescheduleTests {

    // MARK: - Priority is readable

    /// EventKit stores priority as a number with banded meaning, and the bands are not obvious:
    /// 0 is unset, 1–4 high, 5 medium, 6–9 low. Rendering the number would be useless to a
    /// model asked for "the low-priority ones".
    @Test func everyEventKitPriorityBandReadsAsAWord() {
        #expect(AppleRemindersMCPCapabilities.priorityLabel(0) == nil, "0 means unset, not a band")
        for high in 1...4 {
            #expect(AppleRemindersMCPCapabilities.priorityLabel(high) == "high")
        }
        #expect(AppleRemindersMCPCapabilities.priorityLabel(5) == "medium")
        for low in 6...9 {
            #expect(AppleRemindersMCPCapabilities.priorityLabel(low) == "low")
        }
    }

    /// And back, so "make these low priority" has a number to write.
    @Test func aPriorityWordMapsBackToItsBand() {
        #expect(AppleRemindersMCPCapabilities.priorityValue(for: "high") == 1)
        #expect(AppleRemindersMCPCapabilities.priorityValue(for: "medium") == 5)
        #expect(AppleRemindersMCPCapabilities.priorityValue(for: "low") == 9)
        #expect(AppleRemindersMCPCapabilities.priorityValue(for: "none") == 0)
        #expect(AppleRemindersMCPCapabilities.priorityValue(for: "urgent") == nil)
    }

    // MARK: - The capability exists and is gated

    @Test func rescheduleIsRegisteredAndNeedsApproval() {
        guard let update = CapabilityRegistry.shared.capability(id: "reminders.update") else {
            Issue.record("reminders.update is not registered — #3's whole subject"); return
        }
        #expect(
            update.riskLevel.requiresApproval,
            "changing someone's due dates must be approved, like create and complete")
        #expect(update.appBundleID == "com.apple.reminders")
    }

    /// One call, many reminders — that is what makes one sheet possible. Titles are explicit
    /// rather than a filter so the sheet can name what it is about to change; the model is told
    /// to resolve them with reminders.list first, which is a free read.
    @Test func rescheduleTakesTheTitlesExplicitly() {
        guard let update = CapabilityRegistry.shared.capability(id: "reminders.update") else {
            Issue.record("reminders.update is not registered"); return
        }
        let fields = update.inputSchema.fields
        guard let titles = fields.first(where: { $0.name == "titles" }) else {
            Issue.record("no `titles` field — a bulk edit cannot name its records"); return
        }
        #expect(titles.required, "there is nothing to update without them")

        // Something has to change, but either one alone is a valid edit.
        #expect(fields.contains { $0.name == "dueDate" && !$0.required })
        #expect(fields.contains { $0.name == "priority" && !$0.required })
    }

    // MARK: - Splitting the titles

    /// The list arrives as one string from the model. Splitting it is where a bulk edit becomes
    /// the wrong set of records, so it is pure and tested rather than inline.
    @Test func titlesSplitOnCommasAndSurviveUntidyInput() {
        #expect(
            AppleRemindersMCPCapabilities.titles(from: "pay the bank, call mum, book flights")
                == ["pay the bank", "call mum", "book flights"])
        #expect(
            AppleRemindersMCPCapabilities.titles(from: "  pay the bank ,,  call mum  ")
                == ["pay the bank", "call mum"])
        #expect(AppleRemindersMCPCapabilities.titles(from: "one only") == ["one only"])
        #expect(AppleRemindersMCPCapabilities.titles(from: "   ").isEmpty)
    }

    // MARK: - Asking for it

    /// The sentence from issue #3, which started all of this.
    @Test func theCanonicalRequestReadsAsAChange() {
        #expect(
            GeneralAIActionResolver.shared.requestsChange("move the low-priority ones to tomorrow"),
            "this is an edit; reading it as a question is how it got described instead of done")
        #expect(
            GeneralAIActionResolver.shared.requestsChange("reschedule these to friday"),
            "\"reschedule\" is the plainest word for this capability")
    }
}
