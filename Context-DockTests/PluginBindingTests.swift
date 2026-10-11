// Context-Dock
//
// Binding is the whole contract between a script's JSON and a view tree: "{{room}}" in the
// manifest has to become what the script printed, in every host, with no view involved.
// These hold that, and hold the cases a plugin author will hit by accident — a key that is
// not there, a value that is a number, a row that binds to `item.*`.

import CoreGraphics
import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin binding")
struct PluginBindingTests {
    private let data: [String: PluginValue] = [
        "room": .string("Kitchen"),
        "volume": .number(37),
        "playing": .bool(true),
        "queue": .array([
            .object(["title": .string("Jungle"), "artist": .string("Casio")]),
            .object(["title": .string("For Ever")]),
        ]),
        "now": .object(["track": .object(["title": .string("Deep")])]),
    ]

    @Test func aWholeStringBindingBecomesItsValue() {
        let binding = PluginBinding(data: data)
        #expect(binding.resolve(.string("{{room}}")) == .string("Kitchen"))
        #expect(binding.resolve(.string("{{volume}}")) == .number(37))
        #expect(binding.resolve(.string("{{playing}}")) == .bool(true))
    }

    @Test func aLiteralStringIsLeftAlone() {
        #expect(PluginBinding(data: data).resolve(.string("Up next")) == .string("Up next"))
    }

    @Test func aDottedPathWalksObjectsAndArrays() {
        let binding = PluginBinding(data: data)
        #expect(binding.resolve(.string("{{now.track.title}}")) == .string("Deep"))
        #expect(binding.resolve(.string("{{queue.1.title}}")) == .string("For Ever"))
        #expect(binding.resolve(.string("{{queue.9.title}}")) == .null)
    }

    @Test func aMissingKeyIsNullAndReadsAsEmptyText() {
        let binding = PluginBinding(data: data)
        #expect(binding.resolve(.string("{{nope}}")) == .null)
        #expect(binding.text(.string("{{nope}}")) == "")
    }

    @Test func itemScopeResolvesRowBindingsAndKeepsOuterData() {
        let row = PluginValue.object(["title": .string("Jungle"), "artist": .string("Casio")])
        let binding = PluginBinding(data: data, item: row)
        #expect(binding.resolve(.string("{{item.title}}")) == .string("Jungle"))
        #expect(binding.resolve(.string("{{room}}")) == .string("Kitchen"))
    }

    @Test func itemBindingsAreNullOutsideARow() {
        #expect(PluginBinding(data: data).resolve(.string("{{item.title}}")) == .null)
    }

    @Test func aBindingInsideASentenceIsInterpolated() {
        let binding = PluginBinding(data: data)
        #expect(binding.text(.string("Playing in {{room}}")) == "Playing in Kitchen")
        #expect(binding.text(.string("{{room}} · {{volume}}%")) == "Kitchen · 37%")
    }

    @Test func wholeNumbersPrintWithoutADecimalPoint() {
        let binding = PluginBinding(data: data)
        #expect(binding.text(.string("{{volume}}")) == "37")
        #expect(binding.text(.number(1.5)) == "1.5")
    }

    @Test func nestedStructuresResolveThroughout() {
        let binding = PluginBinding(data: data)
        let resolved = binding.resolve(
            .object(["a": .string("{{room}}"), "b": .array([.string("{{volume}}")])]))
        #expect(resolved == .object(["a": .string("Kitchen"), "b": .array([.number(37)])]))
    }

    @Test func itemsReadsARepeatedListAndScopesEachRow() {
        let binding = PluginBinding(data: data)
        let items = binding.items(.string("{{queue}}"))
        #expect(items.count == 2)
        #expect(binding.scoped(to: items[0]).text(.string("{{item.artist}}")) == "Casio")
        #expect(binding.items(.string("{{room}}")).isEmpty)
    }

    @Test func boolReadsTruthTheWayAManifestMeansIt() {
        let binding = PluginBinding(data: data)
        #expect(binding.bool(.string("{{playing}}")) == true)
        #expect(binding.bool(.string("{{nope}}")) == false)
        #expect(binding.bool(.number(1)) == true)
        #expect(binding.bool(.string("yes")) == true)
    }

    @Test func eachHostDeclaresItsOwnWidthAndClass() {
        #expect(HostTraits.dockSheet.widthClass == .regular)
        #expect(HostTraits.cornerPanel.widthClass == .compact)
        #expect(HostTraits.window(.wide, screenHeight: 1000).width == 640)
        #expect(HostTraits.window(.narrow, screenHeight: 1000).maxHeight == 700)
        #expect(HostTraits.strip(.icon).liveBudget == .low)
    }
}
