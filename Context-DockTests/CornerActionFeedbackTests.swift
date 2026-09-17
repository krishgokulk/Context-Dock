import Foundation
import SwiftUI
import Testing

@testable import Context_Dock

/// The corner's answer to a finished action: what colour it carries and how long it stays.
@MainActor
struct CornerActionFeedbackTests {
    private func result(
        _ title: String, icon: String = "checkmark.circle.fill",
        phase: DockInlineFeedback.Phase = .success, bundleID: String? = nil, id: String = "r"
    ) -> DockInlineFeedback {
        DockInlineFeedback(id: id, title: title, icon: icon, phase: phase, bundleID: bundleID)
    }

    // MARK: The dock's colour rules, held here so the corner cannot drift from them

    @Test func destructiveResultsAreRedWhateverTheirPhase() {
        #expect(ActionFeedbackTint.isDestructive(result("Quit Code")))
        #expect(ActionFeedbackTint.isDestructive(result("Emptied the Bin", icon: "trash")))
        #expect(ActionFeedbackTint.isDestructive(result("Removed", phase: .failure)))
        #expect(ActionFeedbackTint.color(for: result("Quit Code"), appColor: .blue) == .red)
    }

    @Test func theAppsOwnColourWinsOverThePhaseWhenThereIsOne() {
        let opened = result("Opened Safari")
        #expect(ActionFeedbackTint.color(for: opened, appColor: .purple) == .purple)
        #expect(ActionFeedbackTint.color(for: opened) == .green)
        #expect(ActionFeedbackTint.color(for: result("Working…", phase: .progress)) == .blue)
        #expect(ActionFeedbackTint.color(for: result("Failed", phase: .failure)) == .orange)
    }

    // MARK: Lifetime

    @Test func aFinishedResultShowsAndThenLeaves() async throws {
        let store = CornerActionFeedback()
        store.show(result("Done", id: "a"), hold: 0.05)
        #expect(store.current?.id == "a")

        // The clear runs on the main actor, which a full parallel suite keeps busy; wait
        // for it rather than for a fixed number of milliseconds.
        for _ in 0..<40 where store.current != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(store.current == nil)
    }

    @Test func progressStaysUntilItIsReplacedOrDismissed() async throws {
        let store = CornerActionFeedback()
        store.show(result("Working…", phase: .progress, id: "p"), hold: 0.05)
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(store.current?.id == "p")

        store.dismiss(id: "p")
        #expect(store.current == nil)
    }

    @Test func aNewerResultIsNotClearedByAnOlderOnesTimer() async throws {
        let store = CornerActionFeedback()
        store.show(result("First", id: "1"), hold: 0.05)
        store.show(result("Second", id: "2"), hold: 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        // The first result's clock ran out; the second is what is on show.
        #expect(store.current?.id == "2")
        store.dismiss(id: "2")
    }

    @Test func dismissingSomethingElseLeavesTheCurrentResultAlone() {
        let store = CornerActionFeedback()
        store.show(result("Kept", phase: .progress, id: "k"))
        store.dismiss(id: "other")
        #expect(store.current?.id == "k")
        store.dismiss(id: "k")
    }
}
