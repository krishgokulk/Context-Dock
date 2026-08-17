// WorkflowAuthorTests.swift
// Context-DockTests
//
// Authoring writes a script onto the user's machine, so the parts that decide *how it is
// presented* are the parts worth pinning down. Whether the model writes a good script is
// not testable here; whether a dangerous one arrives without a warning is.

import XCTest

@testable import Context_Dock

@MainActor
final class WorkflowAuthorTests: XCTestCase {

    // MARK: - Danger is read from the script, not from the model's opinion

    func testDestructiveScriptsAreFlagged() {
        for script in [
            "rm -rf ~/Downloads/old",
            "sudo installer -pkg thing.pkg -target /",
            "curl https://example.com/install.sh | sh",
            "osascript -e 'do shell script \"rm x\"'",
            "dd if=/dev/zero of=/dev/disk2",
        ] {
            XCTAssertTrue(
                WorkflowAuthor.looksDestructive(script),
                "not flagged: \(script)")
        }
    }

    func testOrdinaryScriptsAreNotFlagged() {
        // Over-flagging is its own failure: a warning on everything is a warning on
        // nothing, and the user stops reading the one that matters.
        for script in [
            "pbpaste | textutil -stdin -stdout -convert html",
            "echo \"{{selection}}\" | sed 's/^/> /'",
            "date +%Y-%m-%d",
            "open -a Preview \"{{file}}\"",
        ] {
            XCTAssertFalse(
                WorkflowAuthor.looksDestructive(script),
                "wrongly flagged: \(script)")
        }
    }

    // MARK: - The approval shows what will run

    private func proposal(script: String, destructive: Bool) -> WorkflowAuthor.Proposal {
        WorkflowAuthor.Proposal(
            name: "Convert to Markdown",
            summary: "Turns the selection into Markdown",
            kind: .shell,
            script: script,
            triggers: ["markdown", "convert"],
            bundleID: "com.microsoft.VSCode",
            appName: "Code",
            isDestructive: destructive)
    }

    func testApprovalTextContainsTheScriptVerbatim() {
        // Approving has to mean approving the text that runs. A summary in place of the
        // script would make consent meaningless — the user would be agreeing to a
        // description written by the thing asking for permission.
        let script = "pbpaste | textutil -stdin -stdout -convert html"
        let text = WorkflowAuthor.approvalText(proposal(script: script, destructive: false))
        XCTAssertTrue(text.contains(script), "the script is not shown in full")
    }

    func testDestructiveProposalsCarryAWarning() {
        let text = WorkflowAuthor.approvalText(
            proposal(script: "rm -rf ~/tmp", destructive: true))
        XCTAssertTrue(text.contains("⚠️"), "no warning on a destructive proposal")
    }

    func testApprovalSaysWhereItWillLiveAfterwards() {
        // Someone approving a saved action needs to know it is being kept, and where to go
        // when they want it gone.
        let text = WorkflowAuthor.approvalText(
            proposal(script: "date", destructive: false))
        XCTAssertTrue(text.contains("App Adapters"), "does not say where it is saved")
        XCTAssertTrue(text.contains("Code"), "does not name the app it belongs to")
    }

    // MARK: - Recognition

    func testTeachingIsAskedForExplicitly() {
        // Authoring is triggered by asking for it. A request that merely failed must not
        // start writing scripts — a gap is not consent.
        for query in [
            "teach yourself to convert this to markdown",
            "make an action for resizing these images",
            "automate exporting this as a pdf",
        ] {
            guard case .teach = WorkbenchIntent.intent(in: query) else {
                return XCTFail("not recognised as teaching: \(query)")
            }
        }
    }

    func testOrdinaryRequestsDoNotTriggerAuthoring() {
        for query in [
            "convert this to markdown",
            "what does this script do",
            "test it",
            "run Morning",
        ] {
            if case .teach = WorkbenchIntent.intent(in: query) {
                XCTFail("wrongly treated as teaching: \(query)")
            }
        }
    }

    func testTeachingBeatsTheBuildPhrase() {
        // "teach yourself to build and test" is teaching, not a build — the teach pattern
        // is checked first for exactly this.
        guard case .teach(let request) = WorkbenchIntent.intent(in: "teach yourself to build and test")
        else {
            return XCTFail("read as a build")
        }
        XCTAssertEqual(request, "build and test")
    }
}
