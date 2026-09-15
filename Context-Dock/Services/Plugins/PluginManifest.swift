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
enum PluginWidgetFamily: String, Codable { case small, medium, large }
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
    /// built-in: `copy`, `open`, `reveal`, `paste`, `push:<view>`.
    var type: String
    var script: String?
    var value: String?
    var app: String?
    var title: String?
    var risk: PluginRisk
    var optimistic: String?
    /// Name of another action that reverses this one.
    var undo: String?
    var success: PluginActionFeedback?

    init(type: String, script: String? = nil, value: String? = nil, app: String? = nil,
         title: String? = nil, risk: PluginRisk = .read, optimistic: String? = nil,
         undo: String? = nil, success: PluginActionFeedback? = nil) {
        self.type = type; self.script = script; self.value = value; self.app = app
        self.title = title; self.risk = risk; self.optimistic = optimistic
        self.undo = undo; self.success = success
    }

    enum CodingKeys: String, CodingKey { case type, script, value, app, title, risk, optimistic, undo, success }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        risk = try c.decodeIfPresent(PluginRisk.self, forKey: .risk) ?? .read
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

struct PluginIconView: Codable, Equatable {
    var root: PluginNode?
    var capsule: [PluginNode]?
}

struct PluginWidgetView: Codable, Equatable {
    var family: PluginWidgetFamily
    var root: PluginNode
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

struct PluginWindowView: Codable, Equatable {
    var width: PluginWindowWidth
    var root: PluginNode

    enum CodingKeys: String, CodingKey { case width, root }

    init(width: PluginWindowWidth = .regular, root: PluginNode) { self.width = width; self.root = root }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(PluginWindowWidth.self, forKey: .width) ?? .regular
        root = try c.decode(PluginNode.self, forKey: .root)
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
    var agent: PluginAgent?
    var views: PluginViews

    init(id: String, name: String, icon: String = PluginManifest.defaultIcon, description: String = "",
         keywords: [String] = [], inputs: [String] = ["query"], scope: Bool = true,
         data: PluginDataSource? = nil, actions: [String: PluginAction] = [:], primaryAction: String? = nil,
         permissions: [String] = [], sample: [String: PluginValue] = [:], agent: PluginAgent? = nil,
         views: PluginViews = PluginViews()) {
        self.id = id; self.name = name; self.icon = icon
        self.description = description.isEmpty ? name : description
        self.keywords = keywords; self.inputs = inputs; self.scope = scope
        self.data = data; self.actions = actions; self.primaryAction = primaryAction
        self.permissions = permissions; self.sample = sample; self.agent = agent; self.views = views
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, keywords, inputs, scope, data, actions, primaryAction
        case permissions, sample, agent, views
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
