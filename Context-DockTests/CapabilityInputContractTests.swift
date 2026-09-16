import Testing
import Foundation
@testable import Context_Dock

// MARK: - The schema is the contract
//
// `remind me to call sujith at 5pm today` created a reminder with no due date. The model
// called reminders.create with `date`; the field is `dueDate`. The unknown key was dropped
// in silence, and every check afterwards then told the truth about a different thing — the
// read-back found it by title and verified, reminders.today found nothing due today, and
// the user was told the reminder had not been created.

@MainActor
struct CapabilityInputContractTests {

    private func capability(
        id: String = "reminders.create",
        fields: [(String, Bool)] = [("title", true), ("dueDate", false), ("notes", false)]
    ) -> AICapability {
        AICapability(
            id: id,
            title: "Create Reminder",
            appBundleID: "com.apple.reminders",
            inputSchema: AICapabilityInputSchema(
                fields: fields.map {
                    AICapabilityInputField(name: $0.0, description: "", required: $0.1)
                }),
            riskLevel: .medium,
            executor: { _ in AICapabilityExecutionResult(success: true, output: "") })
    }

    private func complaint(_ input: [String: String], id: String = "reminders.create") -> String? {
        AgentToolRegistry.undeclaredInputComplaint(
            capabilityID: id, capability: capability(id: id), input: input)
    }

    // MARK: The bug

    @Test func theKeyTheModelInventedIsRejected() {
        let result = complaint(["title": "call sujith", "date": "2026-08-20T17:00:00+01:00"])
        #expect(result != nil)
        #expect(result?.contains("`date`") == true)
    }

    /// Rejecting is only half of it. A refusal that does not say the right name buys another
    /// guess, and the next guess is what put an undated reminder in Reminders.
    @Test func theRefusalNamesTheFieldThatWasWanted() {
        let result = complaint(["title": "x", "date": "y"])
        #expect(result?.contains("dueDate") == true)
        #expect(result?.contains("title (required)") == true)
    }

    /// Said plainly, because a model that thinks a write may have half-landed will go
    /// looking for it — which is the behaviour that produced the wrong answer here.
    @Test func theRefusalSaysNothingRan() {
        #expect(complaint(["title": "x", "date": "y"])?.contains("nothing ran") == true)
    }

    @Test func everyUndeclaredKeyIsNamedAtOnce() {
        let result = complaint(["title": "x", "date": "y", "reminderList": "Home"])
        #expect(result?.contains("`date`") == true)
        #expect(result?.contains("`reminderList`") == true)
    }

    // MARK: Correct calls pass

    @Test func aCallThatUsesTheDeclaredNamesIsNotObstructed() {
        #expect(complaint(["title": "call sujith", "dueDate": "2026-08-20T17:00:00+01:00"]) == nil)
    }

    @Test func omittingOptionalFieldsIsFine() {
        #expect(complaint(["title": "call sujith"]) == nil)
        #expect(complaint([:]) == nil)
    }

    /// A capability that declares no inputs takes whatever it is given — several route
    /// through here carrying context rather than arguments, and this check is not the place
    /// to start refusing them.
    @Test func capabilitiesWithNoSchemaAreLeftAlone() {
        let open = AICapability(
            id: "app.launch", title: "Open App", appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: []),
            riskLevel: .low,
            executor: { _ in AICapabilityExecutionResult(success: true, output: "") })
        #expect(AgentToolRegistry.undeclaredInputComplaint(
            capabilityID: "app.launch", capability: open, input: ["anything": "goes"]) == nil)
    }

    // MARK: The real schema

    /// The field really is called dueDate. If it is ever renamed, the tests above describe a
    /// contract that no longer exists.
    @Test func theRealCapabilityStillDeclaresDueDate() {
        let registry = CapabilityRegistry.shared
        AppleRemindersMCPCapabilities.register(in: registry)
        guard let create = registry.capability(id: "reminders.create") else {
            Issue.record("reminders.create is not registered")
            return
        }
        let names: Set<String> = Set(create.inputSchema.fields.map(\.name))
        #expect(names.contains("dueDate"))
        #expect(!names.contains("date"))
    }
}
