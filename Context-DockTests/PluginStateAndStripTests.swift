import AppKit
import Foundation
import Testing

@testable import Context_Dock

/// Plugin state (what a plugin remembers between runs) and the strip host (a pinned plugin
/// drawing as a bar tile), held on their pure parts.
@MainActor
struct PluginStateAndStripTests {
    // MARK: State

    @Test func declaredDefaultsSitUnderWhatWasSet() {
        let merged = PluginStateStore.merged(
            defaults: ["from": .string("USD"), "to": .string("EUR"), "amount": .string("500")],
            current: ["to": .string("GBP")])
        #expect(merged["from"] == .string("USD"))
        #expect(merged["to"] == .string("GBP"))
        #expect(merged["amount"] == .string("500"))
    }

    @Test func stateBindsUnderDataAndDataWinsOnAKeyItEchoes() {
        let bound = PluginRuntime.bindable(
            ["from": .string("USD"), "result": .string("stale")],
            under: ["result": .string("433.36")])
        #expect(bound["from"] == .string("USD"))
        #expect(bound["result"] == .string("433.36"))
    }

    @Test func stateReachesAScriptAsUppercasedEnvironment() {
        var inputs = PluginInputs()
        inputs.state = ["from": .string("USD"), "refresh-rate": .number(10), "on": .bool(true)]
        let env = PluginEnvironment.build(inputs: inputs, host: .widget, widthClass: .compact)
        #expect(env["CD_STATE_FROM"] == "USD")
        #expect(env["CD_STATE_REFRESH_RATE"] == "10")
        #expect(env["CD_STATE_ON"] == "true")
    }

    @Test func aScriptsStateObjectIsAPatchAndAnythingElseIsNot() {
        #expect(
            PluginRuntime.statePatch(in: #"{"state":{"from":"EUR","to":"USD"}}"#)
                == ["from": .string("EUR"), "to": .string("USD")])
        #expect(PluginRuntime.statePatch(in: #"{"result":"1.00"}"#) == nil)
        #expect(PluginRuntime.statePatch(in: "not json") == nil)
    }

    @Test func theStoreRemembersAcrossInstancesOnTheSameFolder() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-state-\(UUID().uuidString)")
        let manifest = PluginManifest(id: "conv", name: "Conv", state: ["from": .string("USD")])

        let first = PluginStateStore(root: root)
        first.set("from", to: .string("GBP"), for: manifest)
        first.merge(["to": .string("JPY")], for: manifest)

        let second = PluginStateStore(root: root)
        let state = second.state(for: manifest)
        #expect(state["from"] == .string("GBP"))
        #expect(state["to"] == .string("JPY"))

