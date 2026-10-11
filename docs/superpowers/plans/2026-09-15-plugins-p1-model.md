# Plugins Phase 1 — model, schema, pack, registry, migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the pure-Swift core of the Plugin system — a manifest that decodes and validates, a pack that loads from a folder, a registry that holds enabled plugins, and a converter that turns every existing Global Command and Global Extension into a manifest with zero errors.

**Architecture:** `PluginManifest` is a tolerant Codable over a generic `PluginNode` tree (component name + props + children), so the model never has to know every component; `PluginComponentCatalog` is the single list of known names and `PluginSchema` turns unknowns and broken references into `PluginDiagnostic`s. `PluginPack` reads a folder; `PluginRegistry` composes packs into an enabled set with a test-injectable root; `PluginMigration` is a pure function from the two legacy models to manifests.

**Tech Stack:** Swift 5, Foundation only (no SwiftUI in this phase), swift-testing. New folder `Context-Dock/Services/Plugins/` (auto-added by the synchronized group). Tests flat in `Context-DockTests/`.

**Spec:** `docs/superpowers/specs/2026-09-15-plugins-design.md` §4, §7, §8, §8b, §14

## Global Constraints

- Deployment target macOS 26.1; Swift 5.0; project-wide `@MainActor` default is **not** set — mark test suites `@MainActor` as the existing ones do.
- Build: `./scripts/build-debug.sh` from the worktree root. Tests: `./scripts/test.sh`; confirm the named suites ran (memory `test-script-can-report-stale-green`). The shell cwd reverts between calls — `cd` into the worktree in every command.
- The dev app may be running from another checkout; do not launch from this worktree during P1 (nothing visible changes).
- Stage explicit paths only. Commit after every task.
- No file in this phase imports SwiftUI or AppKit except `PluginMigration.swift` (needs `SystemCommand`, defined in a file that imports Foundation only — fine).
- Names fixed here are used by P2–P8: `PluginManifest`, `PluginNode`, `PluginValue`, `PluginComponentCatalog`, `PluginDiagnostic`, `PluginSchema`, `PluginPack`, `PluginRegistry`, `PluginMigration`, `PluginDataFormat`.

---

## File structure

| File | Responsibility |
|---|---|
| `Context-Dock/Services/Plugins/PluginValue.swift` | JSON-like value enum with `{{binding}}` detection |
| `Context-Dock/Services/Plugins/PluginNode.swift` | one component in a view tree: name, props, children |
| `Context-Dock/Services/Plugins/PluginManifest.swift` | the manifest: identity, data, actions, inputs, agent, views, sample, permissions |
| `Context-Dock/Services/Plugins/PluginComponentCatalog.swift` | the v1 component names and which take children |
| `Context-Dock/Services/Plugins/PluginSchema.swift` | validation → `[PluginDiagnostic]` |
| `Context-Dock/Services/Plugins/PluginPack.swift` | `pack.json` + `plugins/*/manifest.json` from a folder |
| `Context-Dock/Services/Plugins/PluginRegistry.swift` | enabled plugins across packs; state file; reload |
| `Context-Dock/Services/Plugins/PluginMigration.swift` | `SystemCommand` → manifest, `UserGlobalExtension` → manifest |
| `Context-DockTests/PluginManifestTests.swift` | decode shapes |
| `Context-DockTests/PluginSchemaTests.swift` | every diagnostic rule |
| `Context-DockTests/PluginPackTests.swift` | folder loading, versions |
| `Context-DockTests/PluginRegistryTests.swift` | enable state, reload |
| `Context-DockTests/PluginMigrationTests.swift` | every built-in converts; fixtures for user commands and Route B |

---

### Task 1: `PluginValue` and `PluginNode`

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginValue.swift`
- Create: `Context-Dock/Services/Plugins/PluginNode.swift`
- Test: `Context-DockTests/PluginManifestTests.swift`

**Interfaces:**
- Produces: `enum PluginValue: Codable, Equatable { case string(String), number(Double), bool(Bool), null, array([PluginValue]), object([String: PluginValue]) }` with `var bindingKey: String?` (returns `"art"` for `"{{art}}"`, `"item.title"` for `"{{item.title}}"`, nil otherwise) and `var stringValue: String?`.
- Produces: `struct PluginNode: Codable, Equatable { let component: String; let props: [String: PluginValue]; let children: [PluginNode] }`, decoded from the compact JSON form `{ "mediaCard": { "title": "{{room}}" } }` and from the array form `{ "vstack": [ {...}, {...} ] }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginManifestTests.swift
// The manifest is written by people and by models. Every shape here is one the spec shows,
// so a decode failure is a spec failure, not a typo to fix in the fixture.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin manifest")
@MainActor
struct PluginManifestTests {

    @Test("A binding string knows its key; a plain string does not")
    func bindingKeys() {
        #expect(PluginValue.string("{{art}}").bindingKey == "art")
        #expect(PluginValue.string("{{item.title}}").bindingKey == "item.title")
        #expect(PluginValue.string("  {{ room }} ").bindingKey == "room")
        #expect(PluginValue.string("Kitchen").bindingKey == nil)
        #expect(PluginValue.number(3).bindingKey == nil)
    }

    @Test("A node decodes from the compact object form")
    func nodeObjectForm() throws {
        let json = #"{ "mediaCard": { "title": "{{room}}", "transport": "toggle" } }"#
        let node = try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
        #expect(node.component == "mediaCard")
        #expect(node.props["title"] == .string("{{room}}"))
        #expect(node.children.isEmpty)
    }

    @Test("A node decodes from the array form as children")
    func nodeArrayForm() throws {
        let json = #"{ "vstack": [ { "title": "Up next" }, { "divider": {} } ] }"#
        let node = try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
        #expect(node.component == "vstack")
        #expect(node.children.map(\.component) == ["title", "divider"])
    }

