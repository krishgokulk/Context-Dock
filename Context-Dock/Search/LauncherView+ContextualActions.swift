import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

private enum NativeWritingToolAction: String, CaseIterable {
    case show
    case proofread
    case rewrite
    case friendly
    case professional
    case concise
    case summarize
    case keyPoints
    case list
    case table
    case compose

    var title: String {
        switch self {
        case .show: return "Show Writing Tools"
        case .proofread: return "Proofread"
        case .rewrite: return "Rewrite"
        case .friendly: return "Make Friendly"
        case .professional: return "Make Professional"
        case .concise: return "Make Concise"
        case .summarize: return "Summarize"
        case .keyPoints: return "Create Key Points"
        case .list: return "Make List"
        case .table: return "Make Table"
        case .compose: return "Compose..."
        }
    }

    var icon: String {
        switch self {
        case .show, .compose: return "apple.intelligence"
        case .proofread: return "checkmark.seal"
        case .rewrite: return "pencil.line"
        case .friendly: return "face.smiling"
        case .professional: return "briefcase"
        case .concise: return "text.word.spacing"
        case .summarize: return "text.alignleft"
        case .keyPoints: return "list.bullet.rectangle"
        case .list: return "list.bullet"
        case .table: return "tablecells"
        }
    }

    var aliases: [String] {
        switch self {
        case .show: return ["writing tools", "apple intelligence", "show writing tools"]
        case .proofread: return ["proofread", "spelling", "grammar", "fix writing"]
        case .rewrite: return ["rewrite", "rephrase", "improve writing"]
        case .friendly: return ["friendly", "make friendly", "warmer"]
        case .professional: return ["professional", "make professional", "formal"]
        case .concise: return ["concise", "shorten", "make concise"]
        case .summarize: return ["summarize", "summarise", "summary"]
        case .keyPoints: return ["key points", "bullet points", "create key points"]
        case .list: return ["list", "make list"]
        case .table: return ["table", "make table"]
        case .compose: return ["compose", "draft", "write"]
        }
    }

    var requiresSelection: Bool {
        self != .show && self != .compose
    }

    func prompt(for text: String) -> String {
        let instruction: String
        switch self {
        case .show:
            instruction = "Help improve this writing."
        case .proofread:
            instruction = "Proofread this text. Fix spelling, grammar, punctuation, and obvious typos. Preserve meaning and tone."
        case .rewrite:
            instruction = "Rewrite this text clearly. Preserve meaning."
        case .friendly:
            instruction = "Rewrite this text in a friendly, natural tone. Preserve meaning."
        case .professional:
            instruction = "Rewrite this text in a professional tone. Preserve meaning."
        case .concise:
            instruction = "Rewrite this text concisely. Remove redundancy. Preserve key meaning."
        case .summarize:
            instruction = "Summarize this text concisely."
        case .keyPoints:
            instruction = "Extract key points from this text as short bullets."
        case .list:
            instruction = "Convert this text into a clean list."
        case .table:
            instruction = "Convert this text into a clean Markdown table when possible."
        case .compose:
            instruction = "Use this selected text as writing instructions. Compose the requested final text."
        }
        return """
        \(instruction)

        Return only final text. No preface. No explanation. No quotation marks unless part of text.

        Text:
        \(text)
        """
    }
}

extension LauncherView {
    func scopedSystemCommandPills(
        scopedBundleId: String,
        scopedSearchQuery: String
    ) -> [DockPill] {
        guard scopedBundleId.hasPrefix("syscmd://") else { return [] }
        let id = String(scopedBundleId.dropFirst("syscmd://".count))
        guard let uuid = UUID(uuidString: id),
            let command = SystemCommandsRegistry.shared.commands.first(where: {
                $0.id == uuid && $0.isEnabled
            })
        else { return [] }

        // The Windows command is a native window-layout picker, not a script: its
        // scope renders tiles that arrange the app you were in before opening the
        // launcher. Handled before the generic script/preset path below.
        if command.keywords.contains(where: { $0.lowercased() == "provider:windows" }) {
            return windowManagementScopePills(
                scopedBundleId: scopedBundleId, query: scopedSearchQuery)
        }

        // The Quick Note command turns the scope into a capture surface: type in the
        // input to compose (Return saves), and your saved notes render below —
        // filtered by what you type, so the same field also searches notes.
        if command.keywords.contains(where: { $0.lowercased() == "provider:notepad" }) {
            return quickNotepadScopePills(
                scopedBundleId: scopedBundleId, query: scopedSearchQuery)
        }

        // Process Monitor: live grouped process list (CPU% + memory) with Kill on
        // Enter. A leading row toggles the sort column. Rows come from a single `ps`
        // sample grouped by owning app.
        if command.keywords.contains(where: { $0.lowercased() == "provider:processes" }) {
            return processMonitorScopePills(
                scopedBundleId: scopedBundleId, query: scopedSearchQuery)
        }

        // User-authored list extension: rows come from the command's own script
        // (printed as JSON lines), Enter runs its row-action (undo) script.
        if CustomListProviderService.isListProvider(command) {
            return customListProviderScopePills(
                command: command, scopedBundleId: scopedBundleId, query: scopedSearchQuery)
        }

        let normalizedCommandTerms = ([command.name] + command.keywords).map(normalizedDockPillText)
        let isVolume = normalizedCommandTerms.contains { $0.contains("volume") }
        if let adapterScopeId = systemCommandAdapterScopeId(command) {
            let children = SystemCommandsRegistry.shared.commands
                .filter { child in
                    child.isEnabled
                        && child.id != command.id
                        && child.keywords.contains("adapter-child:\(adapterScopeId)")
                }
            let normalizedQuery = normalizedDockPillText(scopedSearchQuery)
            let visibleChildren = normalizedQuery.isEmpty
                ? children
                : children.filter { child in
                    ([child.name, child.description] + child.keywords).contains { term in
                        normalizedDockPillText(term).contains(normalizedQuery)
                    }
                }
            return visibleChildren.map { child in
                var pill = DockPill(
                    id: "syscmd-child-\(command.id)-\(child.id)",
                    name: child.name,
                    icon: child.icon,
                    accentColorName: "indigo",
                    badge: child.description,
                    execute: {
                        runSystemCommand(child, originalQuery: scopedSearchQuery)
                        searchState.query = ""
                        l2.focusedPillIndex = nil
                    }
                )
                pill.rankingKind = "systemCommand"
                pill.sourceBundleId = scopedBundleId
                pill.sourceAppName = command.name
                pill.trackingIdentifier = "system:\(command.id):child:\(child.id)"
                pill.searchTerms = [command.name, child.name, child.description] + child.keywords
                return pill
            }
        }

        var scopedRows: [DockPill] = []

        // The interactive command is the scoped header. Provider and preset
        // children are appended below it; only this row owns the live control.
        if command.interactionType != .none, !isVolume {
            var pill = DockPill(
                id: "syscmd-\(command.id)-interactive",
                name: command.name,
                icon: command.icon,
                accentColorName: "indigo",
                badge: command.description,
                execute: {
                    let current = InteractiveCommandState.shared.value(for: command) ?? 0
                    switch command.interactionType {
                    case .toggle:
                        let next = current < 0.5
                        InteractiveCommandState.shared.setLocal(next ? 1 : 0, for: command.id)
                        SystemCommandInteractiveRunner.run(command, value: next ? "on" : "off")
                    case .slider:
                        SystemCommandInteractiveRunner.run(
                            command, value: String(Int(current.rounded())))
                    case .none:
                        break
                    }
                }
            )
            pill.rankingKind = "systemCommand"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = command.name
            pill.trackingIdentifier = "system:\(command.id):interactive"
            pill.searchTerms = [command.name, command.description] + command.keywords
            scopedRows.append(pill)
        }

        let query = scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalizedDockPillText(query)
        let queryTargetsCommand = !normalizedQuery.isEmpty
            && normalizedCommandTerms.contains { term in
                term.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(term)
            }

        let dynamicItems = (query.isEmpty || queryTargetsCommand)
            ? systemCommandDynamicItems(command)
            : systemCommandDynamicItems(command).filter {
                normalizedDockPillText($0.title).contains(normalizedQuery)
                    || normalizedDockPillText($0.subtitle).contains(normalizedQuery)
            }
        if !dynamicItems.isEmpty {
            scopedRows.append(contentsOf: dynamicItems.map { item in
                var pill = DockPill(
                    id: "syscmd-\(command.id)-\(item.value)",
                    name: item.title,
                    icon: command.icon,
                    accentColorName: item.isActive ? "green" : "indigo",
                    badge: item.subtitle,
                    execute: {
                        runSystemCommand(command, originalQuery: item.value)
                        searchState.query = ""
                        l2.focusedPillIndex = nil
                    }
                )
                pill.rankingKind = "systemCommand"
                pill.sourceBundleId = scopedBundleId
                pill.sourceAppName = command.name
                pill.trackingIdentifier = "system:\(command.id):\(item.value)"
                pill.searchTerms = [command.name, command.description, item.title, item.subtitle, item.value] + command.keywords
                return pill
            })
            return scopedRows
        }

        let presetValues = systemCommandPresetValues(command, fallbackVolume: isVolume)
        let values = (query.isEmpty || queryTargetsCommand) && !presetValues.isEmpty
            ? presetValues
            : [query]

        scopedRows.append(contentsOf: values.map { value in
            let label = !value.isEmpty && !presetValues.isEmpty ? value : command.name
            var pill = DockPill(
                id: "syscmd-\(command.id)-\(value)",
                name: label,
                icon: command.icon,
                accentColorName: "indigo",
                badge: "System",
                execute: {
                    runSystemCommand(command, originalQuery: value)
                    searchState.query = ""
                    l2.focusedPillIndex = nil
                }
            )
            pill.rankingKind = "systemCommand"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = command.name
            pill.trackingIdentifier = "system:\(command.id):\(value)"
            pill.searchTerms = [command.name, command.description, value] + command.keywords
            return pill
        })
        return scopedRows
    }

    func systemCommandAdapterScopeId(_ command: SystemCommand) -> String? {
        for keyword in command.keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("adapter-scope:") else { continue }
            let value = String(trimmed.dropFirst("adapter-scope:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    func systemCommandPresetValues(_ command: SystemCommand, fallbackVolume: Bool) -> [String] {
        for keyword in command.keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("presets:") || lower.hasPrefix("preset:") else { continue }
            let raw = trimmed.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let values = raw
                .components(separatedBy: CharacterSet(charactersIn: "|;/"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty { return values }
        }
        return fallbackVolume ? ["10", "25", "30", "45", "50", "65", "75", "80", "95", "max"] : []
    }

    struct SystemCommandDynamicItem: Hashable {
        let title: String
        let value: String
        let subtitle: String
        let isActive: Bool
    }

    func systemCommandProviderName(_ command: SystemCommand) -> String? {
        for keyword in command.keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("provider:") else { continue }
            let provider = trimmed.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if provider?.isEmpty == false { return provider?.lowercased() }
        }
        return nil
    }

    func systemCommandDynamicItems(_ command: SystemCommand) -> [SystemCommandDynamicItem] {
        switch systemCommandProviderName(command) {
        case "wifi", "wi-fi":
            let networks = WiFiNetworkProvider.visibleNetworks()
            let rows = networks.map {
                SystemCommandDynamicItem(
                    title: $0.ssid,
                    value: $0.ssid,
                    subtitle: $0.status,
                    isActive: $0.isConnected
                )
            }
            if !rows.isEmpty { return rows }
            return [
                SystemCommandDynamicItem(
                    title: "Settings",
                    value: "settings",
                    subtitle: "Open Wi-Fi Settings",
                    isActive: false
                )
            ]
        case "bluetooth":
            let devices = BluetoothDeviceProvider.pairedDevices()
            let connectedCount = devices.filter(\.isConnected).count
            let summary = SystemCommandDynamicItem(
                title: "Bluetooth Settings",
                value: "settings",
                subtitle: "\(connectedCount) connected · \(devices.count) paired",
                isActive: false
            )
            let rows = devices.map {
                SystemCommandDynamicItem(
                    title: $0.name,
                    value: $0.name,
                    subtitle: $0.status,
                    isActive: $0.isConnected
                )
            }
            return [summary] + rows
        default:
            return []
        }
    }

    func runSystemCommand(_ command: SystemCommand, originalQuery: String) {
        let ctx = AXContextReader.shared.current
        let envVars: [String: String] = [
            "CD_QUERY": originalQuery,
            "CD_URL": ctx.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
            "CD_TEXT": ctx.selectedText ?? "",
            "CD_APP": ctx.appName,
        ]

        let actionType = command.actionType
        if actionType == .aiPrompt {
            let prompt = resolvedSystemCommandValue(command.script, envVars: envVars)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            aiMode.isActive = true
            searchState.query = prompt
            submitAIQuery()
            return
        }

        let actionId = DockActionFeedback.start(
            "Running",
            subject: command.name,
            icon: command.icon,
            tint: .blue.opacity(0.9)
        )

        switch actionType {
        case .url:
            let value = resolvedSystemCommandValue(command.script, envVars: envVars)
            let ok: Bool
            if let url = URL(string: value), url.scheme?.isEmpty == false {
                ok = NSWorkspace.shared.open(url)
            } else {
                ok = NSWorkspace.shared.open(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
            }
            finishSystemCommandFeedback(actionId, command: command, envVars: envVars, success: ok, detail: nil)
        case .file:
            let path = (resolvedSystemCommandValue(command.script, envVars: envVars) as NSString)
                .expandingTildeInPath
            let ok = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            finishSystemCommandFeedback(actionId, command: command, envVars: envVars, success: ok, detail: nil)
        case .bash:
            runTrackedSystemProcess(
                executable: "/bin/zsh",
                arguments: ["-lc", command.script],
                envVars: envVars,
                actionId: actionId,
                command: command
            ) { success, detail in
                finishSystemCommandFeedback(actionId, command: command, envVars: envVars, success: success, detail: detail)
            }
        case .applescript:
            runTrackedSystemProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-e", resolvedSystemCommandValue(command.script, envVars: envVars)],
                envVars: envVars,
                actionId: actionId,
                command: command
            ) { success, detail in
                finishSystemCommandFeedback(actionId, command: command, envVars: envVars, success: success, detail: detail)
            }
        case .jxa:
            runTrackedSystemProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", resolvedSystemCommandValue(command.script, envVars: envVars)],
                envVars: envVars,
                actionId: actionId,
                command: command
            ) { success, detail in
                finishSystemCommandFeedback(actionId, command: command, envVars: envVars, success: success, detail: detail)
            }
        case .scriptFile:
            runTrackedSystemScriptFile(
                resolvedSystemCommandValue(command.script, envVars: envVars),
                envVars: envVars,
                actionId: actionId,
                command: command
            ) { success, detail in
                finishSystemCommandFeedback(actionId, command: command, envVars: envVars, success: success, detail: detail)
            }
        case .aiPrompt:
            break
        }
    }

    private func runTrackedSystemScriptFile(
        _ path: String,
        envVars: [String: String],
        actionId: String,
        command: SystemCommand,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            completion(false, "Script not found")
            return
        }

        let ext = (expanded as NSString).pathExtension.lowercased()
        switch ext {
        case "scpt", "applescript":
            runTrackedSystemProcess(
                executable: "/usr/bin/osascript",
                arguments: [expanded],
                envVars: envVars,
                actionId: actionId,
                command: command,
                completion: completion
            )
        case "py":
            runTrackedSystemProcess(
                executable: "/usr/bin/env",
                arguments: ["python3", expanded],
                envVars: envVars,
                actionId: actionId,
                command: command,
                completion: completion
            )
        case "js":
            runTrackedSystemProcess(
                executable: "/usr/bin/env",
                arguments: ["node", expanded],
                envVars: envVars,
                actionId: actionId,
                command: command,
                completion: completion
            )
        case "rb":
            runTrackedSystemProcess(
                executable: "/usr/bin/env",
                arguments: ["ruby", expanded],
                envVars: envVars,
                actionId: actionId,
                command: command,
                completion: completion
            )
        default:
            runTrackedSystemProcess(
                executable: "/bin/zsh",
                arguments: [expanded],
                envVars: envVars,
                actionId: actionId,
                command: command,
                completion: completion
            )
        }
    }

    private func runTrackedSystemProcess(
        executable: String,
        arguments: [String],
        envVars: [String: String],
        actionId: String,
        command: SystemCommand,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            var env = ProcessInfo.processInfo.environment
            envVars.forEach { env[$0.key] = $0.value }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let success = proc.terminationStatus == 0
                await MainActor.run {
                    completion(success, output?.isEmpty == false ? output : nil)
                }
            } catch {
                await MainActor.run {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private func finishSystemCommandFeedback(
        _ actionId: String,
        command: SystemCommand,
        envVars: [String: String],
        success: Bool,
        detail: String?
    ) {
        let clean = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredTitle = command.successTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredMessage = command.successMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackLabel = configuredTitle.isEmpty ? "\(command.name) done" : configuredTitle
        let label = clean?.isEmpty == false ? clean! : (configuredMessage.isEmpty ? fallbackLabel : configuredMessage)
        if success {
            if command.hasUndoAction {
                let undoTitle = command.undoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                DockActionFeedback.complete(
                    actionId,
                    label: label,
                    actionTitle: undoTitle.isEmpty ? "Undo" : undoTitle
                ) {
                    AppToast.hide()
                    runSystemCommandUndo(command, envVars: envVars)
                }
            } else {
                DockActionFeedback.complete(actionId, label: label)
            }
        } else {
            DockActionFeedback.fail(actionId, label: clean?.isEmpty == false ? clean : "Couldn't run \(command.name)")
        }
    }

    private func runSystemCommandUndo(_ command: SystemCommand, envVars: [String: String]) {
        let undoId = DockActionFeedback.start(
            "Undoing",
            subject: command.name,
            icon: command.icon,
            tint: .pink.opacity(0.9)
        )
        let undoScript = resolvedSystemCommandValue(command.undoScript, envVars: envVars)
        switch command.undoActionType {
        case .url:
            let ok: Bool
            if let url = URL(string: undoScript), url.scheme?.isEmpty == false {
                ok = NSWorkspace.shared.open(url)
            } else {
                ok = NSWorkspace.shared.open(URL(fileURLWithPath: (undoScript as NSString).expandingTildeInPath))
            }
            finishSystemCommandUndoFeedback(undoId, command: command, success: ok, detail: nil)
        case .file:
            let path = (undoScript as NSString).expandingTildeInPath
            let ok = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            finishSystemCommandUndoFeedback(undoId, command: command, success: ok, detail: nil)
        case .bash:
            runTrackedSystemProcess(
                executable: "/bin/zsh",
                arguments: ["-lc", undoScript],
                envVars: envVars,
                actionId: undoId,
                command: command
            ) { success, detail in
                finishSystemCommandUndoFeedback(undoId, command: command, success: success, detail: detail)
            }
        case .applescript:
            runTrackedSystemProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-e", undoScript],
                envVars: envVars,
                actionId: undoId,
                command: command
            ) { success, detail in
                finishSystemCommandUndoFeedback(undoId, command: command, success: success, detail: detail)
            }
        case .jxa:
            runTrackedSystemProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", undoScript],
                envVars: envVars,
                actionId: undoId,
                command: command
            ) { success, detail in
                finishSystemCommandUndoFeedback(undoId, command: command, success: success, detail: detail)
            }
        case .scriptFile:
            runTrackedSystemScriptFile(
                undoScript,
                envVars: envVars,
                actionId: undoId,
                command: command
            ) { success, detail in
                finishSystemCommandUndoFeedback(undoId, command: command, success: success, detail: detail)
            }
        case .aiPrompt:
            aiMode.isActive = true
            searchState.query = undoScript
            submitAIQuery()
            DockActionFeedback.complete(undoId, label: "\(command.name) undo sent")
        }
    }

    private func finishSystemCommandUndoFeedback(
        _ actionId: String,
        command: SystemCommand,
        success: Bool,
        detail: String?
    ) {
        let clean = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if success {
            DockActionFeedback.complete(
                actionId,
                label: clean?.isEmpty == false ? clean : "\(command.name) undone"
            )
        } else {
            DockActionFeedback.fail(
                actionId,
                label: clean?.isEmpty == false ? clean : "Couldn't undo \(command.name)"
            )
        }
    }

    private func resolvedSystemCommandValue(_ value: String, envVars: [String: String]) -> String {
        var resolved = value
        for (key, envValue) in envVars {
            resolved = resolved.replacingOccurrences(of: "{\(key)}", with: envValue)
            resolved = resolved.replacingOccurrences(of: "$\(key)", with: envValue)
        }
        return resolved.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func executeCrossAppIntent(
        _ intent: CrossAppIntent,
        userMessage: String,
        unresolvedMessage: String =
            "❌ Couldn't resolve that. Try: \"send this to [name]\" or \"email this to [name]\""
    ) {
        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.isLoading = false
            l2.activeRequestID = nil
        }
        let capturedContext = effectiveAXContextForConversation()
        let actionId = DockActionFeedback.start(
            "Working", subject: intent.targetAppName ?? "", icon: "bolt.fill", tint: .accentColor)
        l2.currentTask = Task {
            guard let resolved = await CrossAppNLHandler.shared.resolve(intent) else {
                await MainActor.run {
                    DockActionFeedback.fail(actionId, label: "Couldn't resolve action")
                    l2.currentTask = nil
                }
                return
            }
            let output = await CrossAppNLHandler.shared.execute(
                resolved,
                axContext: capturedContext,
                presentSharingPicker: { items in
                    self.presentSharingPicker(items: items)
                }
            )
            await MainActor.run {
                let clean = output.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(
                    of: "❌ ", with: "")
                let success = !output.hasPrefix("❌")
                if success {
                    DockActionFeedback.complete(actionId, label: clean)
                } else {
                    DockActionFeedback.fail(actionId, label: clean)
                }
                l2.currentTask = nil
                searchState.query = ""
                l2.focusedPillIndex = nil
            }
        }
    }

    func executeResolvedAppAction(
        _ resolution: L2AppActionResolution,
        userMessage: String
    ) {
        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.isLoading = false
            l2.activeRequestID = nil
        }

