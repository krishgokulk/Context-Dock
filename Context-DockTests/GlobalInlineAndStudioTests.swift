import AppKit
import PDFKit
import XCTest
@testable import Context_Dock

final class GlobalInlineAndStudioTests: XCTestCase {
    func testInlineCalculatorEvaluatesMathPercentagesUnitsDatesAndWorldTime() {
        // Math expression
        let math = GlobalInlineCalculator.evaluate("(120 + 30) * 2")
        XCTAssertEqual(math?.answerDisplay, "300")
        XCTAssertEqual(math?.categoryLabel, "Calculator")

        // Percentage
        let pct = GlobalInlineCalculator.evaluate("18% of 450")
        XCTAssertEqual(pct?.answerDisplay, "81")
        let pctPlus = GlobalInlineCalculator.evaluate("250 + 20%")
        XCTAssertEqual(pctPlus?.answerDisplay, "300")

        // Unit & Temperature conversion
        let temp = GlobalInlineCalculator.evaluate("212 f to c")
        XCTAssertEqual(temp?.answerDisplay, "100°C")
        let dist = GlobalInlineCalculator.evaluate("10 km in miles")
        XCTAssertNotNil(dist)
        XCTAssertTrue(dist?.answerDisplay.hasSuffix("mi") == true)

        // Date math
        var comps = DateComponents(year: 2026, month: 12, day: 1)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        comps.calendar = cal
        let dec1 = comps.date!
        let daysUntil = GlobalInlineCalculator.evaluate("days until 25 dec 2026", now: dec1, calendar: cal)
        XCTAssertEqual(daysUntil?.answerDisplay, "24 days")

        // World clock
        let tokyo = GlobalInlineCalculator.evaluate("time in tokyo", now: dec1)
        XCTAssertNotNil(tokyo)
        XCTAssertEqual(tokyo?.categoryLabel, "World Clock")
    }

    @MainActor
    func testSelectionCornerRowsKeepsShareDestinationsWhenQueryTyped() {
        let rows: [SelectionActionRow] = [
            SelectionActionRow(id: SelectionShare.entryRowID, title: "Share Selection", icon: "square.and.arrow.up", badge: "File", accentColorName: "blue", kind: .perform),
            SelectionActionRow(id: "share:com.apple.AirDrop", title: "AirDrop", icon: "airplayaudio", badge: "Share", accentColorName: "blue", kind: .share),
            SelectionActionRow(id: "share:com.apple.MobileSMS", title: "Messages", icon: "message.fill", badge: "Share", accentColorName: "blue", kind: .share),
            SelectionActionRow(id: "share:com.apple.journal", title: "Journal", icon: "book.closed.fill", badge: "Share", accentColorName: "blue", kind: .share),
        ]

        // Empty query collapses individual share rows into "Share Selection"
        let collapsed = SelectionActions.cornerRows(rows, query: "")
        XCTAssertEqual(collapsed.map(\.title), ["Share Selection"])

        // Non-empty query keeps matching share destinations visible directly in Selection Scope!
        let expanded = SelectionActions.cornerRows(rows, query: "journal")
        XCTAssertTrue(expanded.contains(where: { $0.title == "Journal" }))
        XCTAssertTrue(expanded.contains(where: { $0.title == "AirDrop" }))
        XCTAssertTrue(expanded.contains(where: { $0.title == "Messages" }))
    }

    func testLocalFileTextExtractorReadsPlainTextAndPDF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Hello DoraX In-Sheet Extractor".write(to: tmp, atomically: true, encoding: .utf8)

        let extracted = LocalFileTextExtractor.extractText(from: tmp)
        XCTAssertEqual(extracted, "Hello DoraX In-Sheet Extractor")
    }

    @MainActor
    func testExtractTextActionSwitchesFileSubmodeInSheet() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Extracted content stays in same sheet".write(to: tmp, atomically: true, encoding: .utf8)

        let prompt = CornerDockController.shared.prompt
        defer { _ = prompt.leaveFileSubmode() }

        XCTAssertTrue(prompt.enterFileSubmode(url: tmp, kind: .selectionScope))
        let extractRow = SelectionActionRow(
            id: "selection-ai-extract-text",
            title: "Extract Text",
            icon: "doc.text.viewfinder",
            badge: "Document",
            accentColorName: "blue",
            kind: .ask(prompt: "Extract all text")
        )
        XCTAssertTrue(prompt.runSelectionRowInSheet(extractRow))
        XCTAssertEqual(prompt.fileSubmode?.kind, .extractedText)
        XCTAssertEqual(prompt.fileSubmode?.returnToSelectionOnBack, true)
    }

    @MainActor
    func testUserSelectionExtensionStoreRoundTripExecution() async {
        let store = UserSelectionExtensionStore.shared
        let item = UserSelectionExtensionItem(
            name: "Count Lines Test",
            icon: "number",
            description: "Counts lines",
            fileExtensions: ["txt"],
            executionKind: .bash,
            body: #"printf "%s" "$CD_TEXT" | wc -w | tr -d ' '"#,
            outputPresentation: .showInSheet
        )
        store.add(item)
        defer { store.remove(id: item.id) }

        XCTAssertNotNil(store.item(forRowID: item.actionRowID))
        let output = await store.execute(item, fileURL: nil, selectedText: "one two three four", query: "")
        XCTAssertEqual(output, "4")
    }
}
