// GlobalCommandCapabilities.swift
// Context-Dock
//
// Exposes the user's Global Commands (SystemCommandsRegistry) to the general AI
// chat as executable capabilities — so the assistant can run "turn on Bluetooth",
// "set volume 30", "sleep the Mac", or any user-authored command, alongside app
// adapters and MCP tools. Provider-only pickers (Quick Note, Windows) and no-op
// placeholder scripts are skipped — there's nothing for the AI to run.
//
// Each command is grouped into a System pack (SystemConnectors) and registers up to two
// capabilities: a read, `globalcmd.<pack>.status`, for commands that can report their
// current value — low risk, so "is Bluetooth on?" is answered without an approval card —
// and the command itself, `globalcmd.<name>`, which changes something and asks first.
// The command ids predate the packs and are kept: remembered approvals and the
// resolver's candidates are keyed on them.

import AppKit
import Foundation
import IOBluetooth

/// How a Global Command is looked up, read and run from chat.
///
/// `.live` is the only one the app uses: the registry, and the same
/// SystemCommandInteractiveRunner the Global Context row's toggle and slider run through.
/// The seam exists so the tests can check that a capability reaches the runner — and with
/// what — without running a real script on the machine that runs them.
struct GlobalCommandRuntime {
    var commands: @MainActor () -> [SystemCommand]
    var readValue: @MainActor (SystemCommand) async -> String?
    var run: @MainActor (SystemCommand, String) async -> String?

    static let live = GlobalCommandRuntime(
        commands: { SystemCommandsRegistry.shared.commands },
        readValue: { await GlobalCommandCapabilities.readLiveValue(of: $0) },
        run: { await GlobalCommandCapabilities.runLive($0, value: $1) })
}

enum GlobalCommandCapabilities {
    /// Capability ids are namespaced so the registry can clear/refresh just these.
    static let idPrefix = "globalcmd."

    static func register(in registry: CapabilityRegistry) {
        for capability in capabilities(runtime: .live) {
            registry.register(capability)
        }
    }

