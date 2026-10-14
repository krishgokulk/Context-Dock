import Foundation
import Testing

@testable import Context_Dock

/// Global Context ends with what to do with the words themselves (owner 2026-10-14, #258 G3).
@Suite("Global fallbacks")
struct GlobalFallbacksTests {
    private let programs: (String) -> Bool = { ["git", "npm", "ls", "open"].contains($0) }

    @Test func shellCommandsAreRecognised() {
        #expect(GlobalFallbacks.looksLikeShellCommand("npm -v", isProgram: programs))
        #expect(GlobalFallbacks.looksLikeShellCommand("git status", isProgram: programs))
        #expect(GlobalFallbacks.looksLikeShellCommand("ls", isProgram: programs))
        #expect(GlobalFallbacks.looksLikeShellCommand("./build.sh", isProgram: programs))
        #expect(GlobalFallbacks.looksLikeShellCommand("~/bin/tool --help", isProgram: programs))
    }

    @Test func wordsThatAreNotCommandsAreNot() {
        #expect(!GlobalFallbacks.looksLikeShellCommand("safari", isProgram: programs))
        #expect(!GlobalFallbacks.looksLikeShellCommand("Terms of Service", isProgram: programs))
        #expect(!GlobalFallbacks.looksLikeShellCommand("hello the", isProgram: programs))
        #expect(!GlobalFallbacks.looksLikeShellCommand("", isProgram: programs))
    }

    @Test func theRowsAreAskThenWebThenTerminalOnlyForACommand() {
        let words = GlobalFallbacks.rows(for: "hello there") { _ in }
        #expect(words.map(\.rankingKind) == [GlobalFallbacks.askKind, GlobalFallbacks.webKind])
        #expect(words.allSatisfy { $0.resultSection == GlobalFallbacks.section })
        #expect(GlobalFallbacks.rows(for: "   ") { _ in }.isEmpty)
    }

    @Test func askHandsTheWordsOver() {
        var asked: String?
        GlobalFallbacks.rows(for: " what is new ") { asked = $0 }.first?.execute()
        #expect(asked == "what is new")
    }

    @Test func appleScriptQuotesAreEscaped() {
        #expect(GlobalFallbacks.appleScriptEscaped(#"echo "hi" \ there"#) == #"echo \"hi\" \\ there"#)
    }
}
