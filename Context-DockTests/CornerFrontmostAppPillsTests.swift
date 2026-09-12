// CornerFrontmostAppPillsTests.swift
// Context-DockTests
//
// The running-app pills were built for Global Context only — the dock's own equivalent
// shows the same row while scoped to one app too, and the corner's frontmost-app chat
// never got that: summon() never populated globalMatchIcons, so the row had nothing to
// show even once its visibility condition was widened to cover this scope.

import Foundation
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
        model.setGlobalTyping(top: nil, icons: [], overflow: 999)

        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")

        // Read live, from the same source the model itself reads — this asserts the
        // mechanism ran, not a specific machine's set of running apps.
        let expected = AppChatPromptModel.pillIcons(excluding: "com.microsoft.VSCode")
        #expect(model.globalOverflowCount != 999)
        #expect(model.globalMatchIcons.count == min(expected.count, AppChatPromptModel.matchIconLimit))
    }

    @Test("The scoped app itself never appears among its own pills")
    func theScopedAppIsExcludedFromItsOwnPills() {
        let model = AppChatPromptModel()

        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")

        #expect(!model.globalMatchIcons.contains { $0.bundleID == "com.microsoft.VSCode" })
    }
}
