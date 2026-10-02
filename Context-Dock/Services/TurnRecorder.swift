// TurnRecorder.swift
// Context-Dock
//
// One record per turn: what it was sent, what it called, and what each round cost.
//
// AITokenLedger keeps one line per provider per model per day. That answers "what did this
// afternoon cost" and nothing else: which turn spent the tokens, how many rounds it took,
// which prompt section was the heavy one, and whether the prompt cache was read at all were
// all invisible. Every engine change after this one (prompt order, the tool loop, focused
// tool sets) is judged by those numbers, so they are written down per turn.
//
// Written to the turn log, and only when the turn log is on. It names providers, models,
// tools and prompt section sizes — never the question, the answer or any prompt text.
//
//     defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
//     python3 scripts/turn-cache-ratio.py
//
// Field names follow the OpenTelemetry GenAI semantic conventions where one exists
// (`gen_ai.*`, `error.type`); the rest are DoraX's own and say so (`dorax.*`).

import Foundation
import Synchronization

/// What one turn did, as written to the turn log.
nonisolated struct TurnTrace: Codable, Sendable, Equatable {

    /// One request to the model and the response it got.
    nonisolated struct Round: Codable, Sendable, Equatable {
        /// Every input token, cached or not — the OpenTelemetry definition. Anthropic reports
        /// the uncached part alone, so its rounds are normalised by `anthropicShaped`.
        var inputTokens: Int?
        /// The part of `inputTokens` served from the provider's prompt cache.
        var cacheReadTokens: Int?
        /// The part of `inputTokens` written into the prompt cache.
        var cacheWriteTokens: Int?
        var outputTokens: Int?
        /// The tools the model called in this round, in the order it called them.
        var toolCalls: [String] = []
        var finishReasons: [String]?
        /// Whether the round arrived as a stream. A streamed OpenAI-shaped round reports no
        /// usage at all, and that is recorded as absent rather than as zero.
        var streamed = false
        /// Seconds from sending the request to holding the whole response.
        var duration: Double?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "gen_ai.usage.input_tokens"
            case cacheReadTokens = "gen_ai.usage.cache_read.input_tokens"
            case cacheWriteTokens = "gen_ai.usage.cache_creation.input_tokens"
            case outputTokens = "gen_ai.usage.output_tokens"
            case toolCalls = "dorax.round.tool_calls"
            case finishReasons = "gen_ai.response.finish_reasons"
            case streamed = "dorax.round.streamed"
            case duration = "dorax.round.duration"
        }

        init(
            inputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil,
            outputTokens: Int? = nil, toolCalls: [String] = [], finishReasons: [String]? = nil,
            streamed: Bool = false, duration: Double? = nil
        ) {
            self.inputTokens = inputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.outputTokens = outputTokens
            self.toolCalls = toolCalls
            self.finishReasons = finishReasons
            self.streamed = streamed
            self.duration = duration
        }

        /// A round from a provider whose `input_tokens` leaves the cached part out — the
        /// Anthropic API and the Claude Code CLI. Summed here so that every round in the log
        /// means the same thing by input, and a cache-read ratio is one division.
        static func anthropicShaped(
            uncachedInput: Int?, cacheRead: Int?, cacheWrite: Int?, output: Int?,
            toolCalls: [String] = [], finishReason: String? = nil, streamed: Bool = false,
            duration: Double? = nil
        ) -> Round {
            let parts = [uncachedInput, cacheRead, cacheWrite]
            let input = parts.allSatisfy { $0 == nil } ? nil : parts.reduce(0) { $0 + ($1 ?? 0) }
            return Round(
                inputTokens: input, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                outputTokens: output, toolCalls: toolCalls,
                finishReasons: finishReason.map { [$0] }, streamed: streamed, duration: duration)
        }
    }

    var operation = "chat"
    var provider: String
    var model: String?
    /// Every tool the model was offered across the turn, without repeats.
    var toolsSent: [String] = []
    /// Every tool the model called, in order, repeats included.
    var toolsCalled: [String] = []
    var rounds: [Round] = []
    /// Characters per prompt section, after any trimming for the provider's budget.
    var promptSections: [String: Int] = [:]
    /// Each answer check that fired and sent the model back for another pass.
    var verifierFires: [String] = []
    /// Each time the turn took a lesser path than the one it asked for.
    var fallbacks: [String] = []
    /// How many times the turn called a provider entry point (a tool loop or the CLI). A
    /// verifier pass is a second one.
    var passes = 0
    /// Seconds from the turn's start to the first streamed fragment — or, when nothing
    /// streamed, to the first complete response.
    var timeToFirstToken: Double?
    /// Seconds from the turn's start to its end.
    var duration: Double?
    /// The Swift type of the error the turn ended with. The message is left out: it can quote
    /// the provider, and the provider can quote the prompt.
    var errorType: String?
    var cancelled = false

    var inputTokens: Int? { Self.sum(rounds.map(\.inputTokens)) }
    var cacheReadTokens: Int? { Self.sum(rounds.map(\.cacheReadTokens)) }
    var cacheWriteTokens: Int? { Self.sum(rounds.map(\.cacheWriteTokens)) }
    var outputTokens: Int? { Self.sum(rounds.map(\.outputTokens)) }

    /// A total over the rounds that reported one. Nil only when none did: a turn whose
    /// provider reports nothing has an unknown cost, not a zero one.
    private static func sum(_ values: [Int?]) -> Int? {
        let reported = values.compactMap { $0 }
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }

    init(provider: String) {
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case operation = "gen_ai.operation.name"
        case provider = "gen_ai.provider.name"
        case model = "gen_ai.request.model"
        case toolsSent = "dorax.tools.sent"
        case toolsCalled = "dorax.tools.called"
        case rounds = "dorax.rounds"
        case promptSections = "dorax.prompt.section_chars"
        case verifierFires = "dorax.verifier.fires"
        case fallbacks = "dorax.fallbacks"
        case passes = "dorax.passes"
        case timeToFirstToken = "dorax.time_to_first_token"
        case duration = "gen_ai.client.operation.duration"
        case errorType = "error.type"
        case cancelled = "dorax.cancelled"
        // Totals are written for a person reading the log; reading it back recomputes them.
        case inputTokens = "gen_ai.usage.input_tokens"
        case cacheReadTokens = "gen_ai.usage.cache_read.input_tokens"
        case cacheWriteTokens = "gen_ai.usage.cache_creation.input_tokens"
        case outputTokens = "gen_ai.usage.output_tokens"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decodeIfPresent(String.self, forKey: .operation) ?? "chat"
        provider = try c.decode(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        toolsSent = try c.decodeIfPresent([String].self, forKey: .toolsSent) ?? []
        toolsCalled = try c.decodeIfPresent([String].self, forKey: .toolsCalled) ?? []
        rounds = try c.decodeIfPresent([Round].self, forKey: .rounds) ?? []
        promptSections = try c.decodeIfPresent([String: Int].self, forKey: .promptSections) ?? [:]
        verifierFires = try c.decodeIfPresent([String].self, forKey: .verifierFires) ?? []
        fallbacks = try c.decodeIfPresent([String].self, forKey: .fallbacks) ?? []
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 0
        timeToFirstToken = try c.decodeIfPresent(Double.self, forKey: .timeToFirstToken)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        errorType = try c.decodeIfPresent(String.self, forKey: .errorType)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation, forKey: .operation)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(toolsSent, forKey: .toolsSent)
        try c.encode(toolsCalled, forKey: .toolsCalled)
        try c.encode(rounds, forKey: .rounds)
        try c.encode(promptSections, forKey: .promptSections)
        try c.encode(verifierFires, forKey: .verifierFires)
        try c.encode(fallbacks, forKey: .fallbacks)
        try c.encode(passes, forKey: .passes)
        try c.encodeIfPresent(timeToFirstToken, forKey: .timeToFirstToken)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(errorType, forKey: .errorType)
        if cancelled { try c.encode(cancelled, forKey: .cancelled) }
        try c.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try c.encodeIfPresent(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encodeIfPresent(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encodeIfPresent(outputTokens, forKey: .outputTokens)
    }
}

/// Collects one turn's trace while it runs, then writes it once.
///
/// Bound with `TurnRecorder.run`, which puts it in a task-local, so a tool loop on any actor
/// adds its rounds to the turn that started it, and two chats answering at once never share
/// a record. A turn nested in another — a verifier pass inside a scoped turn — joins the outer
/// record instead of writing its own.
nonisolated final class TurnRecorder: Sendable {
    @TaskLocal static var current: TurnRecorder?

    /// The prefix every record carries in the turn log, after its timestamp.
    static let linePrefix = "turn.trace "

    private let sink: DoraXTurnLog.Sink
    private let started: ContinuousClock.Instant
    private let state: Mutex<TurnTrace>

    init(provider: String, sink: DoraXTurnLog.Sink) {
        self.sink = sink
        self.started = .now
        self.state = Mutex(TurnTrace(provider: provider))
    }

    /// Runs `body` as one turn.
    ///
    /// Joins the turn already running when there is one. Otherwise starts a record — only if
    /// the sink is on, so a turn with logging off allocates nothing and writes nothing — and
    /// writes it when `body` returns or throws.
    @discardableResult
    static func run<T>(
        provider: String,
        sink: DoraXTurnLog.Sink = DoraXTurnLog.standard,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        if current != nil { return try await body() }
        guard sink.isEnabled else { return try await body() }
        let recorder = TurnRecorder(provider: provider, sink: sink)
        do {
            let value = try await $current.withValue(recorder) { try await body() }
            recorder.finish(error: nil)
            return value
        } catch {
            recorder.finish(error: error)
            throw error
        }
    }

    /// What has been recorded so far.
    var trace: TurnTrace { state.withLock { $0 } }

    func noteModel(_ model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        state.withLock { $0.model = model }
    }

    func notePass() {
        state.withLock { $0.passes += 1 }
    }

    func noteToolsSent(_ names: [String]) {
        state.withLock { trace in
            for name in names where !trace.toolsSent.contains(name) {
                trace.toolsSent.append(name)
            }
        }
    }

    func noteRound(_ round: TurnTrace.Round) {
        let elapsed = Self.seconds(since: started)
        state.withLock { trace in
            trace.rounds.append(round)
            trace.toolsCalled += round.toolCalls
            // A buffered round is the first the user could have seen of the answer.
            if trace.timeToFirstToken == nil { trace.timeToFirstToken = elapsed }
        }
    }

    /// Tool calls reported outside any round — the Claude Code CLI runs its own loop and
    /// reports one round for all of it, so its calls are listed at the turn level.
    func noteToolCalls(_ names: [String]) {
        guard !names.isEmpty else { return }
        state.withLock { $0.toolsCalled += names }
    }

    func notePromptSections(_ sections: [String: Int]) {
        state.withLock { $0.promptSections.merge(sections) { _, new in new } }
    }

    func noteVerifier(_ name: String) {
        state.withLock { $0.verifierFires.append(name) }
    }

    func noteFallback(_ name: String) {
        state.withLock { trace in
            // A stream that failed once is skipped for the rest of the loop, so one line per
            // kind says everything; ten identical entries would only hide the others.
            if !trace.fallbacks.contains(name) { trace.fallbacks.append(name) }
        }
    }

    /// The first fragment of the answer reached the user. Later calls change nothing.
    func noteFirstToken() {
        let elapsed = Self.seconds(since: started)
        state.withLock { trace in
            if trace.timeToFirstToken == nil { trace.timeToFirstToken = elapsed }
        }
    }

    /// Closes the record and writes it. Called once, by `run`.
    @discardableResult
    func finish(error: (any Error)?) -> TurnTrace {
        let elapsed = Self.seconds(since: started)
        let cancelled = Task.isCancelled || error is CancellationError
        let finished = state.withLock { trace -> TurnTrace in
            trace.duration = elapsed
            trace.cancelled = cancelled
            if let error, !(error is CancellationError) {
                trace.errorType = String(describing: type(of: error))
            }
            return trace
        }
        if let line = Self.line(for: finished) { sink.record(line) }
        return finished
    }

    /// The record as the turn log carries it: the prefix, then one line of JSON.
    static func line(for trace: TurnTrace) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(trace),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return linePrefix + json
    }

    /// Seconds since `instant`, to the millisecond. Finer than that is noise in a network turn.
    static func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = instant.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return (seconds * 1000).rounded() / 1000
    }

    /// Tool names out of the schemas a loop is about to send, whichever provider's shape they
    /// are in: `name` at the top (Anthropic, Gemini) or under `function` (OpenAI).
    static func toolNames(in schemas: [[String: Any]]) -> [String] {
        schemas.compactMap { schema in
            (schema["name"] as? String)
                ?? (schema["function"] as? [String: Any])?["name"] as? String
        }
    }
}

/// Reads the records back out of a turn log.
nonisolated enum TurnTraceReport {

    /// Every record in the log, oldest first. Lines that are not records — the turn log also
    /// carries free-text diagnostics — are skipped, as is a record cut off by the size limit.
    static func traces(inLog text: String) -> [TurnTrace] {
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: TurnRecorder.linePrefix) else { return nil }
            let json = line[range.upperBound...]
            return try? decoder.decode(TurnTrace.self, from: Data(json.utf8))
        }
    }

    /// Cache-read tokens over all input tokens, across the last `count` records that reported
    /// input. Nil when none did.
    static func cacheReadRatio(_ traces: [TurnTrace], last count: Int = 50) -> Double? {
        let reporting = traces.filter { $0.inputTokens != nil }.suffix(count)
        let input = reporting.reduce(0) { $0 + ($1.inputTokens ?? 0) }
        guard input > 0 else { return nil }
        let cached = reporting.reduce(0) { $0 + ($1.cacheReadTokens ?? 0) }
        return Double(cached) / Double(input)
    }
}