        second.reset(for: manifest)
        #expect(PluginStateStore(root: root).state(for: manifest)["from"] == .string("USD"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func theSchemaHoldsASetActionToADeclaredKey() {
        let good = PluginManifest(
            id: "s", name: "S", actions: ["pick": PluginAction(type: "set", key: "from")],
            state: ["from": .string("USD")], views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "title", props: ["text": .string("x")]))))
        #expect(!PluginSchema.hasErrors(PluginSchema.validate(good)))

        let noKey = PluginManifest(
            id: "s", name: "S", actions: ["pick": PluginAction(type: "set")],
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "title", props: ["text": .string("x")]))))
        #expect(PluginSchema.validate(noKey).contains { $0.message.contains("needs a key") })

        let undeclared = PluginManifest(
            id: "s", name: "S", actions: ["pick": PluginAction(type: "set", key: "ghost")],
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "title", props: ["text": .string("x")]))))
        #expect(PluginSchema.validate(undeclared).contains { $0.message.contains("not declared under state") })
    }

    // MARK: Bar family

    @Test func aBarTileIsSlotsIconsWideAndOneIconTall() {
        let traits = HostTraits.strip(.widget, family: .bar, slots: 3)
        let expected: CGFloat = 3 * 48 + 2 * 8
        #expect(traits.width == expected)
        #expect(traits.maxHeight == CGFloat(48))
        #expect(traits.isBar)
        #expect(!HostTraits.strip(.widget, family: .small).isBar)
    }

    @Test func aTwoLineTileWithChipsFitsInABar() {
        // caption over title beside two chips: what the currency tile is made of.
        let traits = HostTraits.strip(.widget, family: .bar, slots: 3)
        let numbers = PluginNode(component: "vstack", children: [
            PluginNode(component: "caption", props: ["text": .string("500 USD")]),
            PluginNode(component: "title", props: ["text": .string("433.36")]),
        ])
        let chips = PluginNode(component: "vstack", children: [
            PluginNode(component: "button", props: ["title": .string("USD")]),
            PluginNode(component: "button", props: ["title": .string("EUR")]),
        ])
        let binding = PluginBinding()
        #expect(PluginSizing.height(of: numbers, traits: traits, binding: binding) <= 42)
        #expect(PluginSizing.height(of: chips, traits: traits, binding: binding) <= 42)
    }

    @Test func slotsOutsideTheRangeFallBackToTheDefault() throws {
        let json = #"{"family":"bar","slots":9,"root":{"title":"x"}}"#
        let view = try JSONDecoder().decode(PluginWidgetView.self, from: Data(json.utf8))
        #expect(view.slots == PluginWidgetView.defaultSlots)
    }

    // MARK: Strip host

    private func pin(_ kind: DockPinKind, _ title: String, order: Int) -> DockPin {
        DockPin(id: UUID(), kind: kind, title: title, order: order, documentID: nil)
    }

    @Test func aWidgetPinIsMeasuredAtItsTileWidthAndTheNextPinSitsAfterIt() {
        typealias M = AppChatPromptMetrics
        let widget = pin(.globalCommand(id: "plugin:currency"), "Currency", order: 0)
        let file = pin(.file(path: "/tmp/a.pdf"), "a.pdf", order: 1)
        let composed = DockStripComposition.compose(
            running: [], pins: [widget, file], runningBundleIDs: [],
            widgetSlots: [widget.id: 3])

        #expect(composed.width(of: widget) == HostTraits.barWidth(slots: 3))
        #expect(composed.width(of: file) == M.dockIconSize)
        #expect(composed.widgetExtraWidth == HostTraits.barWidth(slots: 3) - M.dockIconSize)

        let plan = DockStripPlan.make(
            running: [], pins: [widget, file], runningBundleIDs: [],
            widgetSlots: [widget.id: 3], tools: 0)
        let tile = plan.iconCenterOffset(for: .pin(id: widget.id))!
        let next = plan.iconCenterOffset(for: .pin(id: file.id))!
        // The file's centre is the tile's centre plus half the tile, the gap, half an icon.
        #expect(next - tile == HostTraits.barWidth(slots: 3) / 2 + M.dockIconGap + M.dockIconSize / 2)
    }

    @Test func theShellIsMeasuredForTheTile() {
        typealias M = AppChatPromptMetrics
        let plain = M.dockLayout(running: 2, pinned: 1)
        let withTile = M.dockLayout(
            running: 2, pinned: 1, pinnedExtraWidth: HostTraits.barWidth(slots: 3) - M.dockIconSize)
        #expect(withTile.width - plain.width == HostTraits.barWidth(slots: 3) - M.dockIconSize)
    }

    @Test func aPluginPinKnowsItsPluginID() {
        #expect(DockPinKind.globalCommand(id: "plugin:currency").pluginID == "currency")
        #expect(DockPinKind.globalCommand(id: "system:abc").pluginID == nil)
        #expect(DockPinKind.file(path: "/tmp").pluginID == nil)
    }

    // MARK: The plugin itself

    @Test func theCurrencyPluginDecodesAndValidatesClean() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        let diagnostics = PluginSchema.validate(manifest)
        #expect(!PluginSchema.hasErrors(diagnostics), "\(diagnostics)")
        #expect(manifest.views.widget?.family == .bar)
        #expect(manifest.views.widget?.slots == 3)
        #expect(manifest.state["from"] == .string("USD"))
        #expect(manifest.actions["choose"]?.type == "set")
        #expect(manifest.actions["choose"]?.key == "{{picking}}")
        #expect(manifest.actions["pickFrom"]?.pushTarget == "panel")
        #expect(manifest.actions["pickFrom"]?.key == "picking")
    }

    @Test func aPluginFieldOutranksEveryOtherKeyboardClaimant() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: true, selectionWantsKeyboard: true, chatShowsInput: true,
                pluginEditing: true) == .plugin)
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: false,
                pluginEditing: false) == .none)
        #expect(
            CornerKeyboardOwner.panelHoldsKeyboard(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: false,
                pluginEditing: true))
    }

    @Test func aPanelThatOpensWithAHeaderNamesItselfSoTheCardDoesNot() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        #expect(CornerPluginCardMetrics.panelNamesItself(manifest))
        #expect(!CornerPluginCardMetrics.panelNamesItself(PluginExamples.releases))
    }

    // MARK: Which pin's panel the card shows

    private func pluginPin(_ id: String) -> DockPin {
        DockPin(id: UUID(), kind: .globalCommand(id: "plugin:\(id)"), title: id, order: 0,
            documentID: "plugin:\(id)")
    }

    @Test func hoveringAPluginIconOpensItsPanelButATileIsItsOwnPreview() throws {
        let currency = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        let sleep = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.sleepJSON.utf8))
        let manifests = ["releases": PluginExamples.releases, "currency": currency, "sleep": sleep]
        let releases = pluginPin("releases"), tile = pluginPin("currency"), moon = pluginPin("sleep")
        let pins = [releases, tile, moon]
        let route = { (open: UUID?, hovered: UUID?) in
            CornerPluginCardRouting.cardPin(
                open: open, hovered: hovered, pins: pins, manifest: { manifests[$0] })?.pin.id
        }
        // An icon with a panel: the hover is the preview.
        #expect(route(nil, releases.id) == releases.id)
        // A bar tile draws its widget in the row; hovering it opens nothing.
        #expect(route(nil, tile.id) == nil)
        // No panel, nothing to show — the generic pin card takes over.
        #expect(route(nil, moon.id) == nil)
        // A card a tap opened stays up whatever the pointer crosses.
        #expect(route(tile.id, releases.id) == tile.id)
        #expect(route(tile.id, nil) == tile.id)
        #expect(route(nil, nil) == nil)
    }

    // MARK: The strip's icon host

    @Test func aPluginWithAnIconViewDrawsItLiveInTheStripAndOneWithoutDrawsItsSymbol() throws {
        let currency = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        #expect(PluginStripIcon.drawsLive(PluginExamples.sonos))
        #expect(!PluginStripIcon.drawsLive(PluginExamples.releases))
        // A bar widget is the tile; its icon view, if any, is not what the strip draws.
        #expect(!PluginStripIcon.drawsLive(currency))
    }

    @Test func everyIconLeafFitsInsideOneSlot() {
        let traits = HostTraits.strip(.icon)
        let inset = PluginStripIcon.content
        for leaf in ["thumbnail", "cell", "waveform", "pulse", "progress", "caption", "avatar"] {
            #expect(PluginKit.leafHeight(leaf, traits: traits) <= inset, Comment(rawValue: leaf))
        }
        #expect(PluginKit.leafHeight("thumbnail", traits: traits) == inset)
    }

    // MARK: Navigation and state through the host

    private func temporaryRuntime() -> (PluginRuntime, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-runtime-\(UUID().uuidString)")
        return (PluginRuntime(stateStore: PluginStateStore(root: root)), root)
    }

    @Test func aPushIsFoundByTheActionsNameNotOnlyByTheLiteral() throws {
        // The chip says "pickFrom"; the manifest says pickFrom is push:panel. The old check
        // read the name alone, so every declared push went to the runtime and failed there.
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        let host = PluginHostModel(manifest: manifest, presentation: .widget, compact: true)
        #expect(host.pushTarget(of: PluginActionRequest(name: "pickFrom")) == .panel)
        #expect(host.pushTarget(of: PluginActionRequest(name: "push:panel")) == .panel)
        #expect(host.pushTarget(of: PluginActionRequest(name: "swap")) == nil)
        #expect(host.pushTarget(of: PluginActionRequest(name: "push:window")) == nil)
    }

    @Test func aPushWithAKeyRemembersWhatWasTapped() async throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        let (runtime, root) = temporaryRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await runtime.run(
            PluginActionRequest(name: "pickTo", value: .string("to")), manifest: manifest,
            inputs: PluginInputs())
        #expect((try? result.get()) == "panel")
        #expect(runtime.stateStore.state(for: manifest)["picking"] == .string("to"))
    }

    @Test func aSetWithATemplatedKeyWritesWhereverStateSays() async throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        let (runtime, root) = temporaryRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        runtime.stateStore.set("picking", to: .string("to"), for: manifest)
        _ = await runtime.run(
            PluginActionRequest(name: "choose", value: .string("JPY")), manifest: manifest,
            inputs: PluginInputs())
        let state = runtime.stateStore.state(for: manifest)
        #expect(state["to"] == .string("JPY"))
        #expect(state["from"] == .string("USD"))
    }

    @Test func theCurrencyCardHasAPureSizeTheCornerCanHitTest() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.currencyJSON.utf8))
        let size = CornerPluginCardMetrics.size(for: manifest)
        #expect(size.width == HostTraits.cornerPanel.width)
        #expect(size.height > CornerPluginCardMetrics.headerHeight)
        #expect(size.height <= HostTraits.cornerPanel.maxHeight)
    }
}