    @Test("A node with two keys is not a node")
    func nodeRejectsTwoKeys() {
        let json = #"{ "title": "a", "subtitle": "b" }"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
        }
    }

    @Test("A bare string prop becomes a text child of the component")
    func nodeStringShorthand() throws {
        let json = #"{ "title": "Up next" }"#
        let node = try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
        #expect(node.component == "title")
        #expect(node.props["text"] == .string("Up next"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "PluginManifestTests|error:" | head`
Expected: compile errors naming `PluginValue` / `PluginNode` as undefined.

- [ ] **Step 3: Implement `PluginValue`**

```swift
// Context-Dock/Services/Plugins/PluginValue.swift
// Context-Dock
//
// A JSON value as it appears in a plugin manifest. Strings of the form "{{key}}" are
// bindings into the plugin's data; everything else is literal. The renderer (P2) resolves
// bindings; this type only knows how to recognise one.

import Foundation

enum PluginValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([PluginValue])
    case object([String: PluginValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([PluginValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: PluginValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// "{{ item.title }}" → "item.title". Anything that is not exactly one binding is nil.
    var bindingKey: String? {
        guard case .string(let raw) = self else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("{{"), s.hasSuffix("}}"), s.count > 4 else { return nil }
        let inner = s.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, !inner.contains("{{") else { return nil }
        return inner
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [PluginValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: PluginValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
```

- [ ] **Step 4: Implement `PluginNode`**

```swift
// Context-Dock/Services/Plugins/PluginNode.swift
// Context-Dock
//
// One component in a plugin view tree. The manifest writes a node as a single-key object:
//   { "mediaCard": { "title": "{{room}}" } }     props
//   { "vstack": [ {...}, {...} ] }               children
//   { "title": "Up next" }                       shorthand: props["text"]
// The model does not know which component names exist — PluginComponentCatalog does —
// so a manifest from a newer app still decodes here and fails in PluginSchema with a
// diagnostic that names the component.

import Foundation

struct PluginNode: Codable, Equatable {
    let component: String
    let props: [String: PluginValue]
    let children: [PluginNode]

    init(component: String, props: [String: PluginValue] = [:], children: [PluginNode] = []) {
        self.component = component
        self.props = props
        self.children = children
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A node is one object with exactly one key (the component); found \(c.allKeys.map(\.stringValue).sorted())"))
        }
        component = key.stringValue
        let body = try c.decode(PluginValue.self, forKey: key)
        switch body {
        case .object(let o):
            var props = o
            var kids: [PluginNode] = []
            if let childValues = o["children"]?.arrayValue {
                kids = try childValues.map { try PluginNode(value: $0, path: decoder.codingPath) }
                props["children"] = nil
            }
            self.props = props
            self.children = kids
        case .array(let a):
            props = [:]
            children = try a.map { try PluginNode(value: $0, path: decoder.codingPath) }
        case .string, .number, .bool:
            props = ["text": body]
            children = []
        case .null:
            props = [:]
            children = []
        }
    }

    /// Re-enter decoding for a child that arrived as an already-decoded value.
    init(value: PluginValue, path: [CodingKey]) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(PluginNode.self, from: data)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if children.isEmpty {
            try c.encode(PluginValue.object(props), forKey: AnyKey(stringValue: component))
        } else if props.isEmpty {
            try c.encode(children, forKey: AnyKey(stringValue: component))
        } else {
            var o = props
            o["children"] = .array(try children.map { child in
                let data = try JSONEncoder().encode(child)
                return try JSONDecoder().decode(PluginValue.self, from: data)
            })
            try c.encode(PluginValue.object(o), forKey: AnyKey(stringValue: component))
        }
    }

    /// Every node in the tree, depth first, self included.
    var flattened: [PluginNode] { [self] + children.flatMap(\.flattened) }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "Plugin manifest|passed|failed" | head`
Expected: the five tests in "Plugin manifest" pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginValue.swift Context-Dock/Services/Plugins/PluginNode.swift Context-DockTests/PluginManifestTests.swift
git commit -m "feat(plugins): PluginValue and PluginNode, the view-tree atoms

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `PluginManifest`

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginManifest.swift`
- Modify: `Context-DockTests/PluginManifestTests.swift` (append tests)

**Interfaces:**
- Consumes: `PluginValue`, `PluginNode` from Task 1.
- Produces:

```swift
enum PluginDataFormat: String, Codable { case json, jsonl, lines, raw }
enum PluginScriptType: String, Codable { case bash, applescript, jxa, scriptFile, shortcut, http }
enum PluginRisk: String, Codable { case read, low, medium, high }
enum PluginPresentation: String, Codable, CaseIterable { case icon, widget, panel, window }
enum PluginWidgetFamily: String, Codable { case small, medium, large }
enum PluginWindowWidth: String, Codable { case narrow, regular, wide }

struct PluginDataSource: Codable, Equatable {
    var type: PluginScriptType; var script: String; var format: PluginDataFormat
    var refresh: [PluginPresentation: Int]; var timeout: Int
}
struct PluginAction: Codable, Equatable {
    var type: String                 // script type or built-in: copy, open, reveal, paste, push:<view>, shortcut
    var script: String?; var value: String?; var app: String?; var title: String?
    var risk: PluginRisk; var optimistic: String?; var undo: String?
    var success: PluginActionFeedback?
}
struct PluginActionFeedback: Codable, Equatable { var title: String; var message: String }
struct PluginAgent: Codable, Equatable { var instructions: String; var skills: [String]; var tools: [String]; var inputs: [String] }
struct PluginIconView: Codable, Equatable { var root: PluginNode?; var capsule: [PluginNode]? }
struct PluginWidgetView: Codable, Equatable { var family: PluginWidgetFamily; var root: PluginNode }
struct PluginPanelView: Codable, Equatable { var root: PluginNode }        // decoded from { "list": {...} } etc.
struct PluginWindowView: Codable, Equatable { var width: PluginWindowWidth; var root: PluginNode }
struct PluginViews: Codable, Equatable { var icon: PluginIconView?; var widget: PluginWidgetView?; var panel: PluginPanelView?; var window: PluginWindowView? }

struct PluginManifest: Codable, Equatable, Identifiable {
    var id: String; var name: String; var icon: String; var description: String
    var keywords: [String]; var inputs: [String]; var scope: Bool
    var data: PluginDataSource?; var actions: [String: PluginAction]; var primaryAction: String?
    var permissions: [String]; var sample: [String: PluginValue]; var agent: PluginAgent?
    var views: PluginViews
    var declaredPresentations: [PluginPresentation]
}
```

- [ ] **Step 1: Write the failing tests**

Append to `PluginManifestTests`:

```swift
    static let sonos = """
    {
      "id": "sonos-now-playing", "name": "Sonos", "icon": "hifispeaker.fill",
      "keywords": ["sonos", "music"], "inputs": ["query"],
      "data": { "type": "bash", "script": "data.sh", "refresh": { "icon": 30, "widget": 5 }, "timeout": 5 },
      "actions": {
        "toggle": { "type": "bash", "script": "actions/toggle.sh", "optimistic": "playing" },
        "volume": { "type": "bash", "script": "actions/volume.sh", "risk": "low" },
        "openApp": { "type": "open", "app": "Sonos" }
      },
      "permissions": ["network:local"],
      "sample": { "room": "Kitchen +1", "playing": true, "queue": [] },
      "agent": { "instructions": "Rooms, queue, volume.", "skills": ["skills/sonos/SKILL.md"], "tools": ["toggle", "volume"] },
      "views": {
        "icon":   { "capsule": [ { "thumbnail": "{{art}}" }, { "waveform": "{{playing}}" } ] },
        "widget": { "family": "medium", "root": { "mediaCard": { "title": "{{room}}", "transport": "toggle" } } },
        "panel":  { "list": { "filter": "local", "items": "{{queue}}", "row": { "title": "{{item.title}}" } } },
        "window": { "width": "regular", "root": { "vstack": [ { "title": "Up next" } ] } }
      }
    }
    """

    @Test("The spec's Sonos manifest decodes whole")
    func sonosDecodes() throws {
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(Self.sonos.utf8))
        #expect(m.id == "sonos-now-playing")
        #expect(m.data?.format == .json)                       // default
        #expect(m.data?.refresh[.icon] == 30)
        #expect(m.data?.refresh[.panel] == nil)
        #expect(m.actions["toggle"]?.risk == .read)            // default
        #expect(m.actions["volume"]?.risk == .low)
        #expect(m.actions["openApp"]?.type == "open")
        #expect(m.agent?.tools == ["toggle", "volume"])
        #expect(m.views.widget?.family == .medium)
        #expect(m.views.panel?.root.component == "list")
        #expect(m.views.icon?.capsule?.count == 2)
        #expect(m.views.window?.width == .regular)
        #expect(m.scope == true)                               // default
        #expect(m.declaredPresentations == [.icon, .widget, .panel, .window])
    }

    @Test("A ten-line list plugin needs only id, name and a panel")
    func minimalListPlugin() throws {
        let json = """
        { "id": "ports", "name": "Listening Ports",
          "data": { "type": "bash", "script": "lsof -iTCP -sTCP:LISTEN", "format": "lines" },
          "views": { "panel": { "list": { "items": "{{lines}}" } } } }
        """
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(m.icon == "puzzlepiece.extension")
        #expect(m.keywords.isEmpty)
        #expect(m.inputs == ["query"])
        #expect(m.data?.format == .lines)
        #expect(m.data?.timeout == 5)
        #expect(m.declaredPresentations == [.panel])
    }

    @Test("An agent-only plugin has no views and is still a plugin")
    func agentOnlyPlugin() throws {
        let json = """
        { "id": "editor", "name": "Editor",
          "agent": { "instructions": "Tighten prose.", "skills": ["skills/style/SKILL.md"] } }
        """
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(m.declaredPresentations.isEmpty)
        #expect(m.agent?.tools.isEmpty == true)
    }

    @Test("A manifest round-trips through encode")
    func roundTrip() throws {
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(Self.sonos.utf8))
        let again = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(m))
        #expect(again == m)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "error:" | head -5`
