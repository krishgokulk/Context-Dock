// Context-DockTests/PluginCompactRulesTests.swift
//
// What the corner does differently, pinned as a pure transform. The value of doing it this way
// is that these tests can hold the corner's whole behaviour without rendering anything — and
// that no component view contains `if compact`.

import Foundation
import Testing

@testable import Context_Dock

struct PluginCompactRulesTests {
    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test func aRegularHostGetsTheTreeUnchanged() throws {
        let tree = try node(#"{ "listDetail": { "items": "{{d}}", "row": { "title": "x" } } }"#)
        #expect(PluginCompactRules.apply(to: tree, traits: .dockSheet) == tree)
    }

    @Test func theCornerTurnsASplitIntoAListThatPushes() throws {
        let tree = try node(#"""
        { "listDetail": { "items": "{{d}}", "row": { "title": "{{item.t}}" },
                          "detail": { "markdown": "{{item.body}}" } } }
        """#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.component == "list")
        let row = PluginSizing.childNode(compact, key: "row")
        let actions = row?.props["actions"]?.arrayValue ?? []
        #expect(actions.contains { $0.objectValue?["action"]?.stringValue == "push:detail" })
    }

    @Test func aPushedRowIsStillARowAndNotARowInsideARow() throws {
        // The row template is written back as the row's PROPS, because the prop key `row`
        // already names the component (#27). Writing back the encoded node instead nests it
        // one level deeper, and everything downstream — sizing, the schema, the renderer —
        // then reads a row whose only content is another row.
        let tree = try node(#"""
        { "listDetail": { "items": "{{d}}", "row": { "title": "{{item.t}}" },
                          "detail": { "markdown": "{{item.body}}" } } }
        """#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        let row = try #require(PluginSizing.childNode(compact, key: "row"))
        #expect(row.component == "row")
        #expect(row.props["title"] == .string("{{item.t}}"))
        #expect(row.nodeProps["row"] == nil)
        #expect(PluginSizing.height(of: compact, traits: .cornerPanel,
            binding: PluginBinding(data: ["d": .array([.object([:])])]))
            == PluginKit.rowHeight(.cornerPanel))
    }

    @Test func theCornerClampsGridColumns() throws {
        let tree = try node(#"{ "grid": { "columns": 6, "items": "{{p}}" } }"#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.props["columns"] == .number(3))
    }

    @Test func theCornerStacksRowAccessoriesUnderTheSubtitle() throws {
        let tree = try node(#"""
        { "row": { "title": "A", "subtitle": "B", "accessories": [ "1", "2" ] } }
        """#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.props["accessories"] == nil)
        #expect(compact.props["subtitle"] == .string("B · 1 · 2"))
    }

    @Test func theRulesReachNodesNestedInContainers() throws {
        let tree = try node(#"{ "vstack": [ { "grid": { "columns": 6, "items": "{{p}}" } } ] }"#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.children[0].props["columns"] == .number(3))
    }

    @Test func theRulesReachARowTemplateInsideAList() throws {
        // A row lives in a list's props, not in its children, so a transform that walks only
        // children never touches the rows a person actually sees — which is every row.
        let tree = try node(#"""
        { "list": { "items": "{{q}}",
                    "row": { "title": "A", "subtitle": "B", "accessories": [ "2 KB" ] } } }
        """#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        let row = try #require(PluginSizing.childNode(compact, key: "row"))
        #expect(row.props["accessories"] == nil)
        #expect(row.props["subtitle"] == .string("B · 2 KB"))
    }

    @Test func aNodeValuedPropUnderAnUnknownKeyKeepsItsSpelling() throws {
        // `"leading": { "thumbnail": {…} }` is the other node-prop spelling. Rewriting it as
        // the key's own component would turn a thumbnail into a component called `leading`.
        let tree = try node(#"{ "row": { "leading": { "thumbnail": { "src": "/tmp/a.png" } } } }"#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        let leading = try #require(compact.nodeProps["leading"])
        #expect(leading.component == "thumbnail")
        #expect(leading.props["src"] == .string("/tmp/a.png"))
    }

    @Test func aNumberReadsOutOfAValueAndOtherCasesDoNot() {
        #expect(PluginValue.number(6).numberValue == 6)
        #expect(PluginValue.string("6").numberValue == nil)
        #expect(PluginValue.null.numberValue == nil)
    }
}
