import Foundation
import Testing

@testable import Context_Dock

// What a Claude Code turn says while it works.
//
// The owner asked DoraX to update an app. It did — VibeProxy 1.8.244 → 1.8.305 — and they
// could not tell how: the CLI reports every tool call it makes, and DoraX was rendering the
// tool's class name ("Bash") into a panel nobody had open, then appending a notice saying
// Claude Code "can answer here, but not act" underneath the result of it acting.

struct ClaudeCodeActivityTests {

    @Test func aCommandIsShownAsTheCommand() {
        let label = ClaudeCodeBridge.activityLabel(
            tool: "Bash", input: ["command": "brew upgrade --cask vibeproxy"])
        #expect(label == "Running `brew upgrade --cask vibeproxy`")
    }

    @Test func aSearchIsShownAsWhatItSearchesFor() {
        let label = ClaudeCodeBridge.activityLabel(tool: "Grep", input: ["pattern": "notes.create"])
        #expect(label.contains("notes.create"))
        #expect(label.hasPrefix("Searching"))
    }

    @Test func aFileIsShownByName() {
        let label = ClaudeCodeBridge.activityLabel(
            tool: "Read", input: ["file_path": "/Users/x/Developer/App/Thing.swift"])
        #expect(label == "Reading Thing.swift")
    }

    @Test func aToolWithNothingToSayStillNamesItself() {
        #expect(ClaudeCodeBridge.activityLabel(tool: "Bash", input: [:]) == "Running a command")
        #expect(ClaudeCodeBridge.activityLabel(tool: "SomethingNew", input: [:]) == "SomethingNew")
    }

    @Test func aVeryLongCommandIsCut() {
        let long = String(repeating: "a", count: 400)
        let label = ClaudeCodeBridge.activityLabel(tool: "Bash", input: ["command": long])
        #expect(label.count < 120)
        #expect(label.contains("…"))
    }

    @Test func theNoticeNoLongerContradictsWhatJustHappened() {
        // Claude Code is an agent with its own tools, not a model that cannot act. The old
        // wording landed under an answer describing an app it had just upgraded.
        let notice = ProviderActionNotice.note(provider: .claudeCode, intent: .act)
        #expect(notice != nil)
        #expect(notice?.contains("can answer here, but not act") == false)
        #expect(notice?.contains("its own tools") == true)
        #expect(notice?.contains("app actions") == true)
    }

    @Test func aQuestionGetsNoNoticeAtAll() {
        #expect(ProviderActionNotice.note(provider: .claudeCode, intent: .answer) == nil)
        #expect(ProviderActionNotice.note(provider: .claudeCode, intent: .read) == nil)
    }

    @Test func aProviderCarryingDoraXToolsNeverExplainsItself() {
        #expect(ProviderActionNotice.note(provider: .openAI, intent: .act) == nil)
        #expect(ProviderActionNotice.note(provider: .anthropic, intent: .workflow) == nil)
    }
}
