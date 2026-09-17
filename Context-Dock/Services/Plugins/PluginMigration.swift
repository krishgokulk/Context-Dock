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
//
// What this conversion drops (Phase 8 owns parity for these):
//   - The custom-list row template here only carries title/subtitle/badge/icon (see
//     `CustomListRow` in CustomListProviderService.swift), so a compare-layout row's
//     `layout: "compare"`, `left`, `right`, `centerIcon`, `leftQuery`, `rightQuery` and
//     `centerAction` are not migrated. Neither is the "no row-action script authored, but
//     the row's id/icon is a real path → Enter opens it" fallback that
//     `LauncherView+ContextualActions.customListRowOpenablePath` provides at runtime for
//     Global Commands.
//   - The native-provider branch below returns immediately once it recognises the
//     provider, so a native provider's own `interaction` (Wi-Fi and Bluetooth are declared
//     as `"toggle"` in SystemCommands.swift, with a `valueScript` reflecting live state)
//     and its `script` are never carried into the manifest — the manifest only records
//     which native provider owns the panel, not how that provider's own toggle behaves.
//
// A caller converting a *list* of legacy items (not implemented in this phase — nothing
// here has a batch API yet) is responsible for uniquifying the resulting ids before
// installing them: `slug()` alone does not guarantee uniqueness (the legacy UUID is
// dropped and two items named "Deploy" collapse to the same id), and `PluginPack` keeps
// only the first plugin it sees for a given id, silently dropping the rest.

import Foundation

/// One legacy item, converted, with enough of where it came from to show it honestly and to
/// avoid migrating the same thing twice.
struct MigratedPlugin: Identifiable, Equatable {
    enum Source: String, Equatable {
        case globalCommand = "Global Command"
        case globalExtension = "Global Extension"
    }

    let manifest: PluginManifest
    let source: Source
    /// The legacy record's own UUID, as a string.
    let legacyID: String
    let isEnabled: Bool

    var id: String { manifest.id }
}

enum PluginMigration {

    /// Every Global Command and Global Extension at once — the two systems Plugins replaces.
    ///
    /// Ids are made unique here, which single-item conversion cannot do: `slug()` drops the
    /// legacy UUID, so two commands called "Deploy" both become `deploy`, and `PluginPack`
    /// keeps only the first plugin it sees for an id and silently drops the rest. Commands
    /// come first and keep the plain slug; later collisions get `-2`, `-3`.
    ///
    /// Pure, like the rest of this file: it reads no store and writes nothing. The caller
    /// passes what it has and decides what to do with the result.
    static func migrateAll(commands: [SystemCommand], extensions: [UserGlobalExtension])
        -> [MigratedPlugin]
    {
        var taken: Set<String> = []
        var out: [MigratedPlugin] = []

        func add(_ manifest: PluginManifest, _ source: MigratedPlugin.Source,
                 _ legacyID: String, _ isEnabled: Bool) {
            var unique = manifest
            unique.id = uniqueID(manifest.id, taken: &taken)
            out.append(MigratedPlugin(
                manifest: unique, source: source, legacyID: legacyID, isEnabled: isEnabled))
        }

        for command in commands {
            add(manifest(from: command), .globalCommand, command.id.uuidString, command.isEnabled)
        }
        for ext in extensions {
            add(manifest(from: ext), .globalExtension, ext.id.uuidString, ext.isEnabled)
        }
        return out
    }

    private static func uniqueID(_ wanted: String, taken: inout Set<String>) -> String {
        if taken.insert(wanted).inserted { return wanted }
        var n = 2
        while !taken.insert("\(wanted)-\(n)").inserted { n += 1 }
        return "\(wanted)-\(n)"
    }

    private static let destructiveNames: Set<String> = ["Sleep", "Restart...", "Shut Down...", "Empty Trash"]
    private static let metaPrefixes = ["provider:", "refresh:", "query:"]
    private static let nativeProviders: Set<String> = ["wifi", "bluetooth", "windows", "notepad", "processes"]

