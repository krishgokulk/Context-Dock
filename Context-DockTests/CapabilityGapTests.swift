import Testing
import Foundation
@testable import Context_Dock

// MARK: - Saying what is missing
//
// "I added Tutorine as an adapter; did I view any videos in it?" is a fair question with,
// usually, no answer available. A hand-made adapter has actions — things to do — and rarely
// a reader, something that can see what the app holds.
//
// An agent that cannot answer says what it looked at and what is missing. Anything else is
// a guess about the user's own app, and a guess there is indistinguishable from knowledge.

struct CapabilityGapTests {

    private func action(_ id: String) -> CapabilityRecord {
        .init(id: id, app: "Tutorine", kind: .adapterAction, title: id, isWrite: true)
    }
    private func reader(_ id: String) -> CapabilityRecord {
        .init(id: id, app: "Tutorine", kind: .capability, title: id, isWrite: false)
    }
    private func skill(_ id: String) -> CapabilityRecord {
        .init(id: id, app: "Tutorine", kind: .skill, title: id, isWrite: false)
    }

    // MARK: - Nothing can read

    @Test func actionsAloneCannotAnswerAReadQuestion() throws {
        let reply = try #require(CapabilityGap.explain(
            appName: "Tutorine",
            records: [action("play"), action("pause")],
            menuCommands: 12))
        // It says what it has…
        #expect(reply.contains("2 actions"))
        #expect(reply.contains("12 menu commands"))
        // …and what would be needed.
        #expect(reply.contains("reader") || reply.contains("CLI") || reply.contains("MCP"))
        #expect(reply.contains("Tutorine"))
    }

    /// A skill is instructions for the model, not a way to see inside an app. Counting it
    /// as a reader is how "I have a skill for this app" becomes an invented answer.
    @Test func aSkillIsNotAReader() throws {
        let reply = try #require(CapabilityGap.explain(
            appName: "Tutorine",
            records: [action("play"), skill("Tutorine — what this app is")],
            menuCommands: 0))
        #expect(reply.contains("1 skill"))
    }

    /// Linked but empty is a different sentence: there is nothing to list, and the useful
    /// thing to say is where to start.
    @Test func anEmptyAdapterSaysSo() throws {
        let reply = try #require(CapabilityGap.explain(
            appName: "Tutorine", records: [], menuCommands: 0))
        #expect(reply.contains("nothing is connected"))
        #expect(reply.contains("App Adapters"))
        #expect(!reply.contains("0 actions"))
    }

    // MARK: - Something can read

    /// When a reader exists, this must stay out of the way — the normal path should run it
    /// and answer. Returning a gap here would refuse a question DoraX can answer.
    @Test func aReaderMeansNoGapToExplain() {
        #expect(CapabilityGap.explain(
            appName: "Tutorine",
            records: [action("play"), reader("tutorine.history")],
            menuCommands: 4) == nil)
    }

    // MARK: - Counting

    @Test func singularAndPluralBothRead() throws {
        let one = try #require(CapabilityGap.explain(
            appName: "Tutorine", records: [action("play")], menuCommands: 1))
        #expect(one.contains("1 action"))
        #expect(!one.contains("1 actions"))
        #expect(one.contains("1 menu command"))
        #expect(!one.contains("1 menu commands"))
    }
}
