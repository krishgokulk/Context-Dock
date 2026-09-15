// Context-DockTests/PluginSizingTests.swift
//
// How tall a plugin is, before anything is drawn. These hold the arithmetic the corner's
// shell depends on (memory `corner-pill-size-must-be-pure`): same manifest + same binding +
// same traits, same number, every time, with no view ever measured.

import CoreGraphics
import Foundation
import Testing

@testable import Context_Dock

struct PluginSizingTests {
    private let empty = PluginBinding()

    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test func aRowIsShorterInTheCorner() throws {
        let row = try node(#"{ "row": { "title": "One" } }"#)
        #expect(PluginSizing.height(of: row, traits: .dockSheet, binding: empty) == 44)
        #expect(PluginSizing.height(of: row, traits: .cornerPanel, binding: empty) == 38)
    }

    @Test func aStackSumsItsChildrenAndTheGapsBetweenThem() throws {
        let stack = try node(#"{ "vstack": [ { "title": "A" }, { "title": "B" } ] }"#)
        let title = PluginKit.leafHeight("title", traits: .dockSheet)
        #expect(
            PluginSizing.height(of: stack, traits: .dockSheet, binding: empty)
                == title * 2 + PluginKit.gap)
    }

    @Test func anHstackIsAsTallAsItsTallestChild() throws {
        let stack = try node(#"{ "hstack": [ { "title": "A" }, { "mediaCard": {} } ] }"#)
        #expect(
            PluginSizing.height(of: stack, traits: .dockSheet, binding: empty)
                == PluginKit.leafHeight("mediaCard", traits: .dockSheet))
    }

    @Test func aCardAddsItsPaddingOnce() throws {
        let card = try node(#"{ "card": [ { "title": "A" } ] }"#)
        #expect(
            PluginSizing.height(of: card, traits: .dockSheet, binding: empty)
                == PluginKit.leafHeight("title", traits: .dockSheet) + PluginKit.cardPadding * 2)
    }

    @Test func aListIsAsTallAsTheRowsItsDataProduces() throws {
        let list = try node(
            #"{ "list": { "items": "{{queue}}", "row": { "title": "{{item.title}}" } } }"#)
        let binding = PluginBinding(data: [
            "queue": .array([.object([:]), .object([:]), .object([:])])
        ])
        // Written in tokens, not `44 * 3`: a literal-only product inside #expect types as
        // Int, and the macro compares the erased values, so CGFloat 132.0 != Int 132.
        let row = PluginKit.rowHeight(.dockSheet)
        #expect(PluginSizing.height(of: list, traits: .dockSheet, binding: binding) == row * 3)
    }

    @Test func anEmptyListFallsBackToItsEmptyStateHeight() throws {
        let list = try node(#"{ "list": { "items": "{{queue}}" } }"#)
        #expect(
            PluginSizing.height(of: list, traits: .dockSheet, binding: PluginBinding())
                == PluginKit.leafHeight("emptyState", traits: .dockSheet))
    }

    @Test func aGridIsRowsOfCellsAndTheCornerDropsColumns() throws {
        let grid = try node(
            #"{ "grid": { "columns": 6, "items": "{{photos}}", "cell": { "thumbnail": {} } } }"#)
        let binding = PluginBinding(data: ["photos": .array(Array(repeating: .null, count: 6))])
        // Regular: 6 columns → one row. Compact: clamped to 3 → two rows.
        // The template is a `cell` holding a thumbnail, and a cell's height is the cell token
        // — a row does not change height because of what is inside it, and neither does this.
        let cell = PluginKit.leafHeight("cell", traits: .dockSheet)
        #expect(PluginSizing.height(of: grid, traits: .dockSheet, binding: binding) == cell)
        let compactCell = PluginKit.leafHeight("cell", traits: .cornerPanel)
        #expect(
            PluginSizing.height(of: grid, traits: .cornerPanel, binding: binding)
                == compactCell * 2 + PluginKit.gap)
    }

    @Test func aSectionAddsItsHeader() throws {
        let section = try node(#"{ "section": { "header": "Up next", "children": [ { "title": "A" } ] } }"#)
        let header: CGFloat = PluginKit.sectionHeaderHeight + PluginKit.gap
        let title: CGFloat = PluginKit.leafHeight("title", traits: .dockSheet)
        #expect(
            PluginSizing.height(of: section, traits: .dockSheet, binding: empty)
                == header + title)
    }

    @Test func anUnknownComponentTakesTheHeightOfItsDiagnosticRow() throws {
        let unknown = try node(#"{ "orbitCluster": { "title": "x" } }"#)
        #expect(
            PluginSizing.height(of: unknown, traits: .dockSheet, binding: empty)
                == PluginKit.diagnosticHeight)
    }

    @Test func aTreeNeverExceedsTheHostsMaxHeight() throws {
        let long = try node(
            #"{ "list": { "items": "{{rows}}", "row": { "title": "{{item.t}}" } } }"#)
        let binding = PluginBinding(data: ["rows": .array(Array(repeating: .object([:]), count: 200))])
        #expect(
            PluginSizing.treeHeight(long, traits: .cornerPanel, binding: binding)
                == HostTraits.cornerPanel.maxHeight)
    }

    @Test func theSameInputsAlwaysGiveTheSameHeight() throws {
        let tree = try node(#"{ "vstack": [ { "row": {} }, { "stat": {} } ] }"#)
        let first = PluginSizing.treeHeight(tree, traits: .dockSheet, binding: empty)
        let second = PluginSizing.treeHeight(tree, traits: .dockSheet, binding: empty)
        #expect(first == second)
    }

    @Test func aTemplateInPropsIsReadFromNodePropsRatherThanDecodedAgain() throws {
        // #27 landed: `row` and `cell` are already nodes on the parent. Sizing must read them
        // there, so the renderer and the schema can never disagree about what a template is.
        let list = try node(#"{ "list": { "row": { "eventRow": {} } } }"#)
        let row = try #require(PluginSizing.childNode(list, key: "row"))
        #expect(row.component == "row")
        #expect(PluginSizing.childNode(list, key: "cell") == nil)
    }
}
