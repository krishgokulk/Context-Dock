// SearchPresetMergeTests.swift
// Context-DockTests
//
// #15's second defect: a matching Global Command preset replaced the entire result list, so
// searching "screenshot" hid every app, file and menu that also matched.

import AppKit
import Testing

@testable import Context_Dock

@MainActor
private func result(_ title: String, id: String) -> SearchResult {
    SearchResult(
        title: title, subtitle: "", icon: nil, action: {},
        type: .application, filePath: nil, contactData: nil, stableID: id)
}

@Suite("Search preset merge")
@MainActor
struct SearchPresetMergeTests {

    @Test("A preset leads; everything else keeps its place behind it")
    func presetsLeadWithoutReplacing() {
        let merged = SearchPresetMerge.merge(
            presets: [result("Take Screenshot", id: "syscmd://shot")],
            scored: [result("Screenshots", id: "app://folder"), result("Safari", id: "app://safari")])

        #expect(merged.map(\.title) == ["Take Screenshot", "Screenshots", "Safari"])
    }

    @Test("With no preset the scored list is untouched")
    func noPresetChangesNothing() {
        let scored = [result("Safari", id: "a"), result("Notes", id: "b")]

        #expect(SearchPresetMerge.merge(presets: [], scored: scored).map(\.id) == ["a", "b"])
    }

    @Test("A row that is both a preset and a scored result appears once")
    func duplicatesCollapse() {
        let shared = result("Take Screenshot", id: "syscmd://shot")
        let merged = SearchPresetMerge.merge(
            presets: [shared], scored: [shared, result("Safari", id: "app://safari")])

        #expect(merged.count == 2)
        #expect(merged.first?.id == "syscmd://shot")
    }

    @Test("The limit counts the whole list, not each half")
    func limitApplies() {
        let merged = SearchPresetMerge.merge(
            presets: [result("A", id: "a")],
            scored: [result("B", id: "b"), result("C", id: "c")],
            limit: 2)

        #expect(merged.map(\.id) == ["a", "b"])
    }
}
