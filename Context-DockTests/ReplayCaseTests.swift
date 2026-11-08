// ReplayCaseTests.swift
// Context-DockTests
//
// Offline tests for E8a replay case infrastructure (#158).
//
//   1. Saving a recorded turn produces a valid fixture file on disk.
//   2. The fixture reloads accurately: inputs and expected tool outputs survive the round-trip.
//   3. The privacy sanitizer strips personal identifiers, paths, and sensitive tokens.
//
// No network, no model, no UserDefaults.standard writes.

import Foundation
import Testing

@testable import Context_Dock

// MARK: - Helpers

private func makeTrace(provider: String = "test") -> TurnTrace {
    var t = TurnTrace(provider: provider)
    t.model = "test-model"
    t.passes = 1
    t.promptSections = ["system": 500, "tools": 200]
    return t
}

private func tempStore() -> (ReplayCaseStore, cleanup: () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplayCaseTests-\(UUID().uuidString)", isDirectory: true)
    let store = ReplayCaseStore(directoryURL: dir)
    return (store, { try? FileManager.default.removeItem(at: dir) })
}

// MARK: - Schema and round-trip

@Suite("ReplayCase schema")
struct ReplayCaseSchemaTests {

    @Test func roundTripPreservesAllFields() throws {
        let original = ReplayCase(
            id: "test-id-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            query: "List my downloads",
            scope: "com.apple.finder",
            resolvedContext: [
                .init(kind: "file", summary: "Invoice.pdf"),
                .init(kind: "tab", summary: "example.com"),
            ],
            promptSections: ["system": 1024, "tools": 512],
            toolCalls: [
                .init(
                    name: "list_files",
                    input: ["path": .string("<home>/Downloads")],
                    output: "Invoice.pdf, Report.pdf",
                    durationSeconds: 0.3)
            ],
            finalAnswer: "You have 2 files in Downloads.",
            trace: makeTrace(),
            receiptIDs: ["RCPT-123"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReplayCase.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.schemaVersion == ReplayCase.currentSchemaVersion)
        #expect(decoded.query == original.query)
        #expect(decoded.scope == original.scope)
        #expect(decoded.resolvedContext == original.resolvedContext)
        #expect(decoded.promptSections == original.promptSections)
        #expect(decoded.toolCalls == original.toolCalls)
        #expect(decoded.finalAnswer == original.finalAnswer)
        #expect(decoded.receiptIDs == original.receiptIDs)
        #expect(decoded.trace.provider == "test")
        #expect(decoded.trace.model == "test-model")
    }

    @Test func jsonValueRoundTrips() throws {
        let values: [JSONValue] = [
            .null,
            .bool(true),
            .int(42),
            .double(3.14),
            .string("hello"),
            .array([.int(1), .string("x")]),
            .object(["a": .bool(false), "b": .int(7)]),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(JSONValue.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test func jsonValueFromAny() {
        let dict: [String: Any] = [
            "flag": true, "count": 3, "label": "ok",
            "items": ["a", "b"],
            "nested": ["x": 1] as [String: Any],
        ]
        let converted = dict.mapValues { JSONValue.from(any: $0) }
        #expect(converted["flag"] == .bool(true))
        #expect(converted["count"] == .int(3))
        #expect(converted["label"] == .string("ok"))
        if case .array(let arr) = converted["items"] {
            #expect(arr == [.string("a"), .string("b")])
        } else {
            Issue.record("Expected array")
        }
    }

    @Test func jsonValueMapStrings() {
        let v = JSONValue.object([
            "path": .string("/Users/alice/file.txt"),
            "size": .int(42),
            "tags": .array([.string("/Users/alice/x"), .string("safe")]),
        ])
        let sanitized = v.mapStrings { $0.replacingOccurrences(of: "/Users/alice", with: "<home>") }
        if case .object(let d) = sanitized {
            #expect(d["path"] == .string("<home>/file.txt"))
            #expect(d["size"] == .int(42))
            if case .array(let arr) = d["tags"] {
                #expect(arr[0] == .string("<home>/x"))
                #expect(arr[1] == .string("safe"))
            } else { Issue.record("Expected array in tags") }
        } else {
            Issue.record("Expected object")
        }
    }
}

// MARK: - Store (save / load)

@Suite("ReplayCaseStore")
struct ReplayCaseStoreTests {

    @Test func savingProducesAValidJSONFile() throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        let case_ = ReplayCase(
            query: "open mail",
            finalAnswer: "Opened Mail.app",
            trace: makeTrace())
        let url = try store.save(case_)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(ReplayCase.self, from: data)
        #expect(loaded.query == "open mail")
        #expect(loaded.finalAnswer == "Opened Mail.app")
    }

    @Test func loadByIDMatchesSaved() throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        let original = ReplayCase(
            id: "fixture-abc",
            query: "how many tabs",
            toolCalls: [.init(name: "count_tabs", input: [:], output: "5")],
            finalAnswer: "You have 5 tabs.",
            trace: makeTrace())
        try store.save(original)

        let loaded = try store.load(id: "fixture-abc")
        #expect(loaded.query == "how many tabs")
        #expect(loaded.toolCalls.count == 1)
        #expect(loaded.toolCalls[0].name == "count_tabs")
        #expect(loaded.toolCalls[0].output == "5")
        #expect(loaded.finalAnswer == "You have 5 tabs.")
    }

    @Test func loadAllReturnsAllSavedCases() throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        for i in 1...3 {
            let c = ReplayCase(id: "case-\(i)", query: "query \(i)", finalAnswer: "ans \(i)", trace: makeTrace())
            try store.save(c)
        }
        let all = store.loadAll()
        #expect(all.count == 3)
    }

    @Test func toolCallInputsAndOutputsSurviveRoundTrip() throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        let call = ReplayCase.ToolCallRecord(
            name: "run_script",
            input: [
                "script": .string("open /Applications/Mail.app"),
                "timeout": .int(5),
                "env": .object(["TERM": .string("xterm")]),
            ],
            output: "exit 0",
            durationSeconds: 0.12)
        let original = ReplayCase(
            query: "open mail",
            toolCalls: [call],
            finalAnswer: "Done.",
            trace: makeTrace())
        try store.save(original)

        let loaded = try store.load(id: original.id)
        #expect(loaded.toolCalls.count == 1)
        let r = loaded.toolCalls[0]
        #expect(r.name == "run_script")
        #expect(r.input["script"] == .string("open /Applications/Mail.app"))
        #expect(r.input["timeout"] == .int(5))
        #expect(r.input["env"] == .object(["TERM": .string("xterm")]))
        #expect(r.output == "exit 0")
        #expect(r.durationSeconds == 0.12)
    }
}

