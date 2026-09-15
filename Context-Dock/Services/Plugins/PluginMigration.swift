// Context-Dock
//
// Global Commands (SystemCommand) and Global Extensions (UserGlobalExtension) become
// plugin manifests. Pure: no I/O, no registry. The rules are the table in
// docs/superpowers/plans/2026-09-15-plugins-p1-model.md Task 6; each row has a test.
//
// Scripts are never rewritten. A raw-value script stays raw (format .raw), a JSONL rows
// script stays JSONL, a "Title | subtitle" script stays lines — the runner (P3) knows all
// four formats so the user's script keeps working unchanged.
//
// `presets:` keywords are NOT meta-prefixes here: they carry user-visible options
// (Appearance Light/Dark/Auto, Focus scopes) that nothing in the manifest yet represents,
// so they stay in `keywords` until a later phase gives them a home. Only `provider:`,
// `refresh:` and `query:` are consumed.

import Foundation

enum PluginMigration {

    private static let destructiveNames: Set<String> = ["Sleep", "Restart...", "Shut Down...", "Empty Trash"]
    private static let metaPrefixes = ["provider:", "refresh:", "query:"]
    private static let nativeProviders: Set<String> = ["wifi", "bluetooth", "windows", "notepad", "processes"]

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "plugin" : out
    }

    static func nativeProvider(of command: SystemCommand) -> String? {
        for kw in command.keywords {
            let lower = kw.lowercased()
            guard lower.hasPrefix("provider:") else { continue }
            let name = String(lower.dropFirst("provider:".count))
            if nativeProviders.contains(name) { return name }
        }
        return nil
    }

    private static func meta(_ command: SystemCommand, prefix: String) -> String? {
        command.keywords.lazy.map { $0.lowercased() }.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func userKeywords(_ keywords: [String]) -> [String] {
        keywords.filter { kw in !metaPrefixes.contains { kw.lowercased().hasPrefix($0) } }
    }

    /// Normalises a legacy script-type string into the manifest's canonical vocabulary.
    /// `url`, `file` and `aiPrompt` never reach here for the primary action — they are
    /// handled by dedicated branches before this is consulted — but the secondary action
    /// fields (`set`, `rowAction`, `undo`) route through this too so every action's `type`
    /// speaks the same vocabulary, per the migration ruling.
    private static func scriptType(_ raw: String) -> PluginScriptType {
        switch SystemCommandActionType.normalize(raw) {
        case .bash: return .bash
        case .applescript: return .applescript
        case .jxa: return .jxa
        case .scriptFile: return .scriptFile
        case .url, .file, .aiPrompt: return .bash
        }
    }

    // MARK: SystemCommand

    static func manifest(from command: SystemCommand) -> PluginManifest {
        var m = PluginManifest(
            id: slug(command.name), name: command.name, icon: command.icon,
            description: command.description, keywords: userKeywords(command.keywords))

        if let provider = nativeProvider(of: command) {
            m.views.panel = PluginPanelView(root: PluginNode(component: "native", props: ["provider": .string(provider)]))
            return m
        }

        let kind = SystemCommandActionType.normalize(command.scriptType)
        let isCustomList = meta(command, prefix: "provider:") == "custom"

        if isCustomList {
            let refresh = Int(meta(command, prefix: "refresh:") ?? "") ?? 0
            m.data = PluginDataSource(type: scriptType(command.scriptType), script: command.script, format: .jsonl,
                                      refresh: refresh > 0 ? [.panel: refresh] : [:])
            var row: [String: PluginValue] = [
                "title": .string("{{item.title}}"), "subtitle": .string("{{item.subtitle}}"),
                "badge": .string("{{item.badge}}"), "icon": .string("{{item.icon}}"),
            ]
            if command.hasUndoAction {
                m.actions["rowAction"] = PluginAction(type: scriptType(command.undoScriptType).rawValue, script: command.undoScript, risk: .low)
                row["action"] = .string("rowAction")
            }
            let filter = meta(command, prefix: "query:") == "live" ? "query" : "local"
            m.views.panel = PluginPanelView(root: PluginNode(component: "list", props: [
                "filter": .string(filter), "items": .string("{{lines}}"), "row": .object(row),
            ]))
            m.sample = ["lines": .array([])]
            return m
        }

        switch command.interactionType {
        case .slider, .toggle:
            let component = command.interactionType == .slider ? "slider" : "toggle"
            if !command.valueScript.isEmpty {
                m.data = PluginDataSource(type: scriptType(command.scriptType), script: command.valueScript, format: .raw)
            }
            m.actions["set"] = PluginAction(type: scriptType(command.scriptType).rawValue, script: command.script, risk: .low)
            var props: [String: PluginValue] = ["value": .string("{{value}}"), "action": .string("set")]
            if component == "slider" {
                props["min"] = .number(command.sliderMin)
                props["max"] = .number(command.sliderMax)
                props["step"] = .number(command.sliderStep)
            }
            let control = PluginNode(component: component, props: props)
            m.views.panel = PluginPanelView(root: control)
            m.views.widget = PluginWidgetView(family: .small, root: control)
            m.sample = ["value": .string("")]
            return m
        case .none:
            break
        }

        switch kind {
        case .url, .file:
            m.actions["run"] = PluginAction(type: "open", value: command.script, risk: .read)
            m.primaryAction = "run"
        case .aiPrompt:
            m.views.window = PluginWindowView(root: PluginNode(component: "ai", props: ["prompt": .string(command.script)]))
            m.agent = PluginAgent(instructions: command.script)
        default:
            var run = PluginAction(type: scriptType(command.scriptType).rawValue, script: command.script,
                                   risk: destructiveNames.contains(command.name) ? .medium : .low)
            if !command.successTitle.isEmpty || !command.successMessage.isEmpty {
                run.success = PluginActionFeedback(title: command.successTitle, message: command.successMessage)
            }
            if command.hasUndoAction {
                m.actions["undo"] = PluginAction(type: scriptType(command.undoScriptType).rawValue, script: command.undoScript,
                                                 title: command.undoTitle.isEmpty ? "Undo" : command.undoTitle, risk: .low)
                run.undo = "undo"
            }
            m.actions["run"] = run
            m.primaryAction = "run"
        }
        return m
    }

    // MARK: UserGlobalExtension

    static func manifest(from ext: UserGlobalExtension) -> PluginManifest {
        var m = PluginManifest(
            id: slug(ext.name), name: ext.name, icon: ext.icon,
            description: ext.description, keywords: userKeywords(ext.keywords))

        m.data = PluginDataSource(type: scriptType(ext.rowsScriptType), script: ext.rowsScript, format: .lines)
        var row: [String: PluginValue] = ["title": .string("{{item.title}}"), "subtitle": .string("{{item.subtitle}}")]
        if !ext.rowActionScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.actions["rowAction"] = PluginAction(type: scriptType(ext.rowActionScriptType).rawValue, script: ext.rowActionScript, risk: .low)
            row["action"] = .string("rowAction")
        }
        let list = PluginNode(component: "list", props: ["filter": .string("local"), "items": .string("{{lines}}"), "row": .object(row)])
        m.views.panel = PluginPanelView(root: list)
        m.sample = ["lines": .array([])]

        if ext.aiEnabled {
            m.views.window = PluginWindowView(root: PluginNode(component: "vstack", children: [
                list, PluginNode(component: "ai", props: ["prompt": .string(ext.aiPrompt)]),
            ]))
            m.agent = PluginAgent(instructions: ext.aiPrompt)
        }
        return m
    }
}
