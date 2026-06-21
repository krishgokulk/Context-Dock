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

        // Interactive commands render a live control (slider/toggle) on a single
        // pill — value presets become redundant rows.
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
            return [pill]
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
            return dynamicItems.map { item in
                var pill = DockPill(
                    id: "syscmd-\(command.id)-\(item.value)",
                    name: "\(command.name) \(item.title)",
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
            }
        }

        let presetValues = systemCommandPresetValues(command, fallbackVolume: isVolume)
        let values = (query.isEmpty || queryTargetsCommand) && !presetValues.isEmpty
            ? presetValues
            : [query]

        return values.map { value in
            let label = !value.isEmpty && !presetValues.isEmpty ? "\(command.name) \(value)" : command.name
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
        }
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
            let rows = devices.map {
                SystemCommandDynamicItem(
                    title: $0.name,
                    value: $0.name,
                    subtitle: $0.status,
                    isActive: $0.isConnected
                )
            }
            if !rows.isEmpty { return rows }
            return [
                SystemCommandDynamicItem(
                    title: "Settings",
                    value: "settings",
                    subtitle: "Open Bluetooth Settings",
                    isActive: false
                )
            ]
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
        let launched = launchApplication(bundleIdentifier: bundleId, appName: appName)
        if launched {
            DockActionFeedback.start(
                "Opening", subject: appName, icon: "arrow.up.right.circle.fill", tint: .accentColor)
        } else {
            let fid = DockActionFeedback.start(
                "Opening", subject: appName, icon: "arrow.up.right.circle.fill", tint: .accentColor)
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
            pill.sourceBundleId = scopedBundleId
            pill.sourceAppName = scopedAppName
            pill.rankingKind = "nativeWindow"
            pill.rankingScore = 1_400
            pill.trackingIdentifier = "native-window:\(scopedBundleId):\(command.id)"
            pill.searchTerms = command.searchTerms + [scopedAppName]
            return pill
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
                if best == nil || score > best!.score {
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

    func scopedSpecialAppPills(
        bundleIdentifier: String,
        appName: String,
        query: String
    ) -> [DockPill] {
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
            !hasActiveDockContextSelection,
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
            hints =
                attachedFinderFolderSearchPath.isEmpty
                ? "search files and folders in \(finderDesktopSearchScopeLabel)"
                : "search this folder, open files, menu cmds"
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
        guard force || newKey != l2.activeDockSessionKey else { return }

        if let previousKey = l2.activeDockSessionKey {
            AppPanelChatStore.shared.save(l2.chatMessages, for: previousKey)
        }

        l2.activeDockSessionKey = newKey
        l2.currentTask?.cancel()
        l2.currentTask = nil
        l2.isLoading = false
        l2.activeRequestID = nil
        l2.handledApprovalIds = []
        l2.contextExtensions = []
        l2.lastAutoRunExtensionID = nil
        l2.chatMessages = newKey.map { AppPanelChatStore.shared.load(for: $0) } ?? []
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

        let targetApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        })
        let appURL = applicationURL(bundleIdentifier: bundleIdentifier, appName: appName)
        let appPath = appURL?.path ?? ""
        let icon =
            !appPath.isEmpty
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

        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
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

        if let targetApp {
            seedCrossAppMenuCache(for: targetApp)
            loadCrossAppMenu(for: targetApp)
        } else {
            crossAppMenuTargetPID = 0
            crossAppMenuNeedsLiveLoad = false
            // App not running — load from persistent disk cache so command palette still works.
            // Actions route via executeCachedMenuAction (no live PID needed).
            let cached = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                processIdentifier: 0,
                query: "",
                maxResults: 120
            )
            crossAppMenuItems = cached
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
        if hasAnyCLI {
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
        if let previousKey = searchState.activeSmartQueryKey {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: previousKey)
        }
        remPanelAITask?.cancel()
        remPanelIsProcessing = false
        selectedClipboardEntryIDs.removeAll()
        focusedClipboardEntryIndex = nil

        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
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
        if let previousKey = searchState.activeSmartQueryKey {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: previousKey)
        }
        remPanelAITask?.cancel()
        remPanelIsProcessing = false

        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
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
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let localDateTime = formatter.string(from: now)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = .current
        let isoDateTime = isoFormatter.string(from: now)
        let timeZoneName = TimeZone.current.identifier

        return """
            CURRENT DATE & TIME:
            - Local: \(localDateTime)
            - ISO 8601: \(isoDateTime)
            - Time Zone: \(timeZoneName)
            Use this exact date/time for relative time references like today, yesterday, tomorrow, recent, and this week.
            """
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

        if isGlobalContextActive,
            !hasActiveDockContextSelection,
            !showGlobalClipboardPill,
            !isContextDockChatConnected
        {
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            return
        }

        dockPillBuildTask = ContextDockPillCoordinator.schedule(
            input: ContextDockPillCoordinator.Input(
                query: query,
                lastQuery: lastPillQuery,
                delayNanoseconds: delayNanoseconds,
                refreshContext: refreshContext,
                cachedPills: cachedDockPills,
                previewPills: contextDockPreviewPills(for: query),
                isQuestionStyle: isQuestionStyleDockQuery(query)
            ),
            viewModel: contextDockViewModel,
            actions: ContextDockPillCoordinator.Actions(
                commitPreview: { commitPendingDockPreviewPills($0) },
                clearCachedPills: { cachedDockPills = [] },
                refreshContext: { refreshFinderSelectionContextFromFinder() },
                buildPills: { buildDockPills(query: $0) },
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
        contextDockViewModel.replaceCachedPills(
            pills,
            preserveFocus: preserveFocus,
            focusedIndex: l2.focusedPillIndex,
            setFocusedIndex: { l2.focusedPillIndex = $0 },
            clearPillKeyboardNavigation: { l2.pillNavViaKeyboard = false }
        )
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
        let appContentSearchPill: DockPill? = {
            guard !isGlobalContextActive, !isGlobalScope,
                !scopedBundleId.isEmpty, !scopedAppName.isEmpty,
                let intent = AppContentSearchRouter.shared.scopedIntent(
                    for: q,
                    bundleId: scopedBundleId,
                    appName: scopedAppName
                )
            else { return nil }
            return appContentSearchDockPill(intent)
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
        let rawFinderFilePills = rawMacOSExtensionActionPills
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
        let finderFileTitleSet = Set(rawMacOSExtensionActionPills.map { normalizedDockPillText($0.name) })
        let rawFinderSelectionMenuPills =
            isFinderScopedDock && !finderFolderAttachedForDock && !isFinderDesktopOnlyMode
            ? buildFinderSelectionMenuPills(
                query: q,
                excludingTitles: finderFileTitleSet,
                allowedRootNames: ["file", "open with", "tags"]
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
        let shouldExposeCLIPills = scopedBundleId.hasPrefix("cli://")
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
        let useSeededMenuPills =
            q.isEmpty && !liveMenuItems.isEmpty && !shouldSuppressMenuForContext
            && !isScopedToOtherApp

        if isGlobalContextActive && hasActiveDockContextSelection {
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
                // Bare "Share"/"Share…" → reveal destinations; a real child (Mail/
                // AirDrop/Notes) → click its EXACT menu path (never resolve by title).
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
                        if isBareShareMenuItem {
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

        if let appContentSearchPill {
            pills.append(appContentSearchPill)
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
        let pureScopeMenuLimit = 10
        let pureScopeCandidateLimit = 12
        let scopedRunningMenuMatches: (NSRunningApplication, String, Bool) -> [AXMenuItem] = {
            app, filterQ, preferCached in
            let pid = app.processIdentifier
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
                let cachedMatches = crossAppMenuItems.filter { item in
                    item.sourcePID == targetApp.processIdentifier
                        && menuItemMatchesQuery(item, filterQ)
                }
                let matches = dedupeMenuItems(
                    menuItemsAllowedForCurrentScope(
                        cachedMatches + persistentMenuMatches(targetApp, filterQ, candidateLimit)
                    )
                )
                return orderedScopedMenuMatches(matches, filterQuery: filterQ, limit: 16)
            }
            // Default: frontmost app's real menu items first — query-time AX search is primary.
            let cachedMatches = liveMenuItems.filter { item in
                menuItemMatchesQuery(item, q)
            }
            let persistentMatches: [AXMenuItem] = {
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
            return hasStrongContextQuery ? Array(menuMatches.prefix(6)) : menuMatches
        }()

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
        for action in visibleAdapterActions {
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
            if !(isGlobalContextActive && hasActiveDockContextSelection) {
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
                || pill.rankingKind == "submenuParent"
        }

        // When global context has an active file/folder/text selection and no explicit app scope,
        // keep the Finder/menu surface broad. The selection state should feel like the native
        // menu bar after selecting a file: File/Edit/View/Go/Window/Help commands stay available,
        // while app launch/recent-app rows are still removed by the selection-scoped filter.
        guard isGlobalContextActive && hasActiveDockContextSelection && !isExplicitAppScope else {
            return enabled
        }
        return selectionScopedDockPills(enabled)
    }

}
