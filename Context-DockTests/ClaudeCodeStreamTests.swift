import Foundation
import Testing

@testable import Context_Dock

// Reading the CLI's streaming output.
//
// Every line below was captured from claude 2.1.220 running under
// `--output-format stream-json --include-partial-messages --verbose`, and is used verbatim:
// the shape of this stream belongs to the CLI, so it is asserted against real output rather
// than against what its documentation implies. Guessing at a flag contract already cost this
// feature two rounds — `--allowed-tools` where `--tools` was meant, then a tool set with no
// matching allowlist.

@MainActor
struct ClaudeCodeStreamTests {

    // MARK: - The lines worth showing

    /// A tool starting is the one event a progress list wants.
    @Test func aToolStartingBecomesAStep() {
        let line = """
            {"type": "stream_event", "event": {"type": "content_block_start", "index": 0, \
            "content_block": {"type": "tool_use", "id": "toolu_011N", "name": "Read", \
            "input": {}, "caller": {"type": "direct"}}}, "session_id": "02908af6"}
            """
        #expect(ClaudeCodeCLIService.parse(streamLine: line) == .progress("Reading a file…"))
    }

    /// A tool answering is worth a step, but its content is not: a file's worth of text does
    /// not belong in a progress list.
    @Test func aToolResultBecomesAStepWithoutItsContents() {
        let line = """
            {"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_011N", \
            "type": "tool_result", "content": "1\\tdorax-probe-marker-8817\\n2\\t"}]}, \
            "parent_tool_use_id": null, "session_id": "02908af6"}
            """
        guard case .progress(let step) = ClaudeCodeCLIService.parse(streamLine: line) else {
            Issue.record("a tool result should be a step"); return
        }
        #expect(!step.contains("dorax-probe-marker-8817"), "the file's contents leaked into the step")
    }

    /// The answer arrives on the last line, and is what the caller actually returns.
    @Test func theResultLineCarriesTheAnswer() {
        let line = """
            {"type": "result", "subtype": "success", "is_error": false, "num_turns": 2, \
            "result": "dorax-probe-marker-8817", "session_id": "02908af6"}
            """
        #expect(
            ClaudeCodeCLIService.parse(streamLine: line) == .result("dorax-probe-marker-8817"))
    }

    /// A failed turn must surface the CLI's own words rather than an empty answer.
    @Test func anErrorResultIsAFailureNotAnEmptyAnswer() {
        let line = """
            {"type": "result", "subtype": "error", "is_error": true, \
            "result": "Claude requested permissions to use WebFetch", "session_id": "02908af6"}
            """
        #expect(
            ClaudeCodeCLIService.parse(streamLine: line)
                == .failure("Claude requested permissions to use WebFetch"))
    }

    // MARK: - The noise

    /// Most of the stream is the CLI talking to itself. Showing any of it would bury the two
    /// or three lines that mean something — including the user's own hooks, which have nothing
    /// to do with the question asked.
    @Test func theCLIsOwnChatterIsNotProgress() {
        let noise = [
            #"{"type": "system", "subtype": "init", "cwd": "/tmp", "session_id": "029"}"#,
            #"{"type": "system", "subtype": "status", "status": "requesting", "session_id": "029"}"#,
            #"{"type": "system", "subtype": "hook_started", "hook_name": "SessionStart:startup"}"#,
            #"{"type": "system", "subtype": "hook_response", "hook_name": "SessionStart:startup"}"#,
            #"{"type": "system", "subtype": "notification", "key": "stop-hook-error"}"#,
            #"{"type": "rate_limit_event", "rate_limit_info": {"status": "allowed"}}"#,
            #"{"type": "stream_event", "event": {"type": "message_start"}}"#,
            #"{"type": "stream_event", "event": {"type": "message_stop"}}"#,
            #"{"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}}"#,
        ]
        for line in noise {
            #expect(
                ClaudeCodeCLIService.parse(streamLine: line) == .ignored,
                "this is chatter, not a step: \(line.prefix(60))")
        }
    }

    /// The argument deltas are a tool's input arriving character by character. Eleven of them
    /// turned up in a two-tool turn; none is a step.
    @Test func argumentDeltasAreNotSteps() {
        let line = """
            {"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, \
            "delta": {"type": "input_json_delta", "partial_json": ""}}, "session_id": "029"}
            """
        #expect(ClaudeCodeCLIService.parse(streamLine: line) == .ignored)
    }

    /// Half an object is what a pipe delivers when a read lands mid-line. It must be ignored
    /// rather than crash the parse — the buffer will hand it back whole on the next chunk.
    @Test func aPartialLineIsIgnoredRatherThanFatal() {
        for fragment in ["", "   ", "not json at all", #"{"type": "stream_event", "eve"#] {
            #expect(ClaudeCodeCLIService.parse(streamLine: fragment) == .ignored)
        }
    }

    // MARK: - Tool vocabulary

    /// Claude Code's tool names are not DoraX's, so they get their own mapping. An unknown one
    /// still reads as a step rather than disappearing.
    @Test func everyOfferedToolHasReadableWording() {
        #expect(ClaudeCodeCLIService.label(forCLITool: "WebFetch") == "Fetching a page…")
        #expect(ClaudeCodeCLIService.label(forCLITool: "Bash") == "Running a command…")
        #expect(ClaudeCodeCLIService.label(forCLITool: "Edit") == "Editing a file…")
        #expect(ClaudeCodeCLIService.label(forCLITool: "Klaxon").contains("Klaxon"))
    }

    // MARK: - Flags

    /// Streaming is opt-in: a caller with nowhere to show steps still gets the single object.
    @Test func streamingIsOnlyRequestedWhenSomebodyIsListening() {
        let quiet = ClaudeCodeCLIService.arguments(
            prompt: "hi", systemPrompt: nil, model: nil, access: .full,
            workingDirectory: nil, streaming: false)
        #expect(quiet.contains("json") && !quiet.contains("stream-json"))

        let streamed = ClaudeCodeCLIService.arguments(
            prompt: "hi", systemPrompt: nil, model: nil, access: .full,
            workingDirectory: nil, streaming: true)
        #expect(streamed.contains("stream-json"))
        #expect(streamed.contains("--include-partial-messages"))
        #expect(streamed.contains("--verbose"), "stream-json needs verbose to emit events")
    }
}
