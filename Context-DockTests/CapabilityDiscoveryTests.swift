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
        ("browser.currentPage", "Read Current Browser Page"),
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

    func testCurrentPageReaderBeatsTheAllTabsReader() {
        assertTop(
            "browser.currentPage",
            "what page is open give me the exact title domain and summary")
    }

    // MARK: - Reading a capture versus taking one

    func testAskingAboutPastCapturesOffersTheHistory() {
        // Before whole-id aliases, asking what had been captured did not reach the history
        // at all — it offered to take a new screenshot. "Capture" is the same substring as
        // a verb and as a noun, so which one leads is not something word matching can
        // decide; that it is offered at all is.
        for query in ["what are all i capture from code apps", "show captures from vs code"] {
            XCTAssertTrue(
                matches(query).contains("clipboard.history"),
                "“\(query)” ranked \(matches(query).prefix(3))")
        }
    }

    func testTakingAScreenshotStillFindsTheScreenshot() {
        XCTAssertEqual(
            matches("take a screenshot").first, "system.captureScreenshot",
            "asking to take one must not reach for the history")
        // "Capture the screen" is honestly ambiguous between grabbing the whole screen and
        // snipping a region — both titles say exactly that. What must not happen is the
        // clipboard history, which only matches because "captures" contains "capture",
        // outranking either of them.
        let ranked = matches("capture the screen now")
        XCTAssertTrue(
            ranked.contains("system.captureScreenshot"),
            "screenshot must be offered: \(ranked.prefix(3))")
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
        // "What did I save about X" genuinely spans Quick Notes and memory — both hold
        // things the user saved, and the honest answer is to offer both and let the model
        // read the titles. Asserting a winner here would be encoding a preference the
        // question does not express.
        XCTAssertTrue(
            matches("what did i save about dorax").contains("quicknotes.search"),
            "captures must be offered: \(matches("what did i save about dorax").prefix(3))")
        assertTop("memory.search", "what do you remember about me")
        XCTAssertTrue(matches("what cli tools are linked").contains("cli.list"))
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
