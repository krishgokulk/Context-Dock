// AIScriptSkillRecorder.swift
// Context-Dock
//
// Rung 2 of the execution ladder: AI scripts that succeed become learned recipes.
//
// Safety rules (§8 of the agent-harness spec):
//   Rule 1 (verify-discard): only save when success == true.
//   Rule 2 (untrusted guard): discard if hasUntrustedContent is true.
//   Rule 3 (templated names): use SolvedSkillCapture.derive on the user query,
//           never the model's reason text. A leftover value blocks the save.
//   Rule 4 (reads auto-save, writes offered): classification.shouldAutoExecute
//           drives the split.

import Combine
import Foundation

/// Turn context passed from the execution site into the recorder.
struct AIScriptContext {
    let bundleID: String
    let appName: String
    let userQuery: String
    let slotContext: SlotDerivationContext
    let hasUntrustedContent: Bool
}

@MainActor
final class AIScriptSkillRecorder {
    static let shared = AIScriptSkillRecorder()

    nonisolated static let namePrefix = "Script: "

    struct PendingOffer {
        let skill: AdapterSkill
        let bundleID: String
        let store: SkillStore
    }

    @Published var pendingOffer: PendingOffer?

    private init() {}

    // MARK: - Pure recipe builder (testable without store)

    /// Applies all safety rules and returns the recipe skill, or nil if any rule rejects it.
    nonisolated static func makeRecipe(
        command: String,
        success: Bool,
        bundleID: String,
        appName: String,
        userQuery: String,
        slotContext: SlotDerivationContext = .empty,
        hasUntrustedContent: Bool = false,
        appVersion: String = ""
    ) -> AdapterSkill? {
        // Rule 1: verified success only.
        guard success else { return nil }
        // Rule 2: untrusted-turn guard.
        guard !hasUntrustedContent else { return nil }
        // Rule 3: slot derivation — name must come from a template, never a literal.
        guard !userQuery.isEmpty else { return nil }
        guard let derived = SolvedSkillCapture.derive(
            query: userQuery, bundleId: bundleID, context: slotContext),
            !derived.hasLeftoverValue
        else { return nil }

        let title = String(derived.template.prefix(48))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let displayName = appName.isEmpty ? "General" : appName
        let body = """
            Learned automatically from an AI script in \(displayName) that succeeded.

            Command:
            \(command)

            Re-run with run_command when the same task comes up again. \
            Adapt the slot values ({file}, {app}, etc.) from the current request \
            before running.
            """
        return AdapterSkill(
            adapterBundleId: bundleID,
            name: namePrefix + title,
            summary: "How DoraX ran a script for \"\(title)\""
                + (appName.isEmpty ? "." : " in \(appName)."),
            instructions: body,
            // H2: filed under the job, not the name.
            jobKey: LearnedSkillJob.key(
                scope: bundleID, nonSlotWords: derived.nonSlotWords,
                slotNames: derived.slots.map(\.name)),
            rung: LearnedSkillJob.Rung.script,
            learnedAppVersion: appVersion)
    }

    // MARK: - Runtime record (store side effects)

    /// Records a completed AI-script run. Reads auto-save; writes queue a user offer.
    func record(
        command: String,
        success: Bool,
        context: AIScriptContext,
        isRead: Bool,
        store: SkillStore = .shared
    ) {
        // H2 staleness: a failed script counts against the recipe for the same job.
        if !success,
            let key = LearnedSkillJob.key(
                query: context.userQuery, bundleId: context.bundleID,
                context: context.slotContext)
        {
            store.noteLearnedFailure(jobKey: key, bundleId: context.bundleID)
            return
        }
        guard let skill = Self.makeRecipe(
            command: command,
            success: success,
            bundleID: context.bundleID,
            appName: context.appName,
            userQuery: context.userQuery,
            slotContext: context.slotContext,
            hasUntrustedContent: context.hasUntrustedContent,
            appVersion: SkillStore.appVersion(context.bundleID)
        ) else { return }

        if isRead {
            // Rule 4: reads auto-save, under the job key and its conflict order (H2).
            store.saveLearned(skill)
        } else {
            // Rule 4: writes queue "Save as a skill?" offer.
            pendingOffer = PendingOffer(skill: skill, bundleID: context.bundleID, store: store)
        }
    }

    func acceptOffer() {
        guard let offer = pendingOffer else { return }
        pendingOffer = nil
        offer.store.saveLearned(offer.skill)
    }

    func discardOffer() {
        pendingOffer = nil
    }
}
