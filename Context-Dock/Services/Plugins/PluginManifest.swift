// Context-Dock
//
// The manifest a plugin is. Tolerant on decode — a model or a person writing one needs
// id, name and something to show or say; everything else defaults. Strict on meaning —
// PluginSchema is where a manifest is told what is wrong with it.

import Foundation

enum PluginDataFormat: String, Codable { case json, jsonl, lines, raw }
enum PluginScriptType: String, Codable { case bash, applescript, jxa, scriptFile, shortcut, http }
enum PluginRisk: String, Codable { case read, low, medium, high }
enum PluginPresentation: String, Codable, CaseIterable { case icon, widget, panel, window }
/// `small` / `medium` / `large` are the iOS squares. `bar` is the dock strip's own family: a
/// tile the height of a strip icon, `slots` icons wide, so a widget sits in the row with the
/// apps and pins rather than towering over them.
enum PluginWidgetFamily: String, Codable { case small, medium, large, bar }
enum PluginWindowWidth: String, Codable { case narrow, regular, wide }

struct PluginDataSource: Codable, Equatable {
    var type: PluginScriptType
    var script: String
    var format: PluginDataFormat
    var refresh: [PluginPresentation: Int]
    var timeout: Int

    init(type: PluginScriptType, script: String, format: PluginDataFormat = .json,
         refresh: [PluginPresentation: Int] = [:], timeout: Int = 5) {
        self.type = type; self.script = script; self.format = format
        self.refresh = refresh; self.timeout = timeout
    }

    enum CodingKeys: String, CodingKey { case type, script, format, refresh, timeout }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(PluginScriptType.self, forKey: .type)
        script = try c.decode(String.self, forKey: .script)
        format = try c.decodeIfPresent(PluginDataFormat.self, forKey: .format) ?? .json
        let raw = try c.decodeIfPresent([String: Int].self, forKey: .refresh) ?? [:]
        var map: [PluginPresentation: Int] = [:]
        for (k, v) in raw { if let p = PluginPresentation(rawValue: k) { map[p] = v } }
        refresh = map
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 5
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(script, forKey: .script)
        try c.encode(format, forKey: .format)
        try c.encode(Dictionary(uniqueKeysWithValues: refresh.map { ($0.key.rawValue, $0.value) }), forKey: .refresh)
        try c.encode(timeout, forKey: .timeout)
    }
}

struct PluginActionFeedback: Codable, Equatable {
    var title: String
    var message: String
}

struct PluginAction: Codable, Equatable {
    /// A script type (`bash`, `applescript`, `jxa`, `scriptFile`, `shortcut`, `http`) or a
    /// built-in: `copy`, `open`, `reveal`, `paste`, `push:<view>`, `set` (state[key] = value).
    var type: String
    var script: String?
    var value: String?
    var app: String?
    /// `set` only: which state key the tapped value goes into.
    var key: String?
    var title: String?
    var risk: PluginRisk
    var optimistic: String?
    /// Name of another action that reverses this one.
    var undo: String?
    var success: PluginActionFeedback?

    init(type: String, script: String? = nil, value: String? = nil, app: String? = nil,
         key: String? = nil, title: String? = nil, risk: PluginRisk = .read,
         optimistic: String? = nil, undo: String? = nil, success: PluginActionFeedback? = nil) {
        self.type = type; self.script = script; self.value = value; self.app = app
        self.key = key; self.title = title; self.risk = risk; self.optimistic = optimistic
        self.undo = undo; self.success = success
    }

    enum CodingKeys: String, CodingKey { case type, script, value, app, key, title, risk, optimistic, undo, success }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        // Spec §11.3 gates anything beyond read through the approval centre. A script
        // action (bash, applescript, jxa, scriptFile, shortcut, http) that omits `risk`
        // defaults to `.low` so an unannotated shell action still prompts; the built-ins
        // (copy, open, reveal, paste, push:<view>) keep the old `.read` default. An
        // explicit `risk` in the JSON always wins over either default.
        if let declared = try c.decodeIfPresent(PluginRisk.self, forKey: .risk) {
            risk = declared
        } else {
            risk = PluginScriptType(rawValue: type) != nil ? .low : .read
        }
        optimistic = try c.decodeIfPresent(String.self, forKey: .optimistic)
        undo = try c.decodeIfPresent(String.self, forKey: .undo)
        success = try c.decodeIfPresent(PluginActionFeedback.self, forKey: .success)
    }

    var isScript: Bool { PluginScriptType(rawValue: type) != nil }
    var pushTarget: String? { type.hasPrefix("push:") ? String(type.dropFirst(5)) : nil }
}

