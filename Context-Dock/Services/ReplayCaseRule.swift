// ReplayCaseRule.swift
// Context-Dock
//
// Rule protocol and built-in rules for the replay runner (E8b #159).
//
// A rule inspects one ReplayCase and returns pass / fail / skip.
// Rules compose: a RunReport collects results across many cases and many rules,
// then prints a one-line pass rate so a developer can see at a glance whether
// a prompt or routing change broke any recorded behaviour.
//
// Built-in rules cover the common checks:
//   - Was a specific tool called (or not called)?
//   - Does the final answer contain (or not contain) a pattern?
//   - Was the correct scope used?
//   - Was a prompt section present?
//   - Did a context item of an expected kind appear?
//
// The injection-safety rules — which assert the model did NOT follow injected
// instructions — are built from ToolNotCalledRule + AnswerNotContainsRule.

import Foundation

// MARK: - Rule result

enum RuleResult: Sendable, Equatable {
    /// The case satisfies this rule.
    case pass
    /// The case violates this rule. `reason` says what was expected vs. found.
    case fail(String)
    /// This rule does not apply to this case (e.g. scope rule on a case with no scope).
    /// Skipped results are not counted in the pass rate.
    case skip(String)

    var isPassing: Bool {
        if case .pass = self { return true }
        return false
    }
    var isFailing: Bool {
        if case .fail = self { return true }
        return false
    }
    var isSkipped: Bool {
        if case .skip = self { return true }
        return false
    }
}

// MARK: - Rule protocol

protocol ReplayCaseRule: Sendable {
    var name: String { get }
    func check(_ case_: ReplayCase) -> RuleResult
}

// MARK: - Built-in rules

/// At least one tool call with this name must be present.
struct ToolCalledRule: ReplayCaseRule {
    let name: String
    let toolName: String

    init(_ toolName: String) {
        self.name = "tool_called(\(toolName))"
        self.toolName = toolName
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        case_.toolCalls.contains { $0.name == toolName }
            ? .pass
            : .fail("Expected tool '\(toolName)' to be called, but it was not. Calls: \(case_.toolCalls.map(\.name))")
    }
}

/// No tool call with this name may be present.
struct ToolNotCalledRule: ReplayCaseRule {
    let name: String
    let toolName: String

    init(_ toolName: String) {
        self.name = "tool_not_called(\(toolName))"
        self.toolName = toolName
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        if let call = case_.toolCalls.first(where: { $0.name == toolName }) {
            return .fail("Tool '\(toolName)' was called but must not be. Input: \(call.input)")
        }
        return .pass
    }
}

/// The final answer must contain this string (case-insensitive).
struct AnswerContainsRule: ReplayCaseRule {
    let name: String
    let pattern: String

    init(_ pattern: String) {
        self.name = "answer_contains(\(pattern))"
        self.pattern = pattern
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        case_.finalAnswer.localizedCaseInsensitiveContains(pattern)
            ? .pass
            : .fail("Expected answer to contain '\(pattern)'. Answer: \(case_.finalAnswer.prefix(120))")
    }
}

/// The final answer must NOT contain this string (case-insensitive).
struct AnswerNotContainsRule: ReplayCaseRule {
    let name: String
    let pattern: String

    init(_ pattern: String) {
        self.name = "answer_not_contains(\(pattern))"
        self.pattern = pattern
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        if case_.finalAnswer.localizedCaseInsensitiveContains(pattern) {
            return .fail("Answer must not contain '\(pattern)'. Answer: \(case_.finalAnswer.prefix(120))")
        }
        return .pass
    }
}

/// The case's scope must equal `expected`.
struct ScopeRule: ReplayCaseRule {
    let name: String
    let expected: String?

    init(_ expected: String?) {
        self.name = "scope(\(expected ?? "nil"))"
        self.expected = expected
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        guard case_.scope != nil || expected != nil else { return .pass }
        guard let actual = case_.scope else {
            return .fail("Expected scope '\(expected ?? "nil")' but case has no scope.")
        }
        return actual == expected
            ? .pass
            : .fail("Expected scope '\(expected ?? "nil")' but got '\(actual)'.")
    }
}

/// A prompt section with this key must have been sent.
struct PromptSectionPresentRule: ReplayCaseRule {
    let name: String
    let section: String

    init(_ section: String) {
        self.name = "prompt_section_present(\(section))"
        self.section = section
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        if case_.promptSections.isEmpty { return .skip("No prompt sections recorded.") }
        return case_.promptSections[section] != nil
            ? .pass
            : .fail("Expected prompt section '\(section)' but got: \(case_.promptSections.keys.sorted())")
    }
}

/// At least one resolved context item of this kind must be present.
struct ContextKindPresentRule: ReplayCaseRule {
    let name: String
    let kind: String

    init(_ kind: String) {
        self.name = "context_kind_present(\(kind))"
        self.kind = kind
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        if case_.resolvedContext.isEmpty { return .skip("No context items recorded.") }
        return case_.resolvedContext.contains { $0.kind == kind }
            ? .pass
            : .fail("Expected context item of kind '\(kind)' but got: \(case_.resolvedContext.map(\.kind))")
    }
}

/// The case must have at least one receipt ID (an approval was executed).
struct ReceiptPresentRule: ReplayCaseRule {
    let name = "receipt_present"

    func check(_ case_: ReplayCase) -> RuleResult {
        case_.receiptIDs.isEmpty
            ? .fail("Expected at least one receipt ID, but none were recorded.")
            : .pass
    }
}

/// A tool call's output must contain this string.
struct ToolOutputContainsRule: ReplayCaseRule {
    let name: String
    let toolName: String
    let pattern: String

    init(tool toolName: String, contains pattern: String) {
        self.name = "tool_output_contains(\(toolName), \(pattern))"
        self.toolName = toolName
        self.pattern = pattern
    }

    func check(_ case_: ReplayCase) -> RuleResult {
        let calls = case_.toolCalls.filter { $0.name == toolName }
        if calls.isEmpty { return .skip("Tool '\(toolName)' was not called.") }
        return calls.contains { $0.output.localizedCaseInsensitiveContains(pattern) }
            ? .pass
            : .fail("No call to '\(toolName)' had output containing '\(pattern)'.")
    }
}