// MARK: - Privacy sanitizer

@Suite("ReplayCaseSanitizer")
struct ReplayCaseSanitizerTests {

    private let sanitizer = ReplayCaseSanitizer(homeDirectory: "/Users/testuser")

    // MARK: Home paths

    @Test func stripsExactHomeDirectory() {
        #expect(sanitizer.sanitize("/Users/testuser/Documents/file.txt") == "<home>/Documents/file.txt")
    }

    @Test func stripsGenericUsersPaths() {
        #expect(sanitizer.sanitize("open /Users/someone/Downloads") == "open <home>/Downloads")
    }

    @Test func stripsHomeInNestedToolInput() throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        var case_ = ReplayCase(
            query: "find file",
            toolCalls: [
                .init(
                    name: "find_file",
                    input: ["path": .string("/Users/testuser/Desktop/notes.txt")],
                    output: "Found at /Users/testuser/Desktop/notes.txt")
            ],
            finalAnswer: "It is in /Users/testuser/Desktop/notes.txt",
            trace: makeTrace())
        let sanitized = ReplayCaseSanitizer(homeDirectory: "/Users/testuser").sanitize(case_)
        #expect(sanitized.toolCalls[0].input["path"] == .string("<home>/Desktop/notes.txt"))
        #expect(sanitized.toolCalls[0].output == "Found at <home>/Desktop/notes.txt")
        #expect(sanitized.finalAnswer == "It is in <home>/Desktop/notes.txt")
    }

    // MARK: Emails

    @Test func stripsEmailAddresses() {
        #expect(sanitizer.sanitize("Contact alice@example.com for help.") == "Contact <email> for help.")
    }

    @Test func stripsEmailInQuery() {
        let case_ = ReplayCase(
            query: "email bob@corp.io the report",
            finalAnswer: "Sent.",
            trace: makeTrace())
        let s = sanitizer.sanitize(case_)
        #expect(s.query == "email <email> the report")
    }

    // MARK: Tokens

    @Test func stripsAPIKeyWithSkPrefix() {
        #expect(sanitizer.sanitize("key: sk-abc123XYZdef456GHI789") == "key: <token>")
    }

    @Test func stripsGitHubPersonalAccessToken() {
        #expect(sanitizer.sanitize("token: ghp_abcdefghijklmnopqrstuvwx") == "token: <token>")
    }

    @Test func stripsLongHexString() {
        let sha = "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3"
        #expect(sanitizer.sanitize("hash: \(sha)") == "hash: <token>")
    }

    @Test func doesNotStripShortAlphanumeric() {
        // Short IDs like receipt IDs and version strings should survive
        #expect(sanitizer.sanitize("version 1.2.3") == "version 1.2.3")
        #expect(sanitizer.sanitize("RCPT-abc123") == "RCPT-abc123")
    }

    @Test func doesNotStripUUIDs() {
        // UUIDs (8-4-4-4-12) are kept — they are case IDs and receipt IDs, not API secrets.
        // The long-hex strip only fires on runs ≥ 40 chars with no UUID dashes.
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        #expect(sanitizer.sanitize(uuid) == uuid)
    }

    // MARK: Store saves sanitized form

    @Test func storeSavesTheSanitizedCase() throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        let sanitizer = ReplayCaseSanitizer(homeDirectory: "/Users/testuser")
        let rawStore = ReplayCaseStore(directoryURL: store.directoryURL, sanitizer: sanitizer)

        let raw = ReplayCase(
            query: "my email is alice@test.com and my key is sk-secretXYZ123ABC456",
            finalAnswer: "/Users/testuser/file.txt",
            trace: makeTrace())
        try rawStore.save(raw)

        let loaded = try rawStore.load(id: raw.id)
        #expect(!loaded.query.contains("alice@test.com"))
        #expect(loaded.query.contains("<email>"))
        #expect(!loaded.finalAnswer.contains("/Users/testuser"))
        #expect(loaded.finalAnswer.contains("<home>"))
    }
}

