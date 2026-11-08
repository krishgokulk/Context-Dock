// ReplayCaseStore.swift
// Context-Dock
//
// Saves and loads replay cases on disk, and hosts the ReplayCaseRecorder task-local.
//
// ## On-disk layout
//
//   ~/Library/Application Support/Context-Dock/ReplayCases/<id>.json
//
// One JSON file per case, named by its UUID. The store is append-only: nothing
// deletes a file unless the user removes it manually or calls removeCase(id:).
//
// ## Recording a turn
//
//   await ReplayCaseRecorder.run(query: "...", scope: "com.apple.finder") {
//       // ... turn runs here ...
//       let recorder = ReplayCaseRecorder.current
//       recorder?.noteContextItem(kind: "file", summary: "Invoice.pdf")
//       recorder?.noteToolCall(name: "open_file", input: [...], output: "ok")
//       recorder?.noteAnswer("Here is what I found.")
//   }
//   // After the turn, saveCurrentCase() persists it:
//   await ReplayCaseRecorder.saveCurrentCase(to: .standard)
//
// ## Save-as-case hook
//
// The UI and programmatic callers use `ReplayCaseRecorder.saveCurrentCase(to:)`.
// It sanitizes the case with `ReplayCaseSanitizer` before writing.
//
// E8a (#158).

import Foundation
import Synchronization

// MARK: - ReplayCaseStore

/// Reads and writes replay case files in a directory.
///
/// A value type: tests can point it at a temporary directory without touching the real store.
struct ReplayCaseStore: Sendable {

    let directoryURL: URL
    private let sanitizer: ReplayCaseSanitizer

    init(directoryURL: URL, sanitizer: ReplayCaseSanitizer = ReplayCaseSanitizer()) {
        self.directoryURL = directoryURL
        self.sanitizer = sanitizer
    }

    /// The app's own store under Application Support.
    static let standard = ReplayCaseStore(
        directoryURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Context-Dock/ReplayCases", isDirectory: true))

    // MARK: Writing

    /// Sanitizes and saves a replay case to disk. Creates the directory if needed.
    @discardableResult
    func save(_ case_: ReplayCase) throws -> URL {
        let sanitized = sanitizer.sanitize(case_)
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("\(sanitized.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sanitized)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: Reading

    /// Loads a single case by ID.
    func load(id: String) throws -> ReplayCase {
        let fileURL = directoryURL.appendingPathComponent("\(id).json")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReplayCase.self, from: data)
    }

    /// Loads all cases in the directory, oldest first. Skips unreadable files.
    func loadAll() -> [ReplayCase] {
        guard let urls = try? FileManager.default
            .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.creationDateKey])
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { ($0.path) < ($1.path) }
            .compactMap { try? decoder.decode(ReplayCase.self, from: Data(contentsOf: $0)) }
    }

    // MARK: Deletion

    func removeCase(id: String) throws {
        let fileURL = directoryURL.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - ReplayCaseRecorder

/// Accumulates the content of one AI turn for later saving as a replay case.
///
/// Sits alongside `TurnRecorder` in the task tree: `TurnRecorder` captures metrics,
/// `ReplayCaseRecorder` captures content. Neither depends on the other — both are opt-in.
///
/// Recording is off by default (`doraxReplayCaseRecordingEnabled` UserDefaults key).
/// When off, `run(...)` runs the body unchanged with no allocation.
///
///     defaults write com.krishgokul.ContextDock doraxReplayCaseRecordingEnabled -bool YES
nonisolated final class ReplayCaseRecorder: Sendable {
    @TaskLocal static var current: ReplayCaseRecorder?

    static let enabledKey = "doraxReplayCaseRecordingEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private struct State: Sendable {
        var query: String = ""
        var scope: String?
        var resolvedContext: [ReplayCase.ContextItem] = []
        var toolCalls: [ReplayCase.ToolCallRecord] = []
        var finalAnswer: String = ""
        var receiptIDs: [String] = []
    }

    private let state = Mutex(State())
    private let startedAt: Date

    init() {
        startedAt = Date()
    }

    // MARK: - Lifecycle

    /// Runs `body` as one recorded turn.
    ///
    /// When recording is disabled, runs the body immediately with no overhead.
    /// Joins the outer recorder when nested (a verifier pass inside a turn uses the
    /// same recorder), mirroring TurnRecorder.run behaviour.
    @discardableResult
    static func run<T>(
        query: String,
        scope: String? = nil,
        defaults: UserDefaults = .standard,
        _ body: () async throws -> T
    ) async rethrows -> T {
        // Nested: join the outer recorder
        if current != nil { return try await body() }
        guard defaults.bool(forKey: enabledKey) else { return try await body() }
        let recorder = ReplayCaseRecorder()
        recorder.noteQuery(query)
        recorder.noteScope(scope)
        return try await $current.withValue(recorder) { try await body() }
    }

    /// Finalises the current turn's recorder and saves it to `store`.
    ///
    /// Call this once the turn is complete — typically at the same point where
    /// `TurnRecorder.finish` runs. Returns the saved case, or nil when no recorder is active
    /// or no TurnTrace is available.
    @discardableResult
    static func saveCurrentCase(
        to store: ReplayCaseStore = .standard,
        trace: TurnTrace? = nil
    ) throws -> ReplayCase? {
        guard let recorder = current else { return nil }
        let resolved = trace ?? TurnTrace(provider: "unknown")
        return try recorder.finish(trace: resolved, store: store)
    }

    // MARK: - Note methods

    func noteQuery(_ text: String) {
        state.withLock { $0.query = text }
    }

    func noteScope(_ bundleID: String?) {
        state.withLock { $0.scope = bundleID }
    }

    func noteContextItem(kind: String, summary: String) {
        state.withLock {
            $0.resolvedContext.append(ReplayCase.ContextItem(kind: kind, summary: summary))
        }
    }

    func noteToolCall(
        name: String,
        input: [String: Any] = [:],
        output: String,
        durationSeconds: Double? = nil
    ) {
        let jsonInput = input.mapValues { JSONValue.from(any: $0) }
        state.withLock {
            $0.toolCalls.append(ReplayCase.ToolCallRecord(
                name: name, input: jsonInput,
                output: output, durationSeconds: durationSeconds))
        }
    }

    func noteAnswer(_ text: String) {
        state.withLock { $0.finalAnswer = text }
    }

    func noteReceipt(_ id: String) {
        state.withLock { $0.receiptIDs.append(id) }
    }

    // MARK: - Finish

    private func finish(trace: TurnTrace, store: ReplayCaseStore) throws -> ReplayCase {
        let s = state.withLock { $0 }
        let case_ = ReplayCase(
            capturedAt: startedAt,
            query: s.query,
            scope: s.scope,
            resolvedContext: s.resolvedContext,
            promptSections: trace.promptSections,
            toolCalls: s.toolCalls,
            finalAnswer: s.finalAnswer,
            trace: trace,
            receiptIDs: s.receiptIDs)
        try store.save(case_)
        return case_
    }

    // MARK: - Snapshot (for testing)

    /// Returns the case as it stands, without writing to disk.
    func snapshot(trace: TurnTrace) -> ReplayCase {
        let s = state.withLock { $0 }
        return ReplayCase(
            capturedAt: startedAt,
            query: s.query,
            scope: s.scope,
            resolvedContext: s.resolvedContext,
            promptSections: trace.promptSections,
            toolCalls: s.toolCalls,
            finalAnswer: s.finalAnswer,
            trace: trace,
            receiptIDs: s.receiptIDs)
    }
}
