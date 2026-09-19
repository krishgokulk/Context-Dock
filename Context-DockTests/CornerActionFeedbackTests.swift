import Foundation
import SwiftUI
import Testing

@testable import Context_Dock

/// The corner's answer to a finished action: what colour it carries and how long it stays.
///
/// Serialized: three of these post `dockInlineFeedbackChanged`, every listening store in
/// the process hears every post, and `show` replaces whatever was there — so run in
/// parallel they overwrite each other's result and fail on whichever landed last.
@Suite("Corner action feedback", .serialized)
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

    @Test func aResultPostedTheDocksWayReachesTheCorner() async throws {
        // The one notification both surfaces read. A launch or a quit posts through
        // DockActionFeedback and the corner's store must hear it without anything routing.
        let store = CornerActionFeedback(listening: true)
        DockActionFeedback.showResult(
            "Opened Safari", icon: "arrow.up.forward.app", success: true, id: "nc-test",
            bundleID: "com.apple.Safari")
        for _ in 0..<40 where store.current?.id != "nc-test" {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(store.current?.id == "nc-test")
        #expect(store.current?.bundleID == "com.apple.Safari")
        store.dismiss(id: "nc-test")
    }

    /// Quitting an app from the corner's own strip reported nothing at all: no tint, no
    /// glyph, the app gone and the corner silent. Both app results now go through one
    /// pair of calls, and both carry the app so the glyph can draw it and the shell can
    /// take its colour.
    ///
    /// Read off the notification rather than off a listening store: every store in the
    /// suite hears every post, so a parallel test's result lands in this one's `current`.
    private func posted(id: String, _ act: () -> Void) async throws -> DockInlineFeedback {
        var seen: DockInlineFeedback?
        let token = NotificationCenter.default.addObserver(
            forName: .dockInlineFeedbackChanged, object: nil, queue: nil
        ) { note in
            guard let info = note.userInfo, info["id"] as? String == id,
                let title = info["title"] as? String, let icon = info["icon"] as? String,
                let raw = info["phase"] as? String,
                let phase = DockInlineFeedback.Phase(rawValue: raw)
            else { return }
            seen = DockInlineFeedback(
                id: id, title: title, icon: icon, phase: phase,
                bundleID: info["bundleID"] as? String)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        act()
        for _ in 0..<40 where seen == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return try #require(seen)
    }

    @Test func anAppQuitReachesTheCornerInRedCarryingTheApp() async throws {
        let result = try await posted(id: "quit-test") {
            DockActionFeedback.appQuit("Xcode", bundleID: "com.apple.dt.Xcode", id: "quit-test")
        }
        #expect(result.bundleID == "com.apple.dt.Xcode")
        // Red whatever the app's own colour is: this one took something away.
        #expect(ActionFeedbackTint.color(for: result, appColor: .blue) == .red)
    }

    @Test func anAppOpenedReachesTheCornerCarryingTheApp() async throws {
        let result = try await posted(id: "open-test") {
            DockActionFeedback.appOpened("Safari", bundleID: "com.apple.Safari", id: "open-test")
        }
        #expect(result.bundleID == "com.apple.Safari")
        #expect(!ActionFeedbackTint.isDestructive(result))
        // The app's own colour is what the shell takes when there is one.
        #expect(ActionFeedbackTint.color(for: result, appColor: .purple) == .purple)
    }

    @Test func dismissingSomethingElseLeavesTheCurrentResultAlone() {
        let store = CornerActionFeedback()
        store.show(result("Kept", phase: .progress, id: "k"))
        store.dismiss(id: "other")
        #expect(store.current?.id == "k")
        store.dismiss(id: "k")
    }
}
