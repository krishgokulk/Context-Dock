// SolvedSkillMatch.swift
// Context-Dock
//
// The before-the-model half of a solved skill: does this sentence already have a saved
// answer, and if so, run it.
//
// Matching is deliberately tight. A solved skill replays tool calls with no model in the loop
// to notice that the sentence meant something else, so a loose match is a wrong answer given
// confidently. The request's non-slot words must equal the skill's exactly — same words, same
// app — before the slots are filled from the new sentence and the calls replayed through the
// ordinary executor and its gates. Any mismatch, or any failure at run time, returns nil so
// the turn falls through to the model, which is the repair path.

import Foundation
import OSLog

enum SolvedSkillMatch {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "SolvedSkill")

    // MARK: - Match (pure)

    /// The skill whose shape this request fits, with its slots filled from the request, or nil.
    nonisolated static func match(query: String, bundleId: String, skills: [SolvedSkill])
        -> (SolvedSkill, filled: [String: String])?
    {
        guard let derived = SolvedSkillCapture.derive(query: query) else { return nil }

        for skill in skills where skill.bundleId == bundleId {
            // Same words, nothing looser. A superset or a near-miss would run the recorded
            // calls under a request they do not answer.
            guard skill.nonSlotWords == derived.nonSlotWords else { continue }

            var filled: [String: String] = [:]
            for slot in skill.slots {
                guard let value = derived.values[slot.name] else { break }
                filled[slot.name] = value
            }
            guard filled.count == skill.slots.count else { continue }
            return (skill, filled)
        }
        return nil
    }

    // MARK: - Run (wired)

    /// Replays the skill's calls with the slots filled, through `executeWithApproval` — the
    /// same gate the model's own tool calls meet. Returns the answer, or nil on any failure so
    /// the caller runs the model instead.
    @MainActor
    static func run(_ skill: SolvedSkill, filled: [String: String], scope: GeneralChatScope)
        async -> AppScopedChatService.Answer?
    {
        var receipts: [DoraXActionReceipt] = []
        var outputs: [String] = []

        for call in skill.toolCalls {
            let input = call.argTemplate.mapValues { template -> String in
                var value = template
                for (slot, fill) in filled {
                    value = value.replacingOccurrences(of: "{\(slot)}", with: fill)
                }
                return value
            }

            let result: AICapabilityExecutionResult
            do {
                result = try await AIExecutionEngine.shared.executeWithApproval(
                    AIActionPlan(
                        capability: call.capability,
                        input: input,
                        explanation: "Saved skill"),
                    context: .none,
                    chatScope: scope,
                    userRequest: skill.queryTemplate)
            } catch {
                log.notice("saved skill run failed: \(error.localizedDescription, privacy: .public)")
                SolvedSkillStore.shared.markRun(id: skill.id, success: false)
                return nil
            }
            guard result.success else {
                SolvedSkillStore.shared.markRun(id: skill.id, success: false)
                return nil
            }
            receipts.append(
                DoraXActionReceipt(command: call.capability, output: result.output, success: true))
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        SolvedSkillStore.shared.markRun(id: skill.id, success: true)
        return AppScopedChatService.Answer(
            text: outputs.joined(separator: "\n\n"),
            toolChips: skill.toolCalls.map(\.capability),
            evidenceReceipts: receipts,
            trace: ["Used saved skill (no model)"])
    }
}
