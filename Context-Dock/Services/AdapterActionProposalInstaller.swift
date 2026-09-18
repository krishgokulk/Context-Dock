// AdapterActionProposalInstaller.swift
// Context-Dock
//
// Turns a proposed app action into a real adapter action, and says so in the conversation.
//
// The dock and the corner share one conversation and one engine. When the model proposes an
// app action, the message carries `hasInstallButton` and the dock draws an Install card that
// called `installFromProposal` — a method on `LauncherView`, reading `l2.*` for its scope and
// appending its confirmation to `l2.chatMessages`. The corner constructed the same message
// view with no install callback, so the same proposal, same message, same flag, had nowhere
// to become an adapter action. The user created one in the corner and nothing offered to
// keep it.
//
// Only two things in that installer were the dock's: where the scope comes from, and where
// the confirmation goes. Both surfaces read `AppChatConversation.shared` — one conversation
// shown in two places — so the confirmation has one destination. The scope is the only thing
// a caller supplies.

import Foundation

enum AdapterActionProposalInstaller {

    /// The adapter action a proposal describes. Pure, so it can be checked without a store.
    static func action(from proposal: ExtensionProposalData) -> AdapterAction {
        let actionType: AdapterActionType = {
            switch proposal.scriptType.lowercased() {
            case "applescript": return .applescript
            case "jxa": return .jxa
            default: return .shell
            }
        }()
        // Declared triggers plus every word of the name, so the action answers to how the
        // user will actually ask for it. Lowercased and sorted so the same proposal installed
        // twice compares equal instead of accumulating.
        let nameWords = proposal.name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let triggers = Array(Set((proposal.triggers.map(\.value) + nameWords).map { $0.lowercased() }))
            .sorted()

        return AdapterAction(
            id: stableID(for: proposal.name),
            name: proposal.name,
            icon: proposal.icon ?? "sparkles",
            description: proposal.description,
            triggers: triggers,
            category: "AI Workflows",
            type: actionType,
            script: proposal.script,
            // A script the model wrote runs nothing until a person has seen it. Not
            // optional for AI-authored actions, whatever the proposal says.
            requiresApproval: true,
            // A value with no label is no value: nothing to convert to, and a default
            // without a unit is a number nobody can adjust.
            valueLabel: proposal.value.map(\.label).flatMap(nonEmpty),
            valueDefault: proposal.value.flatMap { $0.label.isEmpty ? nil : $0.defaultValue })
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Derived from the name, so installing the same proposal again updates one action
    /// rather than adding a second beside it.
    ///
    /// This is the exact derivation the dock used before the lift — spaces to hyphens, then
    /// everything but letters, digits and hyphens dropped — and it must stay exact: a
    /// different rule would give every already-installed AI action a new id, and the next
    /// install of the same proposal would sit beside the old one instead of replacing it.
    /// The test that pins it caught a "cleaner" rewrite doing precisely that.
    static func stableID(for name: String) -> String {
        "ai." + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// When the action declares a value, the confirmation says so. An action that quietly
    /// takes a new number is a feature nobody uses, because nobody is told it is there —
    /// and this sentence is the one place the user is certain to read.
    static func confirmation(
        actionName: String, appName: String,
        valueLabel: String? = nil, valueDefault: String? = nil
    ) -> String {
        var text = "**\(actionName)** saved to **\(appName)**. Next time, Context Dock will "
            + "match this app action before asking AI to create another workflow."
        if let valueLabel {
            let saved = valueDefault.map { "\($0) \(valueLabel)" } ?? valueLabel
            text += " It runs at \(saved) — say a different number next time and it uses "
                + "that, without creating another action."
        }
        return text
    }

    /// Install into `bundleId`'s adapter — creating the adapter if the app has none — and
    /// post the confirmation to the shared conversation. Returns the message it posted, so a
    /// caller that keeps its own transcript can mirror it.
    @MainActor
    @discardableResult
    static func install(
        _ proposal: ExtensionProposalData, bundleId: String, appName: String
    ) async -> AIChatMessage {
        let trimmedBundle = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty else {
            let failure = AIChatMessage(
                role: .assistant,
                content: "I couldn't save this action because the scoped app is no longer available.",
                isError: true)
            AppChatConversation.shared.messages.append(failure)
            return failure
        }

        let resolvedName = appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "This App" : appName
        if AppAdapterManager.shared.adapter(for: trimmedBundle) == nil {
            await AppAdapterManager.shared.createAdapter(
                appName: resolvedName, bundleId: trimmedBundle, icon: "app.fill")
        }
        let action = action(from: proposal)
        await AppAdapterManager.shared.appendAction(action, to: trimmedBundle)

        let message = AIChatMessage(
            role: .assistant,
            content: confirmation(
                actionName: proposal.name, appName: resolvedName,
                valueLabel: action.valueLabel, valueDefault: action.valueDefault))
        AppChatConversation.shared.messages.append(message)
        return message
    }
}
