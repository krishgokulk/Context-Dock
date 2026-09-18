import Testing
import Foundation
@testable import Context_Dock

// MARK: - An action can declare the one thing about it that varies
//
// A2 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// "minimise after 5 min" is the same action as "minimise after 10 min" with one number
// changed. For the saved action to be reused rather than re-authored, it has to say which
// number, in what unit, and what to use when the sentence names none. Two optional fields;
// every adapter JSON already on disk has neither and must decode exactly as before.

struct AdapterActionValueTests {

    private func action(label: String? = nil, defaultValue: String? = nil) -> AdapterAction {
        AdapterAction(
            id: "ai.minimise-after-a-delay", name: "Minimise after a delay", icon: "sparkles",
            description: "Minimises the front window after a pause", triggers: ["minimise"],
            type: .shell, script: "sleep {{value}}; osascript -e 'tell app \"Finder\" …'",
            requiresApproval: true, valueLabel: label, valueDefault: defaultValue)
    }

    /// The value declaration survives a round trip through the store's encoder.
    @Test func theValueDeclarationRoundTrips() throws {
        let original = action(label: "seconds", defaultValue: "300")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdapterAction.self, from: data)
        #expect(decoded.valueLabel == "seconds")
        #expect(decoded.valueDefault == "300")
    }

    /// Every adapter on disk predates these fields. Absent keys are absent values — not a
    /// decode failure, and not an invented default.
    @Test func anActionWithoutAValueDecodesAsBefore() throws {
        let legacy = """
            {"id":"clean-cache","name":"Clean Cache","icon":"trash","description":"",
             "triggers":["cache"],"type":"shell","script":"rm -rf ~/Library/Caches/x",
             "requiresApproval":true}
            """
        let decoded = try JSONDecoder().decode(AdapterAction.self, from: Data(legacy.utf8))
        #expect(decoded.valueLabel == nil)
        #expect(decoded.valueDefault == nil)
        #expect(decoded.script == "rm -rf ~/Library/Caches/x")
    }

    /// An action with no declaration must not gain one on the way out, or the file on disk
    /// changes for every action the user never touched.
    @Test func anActionWithoutAValueEncodesNone() throws {
        let data = try JSONEncoder().encode(action())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("valueLabel"))
        #expect(!json.contains("valueDefault"))
    }

    /// The question the runtime will ask: does this action take a value at all?
    @Test func anActionKnowsWhetherItTakesAValue() {
        #expect(action(label: "seconds", defaultValue: "300").takesValue)
        #expect(!action().takesValue)
    }

    // MARK: - A3: the value a run uses

    /// "minimise after 10 min" against a seconds action runs with 600 — the number in the
    /// sentence, in the action's unit, no model involved.
    @Test func theSentencesNumberIsTheRunsValue() {
        let a = action(label: "seconds", defaultValue: "300")
        #expect(a.value(for: "minimise after 10 min") == "600")
        #expect(a.value(for: "minimise after five minutes") == "300")
    }

    /// "minimise now" names no number: the action's own default runs, not an invented one.
    @Test func noNumberFallsBackToTheDefault() {
        #expect(action(label: "seconds", defaultValue: "300").value(for: "minimise now") == "300")
    }

    /// An action with no declaration has no value, whatever the sentence says. The number in
    /// "open tab 3" is not a parameter of an action that never asked for one.
    @Test func anActionWithoutAValueHasNone() {
        #expect(action().value(for: "open tab 3") == nil)
    }

    /// An explicit value from a caller wins over the sentence — this is what B and C hand
    /// down once they have decided.
    @Test func anExplicitValueWinsOverTheSentence() {
        let a = action(label: "seconds", defaultValue: "300")
        #expect(a.value(for: "minimise after 10 min", explicit: "45") == "45")
    }
}
