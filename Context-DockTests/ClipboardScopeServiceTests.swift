import AppKit
import Foundation
import Testing

@testable import Context_Dock

/// What a clipboard surface does with clips, tested where both surfaces read it from.
@MainActor
struct ClipboardScopeServiceTests {
    private func entry(
        _ text: String, files: [String] = [], id: UUID = UUID()
    ) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            id: id,
            text: text,
            timestamp: Date(),
            filePaths: files,
            sourceAppName: "Finder",
            sourceBundleId: "com.apple.finder")
    }

    // MARK: - Order

    /// Pasting three clips into a document should produce them in the order the user picked
    /// them, not the order the history happens to hold them.
    @Test func theSelectionPastesInTheOrderItWasPicked() {
        let a = entry("first", id: UUID())
        let b = entry("second", id: UUID())
        let c = entry("third", id: UUID())

        let ordered = ClipboardScopeService.orderedSelection(
            from: [a, b, c],
            selectedIDs: [a.id, b.id, c.id],
            pickOrder: [c.id, a.id, b.id])

        #expect(ordered.map(\.text) == ["third", "first", "second"])
    }

    /// Anything selected before the order was tracked still has to come out somewhere
    /// sensible rather than being dropped.
    @Test func clipsPickedBeforeTheOrderWasKnownFallBackToListOrder() {
        let a = entry("first", id: UUID())
        let b = entry("second", id: UUID())

        let ordered = ClipboardScopeService.orderedSelection(
            from: [a, b], selectedIDs: [a.id, b.id], pickOrder: [])

        #expect(ordered.map(\.text) == ["first", "second"])
    }

    @Test func aRangeCoversEverythingBetweenTheTwoClicks() {
        let a = entry("a", id: UUID())
        let b = entry("b", id: UUID())
        let c = entry("c", id: UUID())

        let range = ClipboardScopeService.rangeSelection(
            in: [a, b, c], from: a.id, to: c.id)

        #expect(range == Set([a.id, b.id, c.id]))
    }

    /// Shift-clicking with nothing to measure from selects the row that was clicked, rather
    /// than nothing or everything.
    @Test func aRangeWithNoAnchorIsJustTheRowClicked() {
        let a = entry("a", id: UUID())
        let b = entry("b", id: UUID())

        let range = ClipboardScopeService.rangeSelection(in: [a, b], from: nil, to: b.id)

        #expect(range == Set([b.id]))
    }

    // MARK: - Payload

    /// Finder, Mail and upload fields all want fileURL items. Handing them the paths as text
    /// is never what was meant.
    @Test func allFilesPasteAsFilesNotAsTheirPaths() {
        let payload = ClipboardScopeService.payload(for: [
            entry("", files: ["/tmp/one.png"]),
            entry("", files: ["/tmp/two.png"]),
        ])

        #expect(payload == .files([URL(fileURLWithPath: "/tmp/one.png"),
                                   URL(fileURLWithPath: "/tmp/two.png")]))
    }

    /// A mixed selection is text first — that is what a paste into a document should yield —
    /// with the files carried alongside for targets that understand them.
    @Test func aMixedSelectionLeadsWithTextAndCarriesTheFiles() {
        let payload = ClipboardScopeService.payload(for: [
            entry("some words"),
            entry("", files: ["/tmp/one.png"]),
        ])

        #expect(
            payload
                == .textWithFiles(
                    text: "some words\n\n/tmp/one.png",
                    files: [URL(fileURLWithPath: "/tmp/one.png")]))
    }

    @Test func nothingSelectedIsNothingToPaste() {
        #expect(ClipboardScopeService.payload(for: []) == .empty)
    }

    // MARK: - Context

    /// The text an AI turn is handed falls through to whatever the clip actually holds.
    @Test func contextTextFallsBackThroughWhatTheClipHas() {
        let text = ClipboardScopeService.contextText(from: [
            entry("readable"),
            entry("", files: ["/tmp/report.pdf"]),
        ])

        #expect(text == "readable\n\n/tmp/report.pdf")
    }

    @Test func emptyClipsContributeNothingToTheContext() {
        #expect(ClipboardScopeService.contextText(from: [entry("")]).isEmpty)
    }
}
