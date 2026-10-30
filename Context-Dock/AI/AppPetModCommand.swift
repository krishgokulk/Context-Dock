// AppPetModCommand.swift
// Context-Dock
//
// Parser and executor for the /mods command (§7).
// Supports listing modes, switching modes per Pet, targeting participants in Combined Chat,
// and honest refusal with available choices on unsupported or ambiguous requests.

import Foundation

/// Result of evaluating a `/mods` user command.
enum AppPetModCommandResult: Equatable, Sendable {
    /// Lists the supported modes for an App Pet.
    case listModes(
        participant: ConversationParticipant,
        modes: [AppPetModeManifest],
        activeModeID: String?
    )

    /// Successfully switched the active mode for a Pet participant.
    case switchedMode(
        participant: ConversationParticipant,
        mode: AppPetModeManifest,
        previousModeID: String?
    )

    /// The requested mode is unsupported or ambiguous for this Pet.
    case unsupportedMode(
        participant: ConversationParticipant,
        requestedName: String,
        availableModes: [AppPetModeManifest]
    )

    /// In Combined Chat, the named participant was not found.
    case unsupportedParticipant(
        requestedName: String,
        availableParticipants: [ConversationParticipant]
    )

    /// General Chat without an active Pet does not have Pet modes.
    case generalChatNotSupported

    /// Formatted message text to show in the chat conversation.
    var userFacingMessage: String {
        switch self {
        case .listModes(let participant, let modes, let activeModeID):
            var lines = ["Supported modes for **\(participant.displayName) Pet**:"]
            for mode in modes {
                let isActive = mode.id == activeModeID || (activeModeID == nil && mode.id == modes.first?.id)
                let activeBadge = isActive ? " *(Active)*" : ""
                let iconGlyph = mode.icon != nil ? " " : ""
                lines.append("• **\(mode.name)**\(activeBadge) — \(mode.summary)")
            }
            lines.append("")
            lines.append("Type `/mods <mode>` to switch mode (e.g. `/mods \(modes.first?.name.lowercased() ?? "assist")`).")
            return lines.joined(separator: "\n")

        case .switchedMode(let participant, let mode, _):
            return "Switched **\(participant.displayName) Pet** mode to **\(mode.name)**.\n*\(mode.summary)*"

        case .unsupportedMode(let participant, let requestedName, let availableModes):
            let choices = availableModes.map(\.name).joined(separator: ", ")
            return "Unknown mode \"\(requestedName)\" for **\(participant.displayName) Pet**.\nAvailable choices: \(choices)."

        case .unsupportedParticipant(let requestedName, let availableParticipants):
            let choices = availableParticipants.map(\.displayName).joined(separator: ", ")
            return "App \"\(requestedName)\" is not connected to this conversation.\nConnected Pets: \(choices)."

        case .generalChatNotSupported:
            return "General Chat does not use Pet modes. Select an App Pet or enter an App scope to customize modes with `/mods`."
        }
    }

    /// Whether this result mutates the active mode.
    var newActiveMode: (participant: ConversationParticipant, modeID: String)? {
        guard case .switchedMode(let participant, let mode, _) = self else { return nil }
        return (participant, mode.id)
    }
}

/// Command parser and evaluator for `/mods`.
enum AppPetModCommand {

    /// Checks if a query is a `/mods` or `/mod` command.
    static func isModCommand(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/mods") || trimmed.hasPrefix("/mod")
    }

    /// Evaluates a `/mods` query against current conversation participants and active modes.
    ///
    /// - Parameters:
    ///   - query: Raw query text (e.g. `/mods`, `/mods research`, `/mods Safari compare`)
    ///   - participants: Connected participants in this conversation
    ///   - focusedParticipant: Focused participant in Combined Chat (or default Pet)
    ///   - activeModes: Currently active mode IDs keyed by participant canonicalKey
    ///   - registry: Manifest registry providing supported modes
    static func resolve(
        query: String,
        participants: ParticipantSet,
        focusedParticipant: ConversationParticipant? = nil,
        activeModes: [String: String] = [:],
        registry: AppPetManifestRegistry = .shared
    ) -> AppPetModCommandResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isModCommand(trimmed) else { return nil }

