import Foundation
import Testing

@testable import Context_Dock

/// ⌘↩ with several clips picked asks where they go: the app the user came from first, then
/// the rest by name.
struct ClipboardPasteTargetTests {
    private func app(_ pid: pid_t, _ name: String, _ bundle: String? = nil) -> ClipboardPasteTarget {
        ClipboardPasteTarget(pid: pid, name: name, bundleID: bundle ?? "com.example.\(name)")
    }

    @Test func frontmostFirstThenTheRestByName() {
        let ordered = ClipboardPasteTarget.ordered(
            [app(1, "Safari"), app(2, "Notes"), app(3, "Finder")], frontPID: 3, excluding: nil)
        #expect(ordered.map(\.name) == ["Finder", "Notes", "Safari"])
    }

    @Test func neverThisAppNorTheSameAppTwice() {
        let ordered = ClipboardPasteTarget.ordered(
            [app(1, "DoraX", "me"), app(2, "Notes"), app(2, "Notes")], frontPID: nil,
            excluding: "me")
        #expect(ordered.map(\.name) == ["Notes"])
    }

    @Test func theArrowsStayInsideTheList() {
        var picker = ClipboardTargetPicker(
            entries: [], targets: [app(1, "A"), app(2, "B")])
        picker.move(-1)
        #expect(picker.chosen?.name == "A")
        picker.move(1); picker.move(1)
        #expect(picker.chosen?.name == "B")
    }
}