struct PluginAgent: Codable, Equatable {
    var instructions: String
    var skills: [String]
    var tools: [String]
    var inputs: [String]

    init(instructions: String = "", skills: [String] = [], tools: [String] = [], inputs: [String] = []) {
        self.instructions = instructions; self.skills = skills; self.tools = tools; self.inputs = inputs
    }

    enum CodingKeys: String, CodingKey { case instructions, skills, tools, inputs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
    }
}

/// `"icon": { "thumbnail": "{{art}}" }` — the node shorthand `PluginPanelView` accepts — is
/// also valid here: a single-key object whose key is neither `root` nor `capsule` IS the
/// root node, the same shorthand rule as the panel and the window. Without this, that shape
/// used to decode to `root: nil, capsule: nil` — silently blank — while still counting as a
/// declared presentation; `PluginSchema` now catches the remaining "declared but nothing to
/// render" case (an explicit `{}` or `{"capsule": []}`).
struct PluginIconView: Codable, Equatable {
    var root: PluginNode?
    var capsule: [PluginNode]?

    init(root: PluginNode? = nil, capsule: [PluginNode]? = nil) {
        self.root = root
        self.capsule = capsule
    }

    private enum CodingKeys: String, CodingKey { case root, capsule }

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        if any.allKeys.count == 1, !["root", "capsule"].contains(any.allKeys[0].stringValue) {
            root = try PluginNode(from: decoder)
            capsule = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(PluginNode.self, forKey: .root)
        capsule = try c.decodeIfPresent([PluginNode].self, forKey: .capsule)
    }
}

/// A widget always needs `family`, so unlike the icon/window views it has no bare-node
/// shorthand — there is no key in a single-key object that could stand in for `family`.
/// `root` stays optional purely so `{ "family": "small" }` with no root decodes (rather than
/// throwing a raw `DecodingError` that would surface as an unreadable `loadErrors` string)
/// and lands as a named `PluginSchema` diagnostic instead.
struct PluginWidgetView: Codable, Equatable {
    var family: PluginWidgetFamily
    /// `bar` only: how many strip icons wide, 1…4. Ignored by the square families.
    var slots: Int
    var root: PluginNode?

    static let defaultSlots = 3
    static let slotRange = 1...4

    init(family: PluginWidgetFamily, slots: Int = PluginWidgetView.defaultSlots, root: PluginNode?) {
        self.family = family
        self.slots = Self.slotRange.contains(slots) ? slots : Self.defaultSlots
        self.root = root
    }

    private enum CodingKeys: String, CodingKey { case family, slots, root }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decode(PluginWidgetFamily.self, forKey: .family)
        let declared = try c.decodeIfPresent(Int.self, forKey: .slots) ?? Self.defaultSlots
        slots = Self.slotRange.contains(declared) ? declared : Self.defaultSlots
        root = try c.decodeIfPresent(PluginNode.self, forKey: .root)
    }
}

/// `"panel": { "list": {...} }` — the panel's body *is* a node, so the whole object decodes
/// as one. `"panel": { "root": {...} }` is accepted too.
struct PluginPanelView: Codable, Equatable {
    var root: PluginNode

    init(root: PluginNode) { self.root = root }

    private struct RootKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RootKey.self)
        if c.allKeys.count == 1, c.allKeys[0].stringValue == "root" {
            root = try c.decode(PluginNode.self, forKey: RootKey(stringValue: "root"))
        } else {
            root = try PluginNode(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: RootKey.self)
        try c.encode(root, forKey: RootKey(stringValue: "root"))
    }
}

/// Accepts the same bare-node shorthand as `PluginPanelView`: a single-key object whose key
/// is neither `width` nor `root` IS the root node (e.g. `"window": { "vstack": [...] } }`).
/// `root` is optional so a window that names neither shape — `{ "width": "wide" }` alone —
/// decodes instead of throwing, and `PluginSchema` reports the missing root by name.
struct PluginWindowView: Codable, Equatable {
    var width: PluginWindowWidth
    var root: PluginNode?

    enum CodingKeys: String, CodingKey { case width, root }

