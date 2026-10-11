import Foundation
import Testing

@testable import Context_Dock

// The per-turn record in the turn log (#150).
//
// Every test owns its switch and its file: a private UserDefaults suite and a temporary log.
// Nothing here reads or writes `UserDefaults.standard` or the app's own turns.log, so these
// can run beside DoraXTurnLogTests in any order without making #169 worse.

struct TurnRecorderTests {

    /// A sink nobody else can see, switched on or off.
    private struct OwnedSink {
        let sink: DoraXTurnLog.Sink
        let fileURL: URL
        let suiteName: String

        init(enabled: Bool) {
            suiteName = "TurnRecorderTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(enabled, forKey: DoraXTurnLog.enabledKey)
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("turn-recorder-\(UUID().uuidString).log")
            sink = DoraXTurnLog.Sink(defaults: defaults, fileURL: fileURL)
        }

        /// What reached the file, after every queued write has landed.
        func contents() -> String? {
            sink.flush()
            return try? String(contentsOf: fileURL, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: fileURL)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - One record per turn

    @Test func aTwoRoundTurnIsOneRecordWithBothRoundsAndTheirTotals() async throws {
        let owned = OwnedSink(enabled: true)
        defer { owned.remove() }

        let answer = try await TurnRecorder.run(provider: "anthropic", sink: owned.sink) {
            let recorder = try #require(TurnRecorder.current)
            recorder.notePass()
            recorder.noteModel("claude-test")
            recorder.noteToolsSent(["read_screen", "run_command"])
            recorder.notePromptSections(["identity": 1200, "memory": 300])
            // Round one: the model reads the screen. The cache is written.
            recorder.noteRound(
                .anthropicShaped(
                    uncachedInput: 100, cacheRead: 0, cacheWrite: 4000, output: 50,
                    toolCalls: ["read_screen"], finishReason: "tool_use"))
            // Round two: the same prefix is read back from the cache, and it answers.
            recorder.noteFirstToken()
            recorder.noteRound(
                .anthropicShaped(
                    uncachedInput: 150, cacheRead: 4000, cacheWrite: 0, output: 200,
                    finishReason: "end_turn", streamed: true))
            return "done"
        }
        #expect(answer == "done")

        let log = try #require(owned.contents())
        let records = log.split(separator: "\n").filter { $0.contains(TurnRecorder.linePrefix) }
        #expect(records.count == 1)

        let trace = try #require(TurnTraceReport.traces(inLog: log).first)
        #expect(trace.provider == "anthropic")
        #expect(trace.model == "claude-test")
        #expect(trace.passes == 1)
        #expect(trace.rounds.count == 2)
        #expect(trace.toolsSent == ["read_screen", "run_command"])
        #expect(trace.toolsCalled == ["read_screen"])
        #expect(trace.promptSections == ["identity": 1200, "memory": 300])
        // Input is every input token, cached or not, so the ratio is one division.
        #expect(trace.rounds[0].inputTokens == 4100)
        #expect(trace.rounds[1].inputTokens == 4150)
        #expect(trace.inputTokens == 8250)
        #expect(trace.cacheReadTokens == 4000)
        #expect(trace.cacheWriteTokens == 4000)
        #expect(trace.outputTokens == 250)
        #expect(trace.rounds[1].streamed)
        #expect(trace.timeToFirstToken != nil)
        #expect(trace.duration != nil)
        #expect(trace.errorType == nil)

        // The totals are in the line itself, under the OpenTelemetry names, for a person
        // reading the log without a decoder.
        #expect(log.contains("\"gen_ai.usage.input_tokens\":8250"))
        #expect(log.contains("\"gen_ai.usage.cache_read.input_tokens\":4000"))
        #expect(log.contains("\"gen_ai.provider.name\":\"anthropic\""))
    }

    @Test func loggingOffWritesNothingAndBindsNothing() async throws {
        let owned = OwnedSink(enabled: false)
        defer { owned.remove() }

        let sawRecorder = try await TurnRecorder.run(provider: "anthropic", sink: owned.sink) {
            TurnRecorder.current != nil
        }

        #expect(!sawRecorder)
        owned.sink.flush()
        #expect(!FileManager.default.fileExists(atPath: owned.fileURL.path))
    }

    /// A verifier pass inside a scoped turn is the same turn: one record, two passes.
    @Test func aNestedTurnJoinsTheOuterRecord() async throws {
        let owned = OwnedSink(enabled: true)
        defer { owned.remove() }

        try await TurnRecorder.run(provider: "openAI", sink: owned.sink) {
            TurnRecorder.current?.notePass()
            TurnRecorder.current?.noteRound(.init(inputTokens: 10, outputTokens: 1))
            TurnRecorder.current?.noteVerifier("answer_verifier.unperformed_work")
            try await TurnRecorder.run(provider: "openAI", sink: owned.sink) {
                TurnRecorder.current?.notePass()
                TurnRecorder.current?.noteRound(.init(inputTokens: 20, outputTokens: 2))
            }
        }

        let traces = TurnTraceReport.traces(inLog: try #require(owned.contents()))
        #expect(traces.count == 1)
        #expect(traces.first?.passes == 2)
        #expect(traces.first?.rounds.count == 2)
        #expect(traces.first?.inputTokens == 30)
        #expect(traces.first?.verifierFires == ["answer_verifier.unperformed_work"])
    }

    @Test func aTurnThatThrowsIsStillRecordedWithItsErrorTypeOnly() async throws {
        struct ProviderSaidNo: Error {}
        let owned = OwnedSink(enabled: true)
        defer { owned.remove() }

        await #expect(throws: ProviderSaidNo.self) {
            try await TurnRecorder.run(provider: "kimi", sink: owned.sink) {
                TurnRecorder.current?.noteFallback("stream_to_buffered")
                TurnRecorder.current?.noteFallback("stream_to_buffered")
                throw ProviderSaidNo()
            }
        }

        let trace = try #require(TurnTraceReport.traces(inLog: owned.contents() ?? "").first)
        #expect(trace.errorType == "ProviderSaidNo")
        #expect(trace.fallbacks == ["stream_to_buffered"])
        #expect(trace.rounds.isEmpty)
        // Nothing reported is unknown, not zero.
        #expect(trace.inputTokens == nil)
    }

    @Test func twoTurnsAreTwoRecords() async throws {
        let owned = OwnedSink(enabled: true)
        defer { owned.remove() }

        for _ in 0..<2 {
            try await TurnRecorder.run(provider: "anthropic", sink: owned.sink) {
                TurnRecorder.current?.noteRound(.init(inputTokens: 5, outputTokens: 5))
            }
        }

        #expect(TurnTraceReport.traces(inLog: try #require(owned.contents())).count == 2)
    }

    // MARK: - What a round means

    @Test func anUnreportedCountIsLeftOutRatherThanWrittenAsZero() throws {
        let streamed = TurnTrace.Round(toolCalls: ["read_screen"], streamed: true)
        var trace = TurnTrace(provider: "openAI")
        trace.rounds = [streamed]

        let line = try #require(TurnRecorder.line(for: trace))
        #expect(!line.contains("gen_ai.usage"))
        #expect(
            TurnTrace.Round.anthropicShaped(
                uncachedInput: nil, cacheRead: nil, cacheWrite: nil, output: nil
            ).inputTokens == nil)
    }