        // Strip leading command token (/mods or /mod)
        var remainder = ""
        if trimmed.hasPrefix("/mods") {
            remainder = String(trimmed.dropFirst("/mods".count)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("/mod") {
            remainder = String(trimmed.dropFirst("/mod".count)).trimmingCharacters(in: .whitespaces)
        }

        // If no participants, this is unscoped General Chat
        if participants.isEmpty && focusedParticipant == nil {
            return .generalChatNotSupported
        }

        // Resolve primary participant to target
        let targetParticipant = focusedParticipant ?? participants.first

        // Parse arguments
        let tokens = remainder.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        switch tokens.count {
        case 0:
            // e.g. "/mods"
            guard let participant = targetParticipant else {
                return .generalChatNotSupported
            }
            let modes = registry.supportedModes(for: participant.petID)
            let activeMode = activeModes[participant.petID.canonicalKey] ?? modes.first?.id
            return .listModes(participant: participant, modes: modes, activeModeID: activeMode)

        case 1:
            // e.g. "/mods research" or in Combined Chat "/mods Safari"
            let arg = tokens[0]

            // Check if arg is a participant name in Combined Chat
            if participants.count >= 2,
               let namedParticipant = participants.first(where: {
                   $0.displayName.caseInsensitiveCompare(arg) == .orderedSame
                       || $0.petID.dockBundleID.caseInsensitiveCompare(arg) == .orderedSame
               }) {
                let modes = registry.supportedModes(for: namedParticipant.petID)
                let activeMode = activeModes[namedParticipant.petID.canonicalKey] ?? modes.first?.id
                return .listModes(participant: namedParticipant, modes: modes, activeModeID: activeMode)
            }

            guard let participant = targetParticipant else {
                return .generalChatNotSupported
            }

            let modes = registry.supportedModes(for: participant.petID)
            if let resolved = registry.resolveMode(named: arg, for: participant.petID) {
                let prev = activeModes[participant.petID.canonicalKey]
                return .switchedMode(participant: participant, mode: resolved, previousModeID: prev)
            } else if participants.count >= 2 {
                return .unsupportedParticipant(requestedName: arg, availableParticipants: Array(participants))
            } else {
                return .unsupportedMode(participant: participant, requestedName: arg, availableModes: modes)
            }

        default:
            // e.g. "/mods Safari research"
            let first = tokens[0]
            let second = tokens.dropFirst().joined(separator: " ")

            // First check if first token matches a participant
            if let namedParticipant = participants.first(where: {
                $0.displayName.caseInsensitiveCompare(first) == .orderedSame
                    || $0.petID.dockBundleID.caseInsensitiveCompare(first) == .orderedSame
            }) {
                let modes = registry.supportedModes(for: namedParticipant.petID)
                if let resolved = registry.resolveMode(named: second, for: namedParticipant.petID) {
                    let prev = activeModes[namedParticipant.petID.canonicalKey]
                    return .switchedMode(participant: namedParticipant, mode: resolved, previousModeID: prev)
                } else {
                    return .unsupportedMode(participant: namedParticipant, requestedName: second, availableModes: modes)
                }
            } else if participants.count >= 2 {
                // In Combined Chat, named participant was not found
                return .unsupportedParticipant(requestedName: first, availableParticipants: Array(participants))
            } else {
                // In single-Pet chat, treat entire remainder as mode name
                guard let participant = targetParticipant else {
                    return .generalChatNotSupported
                }
                let modes = registry.supportedModes(for: participant.petID)
                let modeName = tokens.joined(separator: " ")
                if let resolved = registry.resolveMode(named: modeName, for: participant.petID) {
                    let prev = activeModes[participant.petID.canonicalKey]
                    return .switchedMode(participant: participant, mode: resolved, previousModeID: prev)
                } else {
                    return .unsupportedMode(participant: participant, requestedName: modeName, availableModes: modes)
                }
            }
        }
    }
}
