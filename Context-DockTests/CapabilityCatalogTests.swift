import Testing
import Foundation
@testable import Context_Dock

// MARK: - Turning four stores into one list
//
// The capability is all there — adapter actions, skills, Global Commands, registered
// capabilities — spread across stores that six matchers each read in their own way. These
// cover the conversions, which are the part that can be wrong quietly: a dropped trigger or
// a write filed as a read does not crash, it just makes the ranking answer badly.

@MainActor
struct CapabilityCatalogTests {

    // MARK: - Adapter actions

    @Test func anActionKeepsTheWordsTheUserChose() {
        let action = AdapterAction(
            id: "clean-cache", name: "Clean Cache", icon: "trash",
            description: "Remove build caches", triggers: ["cache", "cleanup", "purge"],
            type: .shell)
        let record = CapabilityCatalog.record(for: action, appName: "Xcode")

        #expect(record.title == "Clean Cache")
        #expect(record.app == "Xcode")
        #expect(record.kind == .adapterAction)
        // The triggers are the user's own vocabulary for this action. Dropping them is how
        // an action becomes unfindable by the word its owner calls it.
        for trigger in ["cache", "cleanup", "purge"] {
            #expect(record.keywords.contains(trigger))
        }
    }

    /// An AI prompt asks the model something. Everything else drives the app, and the
    /// decision layer treats a wrong write as far more expensive than a wrong read.
    @Test func onlyAnAIPromptIsAReadAmongActions() {
        let ask = AdapterAction(
            id: "ask", name: "Ask", icon: "bubble", description: "", type: .aiPrompt)
        let shell = AdapterAction(
            id: "run", name: "Run", icon: "terminal", description: "", type: .shell)
        #expect(!CapabilityCatalog.record(for: ask, appName: "X").isWrite)
        #expect(CapabilityCatalog.record(for: shell, appName: "X").isWrite)
    }

    // MARK: - Skills

    /// A skill steers the model and runs nothing — its own type says so. Filed as a write
    /// it would start asking for approval to think.
    @Test func aSkillIsNeverAWrite() {
        let skill = AdapterSkill(
            adapterBundleId: "com.microsoft.VSCode",
            name: "Code — what this app is",
            summary: "Learned from Code's Help menu",
            instructions: "…")
        let record = CapabilityCatalog.record(for: skill, appName: "Code")
        #expect(!record.isWrite)
        #expect(record.kind == .skill)
        #expect(record.title.contains("Code"))
    }

    // MARK: - Global Commands

    @Test func aGlobalCommandKeepsItsKeywords() {
        let command = SystemCommand(
            name: "Dark Mode", icon: "moon",
            keywords: ["dark", "appearance", "provider:appearance"],
            scriptType: "applescript", script: "",
            description: "Toggle system appearance")
        let record = CapabilityCatalog.record(for: command)

        #expect(record.title == "Dark Mode")
        #expect(record.keywords.contains("dark"))
        // "provider:…" is plumbing. Indexing it means a sentence containing "provider"
        // scores against every command that has one.
        #expect(!record.keywords.contains { $0.hasPrefix("provider:") })
    }

    // MARK: - Registered capabilities

    /// "reminders.create" carries two words the title may not repeat, and they are the two
    /// most useful words it has.
    @Test func aCapabilityIDBecomesSearchableWords() {
        let capability = AICapability(
            id: "reminders.create", title: "Create Reminder", appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: []), riskLevel: .medium,
            executor: { _ in AICapabilityExecutionResult(success: true, output: "") })
        let record = CapabilityCatalog.record(for: capability, appName: "Reminders")
        #expect(record.keywords.contains("reminders"))
        #expect(record.keywords.contains("create"))
        #expect(record.isWrite)
    }

    /// Risk is a proxy for read-versus-write, and the proxy is documented as one. Low-risk
    /// capabilities are the reads.
    @Test func lowRiskCapabilitiesAreReads() {
        let capability = AICapability(
            id: "reminders.today", title: "Today's Reminders", appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: []), riskLevel: .low,
            executor: { _ in AICapabilityExecutionResult(success: true, output: "") })
        #expect(!CapabilityCatalog.record(for: capability, appName: "Reminders").isWrite)
    }

    // MARK: - The index over real records

    /// The point of the whole exercise: a sentence naming an action finds it among records
    /// built from the real types rather than a corpus written for the test.
    @Test func theIndexRanksRealRecords() throws {
        let action = AdapterAction(
            id: "clean-cache", name: "Clean Cache", icon: "trash",
            description: "Remove build caches", triggers: ["cache"], type: .shell)
        let command = SystemCommand(
            name: "Dark Mode", icon: "moon", keywords: ["dark", "appearance"],
            scriptType: "applescript", script: "")

        let index = CapabilityIndex(records: [
            CapabilityCatalog.record(for: action, appName: "Xcode"),
            CapabilityCatalog.record(for: command),
        ])
        #expect(index.search("clean the cache").first?.record.title == "Clean Cache")
        #expect(index.search("dark mode").first?.record.title == "Dark Mode")
    }
}
