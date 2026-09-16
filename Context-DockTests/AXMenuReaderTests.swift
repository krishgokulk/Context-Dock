import Testing
@testable import Context_Dock

struct AXMenuReaderTests {
    @Test func regularAppHistoryMenusAreTraversed() {
        #expect(!AXMenuReader.shouldSkipRecursion(
            menuTitle: "History", bundleIdentifier: "app.tutorini.Tutorini"))
    }

    @Test func browserHistoryAndBookmarksMenusRemainBounded() {
        #expect(AXMenuReader.shouldSkipRecursion(
            menuTitle: "History", bundleIdentifier: "com.apple.Safari"))
        #expect(AXMenuReader.shouldSkipRecursion(
            menuTitle: "BOOKMARKS", bundleIdentifier: "com.google.Chrome"))
    }

    @Test func ordinaryBrowserMenusAreStillTraversed() {
        #expect(!AXMenuReader.shouldSkipRecursion(
            menuTitle: "Playback", bundleIdentifier: "com.apple.Safari"))
    }
}
