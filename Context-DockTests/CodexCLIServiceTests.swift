import Foundation
import Testing
@testable import Context_Dock

/// The Codex specialist is launched by its flags, not by asking it nicely: read-only sandbox,
/// one directory, JSON events. These hold the argv and the event parser without a binary.
struct CodexCLIServiceTests {
    @Test func aReadOnlyRunIsSandboxedToOneDirectory() {
        let arguments = CodexCLIService.arguments(
            prompt: "What does a.txt contain?",
            workingDirectory: URL(fileURLWithPath: "/tmp/probe"),
            allowsWrites: false)
        #expect(arguments.contains("exec"))
        let sandbox = arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] }
        #expect(sandbox == "read-only")
        let directory = arguments.firstIndex(of: "-C").map { arguments[$0 + 1] }
        #expect(directory == "/tmp/probe")
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--ephemeral"))
        #expect(!arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(arguments.last == "What does a.txt contain?")
    }

    @Test func writesAreNeverGrantedFromAWorkerTask() {
        // The envelope forbids writes today; the flag that would allow them must not appear
        // even when a caller asks, until a write path with its own approval exists.
        let arguments = CodexCLIService.arguments(
            prompt: "p", workingDirectory: nil, allowsWrites: true)
        let sandbox = arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] }
        #expect(sandbox == "read-only")
        #expect(!arguments.contains("-C"))
    }

    @Test func commandEventsBecomeSteps() {
        let started = #"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","status":"in_progress"}}"#
        #expect(CodexCLIService.parse(streamLine: started) == .step("Running ls -la"))
        let completed = #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"/bin/zsh -lc 'cat a.txt'","exit_code":0,"status":"completed"}}"#
        #expect(CodexCLIService.parse(streamLine: completed) == .ignored)
    }

    @Test func theLastAgentMessageIsTheReport() {
        let message = #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"a.txt contains hello=1"}}"#
        #expect(CodexCLIService.parse(streamLine: message) == .message("a.txt contains hello=1"))
        let turnDone = #"{"type":"turn.completed","usage":{"input_tokens":1}}"#
        #expect(CodexCLIService.parse(streamLine: turnDone) == .completed)
    }

    @Test func errorsAndNoiseAreNotSteps() {
        let error = #"{"type":"item.completed","item":{"id":"i0","type":"error","message":"mcp down"}}"#
        #expect(CodexCLIService.parse(streamLine: error) == .failure("mcp down"))
        #expect(CodexCLIService.parse(streamLine: "Reading additional input from stdin...") == .ignored)
        #expect(CodexCLIService.parse(streamLine: "") == .ignored)
        #expect(CodexCLIService.parse(streamLine: #"{"type":"thread.started","thread_id":"t"}"#) == .ignored)
    }

    @Test func reportPrefersTheLastMessageOverTheTranscript() {
        let lines = [
            #"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"first thought"}}"#,
            #"{"type":"item.completed","item":{"id":"b","type":"agent_message","text":"final answer"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ]
        #expect(CodexCLIService.report(fromTranscript: lines.joined(separator: "\n")) == "final answer")
        #expect(CodexCLIService.report(fromTranscript: "garbage\n") == nil)
    }
}