    /// Every capability the enabled commands produce, pack by pack, each read before the
    /// write beside it — registration order is find_capability's tie-break, and a question
    /// must not be answered by the capability that changes the thing asked about.
    static func capabilities(runtime: GlobalCommandRuntime) -> [AICapability] {
        SystemConnectors.connectors(from: runtime.commands()).flatMap { connector in
            connector.commands.flatMap { command -> [AICapability] in
                let write = makeCapability(for: command, group: connector.group, runtime: runtime)
                guard canReadState(command) else { return [write] }
                return [
                    makeStatusCapability(for: command, group: connector.group, runtime: runtime),
                    write,
                ]
            }
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

        guard canReadState(command),
              let raw = await readLiveValue(of: command), !raw.isEmpty
        else { return nil }

        return formattedStateAnswer(command: command, raw: raw)
    }

    /// The write's result once the setting has been read back. "Volume 30 ✓ (read back
    /// 30)" when the Mac reports what was asked; a failure naming both values when it does
    /// not, so the step fails and the answer cannot claim success.
    static func readBackResult(
        command: SystemCommand, requested: String, readBack: String,
        attempts: Int = 4, delay: Duration = .milliseconds(300),
        reread: () async -> String? = { nil }
    ) async -> AICapabilityExecutionResult {
        let settled = await ReadBackComparison.settle(
            requested: requested, first: readBack, attempts: attempts, delay: delay,
            reread: reread)
        let readBack = settled.reading
        if settled.outcome == .differs {
            return AICapabilityExecutionResult(
                success: false,
                output: ReadBackComparison.mismatchMessage(
                    name: command.name, requested: requested, readBack: readBack),
                readBack: readBack)
        }
        return AICapabilityExecutionResult(
            success: true,
            output: "\(command.name) \(requested) ✓ (read back \(readBack))",
            readBack: readBack)
    }

    /// A question about a setting's current state — "is Bluetooth on?", "what's the
    /// volume?" — as opposed to an instruction to change it.
    nonisolated static func asksForCurrentState(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !requestsMutation(q) else { return false }
        let openers = ["is ", "are ", "what's ", "whats ", "what is ", "check ", "how loud"]
        return openers.contains(where: q.hasPrefix)
            || q.contains(" status") || q.contains("currently") || q.hasSuffix(" on?")
            || q.hasSuffix(" off?")
    }

    /// True when the command can report its current value: a value script, or one of the
    /// radios read natively rather than through a script.
    static func canReadState(_ command: SystemCommand) -> Bool {
        command.keywords.contains("provider:bluetooth")
            || command.keywords.contains("provider:wifi")
            || !command.valueScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The command's current value, read off the main thread. The one reader behind the
    /// status capability, the write capability's "is it on?" fallback and the chat's live
    /// state answer, so the three cannot disagree about what "on" is.
    static func readLiveValue(of command: SystemCommand) async -> String? {
        if command.keywords.contains("provider:wifi") {
            return WiFiNetworkProvider.isPoweredOn() ? "on" : "off"
        }
        let readsBluetooth = command.keywords.contains("provider:bluetooth")
        let script = command.valueScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionType = command.actionType
        let output: String? = await Task.detached(priority: .userInitiated) {
            if readsBluetooth {
                return IOBluetoothHostController.default().powerState.rawValue == 1 ? "on" : "off"
            }
            guard !script.isEmpty else { return nil }
            return SystemCommandInteractiveRunner.runForOutput(
                script: script, actionType: actionType)
        }.value
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run the command with `value` as CD_QUERY — the Global Context row's own runner.
    /// Radio power goes through the native path, same as the row's switch.
    static func runLive(_ command: SystemCommand, value: String) async -> String? {
        let normalized = value.lowercased()
        if normalized == "on" || normalized == "off" {
            if command.keywords.contains(where: { $0.lowercased() == "provider:bluetooth" }) {
                BluetoothDeviceProvider.setPower(normalized == "on")
                return "Bluetooth turned \(normalized)."
            }
            if command.keywords.contains(where: { $0.lowercased() == "provider:wifi" }) {
                WiFiNetworkProvider.setPower(normalized == "on")
                return "Wi-Fi turned \(normalized)."
            }
        }
        return await Task.detached {
            SystemCommandInteractiveRunner.runForOutput(command: command, value: value)
        }.value
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
                let searchableTerms = Set(searchable
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init))
                // Match semantic words, not substrings. "our project" used to match
                // "your devices" and route an unrelated Safari statement to Bluetooth.
                var score = terms.reduce(0) { $0 + (searchableTerms.contains($1) ? 2 : 0) }
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

    private nonisolated static func requestsMutation(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let mutationSignals = [
            "turn on", "turn off", "enable", "disable", "set ", "switch to",
            "change to", "toggle", "increase", "decrease", "mute", "unmute",
        ]
        return mutationSignals.contains(where: q.contains)
    }

    static func isRunnable(_ command: SystemCommand) -> Bool {
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
        // A switch or a slider moves one setting the user can move straight back — Dark
        // Mode, volume, Bluetooth. It still asks, but it is not Empty Trash.
        if command.interactionType != .none { return .medium }
        // So does a picker: a command whose value is one of a fixed set of presets
        // (Light / Dark / Auto) chooses between states the user can pick again. Saved
        // copies of such commands carry no interaction type, only their presets, and fell
        // through to the script rule below — Appearance asked with a High badge.
        if !presetValues(for: command).isEmpty { return .medium }
        switch command.actionType {
        case .bash, .applescript, .jxa, .scriptFile:
            return .high
        case .url, .file, .aiPrompt:
            return .low
        }
    }

    static func capabilityID(for command: SystemCommand) -> String {
        idPrefix + slug(for: command)
    }

    /// `globalcmd.<pack>.status` — or `globalcmd.<pack>.<name>.status` when the command is
    /// not the pack's namesake (Volume in Sound), so two readable commands in one pack
    /// never share an id. Derived from the command alone, not its siblings, so adding a
    /// command never renames another's.
    static func statusCapabilityID(
        for command: SystemCommand,
        group: SystemConnectorGroup? = nil
    ) -> String {
        let group = group ?? SystemConnectorGroup.group(for: command)
        let slug = slug(for: command)
        let isNamesake = slug.filter { $0 != "-" } == group.rawValue
        return idPrefix + group.rawValue + (isNamesake ? "" : "." + slug) + ".status"
    }

    private static func slug(for command: SystemCommand) -> String {
        let slug = command.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? command.id.uuidString : slug
    }

    /// Title with the pack named when the command's own name does not already say it, so
    /// "sound" finds Volume.
    private static func packTitle(_ base: String, group: SystemConnectorGroup) -> String {
        base.lowercased().contains(group.title.lowercased())
            ? base : "\(base) · \(group.title) pack"
    }

    private static func makeStatusCapability(
        for command: SystemCommand,
        group: SystemConnectorGroup,
        runtime: GlobalCommandRuntime
    ) -> AICapability {
        let commandID = command.id
        let reading = command.interactionType == .slider ? "current level" : "whether it is on"
        return AICapability(
            id: statusCapabilityID(for: command, group: group),
            title: packTitle("\(command.name) status — read \(reading)", group: group),
            appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: []),
            // Reading a setting changes nothing, so it answers without an approval card.
            riskLevel: .low
        ) { _ in
            guard let live = runtime.commands().first(where: { $0.id == commandID && $0.isEnabled })
            else {
                return AICapabilityExecutionResult(
                    success: false, output: "\(command.name) is no longer an enabled command.")
            }
            guard let raw = await runtime.readValue(live), !raw.isEmpty else {
                return AICapabilityExecutionResult(
                    success: false, output: "Could not read the current \(live.name) value.")
            }
            return AICapabilityExecutionResult(
                success: true, output: formattedStateAnswer(command: live, raw: raw).answer)
        }
    }

    private static func makeCapability(
        for command: SystemCommand,
        group: SystemConnectorGroup,
        runtime: GlobalCommandRuntime
    ) -> AICapability {
        let id = capabilityID(for: command)
        let isToggle = command.interactionType == .toggle
        let requiresValue = command.script.contains("$CD_QUERY")
            || command.script.contains("${CD_QUERY}")

        let valueHint: String
        switch command.interactionType {
        case .toggle:
            valueHint = "on or off"
        case .slider:
            valueHint = "a number from \(Int(command.sliderMin)) to \(Int(command.sliderMax))"
        case .none:
            valueHint = "optional value passed to the command (e.g. a network name)"
        }

        let base = command.description.isEmpty
            ? command.name : "\(command.name) — \(command.description)"
        return AICapability(
            id: id,
            title: packTitle(base, group: group),
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
                    let live = runtime.commands().first(where: {
                        $0.id == commandID
                    })
                else {
                    return AICapabilityExecutionResult(
                        success: false, output: "Command no longer exists")
                }
                var value = request.input["value"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var normalized = value.lowercased()

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

                // An omitted value on an interactive command used to mean "read it",
                // unconditionally. That is the right answer to "is dark mode on?" and the
                // wrong one to "turn on dark mode", which came back as "Appearance current
                // value: true" — DoraX reporting the switch's position instead of moving
                // it. Reading is still the default; an explicit instruction is now carried
                // out. See InteractiveCommandIntent.
                if normalized.isEmpty, command.interactionType != .none {
                    if canReadState(live) {
                        let current = await runtime.readValue(live)
                        switch InteractiveCommandIntent.fallback(
                            userRequest: request.userRequest,
                            isToggle: isToggle,
                            current: current)
                        {
                        case .readCurrentValue:
                            if let current, !current.isEmpty {
                                return AICapabilityExecutionResult(
                                    success: true,
                                    output: "\(live.name) current value: \(current)")
                            }
                        case .set(let wanted):
                            value = wanted
                            normalized = wanted
                        case .runAsIs:
                            break
                        }
                    }
                }

                let output = await runtime.run(live, value)

                let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // A setting that can be read is read back, so the answer can say what the
                // Mac now reports rather than that a script exited cleanly.
                if !value.isEmpty, canReadState(live),
                    let after = await runtime.readValue(live)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !after.isEmpty
                {
                    return await readBackResult(
                        command: live, requested: value, readBack: after,
                        reread: { await runtime.readValue(live) })
                }
                return AICapabilityExecutionResult(
                    success: true,
                    output: trimmed.isEmpty
                        ? (value.isEmpty ? "Ran \(live.name)." : "\(live.name) \(value).")
                        : trimmed
                )
            }
        )
    }
}
