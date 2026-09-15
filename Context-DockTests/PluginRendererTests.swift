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

    // MARK: Detail, grid and form (Task 5)

    @Test func aDetailReadsMarkdownAndMetadataFromTheSelectedRow() throws {
        let listDetail = try node(#"""
        { "listDetail": { "items": "{{docs}}",
                          "row": { "title": "{{item.title}}" },
                          "detail": { "markdown": "{{item.body}}",
                                      "metadata": [ { "title": "Size", "text": "{{item.size}}" } ] } } }
        """#)
        let binding = PluginBinding(data: ["docs": .array([
            .object(["title": .string("Notes"), "body": .string("# Hi"), "size": .string("2 KB")])
        ])])
        let detail = PluginListDetailView.detail(for: listDetail, binding: binding, selection: 0)
        #expect(detail?.markdown == "# Hi")
        #expect(detail?.metadata == [PluginMetadataItem(title: "Size", text: "2 KB")])
    }

    @Test func aDetailForARowThatIsNotThereIsNothing() throws {
        // The selection outlives the data whenever a refresh returns fewer items, so this is
        // the ordinary case, not a defensive one.
        let listDetail = try node(#"""
        { "listDetail": { "items": "{{docs}}", "detail": { "markdown": "{{item.body}}" } } }
        """#)
        let binding = PluginBinding(data: ["docs": .array([.object(["body": .string("x")])])])
        #expect(PluginListDetailView.detail(for: listDetail, binding: binding, selection: 3) == nil)
    }

    @Test func aFormCollectsItsFieldsAndSubmitsThemAsOneValue() throws {
        let form = try node(#"""
        { "form": { "submit": "save",
                    "fields": [ { "key": "name", "label": "Name", "kind": "text" },
                                { "key": "public", "label": "Public", "kind": "toggle" } ] } }
        """#)
        let state = PluginFormState(fields: PluginFormView.fields(of: form, binding: PluginBinding()))
        #expect(state.fields.map(\.key) == ["name", "public"])
        state.set("name", .string("Kitchen"))
        state.set("public", .bool(true))
        let sink = RecordingActionSink()
        PluginFormView.submit(form, state: state, binding: PluginBinding(), sink: sink)
        #expect(sink.requests == [PluginActionRequest(
            name: "save", value: .object(["name": .string("Kitchen"), "public": .bool(true)]))])
    }

    @Test func aFormWithNoSubmitActionAsksForNothing() throws {
        let form = try node(#"{ "form": { "fields": [ { "key": "name", "kind": "text" } ] } }"#)
        let state = PluginFormState(fields: PluginFormView.fields(of: form, binding: PluginBinding()))
        let sink = RecordingActionSink()
        PluginFormView.submit(form, state: state, binding: PluginBinding(), sink: sink)
        #expect(sink.requests.isEmpty)
    }

    @Test func aGridClampsItsColumnsToTheWidthClass() throws {
        let grid = try node(#"{ "grid": { "columns": 6, "items": "{{p}}", "cell": { "thumbnail": {} } } }"#)
        #expect(PluginGridView.columns(of: grid, traits: .dockSheet, binding: PluginBinding()) == 6)
        #expect(PluginGridView.columns(of: grid, traits: .cornerPanel, binding: PluginBinding()) == 3)
    }

    // MARK: Containers, text and chips (Task 6)

    @Test func theSixStatusWordsEachGetTheirOwnTone() {
        let words = ["pending", "running", "success", "failed", "expired", "waiting"]
        let tones = words.map { PluginStatusTone.tone(for: $0) }
        for (i, tone) in tones.enumerated() {
            #expect(tone != PluginStatusTone.neutral, "\(words[i]) has no tone of its own")
            for (j, other) in tones.enumerated() where j != i {
                #expect(tone != other, "\(words[i]) and \(words[j]) share a tone")
            }
        }
        // An unknown word is neutral rather than an accident.
        #expect(PluginStatusTone.tone(for: "banana") == PluginStatusTone.neutral)
    }

    @Test func aStatusWordIsReadWhateverItsCase() {
        // Script output is not curated: `SUCCESS` and `Success` are the same status.
        #expect(PluginStatusTone.tone(for: "SUCCESS") == PluginStatusTone.tone(for: "success"))
    }

    @Test func aStatReadsValueLabelAndDelta() throws {
        let stat = try node(#"{ "stat": { "value": "{{count}}", "label": "Tracks", "delta": "+3" } }"#)
        let model = PluginTextView.stat(of: stat, binding: PluginBinding(data: ["count": .number(12)]))
        #expect(model == PluginStatModel(value: "12", label: "Tracks", delta: "+3"))
    }

    @Test func shorthandTextReachesTheView() throws {
        // { "title": "Up next" } decodes to props["text"], not props["title"].
        let title = try node(#"{ "title": "Up next" }"#)
        #expect(PluginTextView.text(of: title, binding: PluginBinding()) == "Up next")
    }

    @Test func aLongFormTextNodeReadsTheSameAsTheShorthand() throws {
        let long = try node(#"{ "title": { "text": "{{heading}}" } }"#)
        let binding = PluginBinding(data: ["heading": .string("Up next")])
        #expect(PluginTextView.text(of: long, binding: binding) == "Up next")
    }

    // MARK: Controls and card rows (Task 7)

    @Test func aButtonsActionAndValueBecomeOneRequest() throws {
        let button = try node(#"{ "button": { "title": "Play", "action": "play", "value": "{{id}}" } }"#)
        let binding = PluginBinding(data: ["id": .string("t9")])
        #expect(PluginControlView.request(of: button, binding: binding)
            == PluginActionRequest(name: "play", value: .string("t9")))
    }

    @Test func aControlWithoutAnActionAsksForNothing() throws {
        let button = try node(#"{ "button": { "title": "Play" } }"#)
        #expect(PluginControlView.request(of: button, binding: PluginBinding()) == nil)
    }

    @Test func aToggleSendsItsNewStateAsTheValue() {
        let sink = RecordingActionSink()
        PluginControlView.send(
            PluginActionRequest(name: "mute", value: .bool(true)), sink: sink)
        #expect(sink.requests == [PluginActionRequest(name: "mute", value: .bool(true))])
    }

    @Test func aToggleStartsWhereItsDataSaysItIs() throws {
        // A light that is already on must not draw as off until someone touches it.
        let on = try node(#"{ "toggle": { "title": "Kitchen", "action": "flip", "value": "{{lit}}" } }"#)
        #expect(PluginControlView.initialBool(of: on, binding: PluginBinding(data: ["lit": .bool(true)])))
        #expect(PluginControlView.initialBool(of: on, binding: PluginBinding()) == false)
    }

    @Test func aSliderStartsAtItsBoundValue() throws {
        let slider = try node(#"{ "slider": { "action": "volume", "value": "{{level}}" } }"#)
        #expect(PluginControlView.initialNumber(of: slider, binding: PluginBinding(data: ["level": .number(35)])) == 35)
        #expect(PluginControlView.initialNumber(of: slider, binding: PluginBinding()) == 0)
    }

    @Test func aStateButtonCyclesThroughItsDeclaredStates() throws {
        let button = try node(#"""
        { "stateButton": { "states": [ { "title": "Play", "action": "play" },
                                       { "title": "Pause", "action": "pause" } ],
                           "state": "{{playing}}" } }
        """#)
        let states = PluginControlView.states(of: button, binding: PluginBinding())
        #expect(states.map(\.title) == ["Play", "Pause"])
        #expect(states[1].request.name == "pause")
    }

    @Test func aStateButtonShowsTheStateItsDataNames() throws {
        let button = try node(#"""
        { "stateButton": { "states": [ { "title": "Play", "action": "play" },
                                       { "title": "Pause", "action": "pause" },
                                       { "title": "Stop", "action": "stop" } ],
                           "state": "{{mode}}" } }
        """#)
        // A bool picks the second state; a number picks by index, which is the only way a
        // three-state control can say which one it is in.
        let states = PluginControlView.states(of: button, binding: PluginBinding())
        #expect(PluginControlView.currentIndex(of: button, binding: PluginBinding(data: ["mode": .bool(true)])) == 1)
        #expect(PluginControlView.currentIndex(of: button, binding: PluginBinding(data: ["mode": .number(2)])) == 2)
        #expect(PluginControlView.currentIndex(of: button, binding: PluginBinding()) == 0)
        // Past the end falls back to the first rather than drawing an empty button.
        let over = PluginControlView.currentIndex(of: button, binding: PluginBinding(data: ["mode": .number(9)]))
        #expect(states.indices.contains(over))
    }

    @Test func anEventRowReadsItsTimeRangeAndDurationChip() throws {
        let row = try node(#"""
        { "eventRow": { "title": "Standup", "timeRange": "09:30 – 09:45", "durationChip": "15m" } }
        """#)
        let model = PluginCardRowView.event(of: row, binding: PluginBinding())
        #expect(model.timeRange == "09:30 – 09:45")
        #expect(model.durationChip == "15m")
    }

    // MARK: Live, media and input (Task 8)

    @Test func liveComponentsFreezeWhenTheHostHasNoBudget() {
        var hidden = HostTraits.cornerPanel
        hidden.liveBudget = .none
        #expect(PluginLiveView.isAnimating(hidden) == false)
        #expect(PluginLiveView.isAnimating(.dockSheet) == true)
    }

    @Test func aMediaCardReadsItsTransportAndVolumeActions() throws {
        let card = try node(#"""
        { "mediaCard": { "title": "{{room}}", "artist": "{{artist}}",
                         "transport": "toggle", "volume": "volume" } }
        """#)
        let binding = PluginBinding(data: ["room": .string("Kitchen"), "artist": .string("Casio")])
        let model = PluginMediaView.model(of: card, binding: binding)
        #expect(model.title == "Kitchen")
        #expect(model.transport == "toggle")
        #expect(model.volume == "volume")
    }

    @Test func progressReadsAFractionAndClampsIt() throws {
        let bar = try node(#"{ "progress": { "value": "{{done}}", "total": "{{all}}" } }"#)
        let binding = PluginBinding(data: ["done": .number(15), "all": .number(10)])
        #expect(PluginLiveView.fraction(of: bar, binding: binding) == 1.0)
        let half = PluginBinding(data: ["done": .number(5), "all": .number(10)])
        #expect(PluginLiveView.fraction(of: bar, binding: half) == 0.5)
    }

    @Test func progressWithNoTotalIsAFractionOfOne() throws {
        // `{ "progress": { "value": "{{done}}" } }` is the common spelling for a 0–1 value,
        // and a zero total must not divide.
        let bar = try node(#"{ "progress": { "value": "{{done}}" } }"#)
        #expect(PluginLiveView.fraction(of: bar, binding: PluginBinding(data: ["done": .number(0.25)])) == 0.25)
        let zero = try node(#"{ "progress": { "value": "1", "total": "0" } }"#)
        #expect(PluginLiveView.fraction(of: zero, binding: PluginBinding()) == 0)
    }

    @Test func everyCatalogNameNowHasAView() {
        // The catalog and the renderer are the same set — no name a manifest may write falls
        // through to the placeholder, and no name the renderer claims is absent from the
        // catalog. A set comparison says both at once; a `Set<String> = []` of exceptions,
        // which the plan proposed, would assert nothing at all.
        #expect(PluginRenderer.implemented == PluginComponentCatalog.v1)
        for component in PluginComponentCatalog.v1 {
            #expect(PluginRenderer.supports(component), "no renderer for \(component)")
        }
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