/// A shipped plugin cannot know the id of the built-in command it replaces — that id is a
/// fresh UUID on every install — so it names it.
struct PluginSupersessionByNameTests {
    @Test func aPluginThatNamesACommandRetiresItWhateverTheCase() {
        let sleep = PluginManifest(id: "sleep", name: "Sleep", keywords: ["sleep", "replaces:Sleep"])
        let replaced = PluginSupersession.replacedNames(in: [sleep])
        #expect(PluginSupersession.supersedes(legacyName: "Sleep", replaced: replaced))
        #expect(PluginSupersession.supersedes(legacyName: "SLEEP", replaced: replaced))
        #expect(!PluginSupersession.supersedes(legacyName: "Stay Awake", replaced: replaced))
    }

    @Test func theReplacesStampIsBookkeepingNotAKeywordAPersonReads() {
        let sleep = PluginManifest(
            id: "sleep", name: "Sleep", keywords: ["sleep", "replaces:Sleep", "migrated-from:abc"])
        #expect(PluginSupersession.userVisibleKeywords(of: sleep) == ["sleep"])
    }

    @Test func aPersonsOwnChoiceIsConsentUpToMediumAnAgentsIsNot() {
        let medium = PluginAction(type: "bash", script: "pmset sleepnow", risk: .medium)
        let high = PluginAction(type: "bash", script: "rm -rf x", risk: .high)
        let read = PluginAction(type: "bash", script: "ls", risk: .read)
        #expect(!PluginPermissions.needsApproval(medium, origin: .user))
        #expect(PluginPermissions.needsApproval(medium, origin: .agent))
        #expect(PluginPermissions.needsApproval(high, origin: .user))
        #expect(!PluginPermissions.needsApproval(read, origin: .agent))
    }

    @Test func theShippedSleepReplacesTheBuiltInOne() throws {
        let sleep = try JSONDecoder().decode(
            PluginManifest.self, from: Data(PluginEssentials.sleepJSON.utf8))
        #expect(PluginSupersession.replacedNames(in: [sleep]).contains("sleep"))
        #expect(sleep.icon == "moon.zzz.fill")
        #expect(!PluginSchema.hasErrors(PluginSchema.validate(sleep)))
    }
}
