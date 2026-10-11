import Testing
import Foundation
@testable import Context_Dock

// MARK: - A terminal directive is a call, not an answer
//
// Owner screenshot, 2026-10-05: in the Corner's Finder scope, "list the files in Downloads"
// was answered with the two directive lines below, shown verbatim. Nothing ran the command,
// and nothing stripped it. These pin both halves on the exact text the model wrote.

struct TerminalDirectiveAnswerTests {

    private let shown = """
        [TERMINAL_COMMAND: ls -la ~/Downloads]
        [COMMAND_PURPOSE: List files in Downloads folder.]
        """

    @Test func theDirectiveIsNeverShown() {
        #expect(ChatAnswerSanitizer.clean(shown).isEmpty)
    }

    @Test func proseAroundTheDirectiveSurvives() {
        let answer = "Here's what's in Downloads:\n\n" + shown + "\n\nAsk if you want more."
        #expect(
            ChatAnswerSanitizer.clean(answer)
                == "Here's what's in Downloads:\n\nAsk if you want more.")
    }

    @Test func theDirectiveIsReadAsACallToRun() throws {
        let call = try #require(ChatAnswerSanitizer.terminalCall(in: shown))
        #expect(call.command == "ls -la ~/Downloads")
        #expect(call.purpose == "List files in Downloads folder.")
    }

    @Test func theJSONFormStillReads() throws {
        let call = try #require(ChatAnswerSanitizer.terminalCall(
            in: #"{"terminal_call":{"command":"rem list","purpose":"Lists"}}"#))
        #expect(call.command == "rem list")
    }

    @Test func plainProseIsNotACall() {
        #expect(ChatAnswerSanitizer.terminalCall(in: "Your Downloads folder has 12 files.") == nil)
    }
}
