import Testing

@testable import Context_Dock

@MainActor
struct ChatSlashAppPickerTests {
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
