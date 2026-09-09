// CornerScopeWalkTests.swift
// Context-DockTests
//
// Global Context is a scope of the corner chat, not a fourth board: the same field asks, and
// the chip says which scope is answering. These pin the walk between the three.

import Testing

@testable import Context_Dock

@Suite("Corner scope walk")
struct CornerScopeWalkTests {

    @Test("The scopes sit in one order: General, Global, the frontmost app")
    func theOrderIsFixed() {
        #expect(CornerChatMode.walk == [.general, .globalContext, .frontmostApp])
    }

    @Test("Left from the app scope reaches Global, and left again reaches General")
    func leftWalksOutward() {
        #expect(CornerChatMode.step(from: .frontmostApp, by: -1) == .globalContext)
        #expect(CornerChatMode.step(from: .globalContext, by: -1) == .general)
    }

    @Test("Right walks back the same way")
    func rightWalksBack() {
        #expect(CornerChatMode.step(from: .general, by: 1) == .globalContext)
        #expect(CornerChatMode.step(from: .globalContext, by: 1) == .frontmostApp)
    }

    @Test("The walk stops at both ends rather than wrapping")
    func itDoesNotWrap() {
        // Running off one end and reappearing at the other reads as losing your place.
        #expect(CornerChatMode.step(from: .general, by: -1) == nil)
        #expect(CornerChatMode.step(from: .frontmostApp, by: 1) == nil)
    }

    @Test("Global Context asks the dock's index, and rests empty until something is typed")
    func globalRestsEmpty() {
        // A search over the whole machine has no useful resting list — "everything" is the
        // one thing it cannot show. The dock's own global bar rests empty too.
        #expect(GlobalContextRow.documents(for: "", limit: 5).isEmpty)
        #expect(GlobalContextRow.documents(for: "   ", limit: 5).isEmpty)
    }

    @Test("Every kind of Global result says where it comes from")
    func everyKindHasASubtitleAndASymbol() {
        // A row with no provenance is a row the user has to guess at, and Global mixes
        // apps, tools, tabs and menus in one list.
        let doc = GlobalSearchService.SearchDocument(
            id: "com.apple.Safari", title: "Safari", subtitle: "", bundleId: "com.apple.Safari",
            filePath: nil, normalizedTitle: "safari", titleWords: ["safari"], acronym: "s",
            aliases: [], aliasWords: [], sourceKind: .running, rankingBoost: 0, icon: nil,
            usageTrackingKey: "com.apple.Safari",
            action: .activatePID(1, bundleId: "com.apple.Safari", path: nil))

        #expect(GlobalContextRow.subtitle(for: doc) == "Running app")
        #expect(GlobalContextRow.symbol(for: doc) == "app")
    }

    @Test("Global Context drops the rows every app has; the app scope keeps them")
    func globalPolicyDropsGenericRows() {
        #expect(FrontmostMenuMatcher.Policy.globalContext.excludesGenericAppMenus)
        #expect(FrontmostMenuMatcher.Policy.cornerAppChat.excludesGenericAppMenus == false)
    }

    @Test("Neither scope offers Apple-menu rows unasked")
    func neitherScopeShowsTheAppleMenu() {
        #expect(FrontmostMenuMatcher.Policy.globalContext.allowsAppleMenuItems == false)
        #expect(FrontmostMenuMatcher.Policy.cornerAppChat.allowsAppleMenuItems == false)
    }
}