    @Test func aRecordReadsBackAsTheSameRecord() throws {
        var trace = TurnTrace(provider: "googleGemini")
        trace.model = "gemini-test"
        trace.passes = 1
        trace.rounds = [.init(inputTokens: 900, cacheReadTokens: 600, outputTokens: 40)]
        trace.verifierFires = ["evidence_sufficiency"]
        trace.duration = 1.25

        let line = try #require(TurnRecorder.line(for: trace))
        let read = TurnTraceReport.traces(inLog: "2026-10-02T00:00:00Z \(line)\n")
        #expect(read == [trace])
    }

    @Test func toolNamesAreReadFromEveryProvidersSchemaShape() {
        let schemas: [[String: Any]] = [
            ["name": "read_screen", "input_schema": [:] as [String: Any]],
            ["type": "function", "function": ["name": "run_command"] as [String: Any]],
            ["description": "no name at all"],
        ]
        #expect(TurnRecorder.toolNames(in: schemas) == ["read_screen", "run_command"])
    }

    // MARK: - Cache-read ratio over the last 50 turns

    @Test func theCacheReadRatioCoversTheLastFiftyTurnsThatReportedInput() throws {
        var log = "2026-10-02T00:00:00Z tools sent (3): a,b,c\n"
        // Ten old turns that read nothing from the cache, then fifty that read half.
        for index in 0..<60 {
            var trace = TurnTrace(provider: "anthropic")
            trace.rounds = [
                .init(inputTokens: 1000, cacheReadTokens: index < 10 ? 0 : 500, outputTokens: 10)
            ]
            log += "2026-10-02T00:00:00Z \(try #require(TurnRecorder.line(for: trace)))\n"
        }
        // A turn whose provider reported nothing does not dilute the ratio.
        log += "2026-10-02T00:00:00Z \(try #require(TurnRecorder.line(for: TurnTrace(provider: "claudeBridge"))))\n"

        let traces = TurnTraceReport.traces(inLog: log)
        #expect(traces.count == 61)
        let ratio = try #require(TurnTraceReport.cacheReadRatio(traces, last: 50))
        print("cache-read ratio over the last 50 recorded turns: \(ratio)")
        #expect(ratio == 0.5)
        #expect(TurnTraceReport.cacheReadRatio([TurnTrace(provider: "x")]) == nil)
    }

    // MARK: - Where the numbers come from

    @Test func promptSectionCountsAreWhatTheModelIsSentAfterTheBudget() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY")
        prompt.set(.memory, "MEMORY")
        prompt.set(.reference, String(repeating: "r", count: 5000))

        #expect(
            prompt.characterCounts(for: .anthropic)
                == ["identity": 8, "memory": 6, "reference": 5000])
        // On-device cannot hold the reference block, so it is dropped — and not counted.
        let onDevice = prompt.characterCounts(for: .onDevice)
        #expect(onDevice["reference"] == nil)
        #expect(onDevice["identity"] == 8)
    }

    @Test func aClaudeCodeResultLineBecomesOneRoundWithCacheReadsCounted() throws {
        let line = """
            {"type":"result","subtype":"success","is_error":false,"result":"hi",\
            "usage":{"input_tokens":12,"cache_creation_input_tokens":300,\
            "cache_read_input_tokens":9000,"output_tokens":40}}
            """
        let round = try #require(ClaudeCodeCLIService.traceRound(streamLine: line))
        #expect(round.inputTokens == 9312)
        #expect(round.cacheReadTokens == 9000)
        #expect(round.cacheWriteTokens == 300)
        #expect(round.outputTokens == 40)
        #expect(round.finishReasons == ["success"])
        #expect(ClaudeCodeCLIService.traceRound(streamLine: #"{"type":"assistant"}"#) == nil)
        #expect(ClaudeCodeCLIService.traceRound(streamLine: "not json") == nil)
    }
}
