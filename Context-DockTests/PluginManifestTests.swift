// Context-DockTests
//
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
}
