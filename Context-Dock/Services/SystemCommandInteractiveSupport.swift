// SystemCommandInteractiveSupport.swift
// Context-Dock
//
// Live state + execution for interactive system commands (slider / toggle rows).
//
// Interactive controls bypass the regular run pipeline on purpose: they execute
// silently (no toast per slider tick) and inject the control's value through the
// same CD_QUERY channel the natural-language path uses, so existing command
// scripts work unchanged.

import AppKit
import Combine
import Foundation
import IOBluetooth

// MARK: - Live value cache

@MainActor
final class InteractiveCommandState: ObservableObject {
    static let shared = InteractiveCommandState()

    /// Slider value, or 1/0 for toggles.
    @Published private(set) var values: [UUID: Double] = [:]
    private var fetchedAt: [UUID: Date] = [:]
    private var inflight: Set<UUID> = []

    private init() {}

    func value(for command: SystemCommand) -> Double? {
        values[command.id]
    }

    /// Optimistic local update so the control tracks the user immediately.
    func setLocal(_ value: Double, for id: UUID) {
        values[id] = value
        fetchedAt[id] = Date()
    }

    /// Fetch the real system value in the background (debounced by age).
    func refreshIfNeeded(_ command: SystemCommand, maxAge: TimeInterval = 4) {
        guard command.interactionType != .none else { return }
        let script = command.valueScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let readsBluetoothPower = command.keywords.contains("provider:bluetooth")
        let readsWiFiPower = command.keywords.contains("provider:wifi")
        guard readsBluetoothPower || readsWiFiPower || !script.isEmpty else { return }
        let id = command.id
        if let last = fetchedAt[id], Date().timeIntervalSince(last) < maxAge { return }
        guard inflight.insert(id).inserted else { return }

        let actionType = command.actionType
        let isToggle = command.interactionType == .toggle
        Task.detached(priority: .utility) {
            let output: String?
            if readsBluetoothPower {
                let powerState = IOBluetoothHostController.default().powerState
                output = powerState.rawValue == 1 ? "on" : "off"
            } else if readsWiFiPower {
                output = WiFiNetworkProvider.isPoweredOn() ? "on" : "off"
            } else {
                output = SystemCommandInteractiveRunner.runForOutput(
                    script: script, actionType: actionType
                )
            }
            await MainActor.run {
                let state = InteractiveCommandState.shared
                state.inflight.remove(id)
                state.fetchedAt[id] = Date()
                guard let output else { return }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if isToggle {
                    let on = ["on", "true", "yes", "1", "enabled"].contains(trimmed)
                    state.values[id] = on ? 1 : 0
                } else if let value = Double(trimmed) {
                    state.values[id] = value
                }
            }
        }
    }
}

// MARK: - Silent execution with a control value

enum SystemCommandInteractiveRunner {
    /// Run the command's script with the control value injected as CD_QUERY.
    /// No feedback UI — interactive controls show their own state.
    static func run(_ command: SystemCommand, value: String) {
        // The Bluetooth / Wi-Fi power switches write natively rather than through
        // the command's AppleScript / networksetup path, which failed silently and
        // left the radio in the wrong state. Device/network selection (any other
        // value) still flows through the script below.
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedValue == "on" || normalizedValue == "off" {
            if command.keywords.contains("provider:bluetooth") {
                Task.detached(priority: .userInitiated) {
                    BluetoothDeviceProvider.setPower(normalizedValue == "on")
                }
                return
            }
            if command.keywords.contains("provider:wifi") {
                Task.detached(priority: .userInitiated) {
                    WiFiNetworkProvider.setPower(normalizedValue == "on")
                }
                return
            }
        }
        let script = command.script
        let actionType = command.actionType
        Task.detached(priority: .userInitiated) {
            switch actionType {
            case .url:
                let resolved = substitute(script, value: value)
                if let url = URL(string: resolved), url.scheme?.isEmpty == false {
                    _ = await MainActor.run { NSWorkspace.shared.open(url) }
                }
            case .file:
                let path = (substitute(script, value: value) as NSString).expandingTildeInPath
                _ = await MainActor.run {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            case .bash, .scriptFile:
                _ = runProcess("/bin/zsh", ["-lc", script], value: value)
            case .applescript:
                _ = runProcess("/usr/bin/osascript", ["-e", substitute(script, value: value)], value: value)
            case .jxa:
                _ = runProcess(
                    "/usr/bin/osascript",
                    ["-l", "JavaScript", "-e", substitute(script, value: value)],
                    value: value
                )
            case .aiPrompt:
                break  // not meaningful for a live control
            }
        }
    }

    /// Run a command's script with `CD_QUERY` injected and capture stdout — used by
    /// the AI capability so it can report what a Global Command produced.
    nonisolated static func runForOutput(command: SystemCommand, value: String) -> String? {
        switch command.actionType {
        case .applescript, .url, .file:
            return runProcess("/usr/bin/osascript", ["-e", command.script], value: value)
        case .jxa:
            return runProcess(
                "/usr/bin/osascript", ["-l", "JavaScript", "-e", command.script], value: value)
        case .bash:
            return runProcess("/bin/zsh", ["-lc", command.script], value: value)
        case .scriptFile:
            let path = (command.script as NSString).expandingTildeInPath
            return runProcess("/bin/zsh", [path], value: value)
        case .aiPrompt:
            return nil
        }
    }

    /// Run a value script and capture stdout (used for reading current state).
    nonisolated static func runForOutput(
        script: String,
        actionType: SystemCommandActionType
    ) -> String? {
        switch actionType {
        case .applescript, .url, .file:
            return runProcess("/usr/bin/osascript", ["-e", script], value: "")
        case .jxa:
            return runProcess("/usr/bin/osascript", ["-l", "JavaScript", "-e", script], value: "")
        case .bash, .scriptFile:
            return runProcess("/bin/zsh", ["-lc", script], value: "")
        case .aiPrompt:
            return nil
        }
    }

    private nonisolated static func substitute(_ script: String, value: String) -> String {
        script
            .replacingOccurrences(of: "{CD_QUERY}", with: value)
    }

    @discardableResult
    private nonisolated static func runProcess(
        _ executable: String,
        _ arguments: [String],
        value: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CD_QUERY"] = value
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
