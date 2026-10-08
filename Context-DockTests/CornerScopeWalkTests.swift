// CornerScopeWalkTests.swift
// Context-DockTests
//
// Global Context is a scope of the corner chat, not a fourth board: the same field asks, and
// the chip says which scope is answering. These pin the walk between the three.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Corner scope walk")
struct CornerScopeWalkTests {

    @Test("← and a swipe right go into General Chat from either scope; → and a swipe left do not")
    func generalIsSteppedIntoSideways() {
        for mode in [CornerChatMode.globalContext, .frontmostApp] {
            #expect(CornerNavigation.destination(for: .leftKey, from: mode, origin: mode) == .general)
            #expect(CornerNavigation.destination(
                for: .swipeSideways(right: true), from: mode, origin: mode) == .general)
            #expect(CornerNavigation.destination(for: .rightKey, from: mode, origin: mode) == nil)
            #expect(CornerNavigation.destination(
                for: .swipeSideways(right: false), from: mode, origin: mode) == nil)
        }
    }

    @Test("Every way out of General Chat but ← goes back to the scope it was entered from")
    func generalReturnsToItsOrigin() {
        for origin in [CornerChatMode.globalContext, .frontmostApp] {
            for move in [CornerNavigation.Move.rightKey, .swipeSideways(right: true),
                .swipeSideways(right: false), .layerUp, .layerDown]
            {
                #expect(CornerNavigation.destination(for: move, from: .general, origin: origin)
                    == origin)
            }
            #expect(CornerNavigation.destination(for: .leftKey, from: .general, origin: origin)
                == nil)
        }
    }

    @Test("Global Context is the layer above the frontmost app, and neither end wraps")
    func theLayersStack() {
        let g = CornerChatMode.globalContext, a = CornerChatMode.frontmostApp
        #expect(CornerNavigation.destination(for: .layerUp, from: a, origin: a) == g)
        #expect(CornerNavigation.destination(for: .layerDown, from: g, origin: g) == a)
        #expect(CornerNavigation.destination(for: .layerUp, from: g, origin: g) == nil)
        #expect(CornerNavigation.destination(for: .layerDown, from: a, origin: a) == nil)
    }

    @Test("A swipe is read with the Dock's thresholds and signs")
    func swipesAreClassifiedLikeTheDock() {
        #expect(CornerSwipe.classify(dx: 90, dy: 0) == .swipeSideways(right: true))
        #expect(CornerSwipe.classify(dx: -90, dy: 10) == .swipeSideways(right: false))
        #expect(CornerSwipe.classify(dx: 70, dy: 0) == nil)  // not past 70
        #expect(CornerSwipe.classify(dx: 90, dy: 60) == nil)  // not 1.8× the vertical
        #expect(CornerSwipe.classify(dx: 0, dy: -60) == .layerDown)  // swipe up
        #expect(CornerSwipe.classify(dx: 0, dy: 60) == .layerUp)  // swipe down
        #expect(CornerSwipe.classify(dx: 0, dy: 55) == nil)  // not past 55
        #expect(CornerSwipe.classify(dx: 50, dy: 56) == nil)  // not 1.15× the sideways
    }

    @Test("Keys and swipes agree from every scope")
    func keysAndSwipesAgree() {
        let pairs: [(CornerNavigation.Move, CornerNavigation.Move)] = [
            (.leftKey, .swipeSideways(right: true)),
            (.layerUp, CornerSwipe.classify(dx: 0, dy: 80)!),
            (.layerDown, CornerSwipe.classify(dx: 0, dy: -80)!),
        ]
        for mode in [CornerChatMode.globalContext, .frontmostApp] {
            for (key, swipe) in pairs {
                #expect(CornerNavigation.destination(for: key, from: mode, origin: mode)
                    == CornerNavigation.destination(for: swipe, from: mode, origin: mode))
            }
        }
        #expect(CornerNavigation.destination(for: .rightKey, from: .general, origin: .globalContext)
            == CornerNavigation.destination(
                for: .swipeSideways(right: false), from: .general, origin: .globalContext))
    }

    @Test("Global Context asks the dock's index, and rests empty until something is typed")
    func globalRestsEmpty() {
        // A search over the whole machine has no useful resting list — "everything" is the
        // one thing it cannot show. The dock's own global bar rests empty too.
        #expect(GlobalContextRow.documents(for: "", limit: 5).isEmpty)
        #expect(GlobalContextRow.documents(for: "   ", limit: 5).isEmpty)
    }

    @Test("A Global Extension is a kind of result the corner knows how to describe")
    func globalExtensionRowIsDescribed() {
        // #15: user-built extensions were in no index at all, so neither surface could find
        // one by any name. Now they are documents like everything else.
        let doc = GlobalSearchService.SearchDocument(
            id: "userext://x", title: "Currency Converter", subtitle: "", bundleId: "userext://x",
            filePath: nil, normalizedTitle: "currency converter",
            titleWords: ["currency", "converter"], acronym: "cc", aliases: ["fx", "money"],
            aliasWords: [["fx"], ["money"]], sourceKind: .systemCommand, rankingBoost: 0,
            icon: nil, usageTrackingKey: "userext:x", action: .userExtension(id: UUID()))

        #expect(GlobalContextRow.subtitle(for: doc) == "Global Extension")
        #expect(GlobalContextRow.symbol(for: doc) == "puzzlepiece.extension")
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

@Suite("App scope hint")
struct AppScopeHintTests {

    @Test("Each app says what it offers, in its own terms")
    func knownAppsHaveTheirOwnHint() {
        #expect(
            AppScopeHint.placeholder(bundleId: "com.apple.finder", appName: "Finder")
                == "Finder — search files and folders")
        #expect(
            AppScopeHint.hint(bundleId: "com.microsoft.VSCode", appName: "Code")
                == "run tasks, commands, menu cmds")
        #expect(
            AppScopeHint.hint(bundleId: "com.apple.mail", appName: "Mail")
                .contains("mailboxes"))
    }

    @Test("An app nobody wrote a line for still says something true")
    func unknownAppsFallBack() {
        // "menu cmds" is the floor: every app has menus, so the hint is never a promise
        // the scope cannot keep.
        #expect(AppScopeHint.hint(bundleId: "com.example.thing", appName: "Thing") == "menu cmds")
        #expect(
            AppScopeHint.hint(bundleId: "com.example.thing", appName: "Thing", hasActions: true)
                == "app actions, menu cmds")
    }

    @Test("A nameless scope is still named")
    func namelessScopeHasAFallback() {
        #expect(AppScopeHint.placeholder(bundleId: "", appName: "").hasPrefix("Context —"))
    }
}
