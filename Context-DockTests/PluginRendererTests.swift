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
