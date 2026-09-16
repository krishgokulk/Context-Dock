// LauncherQueryShapeTests.swift
// Context-DockTests
//
// The line between "run this" and "answer this".
//
// Return in Context Dock runs the first matching app or folder before it considers the
// chat. That is right for how the dock is used most of the time, and wrong the moment
// someone types a sentence: "teach yourself to convert the selected text to markdown"
// matched a folder called ConvertedPhotos on the word "convert" and opened it in Finder,
// dropping both the selection and the request.
//
// Both directions are failures. Sending "xco" to the chat would break the launcher for its
// most common use; opening a folder for a sentence loses the user's actual question. These
// pin the boundary from both sides.

import XCTest

@testable import Context_Dock

@MainActor
final class LauncherQueryShapeTests: XCTestCase {

    private let view = LauncherView()

    func testShortQueriesStillLaunch() {
        for query in [
            "xco",
            "downloads",
            "new private window",
            "open downloads folder",
            "safari",
            "find report",
        ] {
            XCTAssertTrue(
                view.looksLikeLauncherQuery(query),
                "“\(query)” must still run as a launcher query")
        }
    }

    func testSentencesGoToTheConversation() {
        for query in [
            "teach yourself to convert the selected text to markdown",
            "read this and paste it as markdown into the editor",
            "what did i visit on the web yesterday",
            "summarise the selection and save it to notes",
        ] {
            XCTAssertFalse(
                view.looksLikeLauncherQuery(query),
                "“\(query)” is a request, not a launch")
        }
    }

    func testAQuestionIsAQuestionEvenWhenShort() {
        // Length alone would launch this; the question mark says what it is.
        XCTAssertFalse(view.looksLikeLauncherQuery("safari?"))
        XCTAssertFalse(view.looksLikeLauncherQuery("what is this?"))
    }
}
