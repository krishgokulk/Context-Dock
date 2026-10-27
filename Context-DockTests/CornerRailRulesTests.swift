// CornerRailRulesTests.swift
// Context-DockTests
//
// #323: one rail in two densities, and the footer's expand glyph. Pure rules, so the compact
// panel, the window rail and the footer share one answer.

import Testing

@testable import Context_Dock

@Suite("Corner rail rules")
struct CornerRailRulesTests {

    @Test("compact shows today's panel: header, progress, outputs, connectors, can do here")
    func compactIsTodaysPanel() {
        #expect(
            CornerRailRules.cards(for: .compact)
                == [.scope, .progress, .outputs, .connectors, .canDoHere])
    }

    @Test("the window shows every card the issue lists, once")
    func fullHasEveryCard() {
        let full = CornerRailRules.cards(for: .full, hasMods: true)
        #expect(Set(full) == Set(CornerRailCard.allCases))
        #expect(full.count == CornerRailCard.allCases.count)
    }

    @Test("the Mods card waits until a mod applies to the scope")
    func modsHiddenUntilOneApplies() {
        #expect(!CornerRailRules.cards(for: .full).contains(.mods))
        #expect(CornerRailRules.cards(for: .full, hasMods: true).contains(.mods))
        #expect(!CornerRailRules.cards(for: .compact, hasMods: true).contains(.mods))
    }

    @Test("every compact card is also in the window: one component, never a second design")
    func compactIsASubsetOfFull() {
        #expect(Set(CornerRailRules.cards(for: .compact)).isSubset(of: Set(CornerRailRules.cards(for: .full))))
    }

    @Test("expand: none in Global search, inert mid-turn, live otherwise")
    func expandPresentation() {
        #expect(CornerRailRules.expand(isChatScope: false, isAnswering: false) == .hidden)
        #expect(CornerRailRules.expand(isChatScope: false, isAnswering: true) == .hidden)
        #expect(CornerRailRules.expand(isChatScope: true, isAnswering: true) == .disabled)
        #expect(CornerRailRules.expand(isChatScope: true, isAnswering: false) == .enabled)
    }

    @Test("expand opens the app's own thread, or General when there is no app")
    func windowScopeMapping() {
        #expect(CornerRailRules.windowScope(appBundleID: "com.apple.finder") == .app(bundleId: "com.apple.finder"))
        #expect(CornerRailRules.windowScope(appBundleID: nil) == .general)
        #expect(CornerRailRules.windowScope(appBundleID: "") == .general)
    }
}