    /// `Character.isLetter` is true for "é", Cyrillic and CJK alike, so without folding to
    /// ASCII first, a name like "Café" produced the id "café" — a rule-12 schema error with
    /// nothing a user could act on ("your id is invalid" when the id came from their plugin's
    /// own name). Transliterate to Latin then strip remaining diacritics where Foundation
    /// can; anything still non-ASCII afterwards (untransliterable scripts) is dropped like
    /// any other non-letter character, same as before. The empty-name fallback is unchanged.
    static func slug(_ name: String) -> String {
        var folded = name.lowercased()
        if let latin = folded.applyingTransform(.toLatin, reverse: false) { folded = latin }
        if let stripped = folded.applyingTransform(.stripDiacritics, reverse: false) { folded = stripped }
        var out = ""
        var lastDash = true
        for ch in folded {
            if ch.isASCII, ch.isLetter || ch.isNumber {
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

    /// Normalises a legacy script-type string into the manifest's canonical script
    /// vocabulary. Used for `PluginDataSource.type`, which is always a script (a data
    /// source has no `url`/`file`/`aiPrompt` shape to preserve), and, via `legacyAction`
    /// below, as the fallback for a script-type action once `url`, `file` and `aiPrompt`
    /// have already been peeled off by dedicated handling. `.bash` here is only ever a
    /// last-resort default for a genuinely unrecognised type string, never a stand-in for
    /// one of those three.
    private static func scriptType(_ raw: String) -> PluginScriptType {
        switch SystemCommandActionType.normalize(raw) {
        case .bash: return .bash
        case .applescript: return .applescript
        case .jxa: return .jxa
        case .scriptFile: return .scriptFile
        case .url, .file, .aiPrompt: return .bash
        }
    }

    /// The one place a legacy `url`/`file` script becomes the manifest's built-in `open`
    /// action, so a deep link or a file path is opened, not handed to a shell as `bash`.
    private static func openAction(value: String, title: String? = nil) -> PluginAction {
        PluginAction(type: "open", value: value, title: title, risk: .read)
    }

    /// Turns a legacy script-type string into an action for a *secondary* slot — an undo
    /// action, a slider/toggle's `set` action, a custom list's `rowAction` — the same way
    /// the primary `run` action branch below treats it (via the same `openAction` helper),
    /// so every runner that reads these (`LauncherView+ContextualActions`'s
    /// command/undo/row-action switches) sees the same shape regardless of which slot the
    /// script came from:
    ///   - `url`/`file` become `openAction(value:)`.
    ///   - `aiPrompt` has no action shape in a secondary slot (there is no "run an AI
    ///     prompt" action type); `nil` says so, and every caller drops the slot entirely
    ///     rather than mislabelling it `bash` — mirroring how the primary aiPrompt branch
    ///     below already drops a success message it has nowhere to attach.
    ///   - Every other script type maps straight through `scriptType(_:)`.
    private static func legacyAction(scriptType raw: String, script: String, risk: PluginRisk, title: String? = nil) -> PluginAction? {
        switch SystemCommandActionType.normalize(raw) {
        case .url, .file:
            return openAction(value: script, title: title)
        case .aiPrompt:
            return nil
        case .bash, .applescript, .jxa, .scriptFile:
            return PluginAction(type: scriptType(raw).rawValue, script: script, title: title, risk: risk)
        }
    }

    /// Attaches success feedback and an undo action to a run-like action.
    /// `successTitle`/`successMessage`/`undoScript` are generic fields on every
    /// `SystemCommand` regardless of `scriptType` — a URL/deep-link or AI-prompt command
    /// can carry them exactly as a script one can — so this is shared across every branch
    /// that produces a `run` action, not owned by the one-shot default branch alone.
    private static func attachOutcomes(_ action: PluginAction, from command: SystemCommand, into m: inout PluginManifest) -> PluginAction {
        var action = action
        if !command.successTitle.isEmpty || !command.successMessage.isEmpty {
            action.success = PluginActionFeedback(title: command.successTitle, message: command.successMessage)
        }
        if command.hasUndoAction {
            if let undo = legacyAction(scriptType: command.undoScriptType, script: command.undoScript, risk: .low,
                                        title: command.undoTitle.isEmpty ? "Undo" : command.undoTitle) {
                m.actions["undo"] = undo
                action.undo = "undo"
            }
            // else: undoScriptType is aiPrompt — no action shape in a secondary slot, so
            // the undo is dropped rather than mislabelled `bash` (see legacyAction).
        }
        return action
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
            if command.hasUndoAction, let rowAction = legacyAction(scriptType: command.undoScriptType, script: command.undoScript, risk: .low) {
                m.actions["rowAction"] = rowAction
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
            if let set = legacyAction(scriptType: command.scriptType, script: command.script, risk: .low) {
                m.actions["set"] = set
            }
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
            let open = openAction(value: command.script)
            m.actions["run"] = attachOutcomes(open, from: command, into: &m)
            m.primaryAction = "run"
        case .aiPrompt:
            m.views.window = PluginWindowView(root: PluginNode(component: "ai", props: ["prompt": .string(command.script)]))
            m.agent = PluginAgent(instructions: command.script)
            // No `run` action exists in this shape, so a success message has nowhere to
            // attach — intentionally dropped (see task-6-report.md). An undo script still
            // has a home: keep it as a standalone action so it isn't lost, unless the
            // undoScriptType is itself aiPrompt — see legacyAction.
            if command.hasUndoAction,
               let undo = legacyAction(scriptType: command.undoScriptType, script: command.undoScript, risk: .low,
                                        title: command.undoTitle.isEmpty ? "Undo" : command.undoTitle) {
                m.actions["undo"] = undo
            }
        default:
            let run = PluginAction(type: scriptType(command.scriptType).rawValue, script: command.script,
                                   risk: destructiveNames.contains(command.name) ? .medium : .low)
            m.actions["run"] = attachOutcomes(run, from: command, into: &m)
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
