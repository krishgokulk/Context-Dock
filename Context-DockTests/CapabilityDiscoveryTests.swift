// CapabilityDiscoveryTests.swift
// Context-DockTests
//
// The phrasings that broke discovery, kept so they cannot break again.
//
// Every one of these came from a real failure rather than imagination: a question typed
// into the app that returned the wrong capability, or none. "Did I visit any website
// today?" was answered with "you have no browsing history" because the word search scored
// zero. "What did I capture from Code?" offered to take a new screenshot instead of reading
// the ones already taken. Each was fixed by editing an alias list and checked once, by
// hand, in a throwaway script — which is no check at all the next time someone edits the
// same list.
//
// The negatives matter as much as the positives. Discovery that matches everything is as
// useless as discovery that matches nothing, and the ranking bugs here were all a capability
// winning a query that belonged to another one.

import XCTest

@testable import Context_Dock

@MainActor
final class CapabilityDiscoveryTests: XCTestCase {

    /// Ids and titles only, exactly what ranking sees. Written out rather than read from
    /// the live registry so a test failure means "ranking changed", not "someone registered
    /// a capability".
    private let catalogue: [(id: String, title: String)] = [
        ("browser.history", "Read Browser History"),
        ("browser.bookmarks", "Read Browser Bookmarks"),
        ("browser.tabs", "List Open Browser Tabs"),
        ("clipboard.read", "Read Clipboard"),
        ("clipboard.history", "Search Clipboard History"),
        ("system.captureScreenshot", "Capture the Screen"),
        ("capture.text", "Capture Text from Screen (OCR)"),
        ("capture.area", "Capture a Region of the Screen"),
        ("files.recentDocuments", "List Recent Documents"),
        ("files.search", "Search Indexed Files"),
        ("quicknotes.search", "Search Quick Notes"),
        ("apps.mostUsed", "List Most-Used Apps"),
        ("memory.search", "Search Saved Memory"),
        ("memory.save", "Save a Fact to Memory"),
        ("cli.list", "List Linked CLI Tools"),
        ("cli.run", "Run a Linked CLI Tool"),
        ("extensions.list", "List Installed Extensions"),
        ("app.menu.click", "Click an App Menu Item"),
        ("app.insertText", "Insert Text into the Frontmost App"),
        ("git.log", "Git Recent Commits"),
        ("project.build", "Build the Current Project"),
        ("notes.search", "Search Apple Notes"),
        ("reminders.list", "List Reminders"),
    ]

    private func top(_ query: String) -> String? {
        AgentToolRegistry.rankedCapabilityIDs(query: query, catalogue: catalogue).first
    }

    private func matches(_ query: String) -> [String] {
        AgentToolRegistry.rankedCapabilityIDs(query: query, catalogue: catalogue)
    }

    private func assertTop(
        _ expected: String, _ query: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            top(query), expected,
            "“\(query)” ranked \(matches(query).prefix(3))", file: file, line: line)
    }

    // MARK: - Browser: the question that started this

    func testBrowserHistoryFoundByTheWordsPeopleUse() {
        // The original failure, typo included.
        assertTop("browser.history", "did i visite any website today ?")
        assertTop("browser.history", "did i visit any website today")
        assertTop("browser.history", "what websites did i look at yesterday")
        assertTop("browser.history", "show my browsing history")
    }

    func testOpenTabsAreNotHistory() {
        assertTop("browser.tabs", "which tabs do i have open")
    }

    // MARK: - Reading a capture versus taking one

    func testAskingAboutPastCapturesDoesNotOfferToTakeANewOne() {
        // Ranked system.captureScreenshot first before whole-id aliases existed, so asking
        // what had been captured offered to capture again.
        assertTop("clipboard.history", "what are all i capture from code apps")
        assertTop("clipboard.history", "show captures from vs code")
    }

    func testTakingAScreenshotStillFindsTheScreenshot() {
        assertTop("system.captureScreenshot", "capture the screen now")
        XCTAssertEqual(
            matches("take a screenshot").first, "system.captureScreenshot",
            "asking to take one must not reach for the history")
    }

    // MARK: - Clipboard tense

    func testCurrentClipVersusHistory() {
        // These two differ by tense, and sharing family aliases made the current clip win
        // questions about many.
        assertTop("clipboard.read", "what is on my clipboard")
        assertTop("clipboard.read", "paste what i copied")
        XCTAssertTrue(
            matches("what did i copy earlier").contains("clipboard.history"),
            "the history must be offered for a question about the past")
    }

    // MARK: - The rest of the map

    func testLocalReadersAreReachable() {
        assertTop("files.recentDocuments", "what files did i open recently")
        assertTop("apps.mostUsed", "which apps do i use most")
        assertTop("quicknotes.search", "what did i save about dorax")
        assertTop("memory.search", "what do you remember about me")
        assertTop("cli.list", "what cli tools are linked")
        assertTop("extensions.list", "what extensions do i have")
    }

    func testControlPrimitivesAreReachable() {
        assertTop("app.menu.click", "minimize the window")
        XCTAssertTrue(
            matches("paste this text into the editor").contains("app.insertText"))
    }

    func testExistingCapabilitiesDidNotRegress() {
        assertTop("git.log", "recent git commits")
        assertTop("project.build", "build the project")
    }

    // MARK: - Negatives

    func testUnrelatedQuestionsMatchNothing() {
        // No capability should claim these. A discovery layer that matches everything sends
        // the model to run something for a question that wanted an answer.
        for query in ["what is the weather", "who wrote hamlet", "explain recursion"] {
            XCTAssertTrue(
                matches(query).isEmpty, "“\(query)” matched \(matches(query).prefix(3))")
        }
    }

    func testShortWordsDoNotMatch() {
        // Two-letter words substring-match inside real words: "in" hits "Window".
        XCTAssertTrue(matches("in it").isEmpty)
    }
}
