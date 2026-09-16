import Testing

@testable import Context_Dock

@MainActor
struct ChatSlashAppPickerTests {
    @Test func arrowKeysWalkTheMatchesAndStopAtBothEnds() {
        #expect(ChatSlashAppPicker.movedSelection(from: 0, by: 1, count: 3) == 1)
        #expect(ChatSlashAppPicker.movedSelection(from: 2, by: 1, count: 3) == 2)
        #expect(ChatSlashAppPicker.movedSelection(from: 0, by: -1, count: 3) == 0)
    }

    /// With no list open the key is the field's: a text cursor that stops moving because
    /// an invisible picker ate the arrow is worse than no picker at all.
    @Test func arrowKeysBelongToTheFieldWhenNothingMatches() {
        #expect(ChatSlashAppPicker.movedSelection(from: 0, by: 1, count: 0) == nil)
    }

    @Test func slashMessageAndTerminalReturnDirectoryMatches() {
        #expect(ChatSlashAppPicker.matches(for: "/message").first?.name == "Messages")
        #expect(ChatSlashAppPicker.matches(for: "/terminal").first?.name == "Terminal")
    }

    @Test func spaceEndsAppFiltering() {
        #expect(ChatSlashAppPicker.matches(for: "/terminal run tests").isEmpty)
    }

    @Test func plainTextDoesNotFilterApps() {
        #expect(ChatSlashAppPicker.matches(for: "terminal").isEmpty)
    }

    @Test func inlinePickerEntersSlashFilteringWithoutDiscardingExistingQuery() {
        var empty = ""
        ChatSlashAppPicker.openInline(text: &empty)
        #expect(empty == "/")

        var existing = "/term"
        ChatSlashAppPicker.openInline(text: &existing)
        #expect(existing == "/term")
    }
}