        let match = resolution.primary
        let capturedContext = effectiveAXContextForConversation()
        let actionId = DockActionFeedback.start(
            match.action.name, subject: match.adapter.appName, icon: "bolt.fill", tint: .accentColor
        )
        l2.currentTask = Task {
            AppInteractionStore.shared.record(
                bundleId: match.adapter.bundleId,
                appName: match.adapter.appName,
                query: userMessage,
                kind: match.action.type == .pageJS ? .pageJS : .adapterAction,
                actionId: match.action.id
            )

            let result = await adapterManager.execute(
                match.action,
                context: capturedContext,
                targetBundleId: match.adapter.bundleId,
                query: userMessage
            )

            await MainActor.run {
                let success = result.0
                let detail = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
                let label =
                    success
                    ? (detail.isEmpty ? "\(match.action.name) done" : detail)
                    : "Couldn't run \(match.action.name)"
                if success {
                    DockActionFeedback.complete(actionId, label: label)
                } else {
                    DockActionFeedback.fail(actionId, label: label)
                }
                l2.currentTask = nil
                searchState.query = ""
                l2.focusedPillIndex = nil
            }
        }
    }

    func executeGlobalAppLaunch(
        bundleId: String,
        appName: String,
        userMessage: String
    ) {
        let fid = DockActionFeedback.start(
            "Opening", subject: appName, icon: "arrow.up.right.circle.fill", tint: .accentColor)
        let launched = launchApplication(bundleIdentifier: bundleId, appName: appName)
        if launched {
            DockActionFeedback.complete(fid, label: "\(appName) opened")
        } else {
            DockActionFeedback.fail(fid, label: "Couldn't open \(appName)")
        }
        searchState.query = ""
        l2.focusedPillIndex = nil
    }

    var isGlobalQueryModeActive: Bool {
        showContextInDock && isGlobalContextActive
    }

    var effectiveConversationUserContext: UserContext {
        // Selection enriches both modes. It must be resolved before app scope so
        // Context Dock keeps its frontmost-app capabilities while AI receives the payload.
        let effectiveAX = effectiveAXContextForConversation()
        let selectedFiles = effectiveAX.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if !selectedFiles.isEmpty { return .filesSelected(selectedFiles) }
        if let selectedText = effectiveAX.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty
        {
            return .textSelected(selectedText)
        }
        if let currentURL = effectiveAX.currentURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !currentURL.isEmpty
        {
            return .url(currentURL)
        }
        switch currentContext {
        case .filesSelected, .textSelected, .url, .contactSelected:
            return currentContext
        default:
            break
        }

        if showContextInDock && isGlobalContextActive {
            // Clipboard pill: user explicitly copied content (covers VS Code/Electron/any app)
            if showGlobalClipboardPill && !globalClipboardText.isEmpty {
                if let url = URL(string: globalClipboardText), url.scheme != nil {
                    return .url(globalClipboardText)
                }
                return .textSelected(globalClipboardText)
            }
            return .none
        }

        if showContextInDock {
            let scope = resolveDockScope(for: searchState.query)
            if scope.isExplicitAppScope,
                !scope.scopedBundleId.isEmpty,
                !scope.scopedAppName.isEmpty
            {
                return .appFocused(name: scope.scopedAppName, bundleID: scope.scopedBundleId)
            }
        }

        guard isGlobalQueryModeActive else { return currentContext }
        switch currentContext {
        case .appFocused:
            return .none
        default:
            return currentContext
        }
    }

    func resolveGlobalActionQuery(_ query: String) -> L2AppActionResolution? {
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let queryTokens = Set(dockPillTokens(normalizedQuery))
        var matches: [L2AppActionMatch] = []

        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            let normalizedAppName = normalizedDockPillText(adapter.appName)

            for action in adapter.actions {
                let normalizedActionName = normalizedDockPillText(action.name)
                let normalizedTriggers = action.triggers.map(normalizedDockPillText)
                let corpora = ([normalizedActionName] + normalizedTriggers).filter { !$0.isEmpty }

                var score = 0.0

                if corpora.contains(normalizedQuery) {
                    score += 155
                }
                if normalizedActionName == normalizedQuery {
                    score += 135
                }
                if corpora.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                    score += 96
                }
                if corpora.contains(where: { $0.contains(normalizedQuery) }) {
                    score += 72
                }

                let actionTokens = Set(corpora.flatMap { dockPillTokens($0) })
                let overlap = queryTokens.intersection(actionTokens).count
                if overlap > 0 {
                    score += Double(overlap * 26)
                }

                if !normalizedAppName.isEmpty && normalizedQuery.contains(normalizedAppName) {
                    score += 24
                }
                if queryTokens.contains(where: { normalizedAppName.contains($0) }) {
                    score += 16
                }

                guard score >= 90 else { continue }

                matches.append(
                    L2AppActionMatch(
                        adapter: adapter,
                        action: action,
                        score: score,
                        matchedAppPhrase: normalizedAppName,
                        matchedActionPhrase: normalizedQuery,
                        usedFrontmostFallback: false
                    )
                )
            }
        }

        let ranked = matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.action.name.localizedCaseInsensitiveCompare($1.action.name)
                == .orderedAscending
        }

        guard let primary = ranked.first else { return nil }
        let alternatives = Array(ranked.dropFirst().prefix(3)).filter {
            $0.score >= primary.score - 20
        }
        return L2AppActionResolution(primary: primary, alternatives: alternatives)
    }

    func globalAIContextBlock() -> String {
        var lines: [String] = [
            "## Global Context Mode", "Treat the frontmost app as passive context only.",
        ]

        let context = effectiveAXContextForConversation()
        if !context.isEmpty {
            lines.append("## Passive Live Context")
            lines.append(context.contextSummary)
        }

        let selectedFiles = effectiveSelectedFileURLsForConversation()
        if !selectedFiles.isEmpty {
            lines.append("## Selected Files")
            for url in selectedFiles.prefix(8) {
                lines.append("- \(url.lastPathComponent)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func messagesScopedSemanticIntent(for scopedQuery: String) -> CrossAppIntent? {
        let normalized = scopedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return CrossAppNLHandler.shared.parseMessagesScopedIntent(normalized)
    }

    func rawDockQuery(matching normalizedQuery: String) -> String {
        let rawQuery = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty,
            normalizedDockPillText(rawQuery) == normalizedDockPillText(normalizedQuery)
        else {
            return normalizedQuery
        }
        return rawQuery
    }

    func stripScopedAlias(
        _ alias: String,
        from rawQuery: String,
        allowPrefixAlias: Bool = false
    ) -> String {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasTokens = alias.split(separator: " ").map { $0.lowercased() }
        let queryTokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard !aliasTokens.isEmpty, queryTokens.count >= aliasTokens.count else { return trimmed }

        let prefix = queryTokens.prefix(aliasTokens.count).map { $0.lowercased() }
        if prefix == aliasTokens
            || (allowPrefixAlias
                && firstScopedAliasRange(aliasTokens, in: prefix, allowPrefixLastToken: true)?
                    .lowerBound == 0)
        {
            return trimScopedAppFillerWords(
                queryTokens.dropFirst(aliasTokens.count).map(String.init)
            )
        }

        let normalizedTokens = queryTokens.map { normalizedDockPillText(String($0)) }
        guard
            let range = firstScopedAliasRange(
                aliasTokens,
                in: normalizedTokens,
                allowPrefixLastToken: allowPrefixAlias
            )
        else {
            return trimmed
        }
        var remaining = queryTokens.map(String.init)
        remaining.removeSubrange(range)
        return trimScopedAppFillerWords(remaining)
    }

    func firstScopedAliasRange(
        _ aliasTokens: [String],
        in queryTokens: [String],
        allowPrefixLastToken: Bool = false
    ) -> Range<Int>? {
        guard !aliasTokens.isEmpty, queryTokens.count >= aliasTokens.count else { return nil }
        let maxStart = queryTokens.count - aliasTokens.count
        for start in 0...maxStart {
            let candidate = Array(queryTokens[start..<(start + aliasTokens.count)])
            let matches = candidate.enumerated().allSatisfy { index, token in
                let aliasToken = aliasTokens[index]
                if token == aliasToken { return true }
                let isLastToken = index == aliasTokens.count - 1
                return allowPrefixLastToken
                    && (aliasTokens.count > 1 || queryTokens.count > aliasTokens.count)
                    && isLastToken
                    && token.count >= 3
                    && aliasToken.hasPrefix(token)
            }
            if matches {
                return start..<(start + aliasTokens.count)
            }
        }
        return nil
    }

    func trimScopedAppFillerWords(_ tokens: [String]) -> String {
        var words = tokens
        let filler: Set<String> = [
            "app", "open", "go", "goto", "navigate", "launch", "show", "use",
            "please", "the", "a", "an", "to", "in", "on", "for", "with", "into", "using", "and",
        ]
        while let first = words.first,
            filler.contains(normalizedDockPillText(first))
        {
            words.removeFirst()
        }
        while let last = words.last,
            filler.contains(normalizedDockPillText(last))
        {
            words.removeLast()
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rawScopedActionQuery(for normalizedQuery: String, scope: DockScopeResolution)
        -> String
    {
        let rawQuery = rawDockQuery(matching: normalizedQuery)
        let normalizedRawQuery = normalizedDockPillText(rawQuery)

        let installedScopeMode = contextDockInstalledAppScopeMatching
        let runningOnly = contextDockRunningOnlyAppMatching && !installedScopeMode
        let runningBundleIds = runningOnly ? runningBundleIdsForContextDock() : []

        if scope.isExplicitAppScope,
            let explicitTarget = L2AppActionRouter.shared.appScopeTarget(for: normalizedRawQuery),
            !runningOnly || runningBundleIds.contains(explicitTarget.bundleId),
            explicitTarget.bundleId == scope.scopedBundleId
        {
            return stripScopedAlias(
                explicitTarget.matchedAlias,
                from: rawQuery,
                allowPrefixAlias: runningOnly
            )
        }

        if scope.isExplicitAppScope,
            let installedTarget = installedAppMenuTarget(
                for: normalizedRawQuery,
                runningOnly: runningOnly,
                includeAppsWithoutMenuSnapshot: installedScopeMode,
                allowPrefixAlias: installedScopeMode
            ),
            installedTarget.bundleId == scope.scopedBundleId
        {
            return stripScopedAlias(
                installedTarget.matchedAlias,
                from: rawQuery,
                allowPrefixAlias: runningOnly || installedScopeMode
            )
        }

        return rawQuery
    }

    func messageIntentDisplayText(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    func firstQuotedPhrase(in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#, options: []) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
    }

    func makeMessagesSemanticIntentPill(
        fullQuery: String,
        rawScopedQuery: String,
        scopedBundleId: String,
        scopedAppName: String
    ) -> DockPill? {
        guard let intent = messagesScopedSemanticIntent(for: rawScopedQuery),
            let recipientName = intent.recipientName?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            let messageBody = intent.messageBody?.trimmingCharacters(in: .whitespacesAndNewlines),
            !recipientName.isEmpty,
            !messageBody.isEmpty
        else { return nil }

        let rawUserQuery = rawDockQuery(matching: fullQuery)
        let bodyLabel = messageIntentDisplayText(messageBody, limit: 36)
        let recipientLabel = messageIntentDisplayText(recipientName, limit: 26)

        var pill = DockPill(
            id: "messages-intent-send-\(normalizedDockPillText(rawScopedQuery))",
            name: "Send \"\(bodyLabel)\" to \(recipientLabel)",
            icon: "message.fill",
            accentColorName: "green",
            badge: "Conversation",
            execute: {
                self.executeCrossAppIntent(
                    intent,
                    userMessage: rawUserQuery,
                    unresolvedMessage:
                        "❌ Couldn't resolve that Messages recipient. Try: message send \"hi\" to [name]"
                )
            }
        )
        pill.sourceBundleId = scopedBundleId
        pill.sourceAppName = scopedAppName
        pill.rankingKind = "semanticIntent"
        pill.trackingIdentifier =
            "messages-intent:\(normalizedDockPillText(recipientName)):\(normalizedDockPillText(messageBody))"
        pill.searchTerms = [
            scopedAppName, "messages", "message", "send", recipientName, messageBody,
            "conversation",
        ]
        return pill
    }

    func makeMailSemanticSearchPill(
        fullQuery: String,
        rawScopedQuery: String,
        scopedBundleId: String,
        scopedAppName: String
    ) -> DockPill? {
        guard let intent = mailSemanticSearchIntent(from: rawScopedQuery) else { return nil }

        let rawUserQuery = rawDockQuery(matching: fullQuery)
        let queryLabel = messageIntentDisplayText(intent.displayLabel, limit: 42)

        var pill = DockPill(
            id: "mail-search-\(normalizedDockPillText(rawScopedQuery))",
            name: "Search Mail for \"\(queryLabel)\"",
            icon: "magnifyingglass",
            accentColorName: "blue",
            badge: "Mailbox",
            execute: {
                self.executeMailMailboxSearch(
                    intent: intent,
                    userMessage: rawUserQuery
                )
            }
        )
        pill.sourceBundleId = scopedBundleId
        pill.sourceAppName = scopedAppName
        pill.rankingKind = "semanticIntent"
        pill.trackingIdentifier =
            "mail-search:\(intent.tokenKind):\(normalizedDockPillText(intent.query))"
        pill.searchTerms = [scopedAppName, "mail", "mailbox", "search", "find", intent.query]
        return pill
    }

    func makeNativeWindowManagementPills(
        rawScopedQuery: String,
        scopedBundleId: String,
        scopedAppName: String,
        isGlobalScope: Bool
    ) -> [DockPill] {
        guard !isGlobalScope,
            !scopedBundleId.isEmpty,
            !scopedBundleId.hasPrefix("cli://"),
            !scopedBundleId.hasPrefix("scope://"),
            !scopedAppName.isEmpty
        else { return [] }

        let scopedIcon = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == scopedBundleId && !$0.isTerminated }?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: scopedBundleId)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        let otherIcon = secondaryDesktopAppIcon(excluding: scopedBundleId)

        return WindowManagementService.shared.matchingCommands(query: rawScopedQuery).map {
            command in
            var pill = DockPill(
                id: "native-window-\(scopedBundleId)-\(command.id)",
                name: command.title,
                icon: command.icon,
                accentColorName: "blue",
                badge: "Window",
                execute: {
                    launchAndApplyWindowCommand(
                        bundleId: scopedBundleId, appName: scopedAppName, command: command)
                }
            )
            // Layout preview showing the scoped app (and the other desktop app for
            // split arrangements) sitting where the layout will place it.
            pill.menuItemImage = windowLayoutPreviewImage(
                appIcon: scopedIcon, secondaryIcon: otherIcon, command: command)
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.rankingKind = "nativeWindow"
            pill.rankingScore = 1_400
            pill.trackingIdentifier = "native-window:\(scopedBundleId):\(command.id)"
            pill.searchTerms = command.searchTerms + [scopedAppName]
            return pill
        }
    }

    /// Native window-layout tiles for the "Windows" Global Command scope. Targets the
    /// app that was frontmost before Context-Dock opened, so arranging works even
    /// though the launcher itself is key. Empty query shows the full intelligent set;
    /// typing filters via the same matcher the app-scoped window pills use.
    func windowManagementScopePills(scopedBundleId: String, query: String) -> [DockPill] {
        guard let app = AppDelegate.shared?.previousFrontmostApp,
            !app.isTerminated,
            let bundleId = app.bundleIdentifier,
            !bundleId.isEmpty
        else { return [] }
        let appName = app.localizedName ?? "Window"

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands: [WindowManagementService.Command] =
            trimmed.isEmpty
            ? [
                .fill, .left, .right, .top, .bottom,
                .topLeft, .topRight, .bottomLeft, .bottomRight,
                .quarters, .center, .fullScreen, .restorePreviousSize,
            ]
            : WindowManagementService.shared.matchingCommands(query: trimmed)

        let appIcon = app.icon
        return commands.map { command in
            var pill = DockPill(
                id: "syscmd-windows-\(command.id)",
                name: command.title,
                icon: command.icon,
                accentColorName: "blue",
                badge: appName,
                execute: {
                    launchAndApplyWindowCommand(
                        bundleId: bundleId, appName: appName, command: command)
                    searchState.query = ""
                    l2.focusedPillIndex = nil
                }
            )
            // Render a live layout preview: the frontmost app's icon sitting in the
            // region the layout will move it to — instead of a generic split glyph.
            pill.menuItemImage = windowLayoutPreviewImage(
                appIcon: appIcon,
                secondaryIcon: secondaryDesktopAppIcon(excluding: bundleId),
                command: command)
            pill.rankingKind = "systemCommand"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = appName
            pill.trackingIdentifier = "syscmd-windows:\(command.id)"
            pill.searchTerms = command.searchTerms + [appName, "window", "layout"]
            return pill
        }
    }

    /// Live process/memory monitor scope. First row toggles the sort column; the
    /// remaining rows are apps (grouped with their helper processes) showing summed
    /// CPU% and memory. Enter on an app row terminates all of its processes.
    func processMonitorScopePills(scopedBundleId: String, query: String) -> [DockPill] {
        let service = ProcessMonitorService.shared
        let sort = service.sortMode

        // Read ONLY the cached snapshot here — sampling runs `ps` (a blocking
        // subprocess) and MUST NOT happen inside the view-build path. When the cache
        // is empty/stale, kick a background refresh that rebuilds the scope on
        // completion; while the scope stays open this yields ~2s live polling.
        if service.isSnapshotStale {
            service.refresh { [weak launcherViewModel] in
                guard launcherViewModel != nil else { return }
                self.scheduleDockPillRebuild(
                    query: self.searchState.query, delayNanoseconds: 0, refreshContext: false)
            }
        }
        let groups = service.cachedGroups()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = trimmed.isEmpty
            ? groups
            : groups.filter { $0.name.lowercased().contains(trimmed) }

        var pills: [DockPill] = []

        // Sort toggle (stands in for the top-right dropdown). Enter flips Memory⇄CPU
        // and rebuilds the list in place.
        var sortPill = DockPill(
            id: "syscmd-processes-sort",
            name: "Sort: \(sort.label)",
            icon: "arrow.up.arrow.down",
            accentColorName: "gray",
            badge: "\(groups.count) apps · \(groups.reduce(0) { $0 + $1.processCount }) processes",
            execute: {
                service.sortMode = (sort == .memory) ? .cpu : .memory
                scheduleDockPillRebuild(query: searchState.query, delayNanoseconds: 0, refreshContext: false)
            }
        )
        sortPill.rankingKind = "systemCommand"
        sortPill.sourceBundleId = scopedBundleId
        sortPill.sourceAppName = "Process Monitor"
        sortPill.trackingIdentifier = "syscmd-processes:sort"
        sortPill.searchTerms = ["sort", "cpu", "memory", "process", "monitor"]
        pills.append(sortPill)

        let cap = 40
        for group in filtered.prefix(cap) {
            let mem = service.formattedMemory(group.memoryBytes)
            let cpu = String(format: "%.1f%%", group.cpuPercent)
            let countLabel = group.processCount > 1 ? " · \(group.processCount) proc" : ""
            var pill = DockPill(
                id: "syscmd-processes-\(group.id)",
                name: group.name,
                icon: "cpu",
                accentColorName: "blue",
                badge: "\(cpu)   \(mem)\(countLabel)",
                execute: {
                    let killed = service.kill(group)
                    AppToast.show(
                        killed > 0 ? "Quit \(group.name)" : "Couldn't quit \(group.name)",
                        icon: killed > 0 ? "xmark.circle" : "exclamationmark.triangle",
                        tint: killed > 0 ? .orange : .red
                    )
                    // Give SIGTERM a moment to land, then force a fresh sample so the
                    // quit app drops off the list, and rebuild.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak launcherViewModel] in
                        guard launcherViewModel != nil else { return }
                        service.refresh {
                            self.scheduleDockPillRebuild(
                                query: self.searchState.query, delayNanoseconds: 0, refreshContext: false)
                        }
                    }
                }
            )
            pill.menuItemImage = service.icon(for: group)
            pill.rankingKind = "systemCommand"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = "Process Monitor"
            pill.trackingIdentifier = "syscmd-processes:\(group.id)"
            pill.keyboardShortcutLabel = "Kill"
            pill.searchTerms = [group.name, "process", "memory", "cpu", "kill", "activity"]
            pills.append(pill)
        }

        return pills
    }

    /// Renders a user-authored list extension (`provider:custom`). Reads ONLY the
    /// cached rows (the rows script runs off-view); kicks a background refresh when
    /// the cache is stale and rebuilds the scope when it returns.
    func customListProviderScopePills(
        command: SystemCommand, scopedBundleId: String, query: String
    ) -> [DockPill] {
        let service = CustomListProviderService.shared
        let live = CustomListProviderService.isLiveQuery(command)

        if service.isStale(command, query: query) {
            service.refresh(command, query: query) { [weak launcherViewModel] in
                guard launcherViewModel != nil else { return }
                self.scheduleDockPillRebuild(
                    query: self.searchState.query, delayNanoseconds: 0, refreshContext: false)
            }
        }

        let rows = service.rows(for: command)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Live-query scripts already account for the query (via $CD_QUERY), so never
        // client-filter their rows — that would hide a synthetic "Save: <query>" row.
        let filtered = (trimmed.isEmpty || live)
            ? rows
            : rows.filter {
                $0.title.lowercased().contains(trimmed)
                    || ($0.subtitle?.lowercased().contains(trimmed) ?? false)
            }

        let hasAction = !command.undoScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // An extension scope owns the sheet the moment it is entered, so the shell can
        // already be expanded when the rows script has produced nothing — which renders
        // as a large empty box that looks like a crash. Always give the sheet one row
        // saying what is actually happening.
        if filtered.isEmpty {
            let refreshing = service.isRefreshing(command) || !service.hasRun(command)
            var status = DockPill(
                id: "syscmd-custom-status-\(command.id)",
                name: refreshing ? "Working…" : "No results",
                icon: refreshing ? "hourglass" : "magnifyingglass",
                accentColorName: refreshing ? "blue" : "secondary",
                badge: refreshing
                    ? nil
                    : (trimmed.isEmpty ? "Nothing to show" : "Nothing matched “\(query)”"),
                execute: {}
            )
            status.isEnabled = false
            status.rankingKind = "systemCommand"
            status.sourceBundleId = scopedBundleId
            status.sourceAppName = command.name
            status.trackingIdentifier = "syscmd-custom-status:\(command.id)"
            // The dock ranks/filters pills by searchTerms. A computed extension's rows
            // are an ANSWER to the query, not a match for it — "12" appears nowhere in
            // "US Dollar" — so without the raw query here the dock drops every row the
            // moment the user types, leaving the sheet expanded and empty.
            status.searchTerms = [query, command.name]
            return [status]
        }

        return filtered.enumerated().map { index, row in
            var pill = DockPill(
                // Index keeps the id unique even when a script emits duplicate row ids
                // (e.g. several processes sharing one executable path) — duplicate
                // SwiftUI ForEach ids otherwise collapse a row into a blank gap.
                id: "syscmd-custom-\(command.id)-\(index)-\(row.id)",
                name: row.title,
                icon: sfSymbolName(for: row.icon) ?? command.icon,
                accentColorName: "indigo",
                badge: row.badge ?? row.subtitle,
                execute: {
                    if hasAction {
                        service.runAction(command, row: row, query: self.searchState.query)
                        AppToast.show("Ran \(command.name)", icon: command.icon, tint: .blue)
                    } else if let path = Self.customListRowOpenablePath(row) {
                        // No row-action script authored: if the row id/icon is a real
                        // file or app path (Applications, Downloads, Screenshots…), open
                        // it. Makes path scopes work without requiring an undoScript.
                        AppDelegate.shared?.holdDockThroughAppLaunch()
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        self.forceHideLauncherAfterResultExecution()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak launcherViewModel] in
                        guard launcherViewModel != nil else { return }
                        service.refresh(command, query: self.searchState.query) {
                            self.scheduleDockPillRebuild(
                                query: self.searchState.query, delayNanoseconds: 0, refreshContext: false)
                        }
                    }
                }
            )
            // Real Finder icon — and a QuickLook thumbnail where one is meaningful —
            // whenever the row points at a file. Authors nearly always put an SF Symbol in
            // `icon` and the path in `id`, so resolving through the path is what makes a
            // screenshots scope look like Finder instead of identical repeated glyphs.
            if let path = Self.customListRowOpenablePath(row) {
                pill.previewPath = path
                if let thumb = FileThumbnailCache.shared.thumbnail(for: path, onReady: {
                    self.scheduleDockPillRebuild(
                        query: self.searchState.query, delayNanoseconds: 0,
                        refreshContext: false)
                }) {
                    pill.menuItemImage = thumb
                } else if let fileIcon = fileSystemIcon(for: path) {
                    pill.menuItemImage = fileIcon
                }
            } else if let fileIcon = fileSystemIcon(for: row.icon) {
                pill.menuItemImage = fileIcon
            }
            if row.badge != nil, let sub = row.subtitle {
                pill.menuStatusBadge = sub
            }
            pill.rankingKind = "systemCommand"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = command.name
            pill.trackingIdentifier = "syscmd-custom:\(command.id):\(row.id)"
            if hasAction {
                pill.keyboardShortcutLabel = "Run"
            } else if Self.customListRowOpenablePath(row) != nil {
                pill.keyboardShortcutLabel = "Open"
            }
            if row.isCompare {
                pill.compareLeft = row.left
                pill.compareRight = row.right
                pill.compareIcon = row.centerIcon
                pill.compareLeftQuery = row.leftQuery
                pill.compareRightQuery = row.rightQuery
                pill.compareCommandID = command.id
                pill.compareCenterAction = row.centerAction
            }
            // Include the raw query: see the note on the status row. A compare card for
            // "12" contains none of the characters the user typed.
            pill.searchTerms = [row.title, row.subtitle ?? "", command.name, query]
            return pill
        }
    }

    /// Row has no undoScript but its id/icon is a real file or app path → Enter opens it.
    /// Returns the resolved path (id preferred over icon), or nil if neither is a path.
    static func customListRowOpenablePath(_ row: CustomListRow) -> String? {
        for candidate in [row.id, row.icon].compactMap({ $0 }) {
            guard candidate.hasPrefix("/") || candidate.hasPrefix("~") else { continue }
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// If `icon` looks like an SF Symbol name (no slash, no dot-app), return it.
    private func sfSymbolName(for icon: String?) -> String? {
        guard let icon, !icon.isEmpty, !icon.contains("/"), !icon.hasSuffix(".app") else {
            return nil
        }
        return icon
    }

    /// If `icon` is a file/app path, load its Finder icon.
    private func fileSystemIcon(for icon: String?) -> NSImage? {
        guard let icon, icon.contains("/") || icon.hasSuffix(".app") else { return nil }
        let path = (icon as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    /// Normalized regions (top-left origin) a layout moves the window into. `nil`
    /// means the full screen. Quarters is handled specially (four cells).
    private func windowLayoutRegions(
        for command: WindowManagementService.Command
    ) -> [CGRect] {
        switch command {
        case .left: return [CGRect(x: 0, y: 0, width: 0.5, height: 1)]
        case .right: return [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .top: return [CGRect(x: 0, y: 0, width: 1, height: 0.5)]
        case .bottom: return [CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .topLeft: return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]
        case .topRight: return [CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)]
        case .bottomLeft: return [CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)]
        case .bottomRight: return [CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .center: return [CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.68)]
        case .quarters:
            return [
                CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            ]
        // Two-window arrangements: first region is the scoped app, second is the
        // other app sharing the desktop.
        case .leftAndRight:
            return [
                CGRect(x: 0, y: 0, width: 0.5, height: 1),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            ]
        case .rightAndLeft:
            return [
                CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                CGRect(x: 0, y: 0, width: 0.5, height: 1),
            ]
        case .topAndBottom:
            return [
                CGRect(x: 0, y: 0, width: 1, height: 0.5),
                CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
            ]
        case .bottomAndTop:
            return [
                CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
                CGRect(x: 0, y: 0, width: 1, height: 0.5),
            ]
        default:
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]  // fill / fullscreen / restore
        }
    }

    /// Draws a small screen with the app icon placed in the layout's target region.
    func windowLayoutPreviewImage(
        appIcon: NSImage?,
        secondaryIcon: NSImage? = nil,
        command: WindowManagementService.Command
    ) -> NSImage {
        let size = NSSize(width: 30, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let screen = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: 3, yRadius: 3)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        screenPath.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        screenPath.lineWidth = 1
        screenPath.stroke()

        let regions = windowLayoutRegions(for: command)
        let isQuarters = command == .quarters
        for (index, region) in regions.enumerated() {
            // Flip Y: layout regions use a top-left origin; AppKit draws bottom-up.
            let rect = NSRect(
                x: screen.minX + region.minX * screen.width,
                y: screen.minY + (1 - region.minY - region.height) * screen.height,
                width: region.width * screen.width,
                height: region.height * screen.height
            ).insetBy(dx: 0.6, dy: 0.6)
            let tile = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            tile.fill()

            // Region 0 is the scoped app; region 1 is the other app sharing the
            // desktop (split arrangements). Quarters stays a plain grid.
            let icon: NSImage? = isQuarters ? nil : (index == 0 ? appIcon : secondaryIcon)
            if let icon {
                let side = min(rect.width, rect.height) * 0.72
                let iconRect = NSRect(
                    x: rect.midX - side / 2,
                    y: rect.midY - side / 2,
                    width: side,
                    height: side
                )
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }
        return image
    }

    /// Icon of another regular app sharing the current desktop — used as the second
    /// tile in split layout previews. `nil` when the scoped app is the only one.
    func secondaryDesktopAppIcon(excluding bundleId: String) -> NSImage? {
        NSWorkspace.shared.runningApplications
            .first {
                $0.activationPolicy == .regular
                    && !$0.isTerminated
                    && $0.bundleIdentifier != bundleId
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }?
            .icon
    }

    /// Rows for the "Quick Note" (provider:notepad) scope: a Save row that captures
    /// the current input as a note, followed by saved notes (newest first). The
    /// outer scope filter narrows notes by the typed text, so composing and searching
    /// share one input. Tapping a note copies it; the trailing Quit action deletes it.
    func quickNotepadScopePills(scopedBundleId: String, query: String) -> [DockPill] {
        var pills: [DockPill] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            var save = DockPill(
                id: "notepad-save",
                name: "Save note “\(trimmed)”",
                icon: "square.and.pencil",
                accentColorName: "green",
                badge: "Return",
                execute: {
                    QuickNotesStore.shared.add(trimmed)
                    searchState.query = ""
                    clearSearchFieldEditorText()
                    l2.focusedPillIndex = nil
                    reclaimSearchInputFocus()
                }
            )
            save.rankingKind = "systemCommand"
            save.sourceBundleId = scopedBundleId
            save.sourceAppName = "Quick Note"
            save.trackingIdentifier = "notepad:save"
            // Keyword the outer scope filter always matches so this row never drops.
            save.searchTerms = [trimmed, "save", "note", "add"]
            pills.append(save)
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        for note in QuickNotesStore.shared.notes {
            let when = formatter.localizedString(for: note.createdAt, relativeTo: Date())
            var pill = DockPill(
                id: "notepad-\(note.id.uuidString)",
                name: note.text,
                icon: "note.text",
                accentColorName: "indigo",
                badge: when,
                execute: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.text, forType: .string)
                    AppToast.show("Note copied", icon: "doc.on.doc", tint: .indigo)
                    searchState.query = ""
                    clearSearchFieldEditorText()
                    l2.focusedPillIndex = nil
                }
            )
            pill.rankingKind = "systemCommand"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = "Quick Note"
            pill.trackingIdentifier = "notepad:\(note.id.uuidString)"
            pill.searchTerms = [note.text, "note"]
            pills.append(pill)
        }

        if pills.isEmpty {
            var hint = DockPill(
                id: "notepad-empty",
                name: "Type a note, then press Return to save",
                icon: "note.text",
                accentColorName: "gray",
                badge: nil,
                execute: {}
            )
            hint.rankingKind = "systemCommand"
            hint.sourceBundleId = scopedBundleId
            hint.sourceAppName = "Quick Note"
            hint.trackingIdentifier = "notepad:empty"
            hint.searchTerms = ["note"]
            pills.append(hint)
        }
        return pills
    }

    /// Quick Note AI: send the input-field prompt to the user's selected AI provider
    /// and insert the reply into the open note (creating one if none is selected).
    /// The provider is whatever the user picked globally — so the notepad's AI is
    /// their AI, no extra config.
    /// Capture the frontmost window's context (app, window title, URL, selected
    /// text) to attach to the next Quick Note AI prompt — or clear it if already set.
    func toggleNotepadFrontmostContext() {
        if notepadFrontmostContext != nil {
            notepadFrontmostContext = nil
            notepadFrontmostLabel = nil
            return
        }
        let ctx = AXContextReader.shared.current
        let appName = ctx.appName.isEmpty
            ? (AppDelegate.shared?.previousFrontmostApp?.localizedName ?? "Frontmost app")
            : ctx.appName
        var parts: [String] = ["Frontmost app: \(appName)"]
        if let title = ctx.windowTitle, !title.isEmpty { parts.append("Window: \(title)") }
        if let url = ctx.currentURL, !url.isEmpty { parts.append("URL: \(url)") }
        if let selection = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !selection.isEmpty
        {
            parts.append("Selected text:\n\(selection)")
        }
        notepadFrontmostContext = parts.joined(separator: "\n")
        notepadFrontmostLabel = appName
    }

    /// Open the file picker and append the chosen images/files to the Quick Note
    /// AI attachments.
    func attachNotepadFiles(imagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = imagesOnly ? [.image] : [.image, .pdf, .plainText, .data]
        panel.message = "Choose files to attach to your note"
        if panel.runModal() == .OK {
            let newURLs = panel.urls.filter { !notepadAttachments.contains($0) }
            notepadAttachments.append(contentsOf: newURLs)
        }
    }

    /// Move the notepad selection up/down the notes list (newest first).
    func navigateNotepadSelection(delta: Int) {
        let notes = QuickNotesStore.shared.notes
        guard !notes.isEmpty else { return }
        let current = notepadSelectedNoteID.flatMap { id in notes.firstIndex { $0.id == id } } ?? -1
        let next = min(max(current + delta, 0), notes.count - 1)
        notepadSelectedNoteID = notes[next].id
    }

    func submitNotepadAIPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = notepadAttachments
        let capturedText = notepadCapturedText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !(trimmed.isEmpty && attached.isEmpty && capturedText.isEmpty),
            !notepadAIGenerating else { return }

        let targetID: UUID
        if let id = notepadSelectedNoteID,
            QuickNotesStore.shared.notes.contains(where: { $0.id == id })
        {
            targetID = id
        } else {
            targetID = QuickNotesStore.shared.create()
            notepadSelectedNoteID = targetID
        }

        // With only attachments and no text, ask the model to write from them.
        var request = trimmed.isEmpty
            ? "Write a note from the attached image(s), file(s), or captured text."
            : trimmed
        if !capturedText.isEmpty {
            request += "\n\nCaptured screen text:\n\(capturedText)"
        }
        // Fold in the attached frontmost-window context, if any, then clear it.
        let aiQuery: String
        if let context = notepadFrontmostContext {
            aiQuery =
                "Context from the user's frontmost window:\n\(context)\n\n---\n\nRequest: \(request)"
        } else {
            aiQuery = request
        }
        notepadFrontmostContext = nil
        notepadFrontmostLabel = nil
        notepadCapturedText = nil
        notepadAttachments = []

        notepadAIGenerating = true
        searchState.query = ""
        clearSearchFieldEditorText()

        Task { [weak store = QuickNotesStore.shared] in
            let reply: String
            do {
                reply = try await sendToAIProvider(query: aiQuery, attachments: attached)
            } catch {
                reply = "⚠️ AI error: \(error.localizedDescription)"
            }
            await MainActor.run {
                let existing = store?.notes.first(where: { $0.id == targetID })?.text ?? ""
                let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                let joined = existing.isEmpty ? body : existing + "\n\n" + body
                store?.updateText(joined, for: targetID)
                self.notepadAIGenerating = false
            }
        }
    }

    /// Launch (if needed) and tile. In Global Context the target app may be quit,
    /// minimized, or on another Space — so instead of erroring "not running", open it
    /// on the current desktop, restore/activate it, then apply the window arrangement.
    func launchAndApplyWindowCommand(
        bundleId: String, appName: String, command: WindowManagementService.Command
    ) {
        Task { @MainActor in
            @MainActor func apply(_ app: NSRunningApplication) async {
                await MenuExecutionCoordinator.restoreWindowIfAllMinimized(app)
                app.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: 180_000_000)
                _ = WindowManagementService.shared.execute(command, sourceApp: app)
                resetDockStateAfterAppAction()
            }

            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }) {
                await apply(app)
                return
            }

            guard
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            else {
                AppToast.show(
                    "Could not open \(appName)", icon: "exclamationmark.triangle", tint: .orange)
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                let app = try await NSWorkspace.shared.openApplication(
                    at: url, configuration: config)
                // Wait for the app to put a real window on the current Space.
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    let hasWindow =
                        (CGWindowListCopyWindowInfo(
                            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                            as? [[String: Any]])?
                        .contains {
                            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                        } ?? false
                    if hasWindow { break }
                }
                await apply(app)
            } catch {
                AppToast.show(
                    "Could not open \(appName)", icon: "exclamationmark.triangle", tint: .orange)
            }
        }
    }

    func shouldSuppressMenuItemForNativeWindowManagement(_ item: AXMenuItem) -> Bool {
        let normalizedPath = item.path.map(normalizedDockPillText)
        if normalizedPath.first == "window" { return true }
        return WindowManagementService.shared.handlesMenuPath(item.path)
    }

    func makeChatGPTNewChatPill(
        scopedQuery: String,
        scopedBundleId: String,
        scopedAppName: String,
        appPath: String?
    ) -> DockPill? {
        guard scopedBundleId == "com.openai.chat" else { return nil }
        let normalized = normalizedDockPillText(scopedQuery)
        guard !normalized.isEmpty else { return nil }
        let isNewChat =
            normalized == "new chat"
            || normalized == "new conversation"
            || normalized == "start chat"
            || normalized == "start new chat"
            || normalized.contains("new chat")
        guard isNewChat else { return nil }

        var pill = DockPill(
            id: "chatgpt-new-chat",
            name: "New Chat",
            icon: "plus.message",
            accentColorName: "green",
            badge: scopedAppName.isEmpty ? "ChatGPT" : scopedAppName,
            execute: {
                self.executeChatGPTNewChat(appPath: appPath)
            }
        )
        pill.sourceBundleId = scopedBundleId
        pill.sourceAppName = scopedAppName.isEmpty ? "ChatGPT" : scopedAppName
        pill.rankingKind = "semanticIntent"
        pill.trackingIdentifier = "chatgpt:new-chat"
        pill.searchTerms = ["chatgpt", "chat gpt", "new chat", "new conversation", "start chat"]
        return pill
    }

    func executeChatGPTNewChat(appPath: String?) {
        let menuPath = ["File", "New Chat"]
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.chat" && !$0.isTerminated
        }) {
            executeDockMenuAction(
                sourcePID: app.processIdentifier,
                path: menuPath,
                shortcutChar: nil,
                shortcutModifiers: 0
            )
            return
        }

        guard
            launchApplication(
                bundleIdentifier: "com.openai.chat",
                appName: "ChatGPT",
                path: appPath
            )
        else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard
                let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == "com.openai.chat" && !$0.isTerminated
                })
            else { return }
            executeDockMenuAction(
                sourcePID: app.processIdentifier,
                path: menuPath,
                shortcutChar: nil,
                shortcutModifiers: 0
            )
        }
    }

    func buildPayloadActionPills(query: String) -> [DockPill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let selectedPaths = effectiveSelectedFileURLsForConversation().map(\.path)
        let selectedText = (axContext.selectedText ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let currentURL = (axContext.currentURL ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let windowTitle = (axContext.windowTitle ?? frontmost.name).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let clipboardText = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hasFiles = !selectedPaths.isEmpty
        let selectedURLs = selectedPaths.map { URL(fileURLWithPath: $0) }
        let hasText = !selectedText.isEmpty
        let hasURL = !currentURL.isEmpty
        let textPayload = hasText ? selectedText : clipboardText
        let noteBody = [hasText ? selectedText : nil, hasURL ? currentURL : nil]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let reminderText = !textPayload.isEmpty ? textPayload : windowTitle
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Downloads")

        func matches(_ terms: [String]) -> Bool {
            terms.contains { q.contains($0) || $0.contains(q) }
        }

        var pills: [DockPill] = []

        if hasFiles, let transformIntent = transformShareIntent(for: query) {
            let channelLabel: String = {
                switch transformIntent.channelHint {
                case .messages: return "Messages"
                case .mail: return "Mail"
                case .airDrop: return "AirDrop"
                case .picker: return "Share"
                }
            }()
            let recipient = transformIntent.recipientQuery?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = recipient.map { "Summarize + Send to \($0)" } ?? "Summarize + Send"
            var pill = DockPill(
                id: "payload-transform-share-\(normalizedDockPillText(query))",
                name: name,
                icon: transformIntent.channelHint == .mail ? "envelope" : "message",
                accentColorName: transformIntent.channelHint == .mail ? "blue" : "green",
                badge: channelLabel,
                execute: {
                    self.executeTransformShareIntent(transformIntent, userMessage: query)
                }
            )
            pill.rankingKind = "transformShare"
            pill.searchTerms = [
                "summarize", "summary", "explain", "send", "message", "mail", "file",
            ]
            pill.trackingIdentifier = "transform-share:\(normalizedDockPillText(query))"
            pills.append(pill)
        }

        if hasText || hasURL, matches(["notes", "note", "quick note", "save note", "capture"]) {
            pills.append(
                DockPill(
                    id: "payload-notes",
                    name: "Save to Notes",
                    icon: "note.text",
                    accentColorName: "yellow",
                    badge: hasText ? "Selection" : "URL",
                    execute: {
                        guard self.settings.allowAutomation else {
                            self.l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content: "Automation permission is disabled for Notes actions.",
                                    isError: true))
                            return
                        }
                        let title = windowTitle.isEmpty ? "Context Capture" : windowTitle
                        let ok: Bool
                        if !noteBody.isEmpty {
                            ok = AppleAppsAPI.shared.createNote(
                                title: title, body: noteBody, folder: "Context Dock")
                        } else {
                            ok = false
                        }
                        self.l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: ok ? "Saved to Notes." : "Failed to save to Notes.",
                                isError: !ok
                            ))
                    }
                ))
        }

        if hasText || hasURL || hasFiles,
            matches(["mail", "email", "compose", "new mail", "send email", "share via mail"])
        {
            pills.append(
                DockPill(
                    id: "payload-mail",
                    name: hasFiles ? "Share via Mail" : "Compose Mail",
                    icon: "envelope",
                    accentColorName: "blue",
                    badge: hasFiles ? "Files" : "Selection",
                    execute: {
                        self.executeShareIntent(
                            ShareIntent(
                                rawQuery: hasFiles ? "share via mail" : "compose mail",
                                channelHint: .mail,
                                recipientQuery: nil
                            )
                        )
                    }
                ))
        }

        if !textPayload.isEmpty || hasURL, matches(["reminder", "remind", "todo", "task"]) {
            pills.append(
                DockPill(
                    id: "payload-reminder",
                    name: "Create Reminder",
                    icon: "checklist",
                    accentColorName: "orange",
                    badge: "Selection",
                    execute: {
                        guard self.settings.allowAutomation else {
                            self.l2.chatMessages.append(
                                AIChatMessage(
                                    role: .assistant,
                                    content:
                                        "Automation permission is disabled for Reminders actions.",
                                    isError: true))
                            return
                        }
                        let ok = AppleAppsAPI.shared.createReminder(title: reminderText)
                        self.l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: ok ? "Reminder created." : "Failed to create reminder.",
                                isError: !ok
                            ))
                    }
                ))
        }

        if hasText || hasURL || hasFiles,
            matches(["message", "messages", "imessage", "new message", "send message"])
        {
            pills.append(
                DockPill(
                    id: "payload-messages",
                    name: "Send via Messages",
                    icon: "message",
                    accentColorName: "green",
                    badge: hasFiles ? "Files" : "Share",
                    execute: {
                        self.executeShareIntent(
                            ShareIntent(
                                rawQuery: hasFiles ? "send via messages" : "send this via messages",
                                channelHint: .messages,
                                recipientQuery: nil
                            )
                        )
                    }
                ))
        }

        if hasFiles, matches(["downloads", "download", "move to downloads", "send to downloads"]) {
            pills.append(
                DockPill(
                    id: "payload-downloads-move",
                    name: "Move to Downloads",
                    icon: "arrow.down.circle",
                    accentColorName: "teal",
                    badge: "\(selectedPaths.count)",
                    execute: {
                        let fm = FileManager.default
                        try? fm.createDirectory(
                            at: downloadsPath, withIntermediateDirectories: true)
                        var moved = 0
                        for source in selectedURLs {
                            let destination = downloadsPath.appendingPathComponent(
                                source.lastPathComponent)
                            let uniqueDestination = self.uniqueMoveDestination(for: destination)
                            do {
                                try fm.moveItem(at: source, to: uniqueDestination)
                                moved += 1
                            } catch {
                                continue
                            }
                        }
                        let ok = moved > 0
                        self.l2.chatMessages.append(
                            AIChatMessage(
                                role: .assistant,
                                content: ok
                                    ? "Moved \(moved) item\(moved == 1 ? "" : "s") to Downloads."
                                    : "Failed to move items to Downloads.",
                                isError: !ok
                            ))
                    }
                ))
            pills.append(
                DockPill(
                    id: "payload-downloads-open",
                    name: "Open Downloads",
                    icon: "folder",
                    accentColorName: "gray",
                    badge: "Downloads",
                    execute: {
                        NSWorkspace.shared.open(downloadsPath)
                    }
                ))
        }

        if hasFiles, matches(["share", "send", "export"]) {
            pills.append(
                DockPill(
                    id: "payload-share-files",
                    name: "Share Selected Files",
                    icon: "square.and.arrow.up",
                    accentColorName: "blue",
                    badge: "\(selectedPaths.count)",
                    execute: {
                        self.executeShareIntent(
                            ShareIntent(
                                rawQuery: "share selected files",
                                channelHint: .picker,
                                recipientQuery: nil
                            )
                        )
                    }
                ))
        }

        return pills
    }

    func uniqueMoveDestination(for desiredURL: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: desiredURL.path) else { return desiredURL }

        let directory = desiredURL.deletingLastPathComponent()
        let baseName = desiredURL.deletingPathExtension().lastPathComponent
        let ext = desiredURL.pathExtension

        for index in 2...500 {
            let candidateName = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return desiredURL
    }

    func detectCrossAppQuery(_ q: String) -> (NSRunningApplication, String)? {
        guard !q.isEmpty, let delegate = AppDelegate.shared else { return nil }
        let recentApps = delegate.recentApps.filter { !$0.isTerminated }
        let frontPID = delegate.previousFrontmostApp?.processIdentifier ?? 0
        for app in recentApps {
            guard app.processIdentifier != frontPID else { continue }
            let name = (app.localizedName ?? "").lowercased()
            guard !name.isEmpty else { continue }
            // Require a space after the app name so single-word queries like "centre"
            // never accidentally match a recent app whose name starts with "cent" etc.
            if q.hasPrefix(name + " ") {
                let remainder = String(q.dropFirst(name.count + 1))
                return (app, remainder)
            }
            // Also match shortened names: "safari close tab" matches "Safari Technology Preview"
            let firstWord = name.components(separatedBy: " ").first ?? name
            if firstWord.count >= 3, q.hasPrefix(firstWord + " ") {
                let remainder = String(q.dropFirst(firstWord.count + 1))
                return (app, remainder)
            }
        }
        return nil
    }

    func installedAppMenuTarget(
        for query: String,
        runningOnly: Bool = false,
        includeAppsWithoutMenuSnapshot: Bool = false,
        allowPrefixAlias: Bool = false,
        preserveRemainingQueryTokens: Bool = false,
        excludingBundleIds: Set<String> = []
    ) -> InstalledAppMenuTarget? {
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = rawQuery.lowercased()
        guard q.count >= (runningOnly ? 3 : 2) else { return nil }

        let runningBundleIds: Set<String>? =
            runningOnly
            ? Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            : nil

        var best: (target: InstalledAppMenuTarget, score: Int)?

        // Hot path: this runs per keystroke over every installed app. Token
        // extraction is comparatively expensive, so gate each alias behind a
        // cheap necessary-condition check against the query's token set first.
        let prefixMatchingAllowed = runningOnly || allowPrefixAlias
        let normalizedQueryTokens = rawQuery
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { normalizedDockPillText(String($0)) }
        let queryTokenSet = Set(normalizedQueryTokens)

        func aliasCanMatch(_ alias: String) -> Bool {
            guard let firstToken = alias.split(separator: " ").first.map(String.init) else {
                return false
            }
            if queryTokenSet.contains(firstToken) { return true }
            guard prefixMatchingAllowed else { return false }
            return normalizedQueryTokens.contains { token in
                token.count >= 3 && firstToken.hasPrefix(token)
            }
        }

        func consider(
            appName: String,
            bundleId: String,
            appPath: String,
            baseScore: Int
        ) {
            guard !excludingBundleIds.contains(bundleId) else { return }
            let entry = AppScopeMatchCache.shared.aliasEntry(
                bundleId: bundleId, appName: appName
            ) {
                AppScopeMatchCache.AliasEntry(
                    normalizedName: normalizedDockPillText(appName),
                    aliases: dockPillAppAliases(appName: appName, bundleId: bundleId)
                )
            }
            let normalizedName = entry.normalizedName
            guard !normalizedName.isEmpty else { return }

            for alias in entry.aliases where alias.count >= 2 {
                guard aliasCanMatch(alias),
                    let extraction = installedAppActionExtraction(
                        query: rawQuery,
                        alias: alias,
                        allowPrefixAlias: prefixMatchingAllowed,
                        preserveRemainingQueryTokens: preserveRemainingQueryTokens
                    )
                else {
                    continue
                }
                let actionQuery = extraction.actionQuery
                let exactFullNameBonus =
                    alias == normalizedName && !extraction.usedPrefixAlias ? 1_200 : 0
                let exactAliasBonus = extraction.usedPrefixAlias ? 0 : 520
                let positionBonus =
                    extraction.aliasAtStart ? 120 : max(20, 95 - (extraction.aliasStartIndex * 18))
                let score =
                    baseScore
                    + positionBonus
                    + (extraction.usedPrefixAlias ? -220 : 0)
                    + exactAliasBonus
                    + (extraction.aliasTokenCount * 80)
                    + exactFullNameBonus
                    + alias.count
                    + min(actionQuery.count, 24)
                    + (actionQuery.isEmpty ? 25 : 0)
                    + (bundleId == "com.apple.Photos" && alias == "photos" ? 600 : 0)

                let target = InstalledAppMenuTarget(
                    appName: appName,
                    bundleId: bundleId,
                    appPath: appPath,
                    actionQuery: actionQuery,
                    matchedAlias: preserveRemainingQueryTokens
                        ? extraction.matchedQueryAlias : alias,
                    aliasStartIndex: extraction.aliasStartIndex
                )
                if best.map({ score > $0.score }) ?? true {
                    best = (target, score)
                }
            }
        }

        if runningOnly {
            let runningApps =
                runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
            for app in runningApps {
                guard
                    let appName = app.localizedName?.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    !appName.isEmpty,
                    let bundleId = app.bundleIdentifier,
                    !bundleId.isEmpty
                else { continue }
                let appPath =
                    app.bundleURL?.path
                    ?? installedApplicationResult(bundleIdentifier: bundleId)?.subtitle
                    ?? ""
                consider(
                    appName: appName,
                    bundleId: bundleId,
                    appPath: appPath,
                    baseScore: 128
                )
            }

            return best?.target
        }

        for result in allApplications where result.type == .application {
            let appName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let appPath = result.subtitle
            guard !appName.isEmpty, !appPath.isEmpty else { continue }

            guard let bundleId = AppScopeMatchCache.shared.bundleId(forAppPath: appPath) else {
                continue
            }
            if includeAppsWithoutMenuSnapshot,
                implicitContextDockAppScopeBlockedBundleIds.contains(bundleId)
            {
                continue
            }
            // In context dock mode: skip apps that aren't currently running
            if let runningBundleIds, !runningBundleIds.contains(bundleId) { continue }
            // Eligibility lookups are only needed when the cheap flags don't
            // already admit the app — keep them off the per-keystroke path.
            if !includeAppsWithoutMenuSnapshot, !runningOnly, bundleId != "com.openai.chat",
                !GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bundleId)
            {
                let appKey = settings.appKey(forBundleID: bundleId, appName: appName)
                let hasShortcutSurface =
                    appKey.map {
                        !appScopeShortcuts(
                            for: $0, placements: [.quickActions, .contextDock, .both]
                        ).isEmpty
                    } ?? false
                guard hasShortcutSurface else { continue }
            }

            consider(appName: appName, bundleId: bundleId, appPath: appPath, baseScore: 112)
        }

        // System app scopes must work even before the app index/menu snapshot cache is warm.
        // Otherwise natural queries like "new notes" stay in global mode and only Apple-menu
        // matches are visible.
        let builtInAppTargets: [(name: String, bundleId: String, path: String)] = [
            ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
            ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
            ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
            ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
            ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
            ("Reminders", "com.apple.reminders", "/System/Applications/Reminders.app"),
            ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
            ("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
            (
                "System Settings", "com.apple.systempreferences",
                "/System/Applications/System Settings.app"
            ),
        ]
        for target in builtInAppTargets {
            if let runningBundleIds, !runningBundleIds.contains(target.bundleId) { continue }
            consider(
                appName: target.name,
                bundleId: target.bundleId,
                appPath: target.path,
                baseScore: 108
            )
        }

        return best?.target
    }

    func cachedScopedAppMenuPills(
        bundleIdentifier: String,
        appName: String,
        appPath: String?,
        query: String = "",
        maxResults: Int = 24,
        allowLiveRefresh: Bool = true
    ) -> [DockPill] {
        guard !bundleIdentifier.isEmpty else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let runningApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
        let liveMatches: [AXMenuItem] = {
            guard allowLiveRefresh, let runningApp else { return [] }
            let pid = runningApp.processIdentifier
            var live = AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
            guard !live.isEmpty else { return [] }
            for index in live.indices {
                live[index].sourcePID = pid
                live[index].sourceAppName = runningApp.localizedName ?? appName
            }
            AppMenuCapabilityCache.shared.store(items: live, for: runningApp)
            return live
        }()
        let cachedAppName = runningApp?.localizedName ?? appName
        let cachedPID = runningApp?.processIdentifier ?? 0
        let persistentMatches: [AXMenuItem] = {
            guard !trimmedQuery.isEmpty else {
                return GlobalContextEngine.shared.cachedMenuItems(
                    bundleIdentifier: bundleIdentifier,
                    appName: cachedAppName,
                    processIdentifier: cachedPID,
                    query: "",
                    maxResults: maxResults
                )
            }

            let ranked = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleIdentifier,
                appName: cachedAppName,
                processIdentifier: cachedPID,
                query: trimmedQuery,
                maxResults: max(120, maxResults * 6)
            )
            if !ranked.isEmpty { return ranked }

            // Preserve typo tolerance without scanning up to 2,000 browser rows per keypress.
            return GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleIdentifier,
                appName: cachedAppName,
                processIdentifier: cachedPID,
                query: "",
                maxResults: min(350, max(160, maxResults * 8))
            )
        }()
        let items = {
            var seen = Set<String>()
            var merged: [AXMenuItem] = []
            for item in liveMatches + persistentMatches {
                let key = item.path.joined(separator: " > ").lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                merged.append(item)
            }
            return merged
        }()
        let filteredItems: [AXMenuItem] = {
            let appItems = items.filter {
                !isRejectedTopMenuItem($0, appName: appName)
                    && shouldExposeCachedMenuItem($0)
                    && !shouldSuppressMenuItemForNativeWindowManagement($0)
            }
            guard !trimmedQuery.isEmpty else { return appItems }
            return orderedScopedMenuItemsLikeContextDock(
                appItems.filter {
                    cachedScopedMenuItemMatchesQuery($0, query: trimmedQuery)
                },
                filterQuery: trimmedQuery,
                limit: maxResults
            )
        }()

        return filteredItems.flatMap { item -> [DockPill] in
            let path = item.path
            let shortcutChar = item.shortcutChar
            let shortcutModifiers = item.shortcutModifiers
            let menuAppPath = appPath
            if !item.children.isEmpty {
                return makeSubmenuChildDockPills(
                    parent: item,
                    idPrefix: "cached-all-menu-\(bundleIdentifier)-\(path.joined(separator: ">"))",
                    sourceBundleId: bundleIdentifier,
                    sourceAppName: appName,
                    trackingPrefix: "cached-submenu:\(bundleIdentifier)",
                    searchTerms: [appName],
                    executeChild: { child in
                        executeCachedMenuAction(
                            bundleIdentifier: bundleIdentifier,
                            appName: appName,
                            appPath: menuAppPath,
                            path: child.path,
                            shortcutChar: child.shortcutChar,
                            shortcutModifiers: child.shortcutModifiers
                        )
                    }
                )
            }
            return [makeMenuDockPill(
                id: "cached-all-menu-\(bundleIdentifier)-\(path.joined(separator: ">"))",
                item: item,
                sourceBundleId: bundleIdentifier,
                sourceAppName: appName,
                badge: item.shortcutDisplay,
                trackingIdentifier:
                    "cached-menu:\(bundleIdentifier):\(path.joined(separator: " > ").lowercased())",
                searchTerms: item.path + [appName],
                executeLeaf: {
                    executeCachedMenuAction(
                        bundleIdentifier: bundleIdentifier,
                        appName: appName,
                        appPath: menuAppPath,
                        path: path,
                        shortcutChar: shortcutChar,
                        shortcutModifiers: shortcutModifiers
                    )
                }
            )]
        }
    }

    func cachedScopedMenuItemMatchesQuery(_ item: AXMenuItem, query: String) -> Bool {
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return true }

        let title = normalizedDockPillText(item.title)
        let pathParts = item.path.map(normalizedDockPillText).filter { !$0.isEmpty }
        let menuContext = pathParts.dropLast().last ?? pathParts.first ?? ""
        let corpora = ([title, menuContext] + pathParts).filter { !$0.isEmpty }

        if corpora.contains(normalizedQuery) { return true }
        if title.hasPrefix(normalizedQuery) || menuContext.hasPrefix(normalizedQuery) {
            return true
        }
        if title.contains(normalizedQuery) || menuContext.contains(normalizedQuery) { return true }
        if pathParts.contains(where: {
            $0.hasPrefix(normalizedQuery) || $0.contains(normalizedQuery)
        }) {
            return true
        }

        let queryTokens = Set(dockPillTokens(normalizedQuery))
        guard !queryTokens.isEmpty else { return false }
        let titleTokens = Set(dockPillTokens(title))
        let pathTokens = Set(corpora.flatMap(dockPillTokens))
        let orderedQueryTokens = dockPillTokens(normalizedQuery)
        if orderedQueryTokens.allSatisfy({ qToken in
            qToken.count == 1
                ? titleTokens.contains { $0.hasPrefix(qToken) }
                : pathTokens.contains {
                    $0 == qToken || $0.hasPrefix(qToken) || $0.contains(qToken)
                }
        }) {
            return true
        }
        if !queryTokens.intersection(titleTokens).isEmpty { return true }
        if !queryTokens.intersection(pathTokens).isEmpty { return true }

        for qt in queryTokens where qt.count >= 4 {
            for ct in pathTokens where ct.count >= 4 {
                if pillEditDistance(qt, ct) <= 2 { return true }
            }
        }

        // Raycast-style fuzzy subsequence: query chars appear in order across a menu
        // label or path, spanning word boundaries. Guarded to 3+ chars so short queries
        // stay on the stricter prefix/substring paths above and don't match everything.
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
        if compactQuery.count >= 3 {
            let pathJoined = pathParts.joined(separator: " ")
            for hay in ([title, pathJoined] + corpora)
            where dockPillFuzzySubsequence(normalizedQuery, in: hay) {
                return true
            }
        }
        return false
    }

    func orderedScopedMenuItemsLikeContextDock(
        _ items: [AXMenuItem],
        filterQuery: String,
        limit: Int
    ) -> [AXMenuItem] {
        let normalizedQuery = normalizedDockPillText(filterQuery)
        guard !normalizedQuery.isEmpty else { return Array(items.prefix(limit)) }

        func score(_ item: AXMenuItem) -> Int {
            let title = normalizedDockPillText(item.title)
            let pathParts = item.path.map(normalizedDockPillText).filter { !$0.isEmpty }
            let menuContext = pathParts.dropLast().last ?? pathParts.first ?? ""
            let path = pathParts.joined(separator: " ")
            var score = Int(
                rankedTextMatchScore(
                    query: normalizedQuery,
                    primary: title,
                    contexts: [menuContext, path] + pathParts
                ) ?? 0)

            let queryTokens = Set(dockPillTokens(normalizedQuery))
            let orderedQueryTokens = dockPillTokens(normalizedQuery)
            let titleTokens = Set(dockPillTokens(title))
            let orderedTitleTokens = dockPillTokens(title)
            let contextTokens = Set(dockPillTokens(menuContext))
            let orderedPathTokens = pathParts.flatMap(dockPillTokens)
            let pathTokens = Set(orderedPathTokens)
            if title == normalizedQuery { score += 1_200 }
            if title.hasPrefix(normalizedQuery) { score += 880 }
            if title.contains(normalizedQuery) { score += 720 }
            if pathParts.contains(normalizedQuery) { score += 520 }
            if orderedMenuTokens(orderedQueryTokens, appearIn: orderedTitleTokens) {
                score += 680 + orderedQueryTokens.count * 90
            }
            if orderedMenuTokens(orderedQueryTokens, appearIn: orderedPathTokens) {
                score += 420 + orderedQueryTokens.count * 58
            }
            score += queryTokens.intersection(titleTokens).count * 120
            score += queryTokens.intersection(contextTokens).count * 96
            score += queryTokens.intersection(pathTokens).count * 54
            if orderedQueryTokens.allSatisfy({ qToken in
                qToken.count == 1
                    ? titleTokens.contains { $0.hasPrefix(qToken) }
                    : pathTokens.contains {
                        $0 == qToken || $0.hasPrefix(qToken) || $0.contains(qToken)
                    }
            }) {
                score += 260 + orderedQueryTokens.count * 40
            }

            // Fuzzy-subsequence hits rank below exact/prefix/substring but above nothing,
            // so queries like "what" still surface ordered menu matches.
            let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
            if compactQuery.count >= 3, !title.contains(normalizedQuery) {
                if dockPillFuzzySubsequence(normalizedQuery, in: title) {
                    score += 180
                } else if dockPillFuzzySubsequence(normalizedQuery, in: path)
                    || pathParts.contains(where: {
                        dockPillFuzzySubsequence(normalizedQuery, in: $0)
                    })
                {
                    score += 90
                }
            }

            if !item.isEnabled { score -= 60 }
            if menuContext == "services" || menuContext == "open with" {
                score -= 180
            }
            score -= min(item.path.count, 12)
            return score
        }

        return Array(
            items.sorted {
                let lhsScore = score($0)
                let rhsScore = score($1)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return normalizedDockPillText($0.path.joined(separator: " "))
                    < normalizedDockPillText($1.path.joined(separator: " "))
            }
            .prefix(limit)
        )
    }

    func orderedMenuTokens(_ needles: [String], appearIn haystack: [String]) -> Bool {
        guard !needles.isEmpty, !haystack.isEmpty else { return false }
        var searchStart = haystack.startIndex
        for needle in needles {
            guard let found = haystack[searchStart...].firstIndex(where: {
                $0 == needle || $0.hasPrefix(needle) || $0.contains(needle)
            }) else { return false }
            searchStart = haystack.index(after: found)
        }
        return true
    }

    /// Dock pills for one app's adapter actions.
    ///
    /// Extracted so Global Context's app scope renders the same pills, executed the same
    /// way, as Context Dock. Building a second set for the other surface would have meant
    /// two implementations of "run an adapter action" free to drift apart.
    func adapterActionPills(
        actions: [AdapterAction],
        scopedBundleId: String,
        scopedAppName: String,
        scopedSearchQuery: String
    ) -> [DockPill] {
        var pills: [DockPill] = []
        for action in actions {
            let cliCommand =
                action.cliToolCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pillName =
                action.type == .cliTool && !cliCommand.isEmpty
                ? cliCommand
                : action.name
            let shortcutName = action.shortcutName ?? action.name
            let pillIcon = action.type == .shortcut
                ? ShortcutsCatalog.iconName(for: shortcutName)
                : action.icon
            let pillAccent = action.type == .shortcut
                ? ShortcutsCatalog.accentColorName(for: shortcutName)
                : (action.accentColor ?? "blue")
            var pill = DockPill(
                id: "adapter-\(scopedBundleId)-\(action.id)",
                name: pillName,
                icon: pillIcon,
                accentColorName: pillAccent,
                badge: action.type == .menubar
                    ? "Custom" : (action.type == .cliTool ? "CLI" : action.type.displayName),
                execute: {
                    if action.type == .cliTool, !cliCommand.isEmpty {
                        attachCLIToolToCurrentDock(
                            command: cliCommand,
                            bundleIdentifier: scopedBundleId,
                            appName: scopedAppName
                        )
                        return
                    }
                    let capturedContext = effectiveAXContextForConversation()
                    Task {
                        AppInteractionStore.shared.record(
                            bundleId: scopedBundleId,
                            appName: scopedAppName,
                            query: scopedSearchQuery.isEmpty ? action.name : scopedSearchQuery,
                            kind: action.type == .pageJS ? .pageJS : .adapterAction,
                            actionId: action.id
                        )
                        let result = await adapterManager.execute(
                            action,
                            context: capturedContext,
                            targetBundleId: scopedBundleId,
                            query: scopedSearchQuery
                        )
                        await MainActor.run {
                            if action.type == .aiPrompt, result.0, !result.1.isEmpty {
                                searchState.query = result.1
                                isSearchFieldFocused = true
                            }
                        }
                    }
                })
            pill.rankingKind = action.type == .cliTool ? "cliTool" : "adapter"
            if action.type == .shortcut {
                pill.menuItemImage = nil
            }
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "adapter:\(scopedBundleId):\(action.id)"
            pill.searchTerms =
                [action.name, pillName, action.description, action.type.displayName, cliCommand]
                + action.triggers
            pills.append(pill)

            // For CLI tool adapter actions, also emit subcommand pills so the user
            // gets the same scannable help-command pills as standalone CLI packages.
            if action.type == .cliTool, !cliCommand.isEmpty,
                let pkg = terminalPackageManager.packages.first(where: {
                    $0.command.caseInsensitiveCompare(cliCommand) == .orderedSame
                })
            {
                for sub in pkg.subcommands.prefix(5) {
                    let fullCmd = "\(cliCommand) \(sub)"
                    var subPill = DockPill(
                        id: "adapter-sub-\(scopedBundleId)-\(fullCmd)",
                        name: sub,
                        icon: action.icon,
                        accentColorName: action.accentColor ?? "green",
                        badge: cliCommand,
                        execute: {
                            attachCLIToolToCurrentDock(
                                command: fullCmd,
                                package: pkg,
                                runImmediately: true
                            )
                        }
                    )
                    subPill.rankingKind = "cliTool"
                    subPill.sourceBundleId = scopedBundleId
                    subPill.sourceAppName = scopedAppName
                    subPill.trackingIdentifier = "adapter-sub:\(scopedBundleId):\(fullCmd)"
                    subPill.searchTerms = [sub, fullCmd, action.name, cliCommand] + pkg.keywords
                    pills.append(subPill)
                }
            }
        }
        return pills
    }
    func scopedSpecialAppPills(
        bundleIdentifier: String,
        appName: String,
        query: String
    ) -> [DockPill] {
        if isBrowserMenuSource(bundleIdentifier) {
            return buildBrowserNativeCommandPills(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                query: query
            )
        }
        switch bundleIdentifier {
        case "com.apple.systempreferences":
            return buildSystemSettingsPills(
                query: query,
                scopedBundleId: bundleIdentifier,
                scopedAppName: appName
            )
        default:
            return []
        }
    }

    func buildNativeWritingToolPills(query q: String) -> [DockPill] {
        guard let writingContext = nativeWritingToolContext else { return [] }

        let normalizedQuery = normalizedDockPillText(q)
        let queryMatchesWritingTools =
            normalizedQuery.isEmpty
            || [
                "writing", "writing tools", "apple intelligence", "intelligence",
                "proofread", "rewrite", "friendly", "professional", "concise",
                "summarize", "summary", "key points", "list", "table"
            ].contains { term in
                term.hasPrefix(normalizedQuery) || term.contains(normalizedQuery)
                    || normalizedQuery.contains(term)
            }
        guard queryMatchesWritingTools else { return [] }

        let sourcePID =
            writingContext.pid != 0
            ? writingContext.pid
            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
        guard sourcePID != 0 else { return [] }

        let sourceBundleId =
            writingContext.bundleId.isEmpty ? frontmost.bundleID : writingContext.bundleId
        let sourceAppName =
            writingContext.appName.isEmpty ? frontmost.name : writingContext.appName
        let filteredActions = NativeWritingToolAction.allCases.filter { action in
            guard !normalizedQuery.isEmpty else { return true }
            let searchable = normalizedDockPillText(([action.title] + action.aliases).joined(separator: " "))
            return searchable.contains(normalizedQuery)
                || action.aliases.map(normalizedDockPillText).contains { alias in
                    alias.hasPrefix(normalizedQuery) || normalizedQuery.contains(alias)
                }
        }

        return filteredActions.prefix(normalizedQuery.isEmpty ? 10 : 12).map { action in
            var pill = DockPill(
                id: "writing-tool-\(sourcePID)-\(action.rawValue)",
                name: action.title,
                icon: action.icon,
                accentColorName: "purple",
                badge: "DoraX",
                execute: {
                    executeNativeWritingTool(
                        action,
                        context: writingContext,
                        sourcePID: sourcePID,
                        sourceBundleId: sourceBundleId,
                        sourceAppName: sourceAppName
                    )
                }
            )
            pill.menuItemImage = nil
            pill.menuItemName = action.title
            pill.menuContext = "Writing Tools"
            pill.rankingKind = "writingTool"
            pill.rankingScore = 95_000 - Double(NativeWritingToolAction.allCases.firstIndex(of: action) ?? 0)
            pill.sourceBundleId = sourceBundleId
            pill.sourceAppName = sourceAppName
            pill.isEnabled = true
            pill.hasLiveAvailability = true
            pill.menuStatusBadge = action.requiresSelection ? "Selection" : "Native"
            pill.trackingIdentifier = "writing-tool:\(sourceBundleId):\(action.rawValue)"
            pill.searchTerms = [sourceAppName, "writing tools", "apple intelligence", action.title] + action.aliases
            return pill
        }
    }

    func buildNativeSelectionWritingToolPills(query q: String) -> [DockPill] {
        guard case .text(let selectedText) = activeSelection,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        let writingContext = nativeWritingToolContext
            ?? AXContext(
                appName: AppDelegate.shared?.previousFrontmostApp?.localizedName ?? axContext.appName,
                bundleId: AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier ?? axContext.bundleId,
                pid: AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? axContext.pid,
                selectedText: selectedText,
                currentURL: axContext.currentURL,
                windowTitle: axContext.windowTitle,
                focusedElementRole: axContext.focusedElementRole
            )
        let sourcePID =
            writingContext.pid != 0
            ? writingContext.pid
            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
        guard sourcePID != 0 else { return [] }

        let sourceBundleId = writingContext.bundleId.isEmpty ? frontmost.bundleID : writingContext.bundleId
        let sourceAppName = writingContext.appName.isEmpty ? frontmost.name : writingContext.appName
        let normalizedQuery = normalizedDockPillText(q)
        let filteredActions = NativeWritingToolAction.allCases.filter { action in
            guard !normalizedQuery.isEmpty else { return true }
            let searchable = normalizedDockPillText(([action.title] + action.aliases).joined(separator: " "))
            return searchable.contains(normalizedQuery)
                || action.aliases.map(normalizedDockPillText).contains { alias in
                    alias.hasPrefix(normalizedQuery) || normalizedQuery.contains(alias)
                }
        }

        return filteredActions.prefix(normalizedQuery.isEmpty ? 10 : 12).map { action in
            var pill = DockPill(
                id: "selection-writing-tool-\(sourcePID)-\(action.rawValue)",
                name: action.title,
                icon: action.icon,
                accentColorName: "purple",
                badge: "Selection",
                execute: {
                    executeNativeWritingTool(
                        action,
                        context: writingContext,
                        sourcePID: sourcePID,
                        sourceBundleId: sourceBundleId,
                        sourceAppName: sourceAppName
                    )
                }
            )
            pill.menuContext = "Writing Tools"
            pill.rankingKind = "writingTool"
            pill.rankingScore = 100_000 - Double(NativeWritingToolAction.allCases.firstIndex(of: action) ?? 0)
            pill.sourceBundleId = sourceBundleId
            pill.sourceAppName = sourceAppName
            pill.menuItemName = action.title
            pill.menuStatusBadge = "Native"
            pill.trackingIdentifier = "selection-writing-tool:\(sourceBundleId):\(action.rawValue)"
            pill.searchTerms = [sourceAppName, "selection", "writing tools", "apple intelligence", action.title] + action.aliases
            return pill
        }
    }

    var shouldSurfaceNativeWritingTools: Bool {
        nativeWritingToolContext != nil
    }

    var nativeWritingToolContext: AXContext? {
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        for context in [axContext, AXContextReader.shared.current] {
            guard context.bundleId != ownBundleId else { continue }
            guard context.isInTextField || context.hasSelection || hasSelectionScopeSurface else { continue }
            guard !context.bundleId.isEmpty || context.pid != 0 else { continue }
            return context
        }
        return nil
    }

    func nativeWritingToolQueryMatches(_ query: String) -> Bool {
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return false }
        return NativeWritingToolAction.allCases.contains { action in
            let terms = ([action.title] + action.aliases + ["writing tools", "apple intelligence"])
                .map(normalizedDockPillText)
            return terms.contains { term in
                term == normalizedQuery || term.hasPrefix(normalizedQuery)
                    || term.contains(normalizedQuery) || normalizedQuery.contains(term)
            }
        }
    }

    private func executeNativeWritingTool(
        _ action: NativeWritingToolAction,
        context: AXContext,
        sourcePID: pid_t,
        sourceBundleId: String,
        sourceAppName: String
    ) {
        if action == .show {
            searchState.query = "writing tools"
            return
        }

        let selectedText = nativeWritingToolSelectedText(context: context)
        guard !selectedText.isEmpty else {
            DockActionFeedback.showResult("Select text first", icon: "apple.intelligence", success: false)
            return
        }

        DockActionFeedback.showResult("\(action.title)…", icon: action.icon, success: true)
        Task { @MainActor in
            do {
                let request = AIRequest(
                    text: action.prompt(for: selectedText),
                    context: .textSelected(selectedText),
                    mode: .answer,
                    source: isGlobalContextActive ? .globalContext : .contextDock,
                    liveContext: ContextCollector.shared.snapshot()
                )
                let response = try await AIProviderRouter.shared.send(request)
                let output = cleanedNativeWritingToolOutput(response)
                guard !output.isEmpty else {
                    DockActionFeedback.showResult("No writing result", icon: action.icon, success: false)
                    return
                }
                pasteNativeWritingToolOutput(output, sourcePID: sourcePID)
                DockActionFeedback.showResult("\(action.title) pasted", icon: action.icon, success: true)
            } catch {
                DockActionFeedback.showResult(error.localizedDescription, icon: "exclamationmark.triangle", success: false)
            }
        }
    }

    func nativeWritingToolSelectedText(context: AXContext) -> String {
        let candidates: [String?] = [
            context.selectedText,
            axContext.selectedText,
            AXContextReader.shared.current.selectedText,
            {
                if case .text(let text) = activeSelection { return text }
                return nil
            }(),
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    func cleanedNativeWritingToolOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```text", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    func pasteNativeWritingToolOutput(_ text: String, sourcePID: pid_t) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let targetApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == sourcePID }
            ?? AppDelegate.shared?.previousFrontmostApp
        let targetPID = sourcePID != 0 ? sourcePID : (targetApp?.processIdentifier ?? 0)
        hideLauncherAfterResultExecution()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            if let targetApp, !targetApp.isTerminated {
                targetApp.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                postNativeWritingToolPasteShortcut(to: targetPID)
            }
        }
    }

    func postNativeWritingToolPasteShortcut(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode: CGKeyCode = 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        if pid > 0 {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    func nativeWritingToolMenuItems(sourcePID: pid_t, sourceAppName: String) -> [AXMenuItem] {
        var candidates: [AXMenuItem] = []

        func appendFlattened(_ items: [AXMenuItem]) {
            for item in items {
                candidates.append(item)
                if !item.children.isEmpty {
                    appendFlattened(item.children)
                }
            }
        }

        appendFlattened(liveMenuItems)

        let axInfoItems = AXContextReader.shared.current.menuItems.compactMap { info -> AXMenuItem? in
            let path = info.fullPath
                .components(separatedBy: " > ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let title = path.last, !title.isEmpty else { return nil }
            return AXMenuItem(
                title: title,
                path: path,
                isEnabled: info.enabled,
                element: AXUIElementCreateApplication(sourcePID),
                children: [],
                sourcePID: sourcePID,
                sourceAppName: sourceAppName,
                isAppleMenu: path.first == "Apple",
                hasLiveAvailability: true,
                shortcutChar: nil,
                shortcutModifiers: 0
            )
        }
        appendFlattened(axInfoItems)

        var seen = Set<String>()
        let filtered = candidates.filter { item in
            guard isNativeWritingToolMenuItem(item) else { return false }
            let key = item.path.joined(separator: " > ").lowercased()
            guard seen.insert(key).inserted else { return false }
            return true
        }
        return orderNativeWritingToolItems(filtered)
    }

    func fallbackNativeWritingToolMenuItems(
        sourcePID: pid_t,
        sourceAppName: String
    ) -> [AXMenuItem] {
        let fallbackTitles = [
            "Show Writing Tools",
            "Proofread",
            "Rewrite",
            "Make Friendly",
            "Make Professional",
            "Make Concise",
            "Summarize",
            "Create Key Points",
            "Make List",
            "Make Table"
        ]
        return fallbackTitles.map { title in
            AXMenuItem(
                title: title,
                path: ["Edit", "Writing Tools", title],
                isEnabled: true,
                element: AXUIElementCreateApplication(sourcePID),
                children: [],
                sourcePID: sourcePID,
                sourceAppName: sourceAppName,
                isAppleMenu: false,
                hasLiveAvailability: false,
                shortcutChar: nil,
                shortcutModifiers: 0
            )
        }
    }

    func isNativeWritingToolMenuItem(_ item: AXMenuItem) -> Bool {
        guard item.children.isEmpty else { return false }
        let normalizedTitle = normalizedDockPillText(item.title)
        let normalizedPath = item.path.map(normalizedDockPillText)
        guard normalizedPath.contains("writing tools") else { return false }
        let blockedTitles: Set<String> = ["writing tools", "learn more"]
        guard !blockedTitles.contains(normalizedTitle) else { return false }
        return true
    }

    func orderNativeWritingToolItems(_ items: [AXMenuItem]) -> [AXMenuItem] {
        let preferred = [
            "show writing tools": 0,
            "proofread": 1,
            "rewrite": 2,
            "make friendly": 3,
            "make professional": 4,
            "make concise": 5,
            "summarize": 6,
            "summary": 6,
            "create key points": 7,
            "key points": 7,
            "make list": 8,
            "list": 8,
            "make table": 9,
            "table": 9
        ]
        return items.sorted { lhs, rhs in
            let lhsRank = preferred[normalizedDockPillText(lhs.title)] ?? 100
            let rhsRank = preferred[normalizedDockPillText(rhs.title)] ?? 100
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func buildBrowserNativeCommandPills(
        bundleIdentifier: String,
        appName: String,
        query: String
    ) -> [DockPill] {
        let commands = BrowserNativeCommandService.shared.matchingCommands(for: query)
        guard !commands.isEmpty else { return [] }

        let appIcon = resolvedApplicationIcon(bundleIdentifier: bundleIdentifier, appName: appName)
        return commands.map { command in
            var pill = DockPill(
                id: "browser-native-command:\(bundleIdentifier):\(command.rawValue)",
                name: command.title,
                icon: command.icon,
                accentColorName: "blue",
                badge: appName,
                execute: {
                    Task { @MainActor in
                        BrowserNativeCommandService.shared.execute(
                            command,
                            bundleIdentifier: bundleIdentifier,
                            appName: appName
                        )
                    }
                }
            )
            pill.sourceBundleId = bundleIdentifier
            pill.sourceAppName = appName
            pill.rankingKind = "browserCommand"
            pill.trackingIdentifier = "browser-native-command:\(bundleIdentifier):\(command.rawValue)"
            pill.searchTerms = Array(Set(command.aliases + [
                command.title,
                appName,
                "browser",
                "tab",
                "navigation",
            ]))
            pill.rankingScore = 20_000
            pill.menuItemImage = appIcon
            pill.hasLiveAvailability = true
            pill.menuStatusBadge = "Native"
            pill.keyboardShortcutLabel = command.shortcutLabel
            return pill
        }
    }

    // Warm menu cache for a specific app if it's running but not yet snapshotted.
    // After scraping, updates crossAppMenuItems if that app is the current scope target,
    // then triggers a pill rebuild so results appear without another keystroke.
    func warmMenuCacheIfNeeded(bundleId: String, appName: String, force: Bool = false) {
        guard !bundleId.isEmpty else { return }
        if !force {
            let staleThreshold: TimeInterval = 7 * 24 * 3600
            let age =
                AppMenuCapabilityCache.shared.snapshotAge(bundleIdentifier: bundleId) ?? .infinity
            guard age > staleThreshold else { return }  // fresh snapshot exists — skip
        }
        guard warmingMenuBundleIds.insert(bundleId).inserted else { return }
        guard
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            })
        else {
            warmingMenuBundleIds.remove(bundleId)
            return
        }
        Task.detached(priority: .background) {
            // Defer 2 s so the user finishes typing before we start an AX scan.
            // AX API is globally serialized — an immediate scan blocks main-thread AX reads → input freeze.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else {
                _ = await MainActor.run { self.warmingMenuBundleIds.remove(bundleId) }
                return
            }
            // Skip if another scan already running (avoid concurrent AX contention).
            let isScanningMenus = await MainActor.run { AXMenuReader.shared.isScanningMenus }
            guard !isScanningMenus else {
                _ = await MainActor.run { self.warmingMenuBundleIds.remove(bundleId) }
                return
            }
            let pid = app.processIdentifier
            await MenuWarmCacheService.shared.warm(app: app, force: force)
            var items = await MainActor.run { AXMenuReader.shared.peekCachedAllMenuItems(for: pid) }
            if items.isEmpty {
                items = ContextDockEngine.shared.cachedMenuItems(for: app, maxResults: 120)
            }
            for i in items.indices {
                items[i].sourcePID = pid
                items[i].sourceAppName = app.localizedName ?? appName
            }
            let preparedItems = items
            await MainActor.run {
                if self.l2.targetApp?.bundleId == bundleId {
                    self.crossAppMenuItems = preparedItems
                }
                self.warmingMenuBundleIds.remove(bundleId)
                scheduleDockPillRebuild(
                    query: searchState.query, delayNanoseconds: 0, refreshContext: false)
                refreshVisibleGlobalContextAfterMenuCacheUpdate(bundleIdentifier: bundleId)
            }
        }
    }

    func installedAppActionExtraction(
        query q: String,
        alias: String,
        allowPrefixAlias: Bool = false,
        preserveRemainingQueryTokens: Bool = false
    )
        -> (
            actionQuery: String, aliasAtStart: Bool, aliasTokenCount: Int, usedPrefixAlias: Bool,
            aliasStartIndex: Int, matchedQueryAlias: String
        )?
    {
        let aliasTokens = alias.split(separator: " ").map(String.init)
        let queryTokens = q.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !aliasTokens.isEmpty, queryTokens.count >= aliasTokens.count else { return nil }

        let normalizedQueryTokens = queryTokens.map(normalizedDockPillText)
        let exactRange = firstScopedAliasRange(aliasTokens, in: normalizedQueryTokens)
        let prefixRange =
            allowPrefixAlias
            ? firstScopedAliasRange(
                aliasTokens, in: normalizedQueryTokens, allowPrefixLastToken: true)
            : nil
        guard let range = exactRange ?? prefixRange else { return nil }

        var remaining = queryTokens
        remaining.removeSubrange(range)
        let actionQuery =
            preserveRemainingQueryTokens
            ? remaining.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            : trimScopedAppFillerWords(remaining)
        return (
            actionQuery,
            range.lowerBound == 0,
            aliasTokens.count,
            exactRange == nil,
            range.lowerBound,
            queryTokens[range].joined(separator: " ")
        )
    }

    func resolveDockScope(for query: String) -> DockScopeResolution {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let connectedChatBundleId = l2.chatDraftBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let connectedChatAppName = l2.chatDraftAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasConnectedChatScope =
            (l2.chatArmed || l2.showChatPopover || !l2.chatMessages.isEmpty)
            && l2.targetApp == nil
            && !connectedChatBundleId.isEmpty
            && !connectedChatAppName.isEmpty
            && connectedChatBundleId != Bundle.main.bundleIdentifier
        if hasConnectedChatScope {
            return DockScopeResolution(
                scopedBundleId: connectedChatBundleId,
                scopedAppName: connectedChatAppName,
                scopedSearchQuery: q,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        if shouldUsePureGlobalAppSearch,
            isGlobalContextActive,
            !hasSelectionScopeSurface,
            l2.targetApp == nil,
            let inlineScope = globalInlineAppScope
        {
            return DockScopeResolution(
                scopedBundleId: inlineScope.bundleId,
                scopedAppName: inlineScope.appName,
                scopedSearchQuery: q,
                isExplicitAppScope: true,
                isGlobalScope: false
            )
        }

        let installedScopeMode = contextDockInstalledAppScopeMatching
        let runningOnly = contextDockRunningOnlyAppMatching && !installedScopeMode
        let runningBundleIds = runningOnly ? runningBundleIdsForContextDock() : []
        let explicitAppTarget: L2ExplicitAppTarget? =
            (!isGlobalContextActive || q.isEmpty)
            ? nil
            : L2AppActionRouter.shared.appScopeTarget(for: q).flatMap {
                target -> L2ExplicitAppTarget? in
                if installedScopeMode,
                    implicitContextDockAppScopeBlockedBundleIds.contains(target.bundleId)
                {
                    return nil
                }
                return (!runningOnly || runningBundleIds.contains(target.bundleId)) ? target : nil
            }
        let installedMenuTarget =
            (isGlobalContextActive && explicitAppTarget == nil && l2.targetApp == nil)
            ? installedAppMenuTarget(
                for: q,
                runningOnly: false,
                // Use permissive matching so natural app-scope queries like
                // "safari new tab" route into Safari menu search.
                includeAppsWithoutMenuSnapshot: true,
                allowPrefixAlias: true
            )
            : nil
        let isExplicitAppScope =
            l2.targetApp != nil || explicitAppTarget != nil || installedMenuTarget != nil
        let isGlobalScope = isGlobalContextActive && !isExplicitAppScope

        if isGlobalScope {
            return DockScopeResolution(
                scopedBundleId: "",
                scopedAppName: "Global Context",
                scopedSearchQuery: q,
                isExplicitAppScope: false,
                isGlobalScope: true
            )
        }

        let scopedBundleId =
            l2.targetApp?.bundleId
            ?? explicitAppTarget?.bundleId
            ?? installedMenuTarget?.bundleId
            ?? (frontmost.bundleID.isEmpty ? axContext.bundleId : frontmost.bundleID)
        let scopedAppName =
            l2.targetApp?.name
            ?? explicitAppTarget?.appName
            ?? installedMenuTarget?.appName
            ?? contextTargetApp()?.localizedName
            ?? axContext.appName
        let scopedSearchQuery: String = {
            if let actionQuery = explicitAppTarget?.actionQuery ?? installedMenuTarget?.actionQuery
            {
                return actionQuery
            }
            // In explicit app scope (l2.targetApp set), strip trailing "in [appname]" or
            // "[appname]" from the query so "new tab in safari" → filterQ "new tab".
            if let pinnedTarget = l2.targetApp {
                let appLower = pinnedTarget.name.lowercased()
                for suffix in [" in \(appLower)", " \(appLower)"] {
                    if q.hasSuffix(suffix) {
                        return String(q.dropLast(suffix.count))
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return q
        }()

        return DockScopeResolution(
            scopedBundleId: scopedBundleId,
            scopedAppName: scopedAppName,
            scopedSearchQuery: scopedSearchQuery,
            isExplicitAppScope: isExplicitAppScope,
            isGlobalScope: false
        )
    }

    func isPureScopedAppSelection(for query: String) -> Bool {
        let scope = resolveDockScope(for: query)
        return scope.isExplicitAppScope
            && scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var dockScopeDisplayName: String {
        let scope = resolveDockScope(for: searchState.query)
        if scope.isGlobalScope {
            return "Global Context"
        }
        if scope.isExplicitAppScope {
            let scoped = scope.scopedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return frontmost.name
    }

    var dockHeaderDisplayName: String {
        let label = dockScopeDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Context" : label
    }

    /// Ghost/input title for a dock pill. Finder folder/file pills carry the absolute
    /// path as their name; show only the last path component (the file/folder name).
    func inputGhostPillTitle(_ pill: DockPill) -> String {
        let raw = pill.name
        guard raw.contains("/") else { return raw }
        let expanded = (raw as NSString).expandingTildeInPath
        let component = URL(fileURLWithPath: expanded).lastPathComponent
        return component.isEmpty ? raw : component
    }

    func inputFieldDisplayTitle(for result: SearchResult) -> String {
        switch result.type {
        case .file, .folder, .document, .photo:
            let rawPath = (result.filePath ?? result.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = URL(fileURLWithPath: rawPath).lastPathComponent
            return fileName.isEmpty ? result.title : fileName
        default:
            return result.title
        }
    }

    var finderDesktopSearchScopeLabel: String {
        let directories = settings.searchDirectories.filter {
            !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !directories.isEmpty else { return "home folder" }

        let labels = directories.prefix(2).map { directory in
            let displayName = directory.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty { return displayName }

            let pathName = URL(fileURLWithPath: directory.path).lastPathComponent
            return pathName.isEmpty ? finderDisplayPath(directory.path) : pathName
        }

        if directories.count > 2 {
            return "\(labels.joined(separator: ", ")) +\(directories.count - 2) more"
        }
        return labels.joined(separator: ", ")
    }

    var dockScopeGhostPrompt: String {
        let label = dockScopeDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeName = label.isEmpty ? "Context" : label
        let bundleId = resolveDockScope(for: searchState.query).scopedBundleId
        let lowerName = scopeName.lowercased()

        let hints: String
        if bundleId == "com.apple.finder" || lowerName == "finder" {
            if !attachedFinderFolderSearchPath.isEmpty {
                hints = "search this folder, open files, menu cmds"
            } else if isFinderDesktopOnlyMode {
                // No Finder window — desktop file search over the user's folders.
                hints = "search files and folders in \(finderDesktopSearchScopeLabel)"
            } else {
                // Finder window present — live menus/actions like any app; → for current folder.
                hints = "search menus, actions, → current folder"
            }
        } else if AXWebReader.shared.isBrowser(bundleId: bundleId) {
            hints = "tabs, page cmds, menu cmds"
        } else if bundleId == "com.microsoft.VSCode" || lowerName.contains("code") {
            hints = "run tasks, commands, menu cmds"
        } else if bundleId == "com.apple.mail" || lowerName.contains("mail") {
            hints = "mailboxes, compose, search, menu cmds"
        } else if bundleId == "com.apple.MobileSMS" || lowerName.contains("message") {
            hints = "send, search chats, menu cmds"
        } else if bundleId.hasPrefix("cli://") {
            hints = "run commands, inspect help"
        } else {
            let scopedAppKey =
                settings.appKey(forBundleID: bundleId, appName: scopeName)
                ?? settings.autoDetectedAppKey
                ?? ""
            let hasShortcuts =
                !settings.contextDockShortcuts(for: scopedAppKey).isEmpty
                || !settings.shortcuts(for: scopedAppKey).isEmpty
            let hasAdapters = !bundleId.isEmpty && !adapterManager.actions(for: bundleId).isEmpty
            var parts = [String]()
            if hasShortcuts || hasAdapters { parts.append("app actions") }
            parts.append("menu cmds")
            hints = parts.joined(separator: ", ")
        }

        let selectionStatus: String = {
            guard !isGlobalContextActive, case .text(let text) = activeSelection else { return "" }
            return " · Selected text · \(text.count) chars"
        }()
        return "\(scopeName) — \(hints)\(selectionStatus)"
    }

    func finderDisplayPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func scopedDockWorkspaceKey(bundleIdentifier: String, appName: String) -> String {
        if let mapped = settings.appKey(forBundleID: bundleIdentifier, appName: appName),
            !mapped.isEmpty
        {
            return mapped
        }
        let normalized =
            appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .components(
                separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                    .inverted
            )
            .joined()
        return normalized.isEmpty ? bundleIdentifier : normalized
    }

    var currentL2DockSessionKey: String? {
        guard showContextInDock else { return nil }
        let scope = resolveDockScope(for: searchState.query)
        if scope.isGlobalScope {
            return "dock_global"
        }
        let scopedBundleId = scope.scopedBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scopedBundleId.isEmpty {
            return "dock_app_\(scopedBundleId)"
        }
        let appName = scope.scopedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { return nil }
        return "dock_app_\(scopedDockWorkspaceKey(bundleIdentifier: appName, appName: appName))"
    }

    func syncL2DockSession(force: Bool = false) {
        let newKey = currentL2DockSessionKey
        let keyChanged = newKey != l2.activeDockSessionKey
        guard force || keyChanged else { return }

        // Same session re-synced (force from window open / layer toggle): keep the
        // in-memory conversation AND the in-flight request. Cancelling here killed
        // a loading answer every time the launcher was hidden and reopened.
        guard keyChanged else {
            updateL2Results([])
            return
        }

        if let previousKey = l2.activeDockSessionKey {
            AppPanelChatStore.shared.saveSession(l2.chatMessages, for: previousKey)
        }

        l2.activeDockSessionKey = newKey
        l2.currentTask?.cancel()
        l2.currentTask = nil
        l2.isLoading = false
        l2.activeRequestID = nil
        l2.handledApprovalIds = []
        l2.contextExtensions = []
        l2.lastAutoRunExtensionID = nil
        // Entering a scope starts a session: the sheet shows this visit, the chat window
        // keeps the whole conversation. Exiting a scope without clearing therefore loses
        // nothing — it just ends the span the dock is showing.
        if let newKey {
            AppPanelChatStore.shared.beginSession(for: newKey)
        }
        l2.chatMessages = newKey.map { AppPanelChatStore.shared.loadSession(for: $0) } ?? []
        updateL2Results([])
    }

    @discardableResult
    func activateInlineDockAppScope(
        bundleIdentifier: String,
        appName: String,
        queryOverride: String? = nil,
        expand: Bool = true,
        preserveGlobalContext: Bool = false
    ) -> Bool {
        guard !bundleIdentifier.isEmpty, !appName.isEmpty else { return false }
        let isCLIToolScope = bundleIdentifier.hasPrefix("cli://")

        // Entering a CLI tool's scope: make sure its `--help` reference is scanned. A newly
        // pinned binary is registered without a blocking scan (helpText empty), which left the
        // chat model blind — it hallucinated generic scripts instead of using the real tool.
        // Deduped + no-ops when help is already present, so this is cheap on every entry.
        if isCLIToolScope {
            let cliCommand = String(bundleIdentifier.dropFirst("cli://".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cliCommand.isEmpty {
                TerminalPackageManager.shared.ensureHelpScanned(command: cliCommand)
            }
        }

        let targetApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        })
        let appURL = applicationURL(bundleIdentifier: bundleIdentifier, appName: appName)
        let appPath = appURL?.path ?? ""
        let icon =
            isCLIToolScope
            ? NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "CLI Tool")
            : !appPath.isEmpty
            ? NSWorkspace.shared.icon(forFile: appPath)
            : (resolvedApplicationIcon(bundleIdentifier: bundleIdentifier, appName: appName)
                ?? preparedDockIcon(targetApp?.icon))
        let hasLegacyPanelState =
            searchState.activeSmartQueryKey != nil
            || searchState.contextApp != nil
            || searchState.isInSmartMode
            || !searchState.appPanelAllItems.isEmpty
            || !remPanelChatMessages.isEmpty
        let isNewScope = l2.targetApp?.bundleId != bundleIdentifier
        let shouldSyncSession =
            isNewScope
            || searchState.activeSmartQueryKey != nil
            || searchState.contextApp != nil
        // Reset terminal dismissal when switching to a different app scope
        if isNewScope { l2.terminalDismissed = false }
        if let previousKey = searchState.activeSmartQueryKey, hasLegacyPanelState {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: previousKey)
        }

        if hasLegacyPanelState {
            remPanelAITask?.cancel()
            remPanelIsProcessing = false
        }

        withAnimation(.dockStandard) {
            if hasLegacyPanelState {
                searchState.contextApp = nil
                searchState.activeSmartQueryKey = nil
                searchState.isInSmartMode = false
                searchState.appPanelAllItems = []
                remPanelChatMessages = []
                clearPinnedResults()
            }
            l2.targetApp = ScopedApp(name: appName, bundleId: bundleIdentifier, icon: icon)
            showContextInDock = true
            showMediaLayer = false
            aiMode.isActive = false
            if !preserveGlobalContext {
                globalContextActivation = nil
            }
            searchState.results = []
            searchState.selectedIndex = nil
            if expand { isSearchBarExpanded = true }
            if expand {
                if livePanelMode != .terminal { livePanelVisible = false }
            }
            if let queryOverride {
                searchState.query = queryOverride
            }
        }

        if let queryOverride, queryOverride.isEmpty {
            // NSTextField owns a separate field editor while focused. Updating only the
            // SwiftUI binding during a scope transition can leave its old app-name string
            // alive; later sheet rebuilds then push that stale text back onscreen.
            queryChangeGeneration &+= 1
            queryChangeTask?.cancel()
            queryChangeTask = nil
            l2.appCompletion = nil
            clearSearchFieldEditorText()
        }

        if isCLIToolScope {
            crossAppMenuTargetPID = 0
            crossAppMenuNeedsLiveLoad = false
            crossAppMenuItems = []
            // CLI scopes are chat scopes, not app/global search scopes. Keeping both
            // l2.targetApp and globalInlineAppScope made the dock render duplicate
            // capsules and allowed global/app result matching to compete with the
            // scoped CLI conversation. l2.targetApp is the single owner until exit.
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            globalContextActivation = nil
            armGlobalScopedChat(appName: appName, bundleId: bundleIdentifier)
        } else if let targetApp {
            // Force a fresh menu load for the newly scoped app (don't reuse a stale/empty
            // target) so its menus actually populate in Global Context scope.
            DispatchQueue.main.async {
                self.crossAppMenuNeedsLiveLoad = true
                self.seedCrossAppMenuCache(for: targetApp)
                self.loadCrossAppMenu(for: targetApp)
            }
        } else {
            // App not running — load from persistent disk cache so command palette still works.
            // Actions route via executeCachedMenuAction (no live PID needed).
            let cached = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                processIdentifier: 0,
                query: "",
                maxResults: 120
            )
            DispatchQueue.main.async {
                self.crossAppMenuTargetPID = 0
                self.crossAppMenuNeedsLiveLoad = false
                self.crossAppMenuItems = cached
            }
        }

        if shouldSyncSession {
            syncL2DockSession(force: true)
        }

        // Pre-warm the scoped terminal PTY so it's ready when a command needs to run.
        // Do NOT open or show the terminal here — it only appears after the user approves a command.
        let hasAnyCLI =
            !terminalPackageManager.packages(
                forContextBundleId: bundleIdentifier, query: "", maxResults: 1
            ).isEmpty
            || adapterManager.actions(for: bundleIdentifier)
                .contains {
                    $0.type == .cliTool
                        && !($0.cliToolCommand ?? "").trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                }
        if hasAnyCLI && !isCLIToolScope {
            _ = prepareScopedWorkspaceTerminal()
        }

        l2.focusedPillIndex = nil
        isSearchFieldFocused = true
        // SwiftUI may defer focus assignment during the spring animation above.
        // Two deferred dispatches guarantee the field receives first-responder
        // status after the current run-loop turn and the next render pass.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                self.isSearchFieldFocused = false
                self.isSearchFieldFocused = true
            }
        }
        return true
    }

    func activateClipboardScope(queryOverride: String = "") {
        // Compact scope is up — keep the launcher visible when another app takes focus.
        AppDelegate.shared?.smartScopeActive = true
        if let previousKey = searchState.activeSmartQueryKey {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: previousKey)
        }
        remPanelAITask?.cancel()
        remPanelIsProcessing = false
        clearClipboardSelection()
        focusedClipboardEntryIndex = nil
        clipboardSourcePillFocusIndex = nil
        clipboardSourceFilterBundleId = ""
        clipboardSourceFilterName = ""

        withAnimation(.dockStandard) {
            searchState.contextApp = nil
            searchState.activeSmartQueryKey = "clipboard"
            l2.targetApp = nil
            showContextInDock = true
            showMediaLayer = false
            aiMode.isActive = false
            globalContextActivation = nil
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            suppressGlobalInlineAppScopeDetection = false
            dismissedGlobalInlineAppScopes = [:]
            searchState.isInSmartMode = false
            searchState.results = []
            searchState.grouped = GroupedResults()
            searchState.selectedIndex = nil
            clearPinnedResults()
            searchState.appPanelAllItems = []
            remPanelChatMessages = []
            searchState.query = queryOverride
            isSearchBarExpanded = true
            focusedClipboardEntryIndex = nil
            livePanelVisible = false
        }
        l2.focusedPillIndex = nil
        isSearchFieldFocused = true
        _ = importCurrentPasteboardToClipboardHistory()
        refreshCompactScopeResults()
        let q = queryOverride.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        scheduleDockPillRebuild(query: q, delayNanoseconds: 0, refreshContext: false)
        requestWindowSizeUpdate(reason: .panelChanged)
        reclaimCompactScopeInputFocus()
    }

    func activateNotificationScope(queryOverride: String = "") {
        // Compact scope is up — keep the launcher visible when another app takes focus.
        AppDelegate.shared?.smartScopeActive = true
        if let previousKey = searchState.activeSmartQueryKey {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: previousKey)
        }
        remPanelAITask?.cancel()
        remPanelIsProcessing = false

        withAnimation(.dockStandard) {
            searchState.contextApp = nil
            searchState.activeSmartQueryKey = "notifications"
            l2.targetApp = nil
            showContextInDock = true
            showMediaLayer = false
            aiMode.isActive = false
            globalContextActivation = nil
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            suppressGlobalInlineAppScopeDetection = false
            dismissedGlobalInlineAppScopes = [:]
            searchState.isInSmartMode = false
            searchState.results = []
            searchState.grouped = GroupedResults()
            searchState.selectedIndex = nil
            clearPinnedResults()
            searchState.appPanelAllItems = []
            remPanelChatMessages = []
            searchState.query = queryOverride
            isSearchBarExpanded = true
            livePanelVisible = false
        }
        l2.focusedPillIndex = nil
        isSearchFieldFocused = true
        refreshCompactScopeResults()
        scheduleDockPillRebuild(query: queryOverride, delayNanoseconds: 0, refreshContext: false)
        requestWindowSizeUpdate(reason: .panelChanged)
        reclaimCompactScopeInputFocus()
    }

    func reclaimCompactScopeInputFocus() {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                self.reclaimSearchInputFocus()
            }
        }
    }

    func scopedWorkspaceIdentity() -> (
        appName: String, bundleId: String, axContext: AXContext
    )? {
        if let target = l2.targetApp, !target.bundleId.isEmpty,
            !target.bundleId.hasPrefix("scope://")
        {
            return (
                target.name,
                target.bundleId,
                scopedWorkspaceAXContext(appName: target.name, bundleId: target.bundleId)
            )
        }

        if let scope = globalInlineAppScope, !scope.bundleId.isEmpty {
            return (
                scope.appName,
                scope.bundleId,
                scopedWorkspaceAXContext(appName: scope.appName, bundleId: scope.bundleId)
            )
        }

        if let ctx = searchState.contextApp {
            let bundleIdFromPath =
                ctx.appPath.isEmpty ? nil : Bundle(path: ctx.appPath)?.bundleIdentifier
            let bundleIdFromRunningApp = NSWorkspace.shared.runningApplications.first(where: {
                !$0.isTerminated && $0.localizedName == ctx.name
            })?.bundleIdentifier
            let resolvedBundleId = bundleIdFromPath ?? bundleIdFromRunningApp ?? ""
            if !resolvedBundleId.isEmpty {
                return (
                    ctx.name,
                    resolvedBundleId,
                    scopedWorkspaceAXContext(appName: ctx.name, bundleId: resolvedBundleId)
                )
            }
        }

        let meta = smartQueryMeta
        if !meta.appPath.isEmpty, let bundleId = Bundle(path: meta.appPath)?.bundleIdentifier {
            return (
                searchState.contextApp?.name ?? meta.label,
                bundleId,
                scopedWorkspaceAXContext(
                    appName: searchState.contextApp?.name ?? meta.label,
                    bundleId: bundleId
                )
            )
        }

        let fallbackBundleId =
            frontmost.bundleID.isEmpty ? axContext.bundleId : frontmost.bundleID
        let fallbackAppName =
            searchState.contextApp?.name
            ?? (frontmost.name.isEmpty ? axContext.appName : frontmost.name)
        guard !fallbackBundleId.isEmpty, !fallbackAppName.isEmpty else { return nil }
        return (
            fallbackAppName,
            fallbackBundleId,
            scopedWorkspaceAXContext(appName: fallbackAppName, bundleId: fallbackBundleId)
        )
    }

    func scopedWorkspaceAXContext(appName: String, bundleId: String) -> AXContext {
        if axContext.bundleId == bundleId {
            return effectiveAXContextForConversation()
        }

        let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId && !$0.isTerminated
        })

        return AXContext(
            appName: appName,
            bundleId: bundleId,
            pid: runningApp?.processIdentifier ?? 0,
            selectedText: nil,
            currentURL: nil,
            windowTitle: nil,
            focusedElementRole: nil,
            selectedFilePaths: effectiveSelectedFileURLsForConversation().map(\.path),
            menuItems: []
        )
    }

    func prepareScopedWorkspaceTerminal() -> String {
        let consoleKey = activeConsoleKey
        let terminal = panelTerminal(for: consoleKey)
        TerminalAIBridge.shared.terminalController = terminal
        panelShowConsoleMap[consoleKey] = true
        return consoleKey
    }

    func currentDateTimeContextBlock() -> String {
        AppScopedChatService.dateTimeBlock()
    }

    func executeCachedMenuAction(
        bundleIdentifier: String,
        appName: String,
        appPath: String?,
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int
    ) {
        Task.detached(priority: .userInitiated) {
            if !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
            }) {
                await MainActor.run {
                    AppToast.show(
                        "Opening \(appName)", icon: "app.badge", tint: .blue.opacity(0.85))
                }
            }

            let result = await GlobalContextEngine.shared.verifyAndExecuteCachedMenu(
                GlobalMenuExecutionRequest(
                    bundleIdentifier: bundleIdentifier,
                    appName: appName,
                    appPath: appPath,
                    path: path,
                    shortcutChar: shortcutChar,
                    shortcutModifiers: shortcutModifiers
                )
            )

            let shouldRecordInteraction: Bool = {
                switch result.status {
                case .executed, .executionFallback:
                    return result.liveItem != nil
                case .unavailable, .launchFailed:
                    return false
                }
            }()
            if let liveItem = result.liveItem, shouldRecordInteraction {
                await MainActor.run {
                    AppInteractionStore.shared.record(
                        bundleId: bundleIdentifier,
                        appName: appName,
                        query: liveItem.title,
                        kind: .menuItem,
                        actionId: liveItem.path.joined(separator: " > ")
                    )
                }
            }

            await MainActor.run {
                switch result.status {
                case .executed:
                    break
                case .executionFallback:
                    AppToast.show(
                        result.message, icon: "checkmark.circle", tint: .blue.opacity(0.85))
                case .unavailable, .launchFailed:
                    AppToast.show(
                        result.message,
                        icon: "exclamationmark.triangle",
                        tint: .orange.opacity(0.9)
                    )
                }

                if let app = result.app {
                    self.reloadMenuForApp(app)
                    self.refreshVisibleGlobalContextAfterMenuCacheUpdate(
                        bundleIdentifier: app.bundleIdentifier
                    )
                }
            }
        }
    }

    func seedCrossAppMenuCache(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? ""
        var cachedItems = GlobalContextEngine.shared.cachedMenuItems(for: app, maxResults: 120)
        for index in cachedItems.indices {
            cachedItems[index].sourcePID = pid
            cachedItems[index].sourceAppName = appName
        }

        crossAppMenuTargetPID = pid
        crossAppMenuNeedsLiveLoad = true
        crossAppMenuItems = cachedItems
    }

    /// Load menu items for a target app into crossAppMenuItems from the persistent cache.
    /// Live AX scraping is deferred by warmMenuCacheIfNeeded so typing stays responsive.
    func loadCrossAppMenu(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != 0 else { return }
        guard pid != crossAppMenuTargetPID || crossAppMenuNeedsLiveLoad else { return }
        // Defer state mutations to avoid modifying @State during view update (body evaluation).
        DispatchQueue.main.async {
            crossAppMenuTargetPID = pid
            crossAppMenuNeedsLiveLoad = false
            crossAppMenuTask?.cancel()
            crossAppMenuTask = Task.detached(priority: .userInitiated) {
                let name = app.localizedName ?? ""
                var items = GlobalContextEngine.shared.cachedMenuItems(for: app, maxResults: 120)
                for i in items.indices {
                    items[i].sourcePID = pid
                    items[i].sourceAppName = name
                }
                let preparedItems = items
                await MainActor.run {
                    guard self.crossAppMenuTargetPID == pid else { return }
                    self.crossAppMenuItems = preparedItems
                    // Rebuild the dock so the freshly loaded menus render right away.
                    // Without this, a scoped app with CACHED menus stayed empty until an
                    // unrelated keypress (e.g. Cmd) kicked SwiftUI into rebuilding — the
                    // "running-app scope shows nothing in Global Context" bug.
                    if !preparedItems.isEmpty {
                        self.scheduleDockPillRebuild(
                            query: self.searchState.query, delayNanoseconds: 0,
                            refreshContext: false)
                        self.refreshVisibleGlobalContextAfterMenuCacheUpdate(
                            bundleIdentifier: app.bundleIdentifier ?? "")
                    }
                    // No cached menu for this scoped app → force a live AX scan so its
                    // commands actually appear (otherwise the scoped dock stays empty).
                    self.warmMenuCacheIfNeeded(
                        bundleId: app.bundleIdentifier ?? "", appName: name,
                        force: preparedItems.isEmpty)
                }
            }
        }
    }

    func distributedMenuItems(_ items: [AXMenuItem], limit: Int) -> [AXMenuItem] {
        guard limit > 0, !items.isEmpty else { return [] }

        var buckets: [String: [AXMenuItem]] = [:]
        var rootOrder: [String] = []

        for item in items {
            let root = item.path.first ?? item.title
            if buckets[root] == nil {
                buckets[root] = []
                rootOrder.append(root)
            }
            buckets[root, default: []].append(item)
        }

        for root in rootOrder {
            buckets[root]?.sort {
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        var distributed: [AXMenuItem] = []
        var didAppend = true
        while distributed.count < limit && didAppend {
            didAppend = false
            for root in rootOrder where distributed.count < limit {
                guard var bucket = buckets[root], !bucket.isEmpty else { continue }
                distributed.append(bucket.removeFirst())
                buckets[root] = bucket
                didAppend = true
            }
        }

        return distributed
    }

    func orderedScopedMenuMatches(_ items: [AXMenuItem], filterQuery: String, limit: Int)
        -> [AXMenuItem]
    {
        guard !items.isEmpty else { return [] }
        let normalizedFilter = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedFilter.isEmpty {
            return distributedMenuItems(items, limit: limit)
        }

        return Array(
            items.sorted {
                let aScore =
                    rankedTextMatchScore(
                        query: normalizedFilter,
                        primary: $0.title,
                        contexts: [$0.path.dropLast().last ?? "", $0.path.joined(separator: " ")]
                    ) ?? 0
                let bScore =
                    rankedTextMatchScore(
                        query: normalizedFilter,
                        primary: $1.title,
                        contexts: [$1.path.dropLast().last ?? "", $1.path.joined(separator: " ")]
                    ) ?? 0
                if aScore != bScore { return aScore > bScore }
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
        )
    }

    func scheduleDockPillRebuild(
        query: String,
        delayNanoseconds: UInt64 = 55_000_000,
        refreshContext: Bool = true
    ) {
        if isContextDockChatRoutingLocked {
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            return
        }

        if isFinderDesktopOnlyMode {
            commitFinderDesktopModeSnapshot(query: query, preserveFocus: true)
            return
        }

        // Pure, unscoped Global Context uses the global app-search path. Scoped running
        // apps stay inside Global Context now, and must still build dock/menu pills.
        if isGlobalContextActive,
            !hasSelectionScopeSurface,
            currentGlobalScopedBundleID == nil,
            !showGlobalClipboardPill,
            !isContextDockChatConnected
        {
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            return
        }

        let scheduledQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scheduledTargetPID = contextTargetApp()?.processIdentifier ?? -1
        let scheduledTargetBundleID = contextTargetApp()?.bundleIdentifier ?? ""

        dockPillBuildTask = ContextDockPillCoordinator.schedule(
            input: ContextDockPillCoordinator.Input(
                query: query,
                lastQuery: lastPillQuery,
                delayNanoseconds: delayNanoseconds,
                refreshContext: refreshContext,
                cachedPills: cachedDockPills,
                previewPills: contextDockPreviewPills(for: query),
                // Selection Scope never takes the question-style short-circuit. That path wipes
                // the pill cache before buildDockPills runs, so "what im…" produced no rows at
                // all — including the Ask AI row this scope is supposed to always show.
                isQuestionStyle: isQuestionStyleDockQuery(query) && !hasSelectionScopeSurface
            ),
            viewModel: contextDockViewModel,
            actions: ContextDockPillCoordinator.Actions(
                commitPreview: { commitPendingDockPreviewPills($0) },
                clearCachedPills: { cachedDockPills = [] },
                refreshContext: { refreshFinderSelectionContextFromFinder() },
                buildPills: { buildQuery in
                    return buildDockPills(query: buildQuery)
                },
                canCommit: {
                    let currentQuery = searchState.query
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if !scheduledQuery.isEmpty, currentQuery != scheduledQuery {
                        return false
                    }
                    let currentApp = contextTargetApp()
                    let currentPID = currentApp?.processIdentifier ?? -1
                    let currentBundleID = currentApp?.bundleIdentifier ?? ""
                    return currentPID == scheduledTargetPID
                        && currentBundleID == scheduledTargetBundleID
                },
                replaceCachedPills: { pills, preserveFocus in
                    replaceCachedDockPills(pills, preserveFocus: preserveFocus)
                },
                logPerformance: { started, builtQuery in
                    logDockPerformance(
                        "deferred pill rebuild",
                        started: started,
                        query: builtQuery
                    )
                }
            )
        )
    }

    /// Render identity for flicker-free commits: only swap the published pill
    /// array when something the user can see actually changed.
    func dockPillRenderFingerprint(_ pills: [DockPill]) -> String {
        contextDockViewModel.pillRenderFingerprint(pills)
    }

    /// Commit preview pills without animation, and only when content differs —
    /// unconditional per-keystroke reassignment is what made the dock flicker.
    func commitPendingDockPreviewPills(_ pills: [DockPill]) {
        contextDockViewModel.commitPreviewPills(pills)
    }

    func replaceCachedDockPills(_ pills: [DockPill], preserveFocus: Bool) {
        defer { applyQueuedPillNavigationIfReady() }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let focusedRenderedPillID: String? = {
            guard preserveFocus,
                let focusedIndex = l2.focusedPillIndex,
                usesVerticalListDockLayout
            else { return nil }
            let rendered = renderedOrderDockPills(for: q)
            guard rendered.indices.contains(focusedIndex) else { return nil }
            return rendered[focusedIndex].id
        }()

        contextDockViewModel.replaceCachedPills(
            pills,
            preserveFocus: preserveFocus && focusedRenderedPillID == nil,
            focusedIndex: l2.focusedPillIndex,
            setFocusedIndex: { l2.focusedPillIndex = $0 },
            clearPillKeyboardNavigation: { l2.pillNavViaKeyboard = false }
        )

        // Menu-first contract: cache/live AX results may arrive after no-menu chat was
        // auto-armed. If a real scoped menu now matches, return routing to menu mode.
        if isGlobalScopedNoMenuChatComposerArmed,
            pills.contains(where: { !$0.isSeparator && !isSearchOnlyDockPill($0) })
        {
            l2.chatArmed = false
            l2.chatAutoArmedForNoMenuMatch = false
            l2.chatDismissed = true
            l2.chatDraftAppName = ""
            l2.chatDraftBundleId = ""
        }

        guard preserveFocus, let focusedRenderedPillID else { return }
        let rendered = renderedOrderDockPills(for: q)
        if let newIndex = rendered.firstIndex(where: { $0.id == focusedRenderedPillID && !$0.isSeparator }) {
            l2.focusedPillIndex = newIndex
            return
        }

        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
    }

    /// Replay arrow presses received during preview loading against the final ordered rows.
    func applyQueuedPillNavigationIfReady() {
        guard let generation = contextDockViewModel.queuedPillNavigationGeneration,
            generation == dockPillBuildGeneration
        else { return }

        let delta = contextDockViewModel.queuedPillNavigationDelta
        contextDockViewModel.queuedPillNavigationDelta = 0
        contextDockViewModel.queuedPillNavigationGeneration = nil
        guard delta != 0, usesVerticalListDockLayout else { return }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rendered = renderedOrderDockPills(for: q)
        let selectable = rendered.indices.filter { !rendered[$0].isSeparator }
        guard !selectable.isEmpty else { return }

        let currentPosition: Int = {
            if let focused = l2.focusedPillIndex,
                let position = selectable.firstIndex(of: focused)
            {
                return position
            }
            // While typing, row one is the visual default; the first Down selects row two.
            return q.isEmpty ? -1 : 0
        }()
        let target = min(max(currentPosition + delta, 0), selectable.count - 1)
        l2.pillNavViaKeyboard = true
        l2.focusedPillIndex = selectable[target]
    }

    func logDockPerformance(_ label: String, started: Date, query: String) {
        let elapsedMS = Date().timeIntervalSince(started) * 1000
        guard elapsedMS >= 16 else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        SearchPerformanceLog.shared.record(
            label: label, elapsedMS: elapsedMS,
            query: q, pills: cachedDockPills.count
        )
    }

    /// Build the ordered list of visible pills for the current dock state.
    /// This is the single source of truth for both rendering and keyboard navigation.
    func buildDockPills(query q: String) -> [DockPill] {
        // When a submenu parent is locked, the dropdown handles child display directly —
        // skip all pill logic so no app/file/other pills compete with it.
        if lockedSubmenuParent != nil { return [] }
        if lockedFindToken != nil { return [] }
        // Inline Share Sheet: show ONLY the live native share destinations.
        if inlineShareActive { return buildInlineShareDestinationPills(query: q) }

        // Selection Scope FIRST — dedicated to the selection. Runs before the question-style
        // short-circuit so a question like "what is this about?" still shows Ask AI (the whole
        // point is to ask the AI about the selection). Never empty → stable result sheet.
        if hasSelectionScopeSurface {
            let finderFilePills = buildFinderFilePills(query: q)
            let finderMenuTitleSet = Set(finderFilePills.map { normalizedDockPillText($0.name) })
            let macOSExtensionPills = buildMacOSExtensionActionPills(
                query: q,
                excludingTitles: finderMenuTitleSet
            )
            let extensionTitleSet = finderMenuTitleSet.union(
                macOSExtensionPills.map { normalizedDockPillText($0.name) }
            )
            let finderMenuPills = buildFinderSelectionMenuPills(
                query: q,
                excludingTitles: extensionTitleSet,
                allowedRootNames: ["file", "quick actions", "services", "open with", "tags"]
            )
            var sel: [DockPill] = []
            sel.append(selectionScopeAskAIPill(query: q))
            sel.append(contentsOf: selectionScopeCopyPill(query: q))
            sel.append(contentsOf: buildCustomSelectionExtensionPills(query: q, excludingTitles: extensionTitleSet))
            sel.append(contentsOf: selectionScopeBuiltInWorkflowPills(query: q))
            sel.append(contentsOf: buildContextDockSelectionAIPills(query: q))
            sel.append(contentsOf: finderFilePills)
            sel.append(contentsOf: macOSExtensionPills)
            sel.append(contentsOf: finderMenuPills)
            sel.append(contentsOf: buildGlobalSelectionSharePills(query: q))
            sel.append(contentsOf: buildShareQueryDestinationPills(query: q))
            let rankedSelection = dedupeRankedDockPills(
                rankDockPills(
                    sel,
                    rawQuery: q,
                    rankingQuery: q,
                    scopedBundleId: "com.apple.finder",
                    scopedAppName: "Finder",
                    isExplicitAppScope: false,
                    includeNonMatching: q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            )
            // Ask AI is the floor row of this scope, not a search result: ranking dropped it for
            // any query whose words it doesn't carry ("what", "about this file"), which left an
            // expanded-but-empty sheet. Re-seat it whenever ranking filtered it out.
            if rankedSelection.contains(where: { $0.rankingKind == "selectionAI" }) {
                return rankedSelection
            }
            return [selectionScopeAskAIPill(query: q)] + rankedSelection
        }

        if isQuestionStyleDockQuery(q) { return [] }
        if isContextDockChatRoutingLocked { return [] }

        if searchState.activeSmartQueryKey == "clipboard" {
            return buildClipboardHistoryPills(query: q)
        }

        // AI-found menu action: show as a focused pill instead of in the chat result sheet
        if q.isEmpty, let proposal = pendingAIMenuProposal {
            let path = proposal.path
            let sc = proposal.shortcutChar
            let mod = proposal.shortcutModifiers
            let pid = proposal.sourcePID
            let bId = proposal.sourceBundleId
            let aName = proposal.sourceAppName
            var pill = DockPill(
                id: "ai-proposal-\(proposal.fullPathLabel)",
                name: proposal.title,
                icon: "cursorarrow.click",
                accentColorName: "blue",
                badge: aName.isEmpty ? nil : aName,
                execute: {
                    self.pendingAIMenuProposal = nil
                    self.executeDockMenuAction(
                        sourcePID: pid,
                        // A proposal built from a cached snapshot carries pid 0; the bundle id
                        // is what lets the click launch the app first.
                        launchBundleId: pid == 0 ? bId : nil,
                        path: path,
                        shortcutChar: sc,
                        shortcutModifiers: mod
                    )
                }
            )
            pill.menuItemImage = proposal.menuImage
            pill.menuItemName = proposal.title
            pill.sourceBundleId = bId
            pill.sourceAppName = aName
            pill.rankingKind = "menu"
            return [pill]
        }

        // Generic web search belongs to Global Context. Context Dock stays app-scoped.
        if isGlobalContextActive,
            L2AppActionRouter.shared.appScopeTarget(for: q) == nil,
            let searchTerm = L2AppActionRouter.shared.extractWebSearchQuery(from: q)
        {
            let browserName = L2AppActionRouter.defaultBrowserName()
            var pill = DockPill(
                id: "web-search-\(searchTerm)",
                name: "Search \"\(searchTerm)\" on Web",
                icon: "globe",
                accentColorName: "blue",
                badge: browserName,
                execute: { L2AppActionRouter.openWebSearch(searchTerm) }
            )
            pill.rankingKind = "webSearch"
            pill.searchTerms = [searchTerm, "web", "search", browserName]
            pill.trackingIdentifier = "web-search:\(searchTerm)"
            return [pill]
        }

        var pills: [DockPill] = []
        pills.append(contentsOf: buildGlobalSelectionSharePills(query: q))
        // Typing "share"/"airdrop"/… (in any app that exposes a Share menu) lists the
        // live NSSharingService destinations — every installed share-extension — as
        // pills, executed by object identity. This is DoraX's share source, not AX.
        pills.append(contentsOf: buildShareQueryDestinationPills(query: q))
        pills.append(contentsOf: buildContextDockSelectionAIPills(query: q))
        pills.append(contentsOf: buildNativeWritingToolPills(query: q))
        pills.append(contentsOf: buildMarkItDownPagePills(query: q))
        // Safari page-level command pills (search, click, open) — appear before AX menu items
        pills.append(contentsOf: buildSafariCommandPills(query: q))
        pills.append(contentsOf: buildSafariRecentURLPills(query: q))
        pills.append(contentsOf: buildContextDockApplicationSwitchPills(query: q))
        // System Settings pane deep-links (Wallpaper, Wi-Fi, etc.) — sidebar isn't menu-scanned
        if isGlobalContextActive
            || frontmost.bundleID == "com.apple.systempreferences"
            || axContext.bundleId == "com.apple.systempreferences"
        {
            pills.append(contentsOf: buildSystemSettingsPills(query: q))
        }
        let scope = resolveDockScope(for: q)
        let rawScopedSearchQuery = rawScopedActionQuery(for: q, scope: scope)
        let installedScopeMode = contextDockInstalledAppScopeMatching
        let runningOnly = contextDockRunningOnlyAppMatching && !installedScopeMode
        let runningBundleIds = runningOnly ? runningBundleIdsForContextDock() : []
        let explicitAppTarget: L2ExplicitAppTarget? =
            (!isGlobalContextActive || q.isEmpty)
            ? nil
            : L2AppActionRouter.shared.appScopeTarget(for: q).flatMap {
                target -> L2ExplicitAppTarget? in
                if installedScopeMode,
                    implicitContextDockAppScopeBlockedBundleIds.contains(target.bundleId)
                {
                    return nil
                }
                return (!runningOnly || runningBundleIds.contains(target.bundleId)) ? target : nil
            }
        let inlineInstalledMenuTarget: InstalledAppMenuTarget? =
            (shouldUsePureGlobalAppSearch && isGlobalContextActive && l2.targetApp == nil)
            ? globalInlineAppScope.map {
                InstalledAppMenuTarget(
                    appName: $0.appName,
                    bundleId: $0.bundleId,
                    appPath: $0.appPath,
                    actionQuery: q,
                    matchedAlias: $0.matchedAlias,
                    aliasStartIndex: $0.aliasStartIndex
                )
            }
            : nil
        let installedMenuTarget: InstalledAppMenuTarget? = {
            if let target = inlineInstalledMenuTarget { return target }
            guard isGlobalContextActive, explicitAppTarget == nil, l2.targetApp == nil else {
                return nil
            }
            let target = installedAppMenuTarget(
                for: q,
                runningOnly: false,
                includeAppsWithoutMenuSnapshot: true,
                allowPrefixAlias: true
            )
            // In pure global app search, a bare app name (e.g. "terminal") means "launch this app",
            // not "show all its menus". Empty actionQuery → skip installedMenuTarget so unrelated
            // menus don't flood the results list.
            if shouldUsePureGlobalAppSearch, target?.actionQuery.isEmpty == true { return nil }
            return target
        }()
        let isExplicitAppScope = scope.isExplicitAppScope
        let isGlobalScope = scope.isGlobalScope
        // Allow the Apple menu (About This Mac, System Settings, Sleep, Restart…) but
        // LIVE only — for the frontmost Context Dock, never Global Context. The cache
        // already excludes Apple-menu items (AppMenuCapabilityCache), so these come from
        // the live menu read; Recent Items are filtered out below.
        let allowAppleMenuItems = !isGlobalScope && !isGlobalContextActive
        let scopedBundleId = scope.scopedBundleId
        let scopedAppName = scope.scopedAppName
        let scopedSearchQuery = scope.scopedSearchQuery
        let scopedShareDestinationPills: [DockPill] = {
            guard isExplicitAppScope, !scopedSearchQuery.isEmpty else { return [] }
            return buildShareQueryDestinationPills(query: scopedSearchQuery)
        }()
        let appContentSearchPill: DockPill? = {
            guard !isGlobalContextActive, !isGlobalScope,
                !scopedBundleId.isEmpty, !scopedAppName.isEmpty,
                scopedShareDestinationPills.isEmpty,
                let intent = AppContentSearchRouter.shared.scopedIntent(
                    for: scopedSearchQuery,
                    bundleId: scopedBundleId,
                    appName: scopedAppName
                )
            else { return nil }
            if isBrowserMenuSource(scopedBundleId) {
                return browserContentSearchDockPill(intent)
            }
            return appContentSearchDockPill(intent)
        }()
        // Explicit "Chat with <App>" action so the user can jump into the frontmost-app chat
        // even when menu commands match (auto-arm only fires when NO menu matches).
        let chatWithAppPill: DockPill? = {
            guard !isGlobalContextActive, !isGlobalScope, !isFinderDesktopOnlyMode else {
                return nil
            }
            let bundleId = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
            let appName = scopedAppName.isEmpty ? frontmost.name : scopedAppName
            guard !bundleId.isEmpty, !appName.isEmpty,
                bundleId != Bundle.main.bundleIdentifier
            else { return nil }
            return chatWithFrontmostAppDockPill(
                appName: appName, bundleId: bundleId,
                query: scopedSearchQuery.isEmpty ? q : scopedSearchQuery)
        }()
        let isFinderScopedDock =
            !isGlobalScope
            && (!isExplicitAppScope || scopedBundleId == "com.apple.finder")
            && (scopedBundleId == "com.apple.finder"
                || frontmost.bundleID == "com.apple.finder"
                || axContext.bundleId == "com.apple.finder")
        let finderFolderAttachedForDock =
            isFinderScopedDock
            && finderFolderQueryModeActive
            && isFinderFolderSearchAttached(currentFolderPath: currentFinderFolderPath())
        let rawPayloadActionPills = buildPayloadActionPills(query: q)
        // Desktop-only mode: Finder frontmost, no window open — show regardless of global/scoped
        let rawFinderDesktopOnlyPills: [DockPill] =
            isFinderDesktopOnlyMode
            ? buildFinderDesktopModePills(query: q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            : []
        if isFinderDesktopOnlyMode {
            return rankDockPills(
                rawFinderDesktopOnlyPills,
                rawQuery: q,
                rankingQuery: q,
                scopedBundleId: "com.apple.finder",
                scopedAppName: "Finder",
                isExplicitAppScope: false
            )
        }
        let rawMacOSExtensionActionPills =
            isFinderScopedDock && !finderFolderAttachedForDock && !isFinderDesktopOnlyMode
            ? buildMacOSExtensionActionPills(query: q) : []
        let rawFinderFilePills =
            (isFinderScopedDock && !finderFolderAttachedForDock && !isFinderDesktopOnlyMode
                ? buildFinderFilePills(query: q)
                : [])
            + rawMacOSExtensionActionPills
        // User-added search directories belong only to Finder desktop mode.
        // When a Finder window is frontmost, Context Dock should stay on that
        // window's menus/actions/selection, not global directory search.
        let rawFinderHomeFolderPills: [DockPill] = []
        let finderHomeSearchQuery = (scopedSearchQuery.isEmpty ? q : scopedSearchQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldShowFinderHomeSearchOnly =
            isFinderScopedDock
            && !finderFolderAttachedForDock
            && !finderHomeSearchQuery.isEmpty
            && !rawFinderHomeFolderPills.isEmpty
            && effectiveFinderSelectionURLsForPills().isEmpty
        let rawAttachedFinderFolderPills =
            isFinderScopedDock
            ? buildAttachedFinderFolderPills(
                query: scopedSearchQuery.isEmpty ? q : scopedSearchQuery) : []
        let finderFileTitleSet = Set(rawFinderFilePills.map { normalizedDockPillText($0.name) })
        let rawFinderSelectionMenuPills =
            isFinderScopedDock && !finderFolderAttachedForDock && !isFinderDesktopOnlyMode
            ? buildFinderSelectionMenuPills(
                query: q,
                excludingTitles: finderFileTitleSet,
                allowedRootNames: ["file", "quick actions", "services", "open with", "tags"]
            ) : []
        let filteredFinderSelectionMenuPills = rawFinderSelectionMenuPills
        let payloadActionPills: [DockPill] = {
            guard isExplicitAppScope, !scopedSearchQuery.isEmpty else {
                return rawPayloadActionPills
            }
            let payloadIntentWords = [
                "send", "share", "message", "messages", "imessage", "sms",
                "mail", "email", "note", "notes", "reminder", "remind",
                "download", "downloads",
            ]
            let isPayloadIntent = payloadIntentWords.contains { scopedSearchQuery.contains($0) }
            return isPayloadIntent ? rawPayloadActionPills : []
        }()
        let crossAppPills =
            isGlobalContextActive && !isExplicitAppScope ? buildCrossAppPills(query: q) : []
        let semanticFinderPills: [DockPill] = {
            guard !shouldUseFinderSearchPopover(for: q) else { return [] }
            guard finderFolderAttachedForDock else { return [] }
            guard
                scopedBundleId == "com.apple.finder"
                    || frontmost.bundleID == "com.apple.finder"
                    || axContext.bundleId == "com.apple.finder"
            else { return [] }
            // "+prefix" go-to-folder mode: show path completion pills
            if isFinderGoToMode(query: q) { return finderGoToPills }
            let semanticQuery =
                scopedSearchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let semanticProfile = finderSemanticProfile(for: semanticQuery)
            guard !semanticQuery.isEmpty, finderSemanticQuery == semanticQuery else { return [] }
            guard semanticProfile.explicitLocationPath == nil else { return [] }
            return finderSemanticPills
        }()
        let semanticFinderQuickActionPills: [DockPill] = {
            guard !semanticFinderPills.isEmpty else { return [] }
            let semanticQuery =
                scopedSearchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return makeFinderSemanticQuickActionPills(query: semanticQuery)
        }()
        _ = shouldShowFinderHomeSearchOnly
        if finderFolderAttachedForDock {
            let attachedFolderPills = dedupeDockPillsByTrackingIdentifier(
                rawAttachedFinderFolderPills
                    + semanticFinderPills
                    + semanticFinderQuickActionPills
            )
            return rankDockPills(
                attachedFolderPills,
                rawQuery: q,
                rankingQuery: scopedSearchQuery.isEmpty ? q : scopedSearchQuery,
                scopedBundleId: scopedBundleId,
                scopedAppName: scopedAppName,
                isExplicitAppScope: isExplicitAppScope
            )
        }
        let messagesSemanticIntentPill =
            scopedBundleId == "com.apple.MobileSMS"
            ? makeMessagesSemanticIntentPill(
                fullQuery: q,
                rawScopedQuery: rawScopedSearchQuery,
                scopedBundleId: scopedBundleId,
                scopedAppName: scopedAppName
            )
            : nil
        let mailSemanticSearchPill =
            scopedBundleId == "com.apple.mail"
            ? makeMailSemanticSearchPill(
                fullQuery: q,
                rawScopedQuery: rawScopedSearchQuery,
                scopedBundleId: scopedBundleId,
                scopedAppName: scopedAppName
            )
            : nil
        let nativeWindowManagementPills = makeNativeWindowManagementPills(
            rawScopedQuery: rawScopedSearchQuery,
            scopedBundleId: scopedBundleId,
            scopedAppName: scopedAppName,
            isGlobalScope: isGlobalScope
        )
        let preferNativeWindowManagement = !nativeWindowManagementPills.isEmpty
        let chatGPTNewChatPill = makeChatGPTNewChatPill(
            scopedQuery: scopedSearchQuery,
            scopedBundleId: scopedBundleId,
            scopedAppName: scopedAppName,
            appPath: installedMenuTarget?.appPath
        )
        let hasStrongContextQuery = !payloadActionPills.isEmpty
        let shouldSuppressMenuForContext = finderFolderAttachedForDock
        let activeBundleId = isGlobalScope ? "" : scopedBundleId
        let scopedAppKey =
            isGlobalScope
            ? ""
            : (searchState.activeSmartQueryKey
                ?? settings.appKey(forBundleID: scopedBundleId, appName: scopedAppName)
                ?? settings.autoDetectedAppKey
                ?? "")
        let allQuickActions =
            isGlobalScope
            ? []
            : appScopeShortcuts(
                for: scopedAppKey,
                placements: [.quickActions, .contextDock, .both]
            )
        let userScriptExtensions =
            isGlobalScope || scopedAppKey.isEmpty
            ? [AppToolExtension]()
            : appPillScriptExtensions(for: scopedAppKey, query: scopedSearchQuery)
        let cliPackages: [TerminalPackage] = {
            guard !isGlobalScope, !scopedBundleId.isEmpty else { return [] }
            // For cli:// adapter scopes, directly surface the matching package by command name.
            if scopedBundleId.hasPrefix("cli://") {
                let cmd = String(scopedBundleId.dropFirst("cli://".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let pkg = terminalPackageManager.packages.first(where: {
                    $0.isEnabled && $0.command.caseInsensitiveCompare(cmd) == .orderedSame
                }) {
                    if scopedSearchQuery.isEmpty { return [pkg] }
                    let q2 = scopedSearchQuery.lowercased()
                    let matches =
                        pkg.command.lowercased().contains(q2)
                        || pkg.name.lowercased().contains(q2)
                        || pkg.subcommands.contains { $0.lowercased().hasPrefix(q2) }
                    return matches ? [pkg] : []
                }
                return []
            }
            return terminalPackageManager.packages(
                forContextBundleId: scopedBundleId,
                query: scopedSearchQuery,
                maxResults: q.isEmpty ? 6 : 4
            )
        }()
        let adapterActions =
            isGlobalScope || scopedBundleId.isEmpty
            ? [AdapterAction]()
            : (q.isEmpty
                ? adapterManager.actions(for: scopedBundleId)
                : adapterManager.actions(for: scopedBundleId, query: scopedSearchQuery))
        let adapterCLICommands = Set<String>(
            adapterActions.compactMap { action in
                guard action.type == .cliTool else { return nil }
                let command =
                    action.cliToolCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return command.isEmpty ? nil : command.lowercased()
            }
        )
        let isCLIChatScope = scopedBundleId.hasPrefix("cli://")
        let shouldExposeCLIPills = isCLIChatScope && scopedSearchQuery.isEmpty
        let visibleCLIPackages = shouldExposeCLIPills
            ? cliPackages.filter { package in
                !adapterCLICommands.contains(package.command.lowercased())
            }
            : []
        // Menu-bar adapter actions duplicate AX menu results and can leak universal Apple-menu
        // rows into Context Dock. AXMenuReader/AppMenuCapabilityCache exclusively own menus.
        let visibleAdapterActions = adapterActions.filter {
            $0.type != .menubar && (shouldExposeCLIPills || $0.type != .cliTool)
        }
        let allAppTools = {
            guard !isGlobalScope else { return [L2Extension]() }
            guard !scopedAppName.isEmpty || !scopedBundleId.isEmpty else {
                return frontmostAppL2Extensions
            }
            return l2Extensions(forAppName: scopedAppName, bundleID: scopedBundleId)
        }()
        let allCtxExts =
            isExplicitAppScope
            ? scopedContextExtensions(
                query: scopedSearchQuery, appName: scopedAppName, bundleId: scopedBundleId)
            : l2.contextExtensions
        let quickActions =
            q.isEmpty
            ? allQuickActions
            : allQuickActions.filter { $0.name.lowercased().contains(scopedSearchQuery) }
        let appTools =
            q.isEmpty
            ? allAppTools
            : allAppTools.filter {
                $0.displayName.lowercased().contains(scopedSearchQuery)
                    || $0.toolName.lowercased().contains(scopedSearchQuery)
            }
        let ctxExts =
            q.isEmpty
            ? allCtxExts
            : allCtxExts.filter { $0.ilExtension.name.lowercased().contains(scopedSearchQuery) }
        let scopedAppLaunchPill: DockPill? = {
            // No "Open" pill for cli:// adapters — they're not launchable apps
            guard !scopedBundleId.hasPrefix("cli://") else { return nil }
            guard isExplicitAppScope, !q.isEmpty, !scopedBundleId.isEmpty, !scopedAppName.isEmpty,
                scopedSearchQuery.isEmpty
            else { return nil }

            var pill = DockPill(
                id: "launch-\(scopedBundleId)",
                name: "Open \(scopedAppName)",
                icon: "app.badge",
                accentColorName: "blue",
                badge: nil,
                execute: {
                    _ = launchApplication(
                        bundleIdentifier: scopedBundleId,
                        appName: scopedAppName,
                        path: installedMenuTarget?.appPath
                    )
                }
            )
            pill.rankingKind = "appLaunch"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "app-launch:\(scopedBundleId)"
            pill.searchTerms = [scopedAppName, "open", "launch", "app"]
            return pill
        }()

        let favs = settings.favouriteMenuPills(for: activeBundleId)
        let isScopedToOtherApp =
            isExplicitAppScope && !scopedBundleId.isEmpty && scopedBundleId != frontmost.bundleID
        // Selection Scope (Global Context + active selection) is dedicated to the selection —
        // share + AI actions only. Don't surface the frontmost app's menus there.
        let inSelectionScope = hasSelectionScopeSurface
        let useSeededMenuPills =
            q.isEmpty && !liveMenuItems.isEmpty && !shouldSuppressMenuForContext
            && !isScopedToOtherApp && !inSelectionScope

        if hasSelectionScopeSurface {
            pills.append(contentsOf: crossAppPills)
        }

        if !isFinderDesktopOnlyMode {
            pills.append(contentsOf: nativeWindowManagementPills)
        }

        if useSeededMenuPills && !hasStrongContextQuery && !isFinderDesktopOnlyMode {
            let seedItems = Array(
                liveMenuItems
                    .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .filter { allowAppleMenuItems || !isRejectedTopMenuItem($0, appName: scopedAppName) }
                    .filter(shouldExposeCachedMenuItem)
                    .filter { !shouldSuppressMenuItemForNativeWindowManagement($0) }
                    .prefix(16)
            )

            for item in seedItems {
                let path = item.path
                let sourcePID =
                    item.sourcePID != 0
                    ? item.sourcePID
                    : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                let shortcutChar = item.shortcutChar
                let shortcutMods = item.shortcutModifiers
                // Bare "Share"/"Share…" ONLY — never path.contains("share").
                let isBareShareMenuItem = isShareSheetTitle(item.title)
                let shareItem = item
                var pill = makeMenuDockPill(
                    id: "menu-seed-\(item.id)",
                    item: item,
                    sourceBundleId: activeBundleId,
                    sourceAppName: scopedAppName,
                    badge: item.shortcutDisplay,
                    trackingIdentifier:
                        "menu-seed:\(activeBundleId):\(path.joined(separator: " > ").lowercased())",
                    searchTerms: item.path + [scopedAppName] + (isBareShareMenuItem ? ["share"] : []),
                    executeLeaf: {
                        if isBareShareMenuItem {
                            executeShareAction(item: shareItem)
                            return
                        }
                        guard sourcePID != 0 else { return }
                        self.executeDockMenuAction(
                            sourcePID: sourcePID,
                            path: path,
                            shortcutChar: shortcutChar,
                            shortcutModifiers: shortcutMods
                        )
                    }
                )
                if isBareShareMenuItem {
                    // Show the share glyph, not the resolved document/app icon. Routes
                    // to DoraX's inline share sheet (always works) — drop menu state.
                    pill.icon = "square.and.arrow.up"
                    pill.menuItemImage = nil
                    pill.accentColorName = "blue"
                    pill.isShareAction = true
                    pill.hasLiveAvailability = false
                    pill.menuStatusBadge = nil
                }
                pills.append(pill)
            }
        }

        // Submenu drill-down: when query matches a non-leaf menu item, surface its leaf
        // children as direct-action pills ranked before everything else.
        if let subCtx = submenuGhostContext {
            // A Share parent (File ▸ Share ▸ …) NEVER drills into its AX children — show the
            // live NSSharingService destinations instead (no first-child-opens-AirDrop bug,
            // no AX timing). The app's own Share children are ignored on purpose.
            if isShareSheetTitle(subCtx.parent.title) {
                let shareItems = ShareIntentRouter.shared.shareableItems(
                    for: effectiveAXContextForConversation())
                if !shareItems.isEmpty {
                    return dedupeRankedDockPills(
                        pills + shareDestinationPills(listingItems: shareItems, filter: "")
                    )
                }
            }
            let frontPID = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
            let visibleChildren =
                allowAppleMenuItems
                ? subCtx.children.filter(shouldExposeCachedMenuItem)
                : subCtx.children.filter {
                    !isRejectedTopMenuItem($0, appName: scopedAppName)
                        && shouldExposeCachedMenuItem($0)
                }
            let nativeVisibleChildren = visibleChildren.filter {
                !shouldSuppressMenuItemForNativeWindowManagement($0)
            }
            for child in nativeVisibleChildren {
                let path = child.path
                let pid = child.sourcePID != 0 ? child.sourcePID : frontPID
                let sc = child.shortcutChar
                let mod = child.shortcutModifiers
                // Bare "Share"/"Share…" or a Share child (Mail/AirDrop/Notes) routes
                // through native NSSharingService, not an AX submenu click.
                let isBareShareMenuItem = isShareSheetTitle(child.title)
                let parentIsShare = normalizedDockPillText(subCtx.parent.title).contains("share")
                let shareChild = child
                var pill = DockPill(
                    id: "submenu-child-\(child.id)",
                    name: child.title,
                    icon: isBareShareMenuItem ? "square.and.arrow.up" : menuSymbol(for: child),
                    accentColorName: "blue",
                    badge: subCtx.parent.title,
                    execute: {
                        if isBareShareMenuItem || parentIsShare {
                            executeShareAction(item: shareChild)
                            return
                        }
                        guard pid != 0 else { return }
                        self.executeDockMenuAction(
                            sourcePID: pid, path: path,
                            shortcutChar: sc, shortcutModifiers: mod
                        )
                    }
                )
                // Bare Share gets the glyph; real children keep their destination icon.
                pill.menuItemImage =
                    isBareShareMenuItem
                    ? nil
                    : ((parentIsShare ? shareDestinationIcon(forTitle: child.title) : nil)
                        ?? resolvedMenuIcon(for: child))
                pill.menuItemName = child.title
                pill.menuContext = subCtx.parent.title
                pill.sourceBundleId = activeBundleId
                pill.sourceAppName = scopedAppName
                pill.rankingKind = "submenuChild"
                pill.isShareAction = isBareShareMenuItem || parentIsShare
                pill.isEnabled = true
                pill.rankingScore = 1_000  // pin above everything else
                pills.append(
                    pill.applyingSafariFavicon(
                        safariHistoryBookmarkURL(for: child, sourceBundleId: activeBundleId)))
            }
        }

        if let scopedAppLaunchPill {
            pills.append(scopedAppLaunchPill)
        }

        if let chatWithAppPill {
            pills.append(chatWithAppPill)
        }

        if let messagesSemanticIntentPill {
            pills.append(messagesSemanticIntentPill)
        }

        if let mailSemanticSearchPill {
            pills.append(mailSemanticSearchPill)
        }

        if let chatGPTNewChatPill {
            pills.append(chatGPTNewChatPill)
        }

        pills.append(
            contentsOf: rawFinderFilePills.map { pill in
                var enriched = pill
                if enriched.rankingKind.isEmpty {
                    enriched.rankingKind = "finderSelection"
                }
                enriched.sourceBundleId =
                    enriched.sourceBundleId.isEmpty ? "com.apple.finder" : enriched.sourceBundleId
                enriched.sourceAppName =
                    enriched.sourceAppName.isEmpty ? "Finder" : enriched.sourceAppName
                if enriched.searchTerms.isEmpty {
                    enriched.searchTerms = [enriched.name, enriched.badge ?? "", "finder", "files"]
                }
                if enriched.trackingIdentifier.isEmpty {
                    enriched.trackingIdentifier =
                        "finder-selection:\(normalizedDockPillText(enriched.name))"
                }
                return enriched
            })

        pills.append(contentsOf: filteredFinderSelectionMenuPills)

        pills.append(contentsOf: rawFinderDesktopOnlyPills)

        pills.append(contentsOf: rawFinderHomeFolderPills)

        pills.append(contentsOf: rawAttachedFinderFolderPills)

        pills.append(contentsOf: semanticFinderPills)

        pills.append(contentsOf: semanticFinderQuickActionPills)

        pills.append(contentsOf: scopedShareDestinationPills)

        if !isFinderDesktopOnlyMode {
            pills.append(
                contentsOf: payloadActionPills.map { pill in
                    var enriched = pill
                    if enriched.rankingKind.isEmpty {
                        enriched.rankingKind = "payload"
                    }
                    if enriched.searchTerms.isEmpty {
                        enriched.searchTerms = [enriched.name, enriched.badge ?? ""]
                    }
                    if enriched.trackingIdentifier.isEmpty {
                        enriched.trackingIdentifier = "payload:\(normalizedDockPillText(enriched.name))"
                    }
                    return enriched
                })
        }

        let dedupeMenuItems: ([AXMenuItem]) -> [AXMenuItem] = { items in
            var seen = Set<String>()
            var deduped: [AXMenuItem] = []
            for item in items {
                let key = item.path.joined(separator: " > ").lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                deduped.append(item)
            }
            return deduped
        }

        let persistentMenuMatches: (NSRunningApplication, String, Int) -> [AXMenuItem] = {
            app, query, limit in
            GlobalContextEngine.shared.cachedMenuItems(for: app, query: query, maxResults: limit)
        }
        let persistentClosedAppMatches: (String, String, String, Int) -> [AXMenuItem] = {
            bundleId, appName, query, limit in
            GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleId,
                appName: appName,
                processIdentifier: 0,
                query: query,
                maxResults: limit
            )
        }
        let menuItemsAllowedForCurrentScope: ([AXMenuItem]) -> [AXMenuItem] = { items in
            items.filter { item in
                shouldExposeCachedMenuItem(item)
                    && (allowAppleMenuItems || !isRejectedTopMenuItem(item, appName: scopedAppName))
                    && (!preferNativeWindowManagement
                        || !shouldSuppressMenuItemForNativeWindowManagement(item))
            }
        }
        let menuItemsForGlobalContext: ([AXMenuItem]) -> [AXMenuItem] = { items in
            items.filter { item in
                shouldExposeCachedMenuItem(item)
                    && (allowAppleMenuItems || !isRejectedTopMenuItem(item, appName: scopedAppName))
                    && !self.isGenericAppMenu(item)
                    && (!preferNativeWindowManagement
                        || !shouldSuppressMenuItemForNativeWindowManagement(item))
            }
        }
        let menuItemMatchesQuery: (AXMenuItem, String) -> Bool = { item, query in
            let normalizedQuery = normalizedDockPillText(query)
            guard !normalizedQuery.isEmpty else { return true }
            let corpora = ([item.title] + item.path)
                .map(normalizedDockPillText)
                .filter { !$0.isEmpty }
            if corpora.contains(normalizedQuery) { return true }
            if corpora.contains(where: {
                $0.hasPrefix(normalizedQuery) || $0.contains(normalizedQuery)
            }) {
                return true
            }

            let queryTokens = Set(dockPillTokens(normalizedQuery))
            guard !queryTokens.isEmpty else { return false }
            let corpusTokens = Set(corpora.flatMap(dockPillTokens))
            if !queryTokens.intersection(corpusTokens).isEmpty { return true }

            for qt in queryTokens where qt.count >= 4 {
                for ct in corpusTokens where ct.count >= 4 {
                    if pillEditDistance(qt, ct) <= 2 { return true }
                }
            }
            return false
        }
        let frontmostLiveMenuMatches: (NSRunningApplication, String) -> [AXMenuItem] = {
            app, filterQ in
            let frontPID = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
            guard app.processIdentifier != 0,
                app.processIdentifier == frontPID,
                !liveMenuItems.isEmpty
            else { return [] }
            let filter = isGlobalScope ? menuItemsForGlobalContext : menuItemsAllowedForCurrentScope
            return dedupeMenuItems(
                filter(liveMenuItems.filter { menuItemMatchesQuery($0, filterQ) })
            )
        }
        let pureScopeMenuLimit = 10
        let pureScopeCandidateLimit = 12
        let scopedRunningMenuMatches: (NSRunningApplication, String, Bool) -> [AXMenuItem] = {
            app, filterQ, preferCached in
            let pid = app.processIdentifier
            let liveAuthoritativeMatches = frontmostLiveMenuMatches(app, filterQ)
            if !liveAuthoritativeMatches.isEmpty {
                return orderedScopedMenuMatches(
                    liveAuthoritativeMatches,
                    filterQuery: filterQ,
                    limit: preferCached ? pureScopeMenuLimit : 16
                )
            }
            let cachedMatches = crossAppMenuItems.filter { item in
                item.sourcePID == pid
                    && menuItemMatchesQuery(item, filterQ)
            }
            let persistentMatches = persistentMenuMatches(
                app,
                filterQ,
                preferCached ? pureScopeCandidateLimit : 24
            )
            let filter = isGlobalScope ? menuItemsForGlobalContext : menuItemsAllowedForCurrentScope
            let matches = dedupeMenuItems(
                filter(cachedMatches + persistentMatches)
            )
            if matches.isEmpty,
                app.bundleIdentifier == "com.apple.finder",
                !filterQ.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                var live = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 7)
                for index in live.indices {
                    live[index].sourcePID = pid
                    live[index].sourceAppName = app.localizedName ?? "Finder"
                }
                if !live.isEmpty {
                    AppMenuCapabilityCache.shared.store(items: live, for: app)
                }
                let filter = isGlobalScope ? menuItemsForGlobalContext : menuItemsAllowedForCurrentScope
                let liveMatches = dedupeMenuItems(
                    filter(
                        live.filter { menuItemMatchesQuery($0, filterQ) }
                    )
                )
                return orderedScopedMenuMatches(
                    liveMatches,
                    filterQuery: filterQ,
                    limit: preferCached ? pureScopeMenuLimit : 16
                )
            }
            return orderedScopedMenuMatches(
                matches,
                filterQuery: filterQ,
                limit: preferCached ? pureScopeMenuLimit : 16
            )
        }
        let scopedClosedMenuMatches: (String, String, String, Bool) -> [AXMenuItem] = {
            bundleId, appName, filterQ, preferCached in
            let filter = isGlobalScope ? menuItemsForGlobalContext : menuItemsAllowedForCurrentScope
            let matches = dedupeMenuItems(
                filter(
                    persistentClosedAppMatches(
                        bundleId,
                        appName,
                        filterQ,
                        preferCached ? pureScopeCandidateLimit : 24
                    )
                )
            )
            return orderedScopedMenuMatches(
                matches,
                filterQuery: filterQ,
                limit: preferCached ? pureScopeMenuLimit : 16
            )
        }

        // Live menu items: primary (frontmost app) + optional cross-app when query targets another app
        let menuMatches: [AXMenuItem] = {
            // Desktop-only: no Finder window open — suppress menus, show file search instead
            if isFinderDesktopOnlyMode { return [] }
            if let installedMenuTarget {
                let filterQ = installedMenuTarget.actionQuery
                let preferCached = isExplicitAppScope && filterQ.isEmpty
                let targetApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == installedMenuTarget.bundleId && !$0.isTerminated
                })
                if let targetApp {
                    return scopedRunningMenuMatches(targetApp, filterQ, preferCached)
                }
                return scopedClosedMenuMatches(
                    installedMenuTarget.bundleId,
                    installedMenuTarget.appName,
                    filterQ,
                    preferCached
                )
            }
            if let pinnedTarget = l2.targetApp,
                let targetApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == pinnedTarget.bundleId
                })
            {
                let filterQ = scopedSearchQuery
                return scopedRunningMenuMatches(
                    targetApp,
                    filterQ,
                    isExplicitAppScope && filterQ.isEmpty
                )
            }
            if let pinnedTarget = l2.targetApp {
                let matches = scopedClosedMenuMatches(
                    pinnedTarget.bundleId,
                    pinnedTarget.name,
                    scopedSearchQuery,
                    isExplicitAppScope && scopedSearchQuery.isEmpty
                )
                if !matches.isEmpty {
                    return matches
                }
            }
            if let explicitAppTarget,
                let targetApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == explicitAppTarget.bundleId
                })
            {
                let filterQ = explicitAppTarget.actionQuery
                return scopedRunningMenuMatches(
                    targetApp,
                    filterQ,
                    isExplicitAppScope && filterQ.isEmpty
                )
            }
            if let explicitAppTarget {
                let filterQ = explicitAppTarget.actionQuery
                let matches = scopedClosedMenuMatches(
                    explicitAppTarget.bundleId,
                    explicitAppTarget.appName,
                    filterQ,
                    isExplicitAppScope && filterQ.isEmpty
                )
                if !matches.isEmpty {
                    return matches
                }
            }
            // Check if query starts with a known app name → cross-app mode (requires Cross-App Connect)
            if isGlobalContextActive,
                settings.crossAppPills,
                let (targetApp, actionQuery) = detectCrossAppQuery(q)
            {
                let filterQ = actionQuery.isEmpty ? q : actionQuery
                let candidateLimit = filterQ.isEmpty ? 80 : 24
                let liveAuthoritativeMatches = frontmostLiveMenuMatches(targetApp, filterQ)
                let cachedMatches =
                    liveAuthoritativeMatches.isEmpty
                    ? crossAppMenuItems.filter { item in
                        item.sourcePID == targetApp.processIdentifier
                            && menuItemMatchesQuery(item, filterQ)
                    }
                    : liveAuthoritativeMatches
                let persistentMatches =
                    liveAuthoritativeMatches.isEmpty
                    ? persistentMenuMatches(targetApp, filterQ, candidateLimit)
                    : []
                let matches = dedupeMenuItems(
                    menuItemsAllowedForCurrentScope(
                        cachedMatches + persistentMatches
                    )
                )
                return orderedScopedMenuMatches(matches, filterQuery: filterQ, limit: 16)
            }
            // Default: frontmost app's real menu items first — query-time AX search is primary.
            let cachedMatches = liveMenuItems.filter { item in
                menuItemMatchesQuery(item, q)
            }
            let persistentMatches: [AXMenuItem] = {
                guard cachedMatches.isEmpty else { return [] }
                guard let app = AppDelegate.shared?.previousFrontmostApp else { return [] }
                return persistentMenuMatches(app, q, 24)
            }()
            let matches = dedupeMenuItems(
                menuItemsAllowedForCurrentScope(cachedMatches + persistentMatches)
            )
            return Array(
                matches.sorted {
                    let aFav = favs.contains($0.title) ? 0 : 1
                    let bFav = favs.contains($1.title) ? 0 : 1
                    if aFav != bFav { return aFav < bFav }
                    let aTitle = $0.title.lowercased().hasPrefix(q) ? 0 : 1
                    let bTitle = $1.title.lowercased().hasPrefix(q) ? 0 : 1
                    if aTitle != bTitle { return aTitle < bTitle }
                    return $0.path.count < $1.path.count
                }.prefix(maxListViewDockPills))
        }()

        // Context-reactive pills — menu items that just became enabled after a selection change.
        // Only shown when the user hasn't typed a query (they'd surface via menuMatches otherwise).
        if q.isEmpty && !shouldSuppressMenuForContext && menuMatches.isEmpty
            && !contextMenuPills.isEmpty
        {
            for item in menuItemsAllowedForCurrentScope(contextMenuPills) {
                let path = item.path
                let sourcePID =
                    item.sourcePID != 0
                    ? item.sourcePID
                    : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                let sc = item.shortcutChar
                let mod = item.shortcutModifiers
                let badge: String? =
                    item.shortcutDisplay ?? (path.count >= 2 ? path[path.count - 2] : nil)
                let pill = makeMenuDockPill(
                    id: "ctx-menu-\(item.id)",
                    item: item,
                    sourceBundleId: scopedBundleId,
                    sourceAppName: scopedAppName,
                    accentColorName: "blue",
                    badge: badge,
                    trackingIdentifier:
                        "ctx-menu:\(scopedBundleId):\(path.joined(separator: " > ").lowercased())",
                    searchTerms: item.path + [scopedAppName],
                    executeLeaf: {
                        guard sourcePID != 0 else { return }
                        self.executeDockMenuAction(
                            sourcePID: sourcePID,
                            path: path,
                            shortcutChar: sc,
                            shortcutModifiers: mod
                        )
                    }
                )
                pills.append(pill)
            }
        }

        let visibleMenuMatches: [AXMenuItem] = {
            if shouldSuppressMenuForContext { return [] }
            let base = hasStrongContextQuery ? Array(menuMatches.prefix(6)) : menuMatches
            // A scope chip on screen means the dock belongs to exactly ONE app. When that
            // app has no menu match, the generic branches above fall back to the FRONTMOST
            // app's live menus — a "Caffeine" chip listed Safari's Quit items. Drop any row
            // that didn't come from the scoped app.
            let chip: (bundleId: String, appName: String)? = {
                if let target = l2.targetApp, !target.bundleId.isEmpty {
                    return (target.bundleId, target.name)
                }
                if let inline = globalInlineAppScope, !inline.bundleId.isEmpty {
                    return (inline.bundleId, inline.appName)
                }
                if isExplicitAppScope, !scopedBundleId.isEmpty {
                    return (scopedBundleId, scopedAppName)
                }
                return nil
            }()
            guard let chip, !chip.bundleId.hasPrefix("cli://"),
                chip.bundleId != frontmost.bundleID
            else { return base }
            let chipPID = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == chip.bundleId && !$0.isTerminated
            }?.processIdentifier
            return base.filter { item in
                if item.sourcePID != 0 {
                    // Cached rows for a closed app carry pid 0 — only live rows are checked.
                    return item.sourcePID == chipPID
                }
                if !item.sourceAppName.isEmpty {
                    return item.sourceAppName.caseInsensitiveCompare(chip.appName)
                        == .orderedSame
                }
                return true
            }
        }()

        // Always offer "Search <App> for <query>" while typing in a scoped app — not
        // only when no menu item matched — so the user can always send the query to the
        // app's own search.
        if let appContentSearchPill,
            !scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            pills.append(appContentSearchPill)
        }

        if !isFinderDesktopOnlyMode {
        for pill in scopedSystemCommandPills(
            scopedBundleId: scopedBundleId,
            scopedSearchQuery: scopedSearchQuery
        ) {
            pills.append(pill)
        }

        for result in ctxExts {
            let ext = result.ilExtension
            let ctx = currentContext
            var pill = DockPill(
                id: "ctx-\(ext.id)", name: ext.name,
                icon: ext.icon, accentColorName: "teal", badge: nil,
                execute: { Task { await executeL2Extension(ext, context: ctx) } })
            pill.rankingKind = "contextExtension"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "ctxext:\(ext.id)"
            pill.searchTerms = [ext.name]
            pills.append(pill)
        }

        for sc in quickActions {
            var pill = DockPill(
                id: "qa-\(sc.id)", name: sc.name,
                icon: sc.iconName, accentColorName: nil, badge: nil,
                execute: { executeAppShortcut(sc) })
            pill.rankingKind = "quickAction"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "quick:\(sc.id)"
            pill.searchTerms = [sc.name]
            pills.append(pill)
        }
        for ext in userScriptExtensions {
            let icon = ext.iconName.isEmpty ? (ext.scriptLanguage?.systemImage ?? "terminal") : ext.iconName
            let displayName = ext.toolName.replacingOccurrences(of: "-", with: " ").capitalized
            var pill = DockPill(
                id: "usr-script-\(ext.id.uuidString)",
                name: displayName,
                icon: icon,
                accentColorName: "green",
                badge: "Script",
                execute: { executeAppToolExtension(ext, launchQuery: scopedSearchQuery) }
            )
            pill.rankingKind = "userExtension"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "userext:\(scopedAppKey):\(ext.id.uuidString)"
            pill.searchTerms =
                [displayName, ext.toolName, ext.aiHint] + ext.profile.capabilities
                + ext.profile.exampleCommands
            pills.append(pill)
        }
        for package in visibleCLIPackages {
            let isTUI = TerminalAIBridge.shared.isTUICommand(package.command)
            let icon = isTUI ? "terminal.fill" : "chevron.left.forwardslash.chevron.right"
            let displayName = package.name.isEmpty ? package.command : package.name
            var pill = DockPill(
                id: "cli-\(scopedBundleId)-\(package.command)",
                name: displayName,
                icon: icon,
                accentColorName: "green",
                badge: "CLI",
                execute: { openCLIToolPanel(for: package) }
            )
            pill.rankingKind = "cliTool"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "cli:\(scopedBundleId):\(package.command)"
            pill.searchTerms =
                [displayName, package.command, package.description]
                + package.keywords
                + package.subcommands
                + package.taskCategories
                + Array(package.usageExamples.prefix(3))
            pills.append(pill)
        }
        for tool in appTools {
            var pill = DockPill(
                id: "tool-\(tool.toolName)", name: tool.displayName,
                icon: tool.icon, accentColorName: "indigo", badge: nil,
                execute: {
                    l2.chatMessages.append(AIChatMessage(role: .user, content: tool.displayName))
                    l2.isLoading = true
                    Task {
                        let (ok, out) = await L2ExtensionManager.shared.execute(
                            toolName: tool.toolName, arguments: [:])
                        await MainActor.run {
                            let msg =
                                ok
                                ? (out.isEmpty ? "✅ \(tool.displayName) done." : out)
                                : "❌ \(tool.displayName) failed: \(out)"
                            l2.chatMessages.append(AIChatMessage(role: .assistant, content: msg))
                            l2.isLoading = false
                        }
                    }
                })
            pill.rankingKind = "tool"
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.trackingIdentifier = "tool:\(scopedBundleId):\(tool.toolName)"
            pill.searchTerms = [tool.displayName, tool.toolName]
            pills.append(pill)
        }
        pills += adapterActionPills(
            actions: visibleAdapterActions,
            scopedBundleId: scopedBundleId,
            scopedAppName: scopedAppName,
            scopedSearchQuery: scopedSearchQuery)
        } // end !isFinderDesktopOnlyMode

        if !useSeededMenuPills || hasStrongContextQuery {
            for item in visibleMenuMatches {
                let path = item.path
                let menuBundleId = activeBundleId
                let menuAppName = item.sourceAppName.isEmpty ? scopedAppName : item.sourceAppName
                let menuAppPath =
                    installedMenuTarget?.bundleId == menuBundleId
                    ? installedMenuTarget?.appPath
                    : allApplications.first { result in
                        Bundle(url: URL(fileURLWithPath: result.subtitle))?.bundleIdentifier
                            == menuBundleId
                    }?.subtitle
                let sourcePID =
                    item.sourcePID != 0
                    ? item.sourcePID
                    : (menuBundleId.isEmpty
                        ? (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                        : 0)
                // Only show source badge for cross-app items; Apple menu items are universal — no badge
                let isFrontmost =
                    sourcePID == (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                let pillBadge: String? = {
                    if isAppleMenuItem(item) { return nil }  // universal — no app badge
                    if !item.sourceAppName.isEmpty && !isFrontmost {
                        return item.sourceAppName  // cross-app badge
                    }
                    return path.count >= 2 ? path[path.count - 2] : nil  // parent menu name
                }()
                let shortcutChar = item.shortcutChar
                let shortcutMods = item.shortcutModifiers
                let shortcutHint = item.shortcutDisplay

                if !item.children.isEmpty {
                    pills.append(
                        contentsOf: makeSubmenuChildDockPills(
                            parent: item,
                            idPrefix: "menu-\(item.id)",
                            sourceBundleId: menuBundleId,
                            sourceAppName: menuAppName,
                            accentColorName: isAppleMenuItem(item) ? "gray" : "blue",
                            trackingPrefix: "submenu:\(menuBundleId)",
                            searchTerms: [menuAppName],
                            executeChild: { child in
                                AppInteractionStore.shared.record(
                                    bundleId: menuBundleId,
                                    appName: menuAppName,
                                    query: child.title,
                                    kind: .menuItem,
                                    actionId: child.path.joined(separator: " > ")
                                )
                                if sourcePID == 0, !menuBundleId.isEmpty {
                                    executeCachedMenuAction(
                                        bundleIdentifier: menuBundleId,
                                        appName: menuAppName,
                                        appPath: menuAppPath,
                                        path: child.path,
                                        shortcutChar: child.shortcutChar,
                                        shortcutModifiers: child.shortcutModifiers
                                    )
                                    return
                                }
                                let childPID = child.sourcePID != 0 ? child.sourcePID : sourcePID
                                guard childPID != 0 else { return }
                                self.executeDockMenuAction(
                                    sourcePID: childPID,
                                    path: child.path,
                                    shortcutChar: child.shortcutChar,
                                    shortcutModifiers: child.shortcutModifiers
                                )
                            }
                        )
                    )
                    continue
                }

                let isFav = favs.contains(item.title)
                var pill = makeMenuDockPill(
                    id: "menu-\(item.id)",
                    item: item,
                    sourceBundleId: menuBundleId,
                    sourceAppName: menuAppName,
                    accentColorName: isFav ? "yellow" : "gray",
                    badge: shortcutHint ?? pillBadge,
                    trackingIdentifier:
                        "menu:\(menuBundleId):\(path.joined(separator: " > ").lowercased())",
                    searchTerms: item.path + [menuAppName],
                    executeLeaf: {
                        AppInteractionStore.shared.record(
                            bundleId: menuBundleId,
                            appName: menuAppName,
                            query: item.title,
                            kind: .menuItem,
                            actionId: path.joined(separator: " > ")
                        )
                        if sourcePID == 0, !menuBundleId.isEmpty {
                            executeCachedMenuAction(
                                bundleIdentifier: menuBundleId,
                                appName: menuAppName,
                                appPath: menuAppPath,
                                path: path,
                                shortcutChar: shortcutChar,
                                shortcutModifiers: shortcutMods
                            )
                            return
                        }
                        guard sourcePID != 0 else { return }
                        self.executeDockMenuAction(
                            sourcePID: sourcePID,
                            path: path,
                            shortcutChar: shortcutChar,
                            shortcutModifiers: shortcutMods
                        )
                    })
                pill.isFavourited = isFav
                // Bare "Share"/"Share…" leaf ONLY (no children) — never path.contains.
                let isBareShareMenuItem =
                    item.children.isEmpty && isShareSheetTitle(item.title)
                if isBareShareMenuItem {
                    let shareItem = item
                    pill = DockPill(
                        id: pill.id, name: pill.name,
                        icon: "square.and.arrow.up",
                        accentColorName: "blue",
                        badge: pill.badge,
                        execute: { executeShareAction(item: shareItem) })
                    pill.isShareAction = true
                    pill.isFavourited = isFav
                    // Show the share glyph (square.and.arrow.up), never a resolved app
                    // icon. This routes to DoraX's own inline share sheet, which always
                    // works, so don't carry the menu item's "Unavailable now" state.
                    pill.menuItemImage = nil
                    pill.menuItemName = item.title
                    pill.sourceBundleId = menuBundleId
                    pill.sourceAppName = menuAppName
                    pill.menuContext = menuContextLabel(from: item.path)
                    pill.rankingKind = "menu"
                    pill.hasLiveAvailability = false
                    pill.menuStatusBadge = nil
                    pill.trackingIdentifier =
                        "menu:\(menuBundleId):\(path.joined(separator: " > ").lowercased())"
                    pill.searchTerms = item.path + [menuAppName, "share"]
                }
                pills.append(pill)
            }
        }
        if !isExplicitAppScope {
            if !hasSelectionScopeSurface {
                pills += crossAppPills
            }
        }
        let resolvedRulePills = AXTriggerRuleEngine.shared.evaluate(context: axContext)
        if !isExplicitAppScope {
            let filteredRulePills =
                q.isEmpty
                ? resolvedRulePills : resolvedRulePills.filter { $0.name.lowercased().contains(q) }
            pills += filteredRulePills.map { r in
                DockPill(
                    id: r.id, name: r.name, icon: r.icon, accentColorName: r.accentColor,
                    badge: nil, execute: r.execute)
            }
        }

        let rankingQuery = isExplicitAppScope ? scopedSearchQuery : q
        let ranked = rankDockPills(
            pills,
            rawQuery: q,
            rankingQuery: rankingQuery,
            scopedBundleId: scopedBundleId,
            scopedAppName: scopedAppName,
            isExplicitAppScope: isExplicitAppScope
        )
        let dedupedRanked = dedupeRankedDockPills(ranked)
        let scopeOwnedRanked: [DockPill] = {
            guard !isGlobalContextActive, !scopedBundleId.isEmpty else { return dedupedRanked }
            return dedupedRanked.filter { pill in
                pill.sourceBundleId.isEmpty || pill.sourceBundleId == scopedBundleId
                    || pill.rankingKind == "appSwitch"
            }
        }()
        // Treat menu enabled state as advisory. Some apps lazily validate menus only when
        // their native menu opens, so AX can report a runnable action as disabled.
        let enabled = scopeOwnedRanked.filter { pill in
            if isStaleAvailabilityMenuPill(pill) { return true }
            if !q.isEmpty,
                pill.rankingKind == "menu" || pill.rankingKind == "finderMenu",
                dockPillHasQuerySignal(
                    pill,
                    query: rankingQuery,
                    rawQuery: q,
                    scopedBundleId: scopedBundleId,
                    scopedAppName: scopedAppName
                )
            {
                return true
            }
            return pill.isEnabled || pill.rankingKind.isEmpty || pill.rankingKind == "appLaunch"
                || pill.rankingKind == "appSwitch"
                || pill.rankingKind == "finderSelection" || pill.rankingKind == "payload"
                || pill.rankingKind == "cliTool" || pill.rankingKind == "tool"
                || pill.rankingKind == "userExtension" || pill.rankingKind == "submenuChild"
                || pill.rankingKind == "submenuParent" || pill.rankingKind == "writingTool"
        }

        // When global context has an active file/folder/text selection and no explicit app scope,
        // keep the Finder/menu surface broad. The selection state should feel like the native
        // menu bar after selecting a file: File/Edit/View/Go/Window/Help commands stay available,
        // while app launch/recent-app rows are still removed by the selection-scoped filter.
        let resolved: [DockPill] =
            (hasSelectionScopeSurface && !isExplicitAppScope)
            ? selectionScopedDockPills(enabled)
            : enabled
        if resolved.contains(where: { !$0.isSeparator }) { return resolved }

        // No match. Keep the result sheet open with an "Ask AI" row instead of collapsing the
        // surface (which made the shell jump between bar and sheet while typing) or auto-arming
        // the app chat (which swapped the whole outer layer out from under the query).
        guard showContextInDock,
            !isGlobalContextActive,
            !hasSelectionScopeSurface,  // Selection Scope already floors with its own Ask AI row
            !isFinderDesktopOnlyMode,
            !isCompactSmartScope,
            !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return resolved }
        return [contextDockNoResultFallbackPill(for: q)]
    }

}