    init(width: PluginWindowWidth = .regular, root: PluginNode?) { self.width = width; self.root = root }

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        if any.allKeys.count == 1, !["width", "root"].contains(any.allKeys[0].stringValue) {
            width = .regular
            root = try PluginNode(from: decoder)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(PluginWindowWidth.self, forKey: .width) ?? .regular
        root = try c.decodeIfPresent(PluginNode.self, forKey: .root)
    }
}

struct PluginViews: Codable, Equatable {
    var icon: PluginIconView?
    var widget: PluginWidgetView?
    var panel: PluginPanelView?
    var window: PluginWindowView?

    init(icon: PluginIconView? = nil, widget: PluginWidgetView? = nil,
         panel: PluginPanelView? = nil, window: PluginWindowView? = nil) {
        self.icon = icon; self.widget = widget; self.panel = panel; self.window = window
    }
}

struct PluginManifest: Codable, Equatable, Identifiable {
    static let defaultIcon = "puzzlepiece.extension"

    var id: String
    var name: String
    var icon: String
    var description: String
    var keywords: [String]
    var inputs: [String]
    /// When true (default) the panel becomes the search scope on ⏎ / Tab.
    var scope: Bool
    var data: PluginDataSource?
    var actions: [String: PluginAction]
    /// Action run on ⏎ when the plugin has no panel — a one-shot command.
    var primaryAction: String?
    var permissions: [String]
    var sample: [String: PluginValue]
    /// What the plugin remembers between runs, with its starting values: a converter's
    /// currencies, a timer's target. Scripts read it as `CD_STATE_<KEY>`; views bind it like
    /// data; the `set` built-in and a script's `"state"` output change it. Kept on disk per
    /// plugin, so it survives a relaunch — a preference nobody asked twice for.
    var state: [String: PluginValue]
    var agent: PluginAgent?
    var views: PluginViews

    init(id: String, name: String, icon: String = PluginManifest.defaultIcon, description: String = "",
         keywords: [String] = [], inputs: [String] = ["query"], scope: Bool = true,
         data: PluginDataSource? = nil, actions: [String: PluginAction] = [:], primaryAction: String? = nil,
         permissions: [String] = [], sample: [String: PluginValue] = [:],
         state: [String: PluginValue] = [:], agent: PluginAgent? = nil,
         views: PluginViews = PluginViews()) {
        self.id = id; self.name = name; self.icon = icon
        self.description = description.isEmpty ? name : description
        self.keywords = keywords; self.inputs = inputs; self.scope = scope
        self.data = data; self.actions = actions; self.primaryAction = primaryAction
        self.permissions = permissions; self.sample = sample; self.state = state
        self.agent = agent; self.views = views
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, keywords, inputs, scope, data, actions, primaryAction
        case permissions, sample, state, agent, views
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? PluginManifest.defaultIcon
        let desc = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        description = desc.isEmpty ? name : desc
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? ["query"]
        scope = try c.decodeIfPresent(Bool.self, forKey: .scope) ?? true
        data = try c.decodeIfPresent(PluginDataSource.self, forKey: .data)
        actions = try c.decodeIfPresent([String: PluginAction].self, forKey: .actions) ?? [:]
        primaryAction = try c.decodeIfPresent(String.self, forKey: .primaryAction)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        sample = try c.decodeIfPresent([String: PluginValue].self, forKey: .sample) ?? [:]
        state = try c.decodeIfPresent([String: PluginValue].self, forKey: .state) ?? [:]
        agent = try c.decodeIfPresent(PluginAgent.self, forKey: .agent)
        views = try c.decodeIfPresent(PluginViews.self, forKey: .views) ?? PluginViews()
    }

    /// The presentations this plugin can be shown in, in canonical order.
    var declaredPresentations: [PluginPresentation] {
        var out: [PluginPresentation] = []
        if views.icon != nil { out.append(.icon) }
        if views.widget != nil { out.append(.widget) }
        if views.panel != nil { out.append(.panel) }
        if views.window != nil { out.append(.window) }
        return out
    }

    /// Every node across every declared view, for validation and binding checks.
    var allNodes: [PluginNode] {
        var roots: [PluginNode] = []
        if let r = views.icon?.root { roots.append(r) }
        roots.append(contentsOf: views.icon?.capsule ?? [])
        if let r = views.widget?.root { roots.append(r) }
        if let r = views.panel?.root { roots.append(r) }
        if let r = views.window?.root { roots.append(r) }
        return roots.flatMap(\.flattened)
    }
}
