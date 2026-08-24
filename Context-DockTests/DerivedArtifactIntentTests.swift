import Testing

@testable import Context_Dock

struct DerivedArtifactIntentTests {
    @Test func groupedPriorResultsToMarkdownBypassSaveMenu() {
        #expect(DerivedArtifactIntent.shouldBypassNativeAppMenu(
            "group them by AI tools and save it as .md file in Downloads"))
    }

    @Test func ordinarySaveAsRemainsANativeAppCommand() {
        #expect(!DerivedArtifactIntent.shouldBypassNativeAppMenu(
            "save this file as README.md"))
    }

    @Test func groupingWithoutAnArtifactDoesNotBypassMenus() {
        #expect(!DerivedArtifactIntent.shouldBypassNativeAppMenu(
            "group these tabs by project"))
    }
}
