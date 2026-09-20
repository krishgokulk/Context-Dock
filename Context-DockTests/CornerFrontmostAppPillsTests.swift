// CornerFrontmostAppPillsTests.swift
// Context-DockTests
//
// The running-app pills were built for Global Context only — the dock's own equivalent
// shows the same row while scoped to one app too, and the corner's frontmost-app chat
// never got that: summon() never populated globalMatchIcons, so the row had nothing to
// show even once its visibility condition was widened to cover this scope.

import Foundation
import AppKit
import Testing

@testable import Context_Dock

@Suite("Corner frontmost-app pills")
@MainActor
struct CornerFrontmostAppPillsTests {

    @Test("Summoning the frontmost-app chat populates the same pill data Global Context uses")
    func summonPopulatesPills() {
        let model = AppChatPromptModel()
        // Seeded to something summon() must overwrite, so the assertion is that the call
        // actually happened rather than that these fields merely hold their zero value.
        model.setGlobalTyping(top: nil, running: [Self.icon("seed")])

        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")

        // Read live, from the same source the model itself reads — this asserts the
        // mechanism ran, not a specific machine's set of running apps.
        let expected = AppChatPromptModel.pillIcons(excluding: "com.microsoft.VSCode")
        #expect(!model.globalMatchIcons.contains { $0.id == "seed" })
        #expect(model.globalMatchIcons.count == min(expected.count, AppChatPromptModel.matchIconLimit))
    }

    /// The field takes four icons and says `+N`; the strip takes them all and lets its own
    /// width decide. Cutting to four before the strip saw the list is why the dock stopped
    /// growing at four apps with half the screen empty beside it.
    @Test("The field's four and the strip's all come from one list")
    func theStripSeesEveryRunningAppAndTheFieldSeesFour() {
        let model = AppChatPromptModel()
        let running = (0..<9).map { Self.icon("app\($0)") }

        model.setGlobalTyping(top: nil, running: running)

        #expect(model.globalMatchIcons.count == AppChatPromptModel.matchIconLimit)
        #expect(model.globalOverflowCount == 9 - AppChatPromptModel.matchIconLimit)
        #expect(model.stripIcons.count == 9)

        // And what the user took off the strip is still gone from it.
        model.hideRunningApp("app3")
        #expect(model.stripIcons.count == 8)
        #expect(!model.stripIcons.contains { $0.bundleID == "app3" })
    }

    private static func icon(_ id: String) -> MatchDockIcon {
        MatchDockIcon(
            id: id, bundleID: id, title: id, icon: NSImage(), isRunning: true,
            isExpandable: false, score: 0, isExactAppPrefix: false)
    }

    @Test("The scoped app itself never appears among its own pills")
    func theScopedAppIsExcludedFromItsOwnPills() {
        let model = AppChatPromptModel()

        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")

        #expect(!model.globalMatchIcons.contains { $0.bundleID == "com.microsoft.VSCode" })
    }
}
