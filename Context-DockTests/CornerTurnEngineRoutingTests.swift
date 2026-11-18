import Testing
import Foundation
@testable import Context_Dock

// U1: Corner App Chat routes through AppScopedChatService.send.
//
// These tests verify the Answer → AIChatMessage field-mapping that the Corner's
// cloud provider block now uses, so a regression in the mapping shows up here
// rather than only at hand-check time.

struct CornerTurnEngineRowMappingTests {

    // MARK: - Notes

    @Test func noteRowMapsToNoteResults() {
        let row = ChatResultRow(kind: .note, id: "n1", title: "Meeting notes", subtitle: "Work")
        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.notes.count == 1)
        #expect(mapped.notes.first?.title == "Meeting notes")
        #expect(mapped.notes.first?.folder == "Work")
        #expect(mapped.files.isEmpty)
        #expect(mapped.apps.isEmpty)
    }

    // MARK: - Files

    @Test func fileRowMapsToRecentFiles() throws {
        let url = try #require(URL(string: "file:///Users/test/doc.pdf"))
        let row = ChatResultRow(kind: .file, id: url.absoluteString, title: "doc.pdf", url: url)
        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.files.count == 1)
        #expect(mapped.files.first?.url == url)
        #expect(mapped.notes.isEmpty)
    }

    @Test func fileRowWithNoURLIsDropped() {
        let row = ChatResultRow(kind: .file, id: "f1", title: "ghost.pdf")
        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.files.isEmpty)
    }

    // MARK: - Links

    @Test func linkRowMapsToPageLinks() throws {
        let url = try #require(URL(string: "https://example.com"))
        let row = ChatResultRow(kind: .link, id: "l1", title: "Example", url: url)
        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.links.count == 1)
        #expect(mapped.links.first?.title == "Example")
        #expect(mapped.links.first?.url == "https://example.com")
    }

    // MARK: - Apps

    @Test func appRowMapsToAppLaunches() {
        let row = ChatResultRow(
            kind: .app, id: "com.apple.Safari", title: "Safari",
            subtitle: "safari", bundleID: "com.apple.Safari")
        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.apps.count == 1)
        #expect(mapped.apps.first?.bundleId == "com.apple.Safari")
        #expect(mapped.apps.first?.label == "Safari")
    }

    // MARK: - Mixed rows

    @Test func mixedRowsMappedIntoCorrectBuckets() throws {
        let noteURL: URL? = nil
        let fileURL = try #require(URL(string: "file:///tmp/x.txt"))
        let rows: [ChatResultRow] = [
            ChatResultRow(kind: .note, id: "n1", title: "Note A"),
            ChatResultRow(kind: .file, id: "f1", title: "x.txt", url: fileURL),
            ChatResultRow(kind: .app, id: "a1", title: "Finder",
                          bundleID: "com.apple.finder"),
        ]
        _ = noteURL
        let mapped = ChatResultRowMapper.map(rows)
        #expect(mapped.notes.count == 1)
        #expect(mapped.files.count == 1)
        #expect(mapped.apps.count == 1)
        #expect(mapped.links.isEmpty)
        #expect(mapped.reminders.isEmpty)
        #expect(mapped.messages.isEmpty)
    }

    // MARK: - Empty rows

    @Test func emptyRowsProduceEmptyMapped() {
        let mapped = ChatResultRowMapper.map([])
        #expect(mapped.isEmpty)
    }

    // MARK: - Answer chip passthrough

    @Test func answerToolChipsPreservedInConstruction() {
        let chips = ["run_menu_command", "mcp_notes_read"]
        let answer = AppScopedChatService.Answer(text: "Done", toolChips: chips)
        #expect(answer.toolChips == chips)
    }

    @Test func answerSavedSkillDefaultsToNil() {
        let answer = AppScopedChatService.Answer(text: "Done", toolChips: [])
        #expect(answer.savedSkill == nil)
    }
}
