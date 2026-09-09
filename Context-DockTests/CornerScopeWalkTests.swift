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
