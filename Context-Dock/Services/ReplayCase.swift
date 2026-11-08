// ReplayCase.swift
// Context-Dock
//
// A versioned snapshot of one AI turn, used as an offline test fixture.
//
// Goal: turn real turns into test cases so prompt and routing changes can be benchmarked
// offline rather than tuned by feel. Captures query, scope, resolved context, prompt
// sections, every tool call with exact inputs and outputs, the final answer, and receipts.
// Personal data is stripped by ReplayCaseSanitizer before the case reaches disk.
//
// E8a (#158). The companion replay runner (E8b #159) reads these.

import Foundation

/// A versioned snapshot of one AI turn.
///
/// Every field that might hold personal data is passed through `ReplayCaseSanitizer` before
/// the case is written to disk. See that type for a list of what is stripped and replaced.
struct ReplayCase: Codable, Sendable {

    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: String
    var capturedAt: Date

    /// The user's query, sanitized.
    var query: String
    /// App bundle identifier, "global" for Global Context, or nil when unknown.
    var scope: String?
    /// Context items resolved for the turn (file summaries, tabs, selection, etc.).
    var resolvedContext: [ContextItem]
    /// Characters per prompt section, mirroring TurnTrace.promptSections.
    var promptSections: [String: Int]
    /// Every tool call the model made, in order.
    var toolCalls: [ToolCallRecord]
    /// The final answer delivered to the user, sanitized.
    var finalAnswer: String
    /// TurnTrace for token metrics, timing, and round structure.
    var trace: TurnTrace
    /// ApprovalExecutionReceipt IDs written during the turn (E7b, #157).
    var receiptIDs: [String]

    // MARK: - Nested types

    /// One piece of resolved context fed to the model.
    struct ContextItem: Codable, Sendable, Equatable {
        /// Category: "file", "tab", "selection", "clipboard", "app_state", "capability", …
        var kind: String
        /// A sanitized one-line description (e.g. a filename with the home path replaced).
        var summary: String

        init(kind: String, summary: String) {
            self.kind = kind
            self.summary = summary
        }
    }

    /// One tool call: name, sanitized input and output.
    struct ToolCallRecord: Codable, Sendable, Equatable {
        var name: String
        /// JSON object the model passed to the tool, sanitized.
        var input: [String: JSONValue]
        /// Text the tool returned, sanitized.
        var output: String
        var durationSeconds: Double?

        init(
            name: String,
            input: [String: JSONValue] = [:],
            output: String = "",
            durationSeconds: Double? = nil
        ) {
            self.name = name
            self.input = input
            self.output = output
            self.durationSeconds = durationSeconds
        }
    }

    // MARK: - Init

    init(
        id: String = UUID().uuidString,
        capturedAt: Date = Date(),
        query: String,
        scope: String? = nil,
        resolvedContext: [ContextItem] = [],
        promptSections: [String: Int] = [:],
        toolCalls: [ToolCallRecord] = [],
        finalAnswer: String,
        trace: TurnTrace,
        receiptIDs: [String] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.query = query
        self.scope = scope
        self.resolvedContext = resolvedContext
        self.promptSections = promptSections
        self.toolCalls = toolCalls
        self.finalAnswer = finalAnswer
        self.trace = trace
        self.receiptIDs = receiptIDs
    }
}

// MARK: - JSONValue

/// A JSON-safe value type for tool call inputs and outputs.
///
/// Tool inputs are heterogeneous JSON objects; this gives them a Codable representation
/// without losing type information or requiring existential `Any`. Mirrors the shape of a
/// decoded JSON tree so a replay runner can feed it back to a tool stub unchanged.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON type")
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Helpers

    /// Convert from `[String: Any]` (tool input dictionaries from the model).
    static func from(any value: Any) -> JSONValue {
        switch value {
        case is NSNull: return .null
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map { from(any: $0) })
        case let v as [String: Any]: return .object(v.mapValues { from(any: $0) })
        default: return .string(String(describing: value))
        }
    }

    /// Apply a string transform recursively, leaving non-string scalars unchanged.
    func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let s): return .string(transform(s))
        case .array(let arr): return .array(arr.map { $0.mapStrings(transform) })
        case .object(let dict): return .object(dict.mapValues { $0.mapStrings(transform) })
        default: return self
        }
    }
}