Expected: `PluginManifest` undefined.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/Services/Plugins/PluginManifest.swift
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "Plugin manifest|Test .* (passed|failed)" | head -12`
Expected: all "Plugin manifest" tests pass (9 total).

- [ ] **Step 5: Commit**

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginManifest.swift Context-DockTests/PluginManifestTests.swift
git commit -m "feat(plugins): PluginManifest decodes the spec's shapes with defaults

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `PluginComponentCatalog` and `PluginSchema`

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginComponentCatalog.swift`
- Create: `Context-Dock/Services/Plugins/PluginSchema.swift`
- Test: `Context-DockTests/PluginSchemaTests.swift`

**Interfaces:**
- Consumes: `PluginManifest`, `PluginNode`, `PluginValue`.
- Produces:

```swift
enum PluginComponentCatalog {
    static let v1: Set<String>                      // every component name in spec §6 v1 + "compareRow" + "native"
    static let containers: Set<String>              // may have children
    static func isKnown(_ name: String) -> Bool
}
struct PluginDiagnostic: Equatable, CustomStringConvertible {
    enum Severity: Equatable { case error, warning }
    let severity: Severity; let path: String; let message: String
}
enum PluginSchema {
    static func validate(_ m: PluginManifest) -> [PluginDiagnostic]
    static func hasErrors(_ diagnostics: [PluginDiagnostic]) -> Bool
}
```

Rules (each one test):
1. unknown component → error `views.<p>…: unknown component "x"`.
2. a leaf component with children → error.
3. `{{key}}` whose top-level key is absent from `sample` and is not `item.*` / `lines` / `value` → **warning** (sample may be incomplete; still worth telling the author).
4. a node prop naming an action (`transport`, `action`, `volume`, `submit`, `onTap`, or any prop whose value equals an action name) that is not in `actions` → error.
5. `agent.tools` entry not in `actions` → error.
6. `primaryAction` not in `actions` → error; no panel, no primaryAction, no agent, no widget/icon/window → error "nothing to show or run".
7. `data.type == .http` and no `network:<host>` / `network:local` permission → error; `http` script that is not an `https://` or `http://` URL → error.
8. an action of type `shortcut` and no `system:shortcuts` permission → warning.
9. `push:<view>` targeting a presentation the manifest does not declare → error.
10. `inputs` entry not in the allowed set (`query`, `selection.text`, `selection.files`, `selection.url`, `selection.image`, `clipboard.text`, `clipboard.files`, `clipboard.image`, `clipboard.history`, each optionally suffixed `?`) → error.
11. `data.refresh` value < 1 → error; `timeout` < 1 or > 60 → error.
12. id not matching `^[a-z0-9][a-z0-9-]*$` → error.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginSchemaTests.swift
// A manifest that decodes is not a manifest that works. These pin every rule the schema
// enforces, one test each, so a rule cannot be dropped without a test naming it.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin schema")
@MainActor
struct PluginSchemaTests {

    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private func errors(_ m: PluginManifest) -> [String] {
        PluginSchema.validate(m).filter { $0.severity == .error }.map(\.message)
    }

    private func warnings(_ m: PluginManifest) -> [String] {
        PluginSchema.validate(m).filter { $0.severity == .warning }.map(\.message)
    }

    @Test("The Sonos manifest is clean")
    func sonosIsClean() throws {
        let m = try manifest(PluginManifestTests.sonos)
        #expect(PluginSchema.validate(m).filter { $0.severity == .error }.isEmpty)
    }

