// GlobalCommandCapabilities.swift
// Context-Dock
//
// Exposes the user's Global Commands (SystemCommandsRegistry) to the general AI
// chat as executable capabilities — so the assistant can run "turn on Bluetooth",
// "set volume 30", "sleep the Mac", or any user-authored command, alongside app
// adapters and MCP tools. Provider-only pickers (Quick Note, Windows) and no-op
// placeholder scripts are skipped — there's nothing for the AI to run.

import AppKit
import Foundation
import IOBluetooth

enum GlobalCommandCapabilities {
    /// Capability ids are namespaced so the registry can clear/refresh just these.
    static let idPrefix = "globalcmd."

    static func register(in registry: CapabilityRegistry) {
        for command in SystemCommandsRegistry.shared.commands where command.isEnabled {
            guard isRunnable(command) else { continue }
            registry.register(makeCapability(for: command))
        }
    }

    /// Cheap semantic gate used before General Chat decides a short phrase is merely
    /// conversation. Global Context already treats names and keywords as commands; chat
    /// must consult the same source or phrases such as "dark mode" never reach the
    /// registered `globalcmd.appearance` capability.
    @MainActor
    static func hasSemanticMatch(_ query: String) -> Bool {
        bestMatchingCommand(for: query) != nil
    }

    /// Exact installed-command routing for imperative General Chat requests. The model is
    /// useful for fuzzy discovery, but an explicit "run <command name>" must not depend on
    /// whether it remembers to issue a tool call.
    @MainActor
    static func explicitRunMatch(for query: String) -> (command: SystemCommand, id: String)? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let actionSignals = ["run ", "execute ", "open ", "start ", "launch "]
        guard actionSignals.contains(where: q.hasPrefix) else { return nil }
        guard let command = SystemCommandsRegistry.shared.commands
            .filter({ $0.isEnabled && isRunnable($0) })
            .sorted(by: { $0.name.count > $1.name.count })
            .first(where: { q.contains($0.name.lowercased()) })
        else { return nil }
        return (command, capabilityID(for: command))
    }

    static func presetValues(for command: SystemCommand) -> [String] {
        for keyword in command.keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("presets:") || lower.hasPrefix("preset:") else { continue }
            let raw = trimmed.split(separator: ":", maxSplits: 1).dropFirst().first
                .map(String.init) ?? ""
            let values = raw
                .components(separatedBy: CharacterSet(charactersIn: "|;/"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty { return values }
        }
        return []
    }

    /// Read the live value of an interactive Global Command when the request is a status
    /// question or an ambiguous compact phrase. This is deliberately read-only: explicit
    /// mutations ("turn on", "set", "disable") continue through the normal capability,
    /// approval and verification pipeline.
    @MainActor
    static func liveStateAnswer(for query: String) async -> (label: String, answer: String)? {
        guard !requestsMutation(query),
              let command = bestMatchingCommand(for: query),
              command.interactionType != .none
        else { return nil }

        let script = command.valueScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let readsBluetooth = command.keywords.contains("provider:bluetooth")
        let readsWiFi = command.keywords.contains("provider:wifi")
        guard readsBluetooth || readsWiFi || !script.isEmpty else { return nil }

        if readsWiFi {
            let raw = WiFiNetworkProvider.isPoweredOn() ? "on" : "off"
            return formattedStateAnswer(command: command, raw: raw)
        }
        let actionType = command.actionType
        let output: String? = await Task.detached(priority: .userInitiated) {
            if readsBluetooth {
                return IOBluetoothHostController.default().powerState.rawValue == 1 ? "on" : "off"
            }
            return SystemCommandInteractiveRunner.runForOutput(
                script: script, actionType: actionType)
        }.value
        guard let raw = output?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }

        return formattedStateAnswer(command: command, raw: raw)
    }

    private static func formattedStateAnswer(
        command: SystemCommand, raw: String
    ) -> (label: String, answer: String) {
        let normalized = raw.lowercased()
        let answer: String
        if command.interactionType == .toggle {
            let enabled = ["on", "true", "yes", "1", "enabled"].contains(normalized)
            if command.name.caseInsensitiveCompare("Appearance") == .orderedSame {
                answer = "Dark mode is currently \(enabled ? "enabled" : "disabled") on your Mac."
            } else {
                answer = "\(command.name) is currently \(enabled ? "on" : "off")."
            }
        } else {
            answer = "\(command.name) is currently \(raw)."
        }
        return ("Global Command · \(command.name) · live state", answer)
    }

    /// Every installed command this query could mean, best first.
    ///
    /// Exposed because the deterministic resolver could not see Global Commands at all —
    /// it knows adapters, menus, Shortcuts, CLI and MCP, and nothing about the user's own
    /// installed actions. The only door that did know was `explicitRunMatch`, which
    /// requires a verb prefix *and* the command's literal name, so "trash bin" opened
    /// neither and a matching command sat one call away while the model improvised.
    ///
    /// Plural on purpose. Two commands can match a phrase equally well — a built-in and
    /// one the user wrote — and picking between them by alphabetical tie-break, on a list
    /// that contains Empty Trash, is not a decision code should make quietly.
    @MainActor
    static func matchingCommands(for query: String)
        -> [(command: SystemCommand, id: String, score: Int)]
    {
        rankedMatches(for: query).map { (command: $0.command, id: capabilityID(for: $0.command), score: $0.score) }
    }

    @MainActor
    private static func bestMatchingCommand(for query: String) -> SystemCommand? {
        rankedMatches(for: query).first?.command
    }

    @MainActor
    private static func rankedMatches(for query: String) -> [(command: SystemCommand, score: Int)] {
        let terms = significantTerms(query)
        guard !terms.isEmpty else { return [] }
        return SystemCommandsRegistry.shared.commands
            .filter { $0.isEnabled && isRunnable($0) }
            .map { command -> (command: SystemCommand, score: Int) in
                let name = command.name.lowercased()
                let searchable = ([command.name, command.description] + command.keywords)
                    .joined(separator: " ").lowercased()
                var score = terms.reduce(0) { $0 + (searchable.contains($1) ? 2 : 0) }
                if query.lowercased().contains(name) { score += 5 }
                return (command, score)
            }
            // One incidental word is not a command match. Calendar questions were being
            // hijacked by Keep Awake because the old threshold accepted any overlap at all.
            // An explicit command name scores +5; otherwise require two meaningful terms.
            .filter { $0.score >= 4 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.command.name < $1.command.name
            }
    }

    private static func significantTerms(_ query: String) -> [String] {
        let noise: Set<String> = [
            "a", "an", "the", "my", "mac", "please", "currently", "current",
            "status", "is", "are", "what", "which", "show", "tell", "me",
        ]
        return query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !noise.contains($0) }
    }

    private static func requestsMutation(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let mutationSignals = [
            "turn on", "turn off", "enable", "disable", "set ", "switch to",
            "change to", "toggle", "increase", "decrease", "mute", "unmute",
        ]
        return mutationSignals.contains(where: q.contains)
    }

    private static func isRunnable(_ command: SystemCommand) -> Bool {
        // Provider pickers (notepad/windows) carry a placeholder script — nothing to run.
        if command.keywords.contains(where: {
            let k = $0.lowercased()
            return k == "provider:notepad" || k == "provider:windows"
        }) {
            return false
        }
        let script = command.script.trimmingCharacters(in: .whitespacesAndNewlines)
        return !script.isEmpty && script.lowercased() != "return"
    }

    static func riskLevel(for command: SystemCommand) -> AICapabilityRiskLevel {
        let text = (command.name + " " + command.keywords.joined(separator: " ")).lowercased()
        let destructive = ["shut down", "shutdown", "restart", "reboot", "log out", "logout", "sleep"]
        if destructive.contains(where: text.contains) { return .high }
        switch command.actionType {
        case .bash, .applescript, .jxa, .scriptFile:
            return .high
        case .url, .file, .aiPrompt:
            return .low
        }
    }

    static func capabilityID(for command: SystemCommand) -> String {
        let slug = command.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return idPrefix + (slug.isEmpty ? command.id.uuidString : slug)
    }

    private static func makeCapability(for command: SystemCommand) -> AICapability {
        let id = capabilityID(for: command)
        let isToggle = command.interactionType == .toggle
        let requiresValue = command.script.contains("$CD_QUERY")
            || command.script.contains("${CD_QUERY}")

        let valueHint =
            isToggle
            ? "on or off"
            : "optional value passed to the command (e.g. a volume level, network name)"

        return AICapability(
            id: id,
            title: command.description.isEmpty ? command.name : "\(command.name) — \(command.description)",
            appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: [
                AICapabilityInputField(
                    name: "value", description: valueHint, required: requiresValue)
            ]),
            riskLevel: riskLevel(for: command),
            executor: { request in
                let commandID = command.id
                // Re-resolve the live command so edits/toggled state are current.
                guard
                    let live = SystemCommandsRegistry.shared.commands.first(where: {
                        $0.id == commandID
                    })
                else {
                    return AICapabilityExecutionResult(
                        success: false, output: "Command no longer exists")
                }
                let value = request.input["value"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let normalized = value.lowercased()

                // `$CD_QUERY` is the command's target. Running with an empty target makes
                // `open "$CD_QUERY"` resolve to a working directory and unexpectedly opens
                // Finder. Fail closed and let chat ask for the missing site/path/value.
                if requiresValue, value.isEmpty {
                    if !presetValues(for: live).isEmpty {
                        ScopedListPanelManager.shared.pin(live)
                        return AICapabilityExecutionResult(
                            success: true,
                            output: "Opened the pinned \(live.name) picker. Choose a value there to run the command."
                        )
                    }
                    return AICapabilityExecutionResult(
                        success: false,
                        output: "\(live.name) needs a value before it can run. Ask the user which target to use."
                    )
                }

                // An omitted value on an interactive command means "read it", not "run a
                // mutation with an empty argument". This makes the same capability useful
                // for compact status phrases while keeping explicit values on the write path.
                if normalized.isEmpty, command.interactionType != .none {
                    let valueScript = live.valueScript.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !valueScript.isEmpty {
                        let actionType = live.actionType
                        let current = await Task.detached {
                            SystemCommandInteractiveRunner.runForOutput(
                                script: valueScript, actionType: actionType)
                        }.value?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let current, !current.isEmpty {
                            return AICapabilityExecutionResult(
                                success: true, output: "\(live.name) current value: \(current)")
                        }
                    }
                }

                // Radio power toggles use the native path (same as the UI switch).
                if normalized == "on" || normalized == "off" {
                    if live.keywords.contains(where: { $0.lowercased() == "provider:bluetooth" }) {
                        BluetoothDeviceProvider.setPower(normalized == "on")
                        return AICapabilityExecutionResult(
                            success: true, output: "Bluetooth turned \(normalized).")
                    }
                    if live.keywords.contains(where: { $0.lowercased() == "provider:wifi" }) {
                        WiFiNetworkProvider.setPower(normalized == "on")
                        return AICapabilityExecutionResult(
                            success: true, output: "Wi-Fi turned \(normalized).")
                    }
                }

                let output = await Task.detached {
                    SystemCommandInteractiveRunner.runForOutput(command: live, value: value)
                }.value

                let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return AICapabilityExecutionResult(
                    success: true,
                    output: trimmed.isEmpty
                        ? "Ran \(live.name). The executor returned successfully; no independent outcome check is configured for this command."
                        : trimmed
                )
            }
        )
    }
}