// MARK: - Recorder

@Suite("ReplayCaseRecorder")
struct ReplayCaseRecorderTests {

    @Test func recorderCapturesAllNotes() async throws {
        let suiteName = "ReplayCaseRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ReplayCaseRecorder.enabledKey)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        var captured: ReplayCase?

        await ReplayCaseRecorder.run(query: "open safari", scope: "com.apple.Safari", defaults: defaults) {
            let r = ReplayCaseRecorder.current
            r?.noteContextItem(kind: "tab", summary: "example.com")
            r?.noteToolCall(
                name: "open_url",
                input: ["url": "https://example.com"],
                output: "opened",
                durationSeconds: 0.1)
            r?.noteAnswer("Opened example.com in Safari.")
            r?.noteReceipt("RCPT-001")

            let trace = makeTrace(provider: "test-provider")
            captured = ReplayCaseRecorder.current?.snapshot(trace: trace)
        }

        let c = try #require(captured)
        #expect(c.query == "open safari")
        #expect(c.scope == "com.apple.Safari")
        #expect(c.resolvedContext.count == 1)
        #expect(c.resolvedContext[0].kind == "tab")
        #expect(c.resolvedContext[0].summary == "example.com")
        #expect(c.toolCalls.count == 1)
        #expect(c.toolCalls[0].name == "open_url")
        #expect(c.toolCalls[0].input["url"] == .string("https://example.com"))
        #expect(c.toolCalls[0].output == "opened")
        #expect(c.finalAnswer == "Opened example.com in Safari.")
        #expect(c.receiptIDs == ["RCPT-001"])
        #expect(c.trace.provider == "test-provider")
    }

    @Test func recorderIsNoOpWhenDisabled() async {
        let suiteName = "ReplayCaseRecorderTests.disabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: ReplayCaseRecorder.enabledKey)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        await ReplayCaseRecorder.run(query: "test", defaults: defaults) {
            #expect(ReplayCaseRecorder.current == nil)
        }
    }

    @Test func recorderSavesToStore() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }

        let suiteName = "ReplayCaseRecorderTests.save.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ReplayCaseRecorder.enabledKey)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        var caseID: String?

        try await ReplayCaseRecorder.run(query: "list apps", defaults: defaults) {
            ReplayCaseRecorder.current?.noteAnswer("Here are your apps.")
            let trace = makeTrace()
            if let saved = try ReplayCaseRecorder.saveCurrentCase(to: store, trace: trace) {
                caseID = saved.id
            }
        }

        let id = try #require(caseID)
        let loaded = try store.load(id: id)
        #expect(loaded.query == "list apps")
        #expect(loaded.finalAnswer == "Here are your apps.")
    }
}
