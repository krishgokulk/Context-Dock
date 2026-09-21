import Foundation
import Testing

@testable import Context_Dock

// The live account of what the harness is doing.
//
// The owner's report: a turn that read Safari's tabs and wrote a note showed "4 steps" and a
// paragraph — no sign of where it was searching, what it was running, or what came back. Every
// fact needed was already in hand at the call site; none of it was published.

struct AgentToolNarrationTests {

    @Test func aSearchSaysWhatItIsSearchingFor() {
        let line = AgentToolNarration.start(
            tool: "search_messages", arguments: ["query": "invoice"])
        #expect(line == "Searching Messages “invoice”…")
    }

    @Test func aReadSaysWhatItIsReading() {
        let line = AgentToolNarration.start(
            tool: "read_file", arguments: ["path": "/tmp/report.pdf"])
        #expect(line.contains("/tmp/report.pdf"))
        #expect(line.hasPrefix("Reading"))
    }

    @Test func aPressSaysWhatItWillPress() {
        let line = AgentToolNarration.start(
            tool: "operate_app", arguments: ["target": "Check for Updates"])
        #expect(line.contains("Check for Updates"))
        #expect(line.lowercased().contains("live menu bar"))
    }

    @Test func anUnknownToolStillNamesItself() {
        // A tool added later must still produce a readable line without anyone remembering
        // to add it here.
        let line = AgentToolNarration.start(tool: "some_new_tool", arguments: [:])
        #expect(line == "Running some_new_tool…")
    }

    @Test func theMostTellingArgumentIsTheOneShown() {
        // A call carrying both a path and a limit is described by the path.
        let line = AgentToolNarration.start(
            tool: "read_file", arguments: ["limit": 20, "path": "/tmp/a.txt"])
        #expect(line.contains("/tmp/a.txt"))
        #expect(!line.contains("20"))
    }

    @Test func aLongArgumentIsCut() {
        let long = String(repeating: "x", count: 500)
        let line = AgentToolNarration.start(tool: "run_command", arguments: ["command": long])
        #expect(line.count < 120)
        #expect(line.contains("…"))
    }

    @Test func theOutcomeIsEvidenceRatherThanAClaim() {
        // "Done" says nothing that can be checked. The first line of what came back does.
        let line = AgentToolNarration.finish(
            displayCommand: "notes.search(project)", success: true,
            output: "Found 4 note(s) matching 'project':\nID: x-coredata://…")
        #expect(line.contains("Found 4 note(s)"))
        #expect(line.hasPrefix("Ran"))
    }

    @Test func aFailureSaysSo() {
        let line = AgentToolNarration.finish(
            displayCommand: "run_menu_command(File ▸ Export)", success: false,
            output: "That menu item is disabled right now.")
        #expect(line.hasPrefix("Failed"))
        #expect(line.contains("disabled"))
    }

    @Test func silenceIsReportedAsSilence() {
        // A tool that returned nothing must not read as one that returned something.
        let line = AgentToolNarration.finish(
            displayCommand: "finder.searchFiles(*.key)", success: true, output: "   ")
        #expect(line.contains("no output"))
    }
}
