import Foundation
import Testing

@testable import Context_Dock

/// The Quick Look / Open / Reveal buttons on a file card are icon-only. A card holds up to a
/// dozen rows, so their spoken names (VoiceOver, Voice Control, "show names") must say which
/// file — twelve buttons all called "Open" cannot be told apart.
@MainActor
struct CapabilityResultCardLabelTests {

    private func row(_ title: String) -> CapabilityResultRow {
        CapabilityResultRow(id: title, title: title, paths: [URL(fileURLWithPath: "/tmp/\(title)")])
    }

    @Test func eachButtonNamesItsPurposeAndItsFile() {
        let file = row("Passport Scan.pdf")
        #expect(CapabilityResultCard.actionLabel("Quick Look", for: file) == "Quick Look Passport Scan.pdf")
        #expect(CapabilityResultCard.actionLabel("Open", for: file) == "Open Passport Scan.pdf")
        #expect(CapabilityResultCard.actionLabel("Reveal in Finder", for: file)
            == "Reveal in Finder Passport Scan.pdf")
    }

    @Test func twoRowsNeverShareAButtonName() {
        let a = CapabilityResultCard.actionLabel("Open", for: row("a.pdf"))
        let b = CapabilityResultCard.actionLabel("Open", for: row("b.pdf"))
        #expect(a != b)
    }

    @Test func aRowWithoutATitleKeepsTheBarePurpose() {
        #expect(CapabilityResultCard.actionLabel("Open", for: row("  ")) == "Open")
    }
}