    @Test("An unknown component is an error that names it")
    func unknownComponent() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "hologram": {} } } }"#)
        #expect(errors(m).contains { $0.contains("unknown component \"hologram\"") })
    }

    @Test("A leaf may not carry children")
    func leafWithChildren() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "title": [ { "divider": {} } ] } } }"#)
        #expect(errors(m).contains { $0.contains("\"title\" does not take children") })
    }

    @Test("A binding the sample does not have is a warning, not an error")
    func bindingMissingFromSample() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "sample": { "a": 1 }, "views": { "panel": { "title": "{{b}}" } } }"#)
        #expect(errors(m).isEmpty)
        #expect(warnings(m).contains { $0.contains("\"b\" is not in sample") })
    }

    @Test("item.*, lines and value bindings never warn")
    func implicitBindings() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}" } } } } }"#)
        #expect(warnings(m).isEmpty)
    }

    @Test("A view naming an action that does not exist is an error")
    func undeclaredActionInView() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "widget": { "family": "small", "root": { "toggle": { "action": "flip" } } } } }"#)
        #expect(errors(m).contains { $0.contains("action \"flip\" is not declared") })
    }

    @Test("agent.tools must be declared actions")
    func toolsMustBeActions() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "a": { "type": "bash", "script": "true" } }, "agent": { "tools": ["a", "b"] } }"#)
        #expect(errors(m).contains { $0.contains("tool \"b\" is not a declared action") })
    }

    @Test("A plugin with nothing to show or run is an error")
    func nothingToShowOrRun() throws {
        let m = try manifest(#"{ "id": "x", "name": "X" }"#)
        #expect(errors(m).contains { $0.contains("nothing to show or run") })
    }

    @Test("primaryAction alone is enough, and must exist")
    func primaryAction() throws {
        let ok = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "true" } }, "primaryAction": "run" }"#)
        #expect(errors(ok).isEmpty)
        let bad = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "true" } }, "primaryAction": "go" }"#)
        #expect(errors(bad).contains { $0.contains("primaryAction \"go\" is not declared") })
    }

    @Test("http data needs a network permission and a URL")
    func httpNeedsPermission() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "http", "script": "https://api.example.com/x" }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(m).contains { $0.contains("network:api.example.com") })
        let ok = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:api.example.com"], "data": { "type": "http", "script": "https://api.example.com/x" }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(ok).isEmpty)
        let notURL = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:local"], "data": { "type": "http", "script": "curl x" }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(notURL).contains { $0.contains("is not a URL") })
    }

    @Test("push targets a declared presentation")
    func pushTarget() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "more": { "type": "push:window" } }, "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "action": "more" } } } } }"#)
        #expect(errors(m).contains { $0.contains("push:window") && $0.contains("not declared") })
    }

    @Test("inputs come from the fixed set, optional with a question mark")
    func inputsSet() throws {
        let ok = try manifest(#"{ "id": "x", "name": "X", "inputs": ["query", "selection.text?", "clipboard.history"], "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(ok).isEmpty)
        let bad = try manifest(#"{ "id": "x", "name": "X", "inputs": ["mood"], "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(bad).contains { $0.contains("input \"mood\"") })
    }

    @Test("refresh and timeout bounds")
    func bounds() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "bash", "script": "true", "refresh": { "panel": 0 }, "timeout": 61 }, "views": { "panel": { "title": "{{v}}" } } }"#)
        let e = errors(m)
        #expect(e.contains { $0.contains("refresh.panel") })
        #expect(e.contains { $0.contains("timeout") })
    }

    @Test("ids are lowercase slugs")
    func idSlug() throws {
        let m = try manifest(#"{ "id": "My Plugin", "name": "X", "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(m).contains { $0.contains("id") && $0.contains("slug") })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "error:" | head -5`
Expected: `PluginSchema` / `PluginComponentCatalog` undefined.

- [ ] **Step 3: Implement the catalog**

```swift
// Context-Dock/Services/Plugins/PluginComponentCatalog.swift
// Context-Dock
//
// The one list of component names a manifest may use. The renderer (UI/Plugins) implements
// exactly these; adding a component means adding it here first so the schema, the Creator's
// prompt and the renderer agree. Spec §6.

import Foundation

enum PluginComponentCatalog {
    static let containers: Set<String> = [
        "card", "vstack", "hstack", "grid", "section", "footerCard",
        "list", "listDetail", "detail", "form", "actionPanel", "capsule",
    ]

    static let leaves: Set<String> = [
        // header, text
        "header", "title", "subtitle", "body", "caption", "markdown", "stat", "divider",
        // rows
        "row", "checkRow", "eventRow", "activityRow", "fileRow", "compareRow",
        // panel states
        "emptyState", "loading",
        // controls
        "button", "iconButton", "buttonRow", "toggle", "slider", "stateButton",
        // chips
        "tag", "statusBadge", "chipRow", "segment",
        // live
        "progress", "timer", "waveform", "liveText", "pulse",
        // media
        "mediaCard", "thumbnail", "avatar",
        // input
        "textField", "searchField", "dropzone",
        // ai, and the escape hatch for Swift-implemented built-in panels (wifi, bluetooth…)
        "ai", "native",
    ]

    static var v1: Set<String> { containers.union(leaves) }

    static func isKnown(_ name: String) -> Bool { v1.contains(name) }
    static func takesChildren(_ name: String) -> Bool { containers.contains(name) }

    /// Props whose value names an action. Kept here so the schema and the renderer agree
    /// on which strings are references and which are text.
    static let actionProps: Set<String> = ["action", "transport", "volume", "submit", "onTap", "primary", "secondary"]
}
```

- [ ] **Step 4: Implement the schema**

```swift
// Context-Dock/Services/Plugins/PluginSchema.swift
// Context-Dock
//
// What is wrong with a manifest, as a list the Creator can show and a test can assert.
// Errors stop a plugin from installing; warnings do not. Every rule here has a test in
// PluginSchemaTests named after it.

import Foundation

struct PluginDiagnostic: Equatable, CustomStringConvertible {
    enum Severity: Equatable { case error, warning }
    let severity: Severity
    let path: String
    let message: String

    var description: String {
        "\(severity == .error ? "error" : "warning") at \(path): \(message)"
    }
}

enum PluginSchema {
    static let allowedInputs: Set<String> = [
        "query", "selection.text", "selection.files", "selection.url", "selection.image",
        "clipboard.text", "clipboard.files", "clipboard.image", "clipboard.history",
    ]

    static func hasErrors(_ diagnostics: [PluginDiagnostic]) -> Bool {
        diagnostics.contains { $0.severity == .error }
    }

    static func validate(_ m: PluginManifest) -> [PluginDiagnostic] {
        var out: [PluginDiagnostic] = []
        func error(_ path: String, _ message: String) { out.append(.init(severity: .error, path: path, message: message)) }
        func warn(_ path: String, _ message: String) { out.append(.init(severity: .warning, path: path, message: message)) }

        // 12. id
        let slug = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")
        if slug.firstMatch(in: m.id, range: NSRange(m.id.startIndex..., in: m.id)) == nil {
            error("id", "id \"\(m.id)\" must be a lowercase slug (a-z, 0-9, -)")
        }

        // 10. inputs
        for input in m.inputs + (m.agent?.inputs ?? []) {
            let base = input.hasSuffix("?") ? String(input.dropLast()) : input
            if !allowedInputs.contains(base) {
                error("inputs", "input \"\(input)\" is not one of \(allowedInputs.sorted().joined(separator: ", "))")
            }
        }

        // 6. something to show or run
        if m.declaredPresentations.isEmpty && m.primaryAction == nil && m.agent == nil {
            error("views", "nothing to show or run: declare a view, a primaryAction, or an agent")
        }
        if let primary = m.primaryAction, m.actions[primary] == nil {
            error("primaryAction", "primaryAction \"\(primary)\" is not declared in actions")
        }

        // 5. agent.tools
        for tool in m.agent?.tools ?? [] where m.actions[tool] == nil {
            error("agent.tools", "tool \"\(tool)\" is not a declared action")
        }

        // 7, 11. data
        if let data = m.data {
            if data.type == .http {
                let url = URL(string: data.script)
                if let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host {
                    let needed = "network:\(host)"
                    if !m.permissions.contains(needed) && !m.permissions.contains("network:local") {
                        error("permissions", "http data needs permission \"\(needed)\"")
                    }
                } else {
                    error("data.script", "http data script \"\(data.script)\" is not a URL")
                }
            }
            for (presentation, seconds) in data.refresh where seconds < 1 {
                error("data.refresh.\(presentation.rawValue)", "refresh.\(presentation.rawValue) must be at least 1 second")
            }
            if data.timeout < 1 || data.timeout > 60 {
                error("data.timeout", "timeout must be between 1 and 60 seconds")
            }
        }

        // 8, 9. actions
        for (name, action) in m.actions {
            if action.type == "shortcut" && !m.permissions.contains("system:shortcuts") {
                warn("actions.\(name)", "a shortcut action usually needs permission \"system:shortcuts\"")
            }
            if let target = action.pushTarget {
                if let presentation = PluginPresentation(rawValue: target) {
                    if !m.declaredPresentations.contains(presentation) {
                        error("actions.\(name)", "push:\(target) targets a view this plugin has not declared")
                    }
                } else {
                    error("actions.\(name)", "push:\(target) is not a presentation")
                }
            }
            if let undo = action.undo, m.actions[undo] == nil {
                error("actions.\(name)", "undo \"\(undo)\" is not a declared action")
            }
        }

        // 1–4. views
        let sampleKeys = Set(m.sample.keys)
        for node in m.allNodes {
            let path = "views.\(node.component)"
            if !PluginComponentCatalog.isKnown(node.component) {
                error(path, "unknown component \"\(node.component)\"")
                continue
            }
            if !node.children.isEmpty && !PluginComponentCatalog.takesChildren(node.component) {
                error(path, "\"\(node.component)\" does not take children")
            }
            for (prop, value) in node.props {
                if let key = value.bindingKey {
                    let top = String(key.split(separator: ".").first ?? Substring(key))
                    let implicit = top == "item" || top == "lines" || top == "value"
                    if !implicit && !sampleKeys.contains(top) {
                        warn("\(path).\(prop)", "binding \"\(top)\" is not in sample; the preview will show it empty")
                    }
                } else if PluginComponentCatalog.actionProps.contains(prop), let name = value.stringValue {
                    if m.actions[name] == nil {
                        error("\(path).\(prop)", "action \"\(name)\" is not declared")
                    }
                }
            }
        }

        return out
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "Plugin schema|Test .* (passed|failed)" | head -20`
Expected: all 14 "Plugin schema" tests pass. If `sonosIsClean` fails on `transport: "toggle"`, the fixture's action exists — check `actionProps` contains `transport`.

- [ ] **Step 6: Commit**

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginComponentCatalog.swift Context-Dock/Services/Plugins/PluginSchema.swift Context-DockTests/PluginSchemaTests.swift
git commit -m "feat(plugins): the component catalog and the schema that names what is wrong

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `PluginPack`

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginPack.swift`
- Test: `Context-DockTests/PluginPackTests.swift`

**Interfaces:**
- Consumes: `PluginManifest`, `PluginSchema`.
- Produces:

```swift
struct PluginPackInfo: Codable, Equatable { var id: String; var name: String; var author: String; var version: String; var icon: String; var description: String; var permissions: [String]; var minAppVersion: String? }
struct PluginPack: Equatable {
    let info: PluginPackInfo; let folder: URL
    let plugins: [PluginManifest]                       // decoded, in folder order
    let diagnostics: [String: [PluginDiagnostic]]       // by plugin id
    let loadErrors: [String]                            // files that would not decode, with the reason
    static func load(from folder: URL) throws -> PluginPack
    func isNewer(than other: PluginPack) -> Bool        // semver on info.version
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult
}
enum PluginPackError: Error, Equatable { case missingPackJSON(URL), badPackJSON(URL, String) }
```

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginPackTests.swift
// A pack is a folder. These build folders in a temporary directory and load them, so the
// layout the spec draws is the layout the loader reads.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin pack")
@MainActor
struct PluginPackTests {

    private func makePack(_ name: String, version: String = "1.0.0", plugins: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        let pack = """
        { "id": "\(name)", "name": "\(name.capitalized)", "author": "test", "version": "\(version)", "icon": "puzzlepiece", "description": "d" }
        """
        try pack.write(to: folder.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
        for (id, json) in plugins {
            let dir = folder.appendingPathComponent("plugins/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        return folder
    }

    @Test("A pack folder loads its plugins and validates each")
    func loadsPlugins() throws {
        let folder = try makePack("sonos", plugins: [
            "now-playing": PluginManifestTests.sonos,
            "broken": #"{ "id": "broken", "name": "B", "views": { "panel": { "hologram": {} } } }"#,
        ])
        let pack = try PluginPack.load(from: folder)
        #expect(pack.info.id == "sonos")
        #expect(pack.plugins.map(\.id).sorted() == ["broken", "sonos-now-playing"])
        #expect(pack.diagnostics["sonos-now-playing"]?.filter { $0.severity == .error }.isEmpty == true)
        #expect(pack.diagnostics["broken"]?.contains { $0.message.contains("hologram") } == true)
        #expect(pack.loadErrors.isEmpty)
    }

    @Test("A manifest that will not decode is reported, not fatal")
    func undecodableManifestIsReported() throws {
        let folder = try makePack("mixed", plugins: [
            "ok": #"{ "id": "ok", "name": "OK", "views": { "panel": { "title": "hi" } } }"#,
            "junk": "not json",
        ])
        let pack = try PluginPack.load(from: folder)
        #expect(pack.plugins.map(\.id) == ["ok"])
        #expect(pack.loadErrors.count == 1)
        #expect(pack.loadErrors[0].contains("junk"))
    }

    @Test("A folder without pack.json is not a pack")
    func missingPackJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nopack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: PluginPackError.missingPackJSON(folder)) {
            try PluginPack.load(from: folder)
        }
    }

    @Test("Versions compare as semver, not as strings")
    func semver() {
        #expect(PluginPack.compareVersions("1.10.0", "1.9.0") == .orderedDescending)
        #expect(PluginPack.compareVersions("1.0", "1.0.0") == .orderedSame)
        #expect(PluginPack.compareVersions("2", "1.99.99") == .orderedDescending)
        #expect(PluginPack.compareVersions("0.9", "1.0") == .orderedAscending)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "error:" | head -5`
Expected: `PluginPack` undefined.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/Services/Plugins/PluginPack.swift
// Context-Dock
//
// A pack is a folder:
//   <pack>/pack.json
//   <pack>/plugins/<id>/manifest.json   (+ scripts, skills beside it)
// Loading never throws for one bad plugin — that plugin is reported and the rest load.
// Only a missing or unreadable pack.json makes the folder not a pack.

import Foundation

struct PluginPackInfo: Codable, Equatable {
    var id: String
    var name: String
    var author: String
    var version: String
    var icon: String
    var description: String
    var permissions: [String]
    var minAppVersion: String?

    enum CodingKeys: String, CodingKey { case id, name, author, version, icon, description, permissions, minAppVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? PluginManifest.defaultIcon
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
    }
}

enum PluginPackError: Error, Equatable {
    case missingPackJSON(URL)
    case badPackJSON(URL, String)
}

struct PluginPack: Equatable {
    let info: PluginPackInfo
    let folder: URL
    let plugins: [PluginManifest]
    let diagnostics: [String: [PluginDiagnostic]]
    let loadErrors: [String]

    static func load(from folder: URL) throws -> PluginPack {
        let packURL = folder.appendingPathComponent("pack.json")
        guard FileManager.default.fileExists(atPath: packURL.path) else {
            throw PluginPackError.missingPackJSON(folder)
        }
        let info: PluginPackInfo
        do {
            info = try JSONDecoder().decode(PluginPackInfo.self, from: Data(contentsOf: packURL))
        } catch {
            throw PluginPackError.badPackJSON(packURL, String(describing: error))
        }

        var plugins: [PluginManifest] = []
        var diagnostics: [String: [PluginDiagnostic]] = [:]
        var loadErrors: [String] = []

        let pluginsDir = folder.appendingPathComponent("plugins")
        let entries = (try? FileManager.default.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]))?
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for dir in entries {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
                plugins.append(manifest)
                diagnostics[manifest.id] = PluginSchema.validate(manifest)
            } catch {
                loadErrors.append("\(dir.lastPathComponent)/manifest.json: \(error.localizedDescription)")
            }
        }

        return PluginPack(info: info, folder: folder, plugins: plugins, diagnostics: diagnostics, loadErrors: loadErrors)
    }

    func isNewer(than other: PluginPack) -> Bool {
        Self.compareVersions(info.version, other.info.version) == .orderedDescending
    }

    /// "1.10.0" > "1.9.0"; "1.0" == "1.0.0"; missing components read as 0.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        var x = parts(a), y = parts(b)
        let n = max(x.count, y.count)
        x += Array(repeating: 0, count: n - x.count)
        y += Array(repeating: 0, count: n - y.count)
        for (p, q) in zip(x, y) where p != q { return p < q ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "Plugin pack|Test .* (passed|failed)" | head`
Expected: 4 "Plugin pack" tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginPack.swift Context-DockTests/PluginPackTests.swift
git commit -m "feat(plugins): PluginPack loads a folder and reports each plugin's diagnostics

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `PluginRegistry`

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginRegistry.swift`
- Test: `Context-DockTests/PluginRegistryTests.swift`

**Interfaces:**
- Consumes: `PluginPack`, `PluginManifest`, `PluginSchema`.
- Produces:

```swift
struct InstalledPlugin: Identifiable, Equatable { let manifest: PluginManifest; let packID: String; let folder: URL; var isEnabled: Bool; var hasErrors: Bool; var id: String { manifest.id } }
@MainActor final class PluginRegistry: ObservableObject {
    static let shared: PluginRegistry                        // roots: bundle Essentials (if present) + ~/Library/Application Support/Context-Dock/plugins
    init(roots: [URL], stateFile: URL)
    @Published private(set) var packs: [PluginPack]
    @Published private(set) var plugins: [InstalledPlugin]
    var enabledPlugins: [InstalledPlugin]                    // enabled and error-free
    func reload()
    func setEnabled(_ enabled: Bool, pluginID: String)
    func plugin(id: String) -> InstalledPlugin?
    func folder(forPlugin id: String) -> URL?                // <pack>/plugins/<dir> that holds it
}
```

State file: JSON `{ "disabled": ["id", ...] }` — enabled is the default so a fresh install shows everything, and a plugin that fails to load can't be "enabled" into existence.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginRegistryTests.swift
// The registry is the one list every host reads. Enabled is the default; disabling is
// remembered; a plugin with schema errors is loaded (so Settings can show why) but never
// enabled.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin registry")
@MainActor
struct PluginRegistryTests {

    private func root(with packs: [String: [String: String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
        for (packName, plugins) in packs {
            let folder = root.appendingPathComponent(packName)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("plugins"), withIntermediateDirectories: true)
            try #"{ "id": "\#(packName)", "version": "1.0.0" }"#.write(to: folder.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
            for (id, json) in plugins {
                let dir = folder.appendingPathComponent("plugins/\(id)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try json.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    private let ok = #"{ "id": "ok", "name": "OK", "views": { "panel": { "title": "hi" } } }"#
    private let broken = #"{ "id": "broken", "name": "B", "views": { "panel": { "hologram": {} } } }"#

    @Test("Everything loads; only error-free plugins are enabled")
    func loadsAndFiltersErrors() throws {
        let r = try root(with: ["one": ["ok": ok, "broken": broken]])
        let state = r.appendingPathComponent("state.json")
        let registry = PluginRegistry(roots: [r], stateFile: state)
        #expect(registry.plugins.map(\.id).sorted() == ["broken", "ok"])
        #expect(registry.enabledPlugins.map(\.id) == ["ok"])
        #expect(registry.plugin(id: "broken")?.hasErrors == true)
    }

    @Test("Disabling is remembered across a reload and a new registry")
    func disableIsPersistent() throws {
        let r = try root(with: ["one": ["ok": ok]])
        let state = r.appendingPathComponent("state.json")
        let registry = PluginRegistry(roots: [r], stateFile: state)
        registry.setEnabled(false, pluginID: "ok")
        #expect(registry.enabledPlugins.isEmpty)
        registry.reload()
        #expect(registry.enabledPlugins.isEmpty)
        let fresh = PluginRegistry(roots: [r], stateFile: state)
        #expect(fresh.enabledPlugins.isEmpty)
        fresh.setEnabled(true, pluginID: "ok")
        #expect(fresh.enabledPlugins.map(\.id) == ["ok"])
    }

    @Test("Two roots merge; the same plugin id in two packs keeps the newer pack's copy")
    func rootsMergeNewestWins() throws {
        let a = try root(with: ["essentials": ["ok": ok]])
        let b = try root(with: ["essentials": ["ok": #"{ "id": "ok", "name": "OK v2", "views": { "panel": { "title": "hi" } } }"#]])
        try #"{ "id": "essentials", "version": "2.0.0" }"#.write(to: b.appendingPathComponent("essentials/pack.json"), atomically: true, encoding: .utf8)
        let registry = PluginRegistry(roots: [a, b], stateFile: a.appendingPathComponent("state.json"))
        #expect(registry.plugins.count == 1)
        #expect(registry.plugin(id: "ok")?.manifest.name == "OK v2")
    }

    @Test("The folder of a plugin is the directory holding its manifest")
    func folderLookup() throws {
        let r = try root(with: ["one": ["ok": ok]])
        let registry = PluginRegistry(roots: [r], stateFile: r.appendingPathComponent("state.json"))
        #expect(registry.folder(forPlugin: "ok")?.lastPathComponent == "ok")
    }

    @Test("A missing root is not an error")
    func missingRoot() {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        let registry = PluginRegistry(roots: [r], stateFile: r.appendingPathComponent("state.json"))
        #expect(registry.plugins.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "error:" | head -5`
Expected: `PluginRegistry` undefined.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/Services/Plugins/PluginRegistry.swift
// Context-Dock
//
// Every installed plugin, from every pack root, in one list. Roots are searched in order
// and a later root's newer pack replaces an earlier one's plugin of the same id — that is
// how a user-installed update shadows the bundled Essentials copy. Enabled is the default;
// the state file remembers only what the user turned off.

import Foundation
import Combine

struct InstalledPlugin: Identifiable, Equatable {
    let manifest: PluginManifest
    let packID: String
    let folder: URL
    var isEnabled: Bool
    var hasErrors: Bool

    var id: String { manifest.id }
}

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared: PluginRegistry = {
        var roots: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Essentials", withExtension: nil, subdirectory: "Plugins") {
            roots.append(bundled.deletingLastPathComponent())
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/plugins", isDirectory: true)
        roots.append(support)
        return PluginRegistry(roots: roots, stateFile: support.appendingPathComponent("state.json"))
    }()

    private struct State: Codable { var disabled: Set<String> = [] }

    let roots: [URL]
    let stateFile: URL
    private var state = State()

    @Published private(set) var packs: [PluginPack] = []
    @Published private(set) var plugins: [InstalledPlugin] = []

    init(roots: [URL], stateFile: URL) {
        self.roots = roots
        self.stateFile = stateFile
        reload()
    }

    var enabledPlugins: [InstalledPlugin] {
        plugins.filter { $0.isEnabled && !$0.hasErrors }
    }

    func plugin(id: String) -> InstalledPlugin? {
        plugins.first { $0.id == id }
    }

    func folder(forPlugin id: String) -> URL? {
        plugin(id: id)?.folder
    }

    func reload() {
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()

        var packsByID: [String: PluginPack] = [:]
        var order: [String] = []
        for root in roots {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for folder in folders {
                guard let pack = try? PluginPack.load(from: folder) else { continue }
                if let existing = packsByID[pack.info.id], !pack.isNewer(than: existing) { continue }
                if packsByID[pack.info.id] == nil { order.append(pack.info.id) }
                packsByID[pack.info.id] = pack
            }
        }
        packs = order.compactMap { packsByID[$0] }

        var seen: Set<String> = []
        var installed: [InstalledPlugin] = []
        for pack in packs {
            for manifest in pack.plugins where !seen.contains(manifest.id) {
                seen.insert(manifest.id)
                let folder = Self.folder(for: manifest, in: pack)
                let errors = PluginSchema.hasErrors(pack.diagnostics[manifest.id] ?? [])
                installed.append(InstalledPlugin(
                    manifest: manifest, packID: pack.info.id, folder: folder,
                    isEnabled: !state.disabled.contains(manifest.id), hasErrors: errors))
            }
        }
        plugins = installed
    }

    func setEnabled(_ enabled: Bool, pluginID: String) {
        if enabled { state.disabled.remove(pluginID) } else { state.disabled.insert(pluginID) }
        if let idx = plugins.firstIndex(where: { $0.id == pluginID }) {
            plugins[idx].isEnabled = enabled
        }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    /// The plugin directory is the one under plugins/ whose manifest.json carries this id.
    private static func folder(for manifest: PluginManifest, in pack: PluginPack) -> URL {
        let pluginsDir = pack.folder.appendingPathComponent("plugins")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let url = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: url),
               let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
               m.id == manifest.id {
                return dir
            }
        }
        return pluginsDir.appendingPathComponent(manifest.id)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "Plugin registry|Test .* (passed|failed)" | head`
Expected: 5 "Plugin registry" tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginRegistry.swift Context-DockTests/PluginRegistryTests.swift
git commit -m "feat(plugins): PluginRegistry merges pack roots; enabled by default, errors never enabled

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `PluginMigration` — Global Commands and Global Extensions become manifests

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginMigration.swift`
- Test: `Context-DockTests/PluginMigrationTests.swift`

**Interfaces:**
- Consumes: `SystemCommand` (`Services/SystemCommands.swift`), `SystemCommandsRegistry.defaults`, `UserGlobalExtension` (`Services/UserGlobalExtensionStore.swift`), `PluginManifest`, `PluginSchema`.
- Produces:

```swift
enum PluginMigration {
    static func manifest(from command: SystemCommand) -> PluginManifest
    static func manifest(from ext: UserGlobalExtension) -> PluginManifest
    static func slug(_ name: String) -> String                 // "Wi-Fi" → "wi-fi", "Restart..." → "restart"
    static func nativeProvider(of command: SystemCommand) -> String?   // "wifi" | "bluetooth" | "windows" | "notepad" | "processes" | nil
}
```

Mapping rules (from `SystemCommands.swift` and `CustomListProviderService.swift`):

| Legacy | Manifest |
|---|---|
| keywords with prefixes `provider:`, `refresh:`, `query:`, `presets:` | stripped from `keywords`; consumed below |
| `provider:wifi/bluetooth/windows/notepad/processes` | `views.panel = { "native": { "provider": "<name>" } }`; no `data` (Swift panel stays, P4 renders it via `native`) |
| `provider:custom` | `data = { type: scriptType, script, format: .jsonl, refresh: { panel: N } }`; `views.panel = { "list": { "filter": query:live ? "query" : "local", "items": "{{lines}}", "row": { "title": "{{item.title}}", "subtitle": "{{item.subtitle}}", "badge": "{{item.badge}}", "icon": "{{item.icon}}", "action": "rowAction" } } }`; if `undoScript` non-empty → `actions.rowAction = { type: undoScriptType, script: undoScript }` |
| `interaction == slider` | `data = { type: scriptType, script: valueScript, format: .raw }` (if valueScript non-empty); `actions.set = { type: scriptType, script }`; `views.panel = { "slider": { "min", "max", "step", "value": "{{value}}", "action": "set" } }`; `views.widget = { family: .small, root: same slider }` |
| `interaction == toggle` | same with `toggle` |
| one-shot (none of the above) | `actions.run = { type: scriptType, script, risk: destructive ? .medium : .low, success: (successTitle, successMessage) if any, undo: "undo" if undoScript }`; `actions.undo` when present; `primaryAction = "run"`; no views |
| destructive = name in {"Sleep", "Restart...", "Shut Down...", "Empty Trash"} | `risk = .medium` (approval on first run) |
| `isEnabled == false` | returned manifest is unchanged; the caller records the id as disabled in the registry state |
| `scriptType` | normalised through `SystemCommandActionType.normalize`: `url`/`file` become `actions.run = { type: "open", value: script }`; `aiPrompt` becomes `views.window = { root: { "ai": { "prompt": script } } }` with `agent.instructions = script` |
| Route B `rowsScript` | `data = { type, script, format: .lines }`; `views.panel.list` with `row.title = "{{item.title}}"`, `row.subtitle = "{{item.subtitle}}"` (the runner splits `Title \| subtitle` for `.lines`, P3) |
| Route B `rowActionScript` | `actions.rowAction` |
| Route B `aiEnabled` | `views.window = { width: .regular, root: { "vstack": [ panel list, { "ai": { "prompt": aiPrompt } } ] } }`, `agent = { instructions: aiPrompt }` |

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginMigrationTests.swift
// Nothing a user built may be lost in the move. Every built-in converts with zero errors;
// a representative of each legacy shape converts to the manifest the table in the plan
// describes; and keywords the user typed survive while the meta keywords do not.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin migration")
@MainActor
struct PluginMigrationTests {

    @Test("Every built-in Global Command converts with zero schema errors")
    func allBuiltInsConvert() {
        for command in SystemCommandsRegistry.defaults {
            let m = PluginMigration.manifest(from: command)
            let errors = PluginSchema.validate(m).filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(command.name): \(errors.map(\.message))")
            #expect(m.name == command.name)
            #expect(m.icon == command.icon)
        }
    }

    @Test("Names become slugs")
    func slugs() {
        #expect(PluginMigration.slug("Wi-Fi") == "wi-fi")
        #expect(PluginMigration.slug("Restart...") == "restart")
        #expect(PluginMigration.slug("Top CPU") == "top-cpu")
        #expect(PluginMigration.slug("  Keep   Awake ") == "keep-awake")
    }

    @Test("Meta keywords are consumed; user keywords survive")
    func keywordsSurvive() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Top Memory" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.keywords.contains("ram"))
        #expect(!m.keywords.contains { $0.hasPrefix("provider:") || $0.hasPrefix("refresh:") })
    }

    @Test("A provider:custom command becomes a jsonl list with its refresh")
    func customListBecomesList() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Top Memory" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.data?.format == .jsonl)
        #expect(m.data?.refresh[.panel] == 3)
        #expect(m.views.panel?.root.component == "list")
        #expect(m.views.panel?.root.props["filter"] == .string("local"))
    }

    @Test("query:live makes the list filter by query")
    func queryLive() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Scratch Notes" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.views.panel?.root.props["filter"] == .string("query"))
    }

    @Test("A native provider keeps its Swift panel through the native component")
    func nativeProvider() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Wi-Fi" })
        #expect(PluginMigration.nativeProvider(of: cmd) == "wifi")
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.views.panel?.root.component == "native")
        #expect(m.views.panel?.root.props["provider"] == .string("wifi"))
        #expect(m.data == nil)
    }

    @Test("A slider command becomes a slider panel and a small widget over a raw value script")
    func sliderCommand() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Volume" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.views.widget?.family == .small)
        #expect(m.views.widget?.root.component == "slider")
        #expect(m.views.panel?.root.component == "slider")
        #expect(m.views.panel?.root.props["action"] == .string("set"))
        #expect(m.actions["set"] != nil)
        if !cmd.valueScript.isEmpty { #expect(m.data?.format == .raw) }
    }

    @Test("A one-shot command becomes a primaryAction; destructive ones carry medium risk")
    func oneShot() throws {
        let trash = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Empty Trash" })
        let m = PluginMigration.manifest(from: trash)
        #expect(m.declaredPresentations.isEmpty)
        #expect(m.primaryAction == "run")
        #expect(m.actions["run"]?.risk == .medium)
        #expect(m.actions["run"]?.type == "applescript")
    }

    @Test("Undo becomes a second action the first one points at")
    func undoPreserved() {
        let cmd = SystemCommand(name: "Hide Desktop", icon: "eye.slash", keywords: ["desktop"],
                                scriptType: "bash", script: "defaults write com.apple.finder CreateDesktop false; killall Finder",
                                successTitle: "Desktop hidden", successMessage: "Icons are gone",
                                undoTitle: "Show Desktop", undoScriptType: "bash",
                                undoScript: "defaults write com.apple.finder CreateDesktop true; killall Finder")
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.actions["run"]?.undo == "undo")
        #expect(m.actions["undo"]?.title == "Show Desktop")
        #expect(m.actions["run"]?.success?.title == "Desktop hidden")
    }

    @Test("URL and file commands become open actions")
    func urlBecomesOpen() {
        let cmd = SystemCommand(name: "Bluetooth Settings", icon: "gear", keywords: ["bt"],
                                scriptType: "url", script: "x-apple.systempreferences:com.apple.BluetoothSettings")
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.actions["run"]?.type == "open")
        #expect(m.actions["run"]?.value == "x-apple.systempreferences:com.apple.BluetoothSettings")
    }

    @Test("A Global Extension becomes a lines list; AI on makes it a window with an agent")
    func routeB() {
        let ext = UserGlobalExtension(name: "Branches", icon: "arrow.triangle.branch", keywords: ["git"],
                                      rowsScript: "git branch --format='%(refname:short) | %(upstream:short)'",
                                      rowActionScript: "git switch \"$CD_ROW_TITLE\"",
                                      aiEnabled: true, aiPrompt: "You help with git branches.")
        let m = PluginMigration.manifest(from: ext)
        #expect(m.id == "branches")
        #expect(m.data?.format == .lines)
        #expect(m.views.panel?.root.component == "list")
        #expect(m.actions["rowAction"]?.script == "git switch \"$CD_ROW_TITLE\"")
        #expect(m.views.window?.root.flattened.contains { $0.component == "ai" } == true)
        #expect(m.agent?.instructions == "You help with git branches.")
        #expect(PluginSchema.validate(m).filter { $0.severity == .error }.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "error:" | head -5`
Expected: `PluginMigration` undefined.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/Services/Plugins/PluginMigration.swift
// Context-Dock
//
// Global Commands (SystemCommand) and Global Extensions (UserGlobalExtension) become
// plugin manifests. Pure: no I/O, no registry. The rules are the table in
// docs/superpowers/plans/2026-09-15-plugins-p1-model.md Task 6; each row has a test.
//
// Scripts are never rewritten. A raw-value script stays raw (format .raw), a JSONL rows
// script stays JSONL, a "Title | subtitle" script stays lines — the runner (P3) knows all
// four formats so the user's script keeps working unchanged.

import Foundation

enum PluginMigration {

    private static let destructiveNames: Set<String> = ["Sleep", "Restart...", "Shut Down...", "Empty Trash"]
    private static let metaPrefixes = ["provider:", "refresh:", "query:", "presets:"]
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

    private static func scriptType(_ raw: String) -> PluginScriptType {
        switch SystemCommandActionType.normalize(raw) {
        case .bash: return .bash
        case .applescript: return .applescript
        case .jxa: return .jxa
        case .scriptFile: return .scriptFile
        case .url, .file, .aiPrompt: return .bash   // handled before this is consulted
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
                m.actions["rowAction"] = PluginAction(type: command.undoScriptType, script: command.undoScript, risk: .low)
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
            m.actions["set"] = PluginAction(type: command.scriptType, script: command.script, risk: .low)
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
            var run = PluginAction(type: command.scriptType, script: command.script,
                                   risk: destructiveNames.contains(command.name) ? .medium : .low)
            if !command.successTitle.isEmpty || !command.successMessage.isEmpty {
                run.success = PluginActionFeedback(title: command.successTitle, message: command.successMessage)
            }
            if command.hasUndoAction {
                m.actions["undo"] = PluginAction(type: command.undoScriptType, script: command.undoScript,
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
            m.actions["rowAction"] = PluginAction(type: ext.rowActionScriptType, script: ext.rowActionScript, risk: .low)
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && ./scripts/test.sh 2>&1 | grep -E "Plugin migration|Test .* (passed|failed)" | head -14`
Expected: all 11 "Plugin migration" tests pass. If `allBuiltInsConvert` fails, the failing command's name and diagnostics are in the message — extend the mapping, do not weaken the schema.

- [ ] **Step 5: Run the whole suite and confirm by name**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && pwd && ./scripts/test.sh 2>&1 | grep -E "Suite \"Plugin|TEST (SUCCEEDED|FAILED)|passed, .* failed" | head`
Expected: the five Plugin suites listed as passed; overall count unchanged apart from the additions (the one pre-existing github contract failure may remain — memory `github-capability-test-fails-on-a-default-machine`).

- [ ] **Step 6: Commit**

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginMigration.swift Context-DockTests/PluginMigrationTests.swift
git commit -m "feat(plugins): every Global Command and Global Extension converts to a manifest

Scripts are never rewritten: raw, jsonl and lines formats carry the legacy
output shapes so a user's script keeps working unchanged.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** §4 (Pack → Plugin → views, agent) → Tasks 2, 4; §7 manifest → Task 2; §8 inputs set → Task 3 rule 10; §8b agent block → Tasks 2, 3 rule 5; §11.3 implied permissions → Task 3 rule 7; §14 migration → Task 6; §16 defaults (families, `http` GET, `scope` default) → Tasks 2, 3. Folder watch (spec §12 "file-watches") is deliberately P6/P7 — `reload()` is the seam.
- **Placeholder scan:** none; every step has code or an exact command.
- **Type consistency:** `PluginNode(component:props:children:)`, `PluginPanelView(root:)`, `PluginWidgetView(family:root:)`, `PluginWindowView(width:root:)`, `PluginDataSource(type:script:format:refresh:timeout:)`, `PluginAction(type:script:value:app:title:risk:optimistic:undo:success:)` used identically in Tasks 2, 3 and 6. `PluginSchema.hasErrors` used by Task 5. `PluginManifestTests.sonos` is `static` so Tasks 3 and 4 can reuse it.
