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
}
