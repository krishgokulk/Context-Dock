import Foundation
import Testing

@testable import Context_Dock

// MARK: - TurnFocus + AIToolBudget.apply Tests (#156: E7a)
//
// Verifies that the focus-based tool filter behaves as specified:
// 1. `.answer`  → empty tool list (zero tools sent)
// 2. `.inspect` → all tools except write tools
// 3. `.act`     → write tools plus the essential lookup set
// 4. `.verify`  → only verify-set tools
// 5. `find_capability` survives inspect and verify (never trimmed)
// 6. TurnFocus round-trips through Codable

struct TurnFocusTests {

    // MARK: - Helpers

    /// Build a minimal OpenAI-shaped tool schema with the given name.
    private func openAITool(_ name: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": "test tool \(name)",
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ] as [String: Any],
        ]
    }

    /// A representative cross-section of tool names across all three categories.
    private var mixedTools: [[String: Any]] {
        let names: [String] = [
            // write tools
            "run_command", "ax_act", "send_keys", "compose_message",
            // read / inspect tools
            "find_capability", "run_capability", "read_tool_result",
            "verify_outcome", "ax_read",
            // neutral tools (not in write or verify sets)
            "get_context", "summarise_text",
        ]
        return names.map { openAITool($0) }
    }

    // MARK: - .answer

    @Test func answerReturnsEmptyTools() {
        let result = AIToolBudget.apply(focus: .answer, to: mixedTools)
        #expect(result.isEmpty, "answer focus must send zero tools")
    }

    @Test func answerOnEmptyInputIsEmpty() {
        let result = AIToolBudget.apply(focus: .answer, to: [])
        #expect(result.isEmpty)
    }

    // MARK: - .inspect

    @Test func inspectExcludesWriteTools() {
        let result = AIToolBudget.apply(focus: .inspect, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        for writeName in AIToolBudget.writeToolNames {
            #expect(!names.contains(writeName), "inspect must not include write tool \(writeName)")
        }
    }

    @Test func inspectKeepsFindCapability() {
        let result = AIToolBudget.apply(focus: .inspect, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        #expect(names.contains("find_capability"), "inspect must keep find_capability")
    }

    @Test func inspectIsNonEmpty() {
        let result = AIToolBudget.apply(focus: .inspect, to: mixedTools)
        #expect(!result.isEmpty)
    }

    // MARK: - .act

    @Test func actIncludesWriteTools() {
        let result = AIToolBudget.apply(focus: .act, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        // Every write tool that is in mixedTools should appear
        for name in ["run_command", "ax_act", "send_keys", "compose_message"] {
            #expect(names.contains(name), "act must include write tool \(name)")
        }
    }

    @Test func actKeepsFindCapabilityAndReadToolResult() {
        let result = AIToolBudget.apply(focus: .act, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        #expect(names.contains("find_capability"))
        #expect(names.contains("read_tool_result"))
    }

    @Test func actExcludesNeutralTools() {
        let result = AIToolBudget.apply(focus: .act, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        #expect(!names.contains("get_context"), "act must not include neutral tool get_context")
        #expect(!names.contains("summarise_text"))
    }

    // MARK: - .verify

    @Test func verifyContainsOnlyVerifySet() {
        let result = AIToolBudget.apply(focus: .verify, to: mixedTools)
        let names = Set(result.compactMap { AIToolBudget.toolName($0) })
        #expect(names.isSubset(of: AIToolBudget.verifyToolNames),
                "verify must contain only verify-set tools, got extras: \(names.subtracting(AIToolBudget.verifyToolNames))")
    }

    @Test func verifyKeepsFindCapability() {
        let result = AIToolBudget.apply(focus: .verify, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        #expect(names.contains("find_capability"))
    }

    @Test func verifyExcludesWriteTools() {
        let result = AIToolBudget.apply(focus: .verify, to: mixedTools)
        let names = result.compactMap { AIToolBudget.toolName($0) }
        for writeName in AIToolBudget.writeToolNames {
            #expect(!names.contains(writeName), "verify must not include write tool \(writeName)")
        }
    }

    // MARK: - Anthropic schema shape

    @Test func applyWorksWithAnthropicSchemas() {
        let anthropicTools: [[String: Any]] = [
            ["name": "ax_act", "description": "write"],
            ["name": "find_capability", "description": "lookup"],
            ["name": "ax_read", "description": "read"],
        ]
        let inspect = AIToolBudget.apply(focus: .inspect, to: anthropicTools)
        let names = inspect.compactMap { AIToolBudget.toolName($0) }
        #expect(!names.contains("ax_act"))
        #expect(names.contains("find_capability"))
        #expect(names.contains("ax_read"))
    }

    // MARK: - TurnFocus Codable

    @Test func turnFocusCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for focus in [TurnFocus.answer, .inspect, .act, .verify] {
            let data = try encoder.encode(focus)
            let decoded = try decoder.decode(TurnFocus.self, from: data)
            #expect(decoded == focus, "TurnFocus.\(focus.rawValue) did not round-trip")
        }
    }

    // MARK: - TurnTrace.Round focus field

    @Test func turnTraceRoundFocusCodable() throws {
        var round = TurnTrace.Round()
        round.focus = .inspect
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(round)
        let decoded = try decoder.decode(TurnTrace.Round.self, from: data)
        #expect(decoded.focus == .inspect)

        // Absent focus decodes as nil (old log entries stay readable).
        var roundNoFocus = TurnTrace.Round()
        roundNoFocus.focus = nil
        let data2 = try encoder.encode(roundNoFocus)
        let decoded2 = try decoder.decode(TurnTrace.Round.self, from: data2)
        #expect(decoded2.focus == nil)
    }

    // MARK: - TurnTrace top-level focus field

    @Test func turnTraceFocusCodable() throws {
        var trace = TurnTrace(provider: "test")
        trace.focus = .act
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(trace)
        let decoded = try decoder.decode(TurnTrace.self, from: data)
        #expect(decoded.focus == .act)
    }
}
