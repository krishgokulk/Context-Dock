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

enum GlobalCommandCapabilities {
    /// Capability ids are namespaced so the registry can clear/refresh just these.
    static let idPrefix = "globalcmd."

    static func register(in registry: CapabilityRegistry) {
        for command in SystemCommandsRegistry.shared.commands where command.isEnabled {
            guard isRunnable(command) else { continue }
            registry.register(makeCapability(for: command))
        }
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

    private static func riskLevel(for command: SystemCommand) -> AICapabilityRiskLevel {
        let text = (command.name + " " + command.keywords.joined(separator: " ")).lowercased()
        let destructive = ["shut down", "shutdown", "restart", "reboot", "log out", "logout", "sleep"]
        if destructive.contains(where: text.contains) { return .high }
        return .low
    }

    private static func makeCapability(for command: SystemCommand) -> AICapability {
        let slug = command.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let id = idPrefix + (slug.isEmpty ? command.id.uuidString : slug)
        let isToggle = command.interactionType == .toggle

        let valueHint =
            isToggle
            ? "on or off"
            : "optional value passed to the command (e.g. a volume level, network name)"

        return AICapability(
            id: id,
            title: command.description.isEmpty ? command.name : "\(command.name) — \(command.description)",
            appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: [
                AICapabilityInputField(name: "value", description: valueHint, required: false)
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
                    output: trimmed.isEmpty ? "Ran \(live.name)." : trimmed
                )
            }
        )
    }
}
