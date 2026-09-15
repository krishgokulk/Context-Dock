// Context-DockTests/PluginRendererTests.swift
//
// The renderer's contract, before any component exists. Two of these are the phase's bar:
// `theRendererImplementsEveryNameInTheCatalog` is deliberately RED from Task 3 to Task 8 and
// Tasks 4–8 turn it green one component group at a time. Do not weaken it to make a task look
// finished — a green catalog test with half the kit missing is how a plugin ends up drawing
// nothing and nobody noticing.

import Foundation
import SwiftUI
import Testing

@testable import Context_Dock

@MainActor
struct PluginRendererTests {
    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test func theRendererImplementsEveryNameInTheCatalog() {
        for component in PluginComponentCatalog.v1 {
            #expect(PluginRenderer.supports(component), "no renderer for \(component)")
        }
    }

    @Test func anUnknownComponentRendersAsADiagnosticNotACrash() throws {
        let unknown = try node(#"{ "orbitCluster": {} }"#)
        #expect(PluginRenderer.supports(unknown.component) == false)
        let diagnostics = PluginRenderer.diagnostics(for: unknown)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].message.contains("orbitCluster"))
    }

    @Test func aComponentTheKitKnowsButHasNoViewForYetIsNotADiagnostic() throws {
        // "Not written yet" and "no such component" are different failures and must not read
        // the same: one is this phase's own progress, the other is a manifest the app cannot
        // honour. Only the second is ever shown to a user.
        let known = try node(#"{ "waveform": {} }"#)
        #expect(PluginComponentCatalog.isKnown("waveform"))
        #expect(PluginRenderer.diagnostics(for: known).isEmpty)
    }

    @Test func aDiagnosticIsReportedForAnUnknownNameAnywhereInTheTree() throws {
        // The schema walks node props (#27), so the renderer must too — an unknown component
        // inside a list's row template is the case a panel would otherwise draw blank.
        let tree = try node(#"{ "list": { "row": { "orbitCluster": {} } } }"#)
        let messages = PluginRenderer.diagnostics(for: tree).map(\.message)
        #expect(messages.contains { $0.contains("orbitCluster") })
    }

    // MARK: Panel views (Task 4)

    @Test func aListBuildsOneRowModelPerItemInOrder() throws {
        let list = try node(#"""
        { "list": { "items": "{{queue}}",
                    "row": { "title": "{{item.title}}", "subtitle": "{{item.artist}}" } } }
        """#)
        let binding = PluginBinding(data: ["queue": .array([
            .object(["title": .string("Jungle"), "artist": .string("Casio")]),
            .object(["title": .string("For Ever"), "artist": .string("Casio")]),
        ])])
        let models = PluginListView.rowModels(for: list, binding: binding)
        #expect(models.map(\.title) == ["Jungle", "For Ever"])
        #expect(models[0].subtitle == "Casio")
    }

    @Test func aLocalFilterNarrowsRowsWithoutRunningAnything() throws {
        let list = try node(#"""
        { "list": { "filter": "local", "items": "{{queue}}", "row": { "title": "{{item.title}}" } } }
        """#)
        let binding = PluginBinding(data: ["queue": .array([
            .object(["title": .string("Jungle")]), .object(["title": .string("For Ever")]),
        ])])
        #expect(PluginListView.rowModels(for: list, binding: binding, query: "ever").map(\.title)
            == ["For Ever"])
        // filter: query hands the typing to the data script instead, so the rows stand.
        let queryList = try node(#"""
        { "list": { "filter": "query", "items": "{{queue}}", "row": { "title": "{{item.title}}" } } }
        """#)
        #expect(PluginListView.rowModels(for: queryList, binding: binding, query: "ever").count == 2)
    }

    @Test func aRowsActionsCarryTheirResolvedValue() throws {
        let list = try node(#"""
        { "list": { "items": "{{queue}}",
                    "row": { "title": "{{item.title}}",
                             "actions": [ { "title": "Play", "action": "play", "value": "{{item.id}}" } ] } } }
        """#)
        let binding = PluginBinding(data: ["queue": .array([
            .object(["id": .string("t1"), "title": .string("Jungle")])
        ])])
        let models = PluginListView.rowModels(for: list, binding: binding)
        #expect(models[0].actions.first?.request
            == PluginActionRequest(name: "play", value: .string("t1")))
    }

    @Test func aListWithNoRowTemplateStillNamesItsItems() throws {
        // The fallback template is what a migrated provider:custom list leans on; without it
        // a list with data draws a column of blank rows and looks broken rather than bare.
        let list = try node(#"{ "list": { "items": "{{lines}}" } }"#)
        let binding = PluginBinding(data: ["lines": .array([
            .object(["title": .string("8080")])
        ])])
        #expect(PluginListView.rowModels(for: list, binding: binding).map(\.title) == ["8080"])
    }

    @Test func runningARowsPrimaryActionReachesTheSink() {
        let sink = RecordingActionSink()
        let action = PluginRowAction(title: "Play", request: .init(name: "play", value: .string("t1")))
        PluginListView.perform(action, sink: sink)
        #expect(sink.requests.map(\.name) == ["play"])
    }

    @Test func aSinkReceivesWhatAComponentAsksToRun() {
        let sink = RecordingActionSink()
        sink.run(PluginActionRequest(name: "toggle", value: .string("kitchen")))
        #expect(sink.requests == [PluginActionRequest(name: "toggle", value: .string("kitchen"))])
    }

    @Test func aStateViewIsChosenForAnEmptyListAndForNoDataYet() throws {
        let list = try node(#"{ "list": { "items": "{{queue}}" } }"#)
        #expect(PluginRenderer.state(for: list, binding: PluginBinding()) == .empty)
        #expect(
            PluginRenderer.state(for: list, binding: PluginBinding(data: ["queue": .array([.null])]))
                == .content)
        #expect(PluginRenderer.state(for: list, binding: nil) == .loading)
    }

    @Test func aNodeThatHoldsNoDataIsContentEvenBeforeAScriptAnswers() throws {
        // Only the data-driven components have an empty state. A card of static text is
        // content the moment it decodes, and must not sit on a spinner forever.
        let card = try node(#"{ "card": [ { "title": "Hello" } ] }"#)
        #expect(PluginRenderer.state(for: card, binding: PluginBinding()) == .content)
    }
}
