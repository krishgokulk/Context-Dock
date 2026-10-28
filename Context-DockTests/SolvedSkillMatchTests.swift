import Testing
import Foundation
@testable import Context_Dock

// MARK: - A saved skill answers only the sentence it was made for (#205)

struct SolvedSkillMatchTests {

    private let mail = "com.apple.mail"

    private var skill: SolvedSkill {
        SolvedSkill(
            queryTemplate: "unread mail from {sender} {day}",
            nonSlotWords: ["unread", "mail", "from"],
            slots: [
                SolvedSkillSlot(name: "sender", tokenFamily: "sender"),
                SolvedSkillSlot(name: "day", tokenFamily: "day"),
            ],
            toolCalls: [
                SolvedSkillToolCall(
                    capability: "mail.search",
                    argTemplate: ["sender": "{sender}", "day": "{day}"], isReadOnly: true)
            ],
            bundleId: mail)
    }

    @Test func aSimilarSentenceFillsTheSlots() throws {
        let hit = try #require(
            SolvedSkillMatch.match(
                query: "unread mail from ICICI yesterday", bundleId: mail, skills: [skill]))
        #expect(hit.filled == ["sender": "ICICI", "day": "yesterday"])
    }

    @Test func anUnrelatedSentenceFallsThrough() {
        #expect(
            SolvedSkillMatch.match(
                query: "archive everything from ICICI yesterday", bundleId: mail, skills: [skill])
                == nil)
        #expect(
            SolvedSkillMatch.match(query: "what is the weather", bundleId: mail, skills: [skill])
                == nil)
    }

    @Test func aMissingOrExtraSlotFallsThrough() {
        // No day given, and a skill that needs one.
        #expect(
            SolvedSkillMatch.match(
                query: "unread mail from ICICI", bundleId: mail, skills: [skill]) == nil)
    }

    @Test func anotherAppsSkillIsNeverUsed() {
        #expect(
            SolvedSkillMatch.match(
                query: "unread mail from ICICI yesterday", bundleId: "com.apple.Notes",
                skills: [skill]) == nil)
    }
}
