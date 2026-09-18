import Testing
import Foundation
@testable import Context_Dock

// MARK: - The saved adjustable action is reachable from the chat that saved it
//
// The owner authored "Minimize Code After Delay" in Code's app chat, was told it runs at 60
// seconds and that saying a different number would use that, and then said:
//
//     "now minimise code app after 2min"
//
// The answer was "Nothing ran. Code not minimised. Missing piece: no tool in this chat fires
// adapter actions." Three defects between the saved action and that sentence:
//
// 1. `requestsChange` has no window verbs, so the sentence reads as a QUESTION and
//    `toolsAvailable(for:)` strips run_adapter_action from the turn. The model was telling
//    the truth: it had no tool. ChatRouteResolver.isActionRequest gained those verbs for
//    exactly this reason and this list — the one its own comment calls "one list, used by
//    everything that needs to tell a question from an instruction" — never did.
// 2. run_adapter_action passed the model's `reason` string as the action's query, so the
//    value would have been read from "Requested in chat" rather than from what the user
//    said. An adjustable action reached this way could only ever run at its default.
// 3. The app inventory lists actions as "id — name", so a model has no way to know an
//    action takes a value at all.

struct AdjustableActionReachTests {

    // MARK: - 1. A window verb is an instruction

    @MainActor @Test func minimisingAnAppIsNotAQuestion() {
        let resolver = GeneralAIActionResolver.shared
        #expect(!resolver.asksOnly("now minimise code app after 2min"))
        #expect(!resolver.asksOnly("minimize safari"))
        #expect(!resolver.asksOnly("hide the finder window"))
        #expect(!resolver.asksOnly("zoom this window"))
    }

    /// The other half: loosening it must not turn questions about windows into commands.
    @MainActor @Test func askingAboutAWindowIsStillAQuestion() {
        let resolver = GeneralAIActionResolver.shared
        #expect(resolver.asksOnly("which window is minimised?"))
        #expect(resolver.asksOnly("what does minimise do"))
    }

    /// The consequence that was actually reported: with the sentence read as an instruction,
    /// the turn keeps the tool that runs the saved action.
    @MainActor @Test func anActionTurnKeepsTheToolThatRunsSavedActions() {
        let names = AgentToolRegistry.shared.toolNamesAvailable(
            for: "now minimise code app after 2min")
        #expect(names.contains("run_adapter_action"))
    }

    @MainActor @Test func aQuestionStillLosesIt() {
        let names = AgentToolRegistry.shared.toolNamesAvailable(for: "what is this app")
        #expect(!names.contains("run_adapter_action"))
    }

    // MARK: - 2. The value comes from what the user said

    private func minimiseAfterADelay() -> AdapterAction {
        AdapterAction(
            id: "ai.minimize-code-after-delay", name: "Minimize Code After Delay",
            icon: "sparkles", description: "Waits a set number of seconds, then minimises",
            triggers: ["minimize", "minimise", "delay"], type: .shell,
            script: "sleep {{value}}; osascript -e 'minimise'",
            requiresApproval: true, valueLabel: "seconds", valueDefault: "60")
    }

    /// "after 2min" is 120 seconds. The model's own one-line reason is not where that number
    /// lives, and an action run from a reason string would silently use its default.
    @Test func theValueIsReadFromTheUsersSentenceNotTheModelsReason() {
        let action = minimiseAfterADelay()
        #expect(action.value(for: "now minimise code app after 2min") == "120")
        #expect(action.value(for: "Requested in chat") == "60")
    }

    /// An explicit value from the tool call wins, so a model that names the number is obeyed
    /// rather than second-guessed.
    @Test func anExplicitValueFromTheToolCallIsUsed() {
        #expect(minimiseAfterADelay().value(for: "whatever", explicit: "120") == "120")
    }

    // MARK: - 3. The inventory says the action takes a value

    @MainActor @Test func theInventoryLineNamesTheValueAndItsDefault() {
        let line = ScopedAppPromptBuilder.inventoryLine(for: minimiseAfterADelay())
        #expect(line.contains("ai.minimize-code-after-delay"))
        #expect(line.contains("Minimize Code After Delay"))
        // Enough for the model to pass one: the unit, and what it runs at otherwise.
        #expect(line.contains("seconds"))
        #expect(line.contains("60"))
    }

    /// An action with nothing to adjust reads exactly as it did before.
    @MainActor @Test func anOrdinaryActionsLineIsUnchanged() {
        let plain = AdapterAction(
            id: "ai.clean", name: "Clean", icon: "trash", description: "",
            triggers: [], type: .shell, script: "true", requiresApproval: false)
        #expect(ScopedAppPromptBuilder.inventoryLine(for: plain) == "    • ai.clean — Clean")
    }
}
