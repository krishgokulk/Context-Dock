// Context-DockTests/PluginNodePropsTests.swift
// A list's `row` is a template: instantiated per item, never drawn once. It lives in props,
// not children — but the schema still has to see inside it, which is #27. These pin both
// spellings a manifest uses for such a prop, and pin that `children` is unchanged.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin node props")
@MainActor
struct PluginNodePropsTests {

    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test("A prop whose key names a component is that component with those props")
    func propKeyNamesTheComponent() throws {
        let n = try node(#"{ "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "action": "open" } } }"#)
        let row = try #require(n.nodeProps["row"])
        #expect(row.component == "row")
        #expect(row.props["title"] == .string("{{item.title}}"))
        #expect(row.props["action"] == .string("open"))
    }

    @Test("A prop whose value is itself a node is that node, when the key names no component")
    func propValueIsANode() throws {
        let n = try node(#"{ "row": { "leading": { "thumbnail": { "src": "{{item.art}}" } } } }"#)
        let leading = try #require(n.nodeProps["leading"])
        #expect(leading.component == "thumbnail")
        #expect(leading.props["src"] == .string("{{item.art}}"))
    }

    @Test("A prop key that names a component wins over the node-valued spelling")
    func propKeyBeatsInnerNode() throws {
        // `detail` is itself a component, so this is a detail holding markdown — not a
        // markdown node. Otherwise the prop would change meaning as soon as a second key
        // (`metadata`) was written beside the first.
        let n = try node(#"{ "listDetail": { "detail": { "markdown": "{{item.body}}" } } }"#)
        let detail = try #require(n.nodeProps["detail"])
        #expect(detail.component == "detail")
        #expect(detail.props["markdown"] == .string("{{item.body}}"))
    }

    @Test("An empty object under an unknown name is a component nobody knows, not data")
    func emptyObjectUnderUnknownNameIsAComponent() throws {
        let n = try node(#"{ "row": { "hologram": {} } }"#)
        let row = try #require(n.nodeProps["hologram"])
        #expect(row.component == "hologram")
        #expect(PluginComponentCatalog.isKnown("hologram") == false)
    }

    @Test("An object prop that is neither shape stays ordinary data")
    func ordinaryObjectPropIsNotANode() throws {
        let n = try node(#"{ "row": { "trailing": { "kind": "chip", "label": "4k" } } }"#)
        #expect(n.nodeProps["trailing"] == nil)
        #expect(n.props["trailing"]?.objectValue?["label"] == .string("4k"))
    }

    @Test("A string prop is never a node")
    func stringPropIsNotANode() throws {
        let n = try node(#"{ "list": { "filter": "local", "items": "{{lines}}" } }"#)
        #expect(n.nodeProps.isEmpty)
    }

    @Test("children keeps its exact meaning: a node with only node-props has no children")
    func childrenUnchanged() throws {
        let n = try node(#"{ "list": { "row": { "title": "a" } } }"#)
        #expect(n.children.isEmpty)
        let stack = try node(#"{ "vstack": [ { "title": "a" }, { "divider": {} } ] }"#)
        #expect(stack.children.map(\.component) == ["title", "divider"])
        #expect(stack.nodeProps.isEmpty)
    }

    @Test("flattened walks node props as well as children, so the schema reaches them")
    func flattenedIncludesNodeProps() throws {
        let n = try node(#"{ "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}" } } }"#)
        #expect(n.flattened.map(\.component).sorted() == ["list", "row"])
    }

    @Test("A node prop round-trips through encode")
    func roundTrip() throws {
        let n = try node(#"{ "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}" } } }"#)
        let again = try JSONDecoder().decode(PluginNode.self, from: JSONEncoder().encode(n))
        #expect(again == n)
        #expect(again.nodeProps["row"]?.props["title"] == .string("{{item.title}}"))
    }

    @Test("A migrated custom-list manifest exposes its row template")
    func migratedListExposesItsRow() throws {
        let command = SystemCommand(
            name: "Ports", icon: "network", keywords: ["ports", "provider:custom", "refresh:3"],
            scriptType: "bash", script: "echo '{}'",
            undoScriptType: "bash", undoScript: "kill $CD_ROW_ID")
        let manifest = PluginMigration.manifest(from: command)
        let list = try #require(manifest.views.panel?.root)
        let row = try #require(list.nodeProps["row"])
        #expect(row.props["action"] == .string("rowAction"))
    }
}
