// FrontmostMenuMatcherTests.swift
// Context-DockTests
//
// The dock's live menu filtering had no direct test, because every rule it uses was a
// method on LauncherView — a SwiftUI struct with 420+ @State vars — and nothing could
// construct one. These pin the behaviour as it shipped, so moving it into
// FrontmostMenuMatcher is provably a move and not a rewrite.

import ApplicationServices
import Testing

@testable import Context_Dock

@MainActor
private func menuItem(
    _ title: String,
    path: [String],
    enabled: Bool = true,
    isAppleMenu: Bool = false,
    children: [AXMenuItem] = []
) -> AXMenuItem {
    AXMenuItem(
        title: title,
        path: path,
        isEnabled: enabled,
        element: AXUIElementCreateSystemWide(),
        children: children,
        isAppleMenu: isAppleMenu
    )
}

@Suite("Frontmost menu matcher")
@MainActor
struct FrontmostMenuMatcherTests {

    // MARK: - Matching

    @Test("An empty query matches everything, because the list is the app's whole menu")
    func emptyQueryMatchesEverything() {
        let item = menuItem("Minimize", path: ["Window", "Minimize"])
        #expect(FrontmostMenuMatcher.matches(item, query: ""))
        #expect(FrontmostMenuMatcher.matches(item, query: "   "))
    }

    @Test("A prefix of the title matches")
    func prefixMatches() {
        let item = menuItem("Minimize", path: ["Window", "Minimize"])
        #expect(FrontmostMenuMatcher.matches(item, query: "mini"))
    }

    @Test("A word inside the title matches, not only its start")
    func substringMatches() {
        let item = menuItem("Enter Full Screen", path: ["View", "Enter Full Screen"])
        #expect(FrontmostMenuMatcher.matches(item, query: "full"))
    }

    @Test("The menu the item lives under matches, so \"window\" finds what Window holds")
    func pathMatches() {
        let item = menuItem("Zoom", path: ["Window", "Zoom"])
        #expect(FrontmostMenuMatcher.matches(item, query: "window"))
    }

    @Test("A typo within two edits matches, but only for tokens of four or more")
    func typoToleranceHasAFloor() {
        let item = menuItem("Preferences", path: ["Code", "Preferences"])
        #expect(FrontmostMenuMatcher.matches(item, query: "prefrences"))

        // Three letters is below the rung: "zom" must not reach "Zoom".
        let short = menuItem("Zoom", path: ["Window", "Zoom"])
        #expect(!FrontmostMenuMatcher.matches(short, query: "zom"))
    }

    @Test("An unrelated query matches nothing")
    func unrelatedQueryDoesNotMatch() {
        let item = menuItem("Minimize", path: ["Window", "Minimize"])
        #expect(!FrontmostMenuMatcher.matches(item, query: "database"))
    }

    // MARK: - Dedupe

    @Test("The same menu path appears once, however many sources offered it")
    func dedupeKeepsOnePerPath() {
        let live = menuItem("Minimize", path: ["Window", "Minimize"])
        let cached = menuItem("Minimize", path: ["Window", "Minimize"])
        let other = menuItem("Zoom", path: ["Window", "Zoom"])

        let deduped = FrontmostMenuMatcher.dedupe([live, cached, other])

        #expect(deduped.count == 2)
        #expect(deduped.map(\.title) == ["Minimize", "Zoom"])
    }

    @Test("An item with no path is dropped rather than deduped to an empty key")
    func pathlessItemsAreDropped() {
        #expect(FrontmostMenuMatcher.dedupe([menuItem("Orphan", path: [])]).isEmpty)
    }

    // MARK: - Ordering

    @Test("An exact title outranks a mere prefix")
    func exactTitleWins() {
        let exact = menuItem("Zoom", path: ["Window", "Zoom"])
        let prefixed = menuItem("Zoom In", path: ["View", "Zoom In"])

        let ordered = FrontmostMenuMatcher.ordered(
            [prefixed, exact], filterQuery: "zoom", limit: 10)

        #expect(ordered.first?.title == "Zoom")
    }

    @Test("With equal scores the shallower menu path comes first")
    func shallowerPathBreaksTies() {
        let deep = menuItem("Export", path: ["File", "Share", "Export"])
        let shallow = menuItem("Export", path: ["File", "Export"])

        let ordered = FrontmostMenuMatcher.ordered(
            [deep, shallow], filterQuery: "export", limit: 10)

        #expect(ordered.first?.path.count == 2)
    }

    @Test("The limit is honoured")
    func limitIsHonoured() {
        let items = (1...20).map { menuItem("Item \($0)", path: ["File", "Item \($0)"]) }
        #expect(FrontmostMenuMatcher.ordered(items, filterQuery: "item", limit: 6).count == 6)
    }

    @Test("With no query the list spreads across menus instead of draining the first one")
    func emptyQueryDistributesAcrossMenus() {
        let items = [
            menuItem("New", path: ["File", "New"]),
            menuItem("Open", path: ["File", "Open"]),
            menuItem("Save", path: ["File", "Save"]),
            menuItem("Copy", path: ["Edit", "Copy"]),
            menuItem("Paste", path: ["Edit", "Paste"]),
            menuItem("Zoom", path: ["Window", "Zoom"]),
        ]

        let ordered = FrontmostMenuMatcher.ordered(items, filterQuery: "", limit: 3)

        // One from each menu before a second from any — the dock's distributed rule.
        #expect(Set(ordered.map { $0.path.first ?? "" }) == ["File", "Edit", "Window"])
    }

    // MARK: - Policy

    @Test("Apple-menu items stay out unless the policy allows them")
    func appleMenuItemsAreExcludedByDefault() {
        let apple = menuItem("System Settings…", path: ["Apple", "System Settings…"],
                             isAppleMenu: true)
        let own = menuItem("Minimize", path: ["Window", "Minimize"])

        let withoutApple = FrontmostMenuMatcher.ranked(
            [apple, own], query: "", limit: 10, policy: .cornerAppChat)
        #expect(withoutApple.map(\.title) == ["Minimize"])

        var allowing = FrontmostMenuMatcher.Policy.cornerAppChat
        allowing.allowsAppleMenuItems = true
        let withApple = FrontmostMenuMatcher.ranked(
            [apple, own], query: "", limit: 10, policy: allowing)
        #expect(withApple.count == 2)
    }

    @Test("A disabled item with no shortcut and no children never reaches the list")
    func disabledNonLeafIsHidden() {
        let disabledParent = menuItem(
            "Recent Files", path: ["File", "Recent Files"], enabled: false,
            children: [menuItem("a.txt", path: ["File", "Recent Files", "a.txt"])])

        let ranked = FrontmostMenuMatcher.ranked(
            [disabledParent], query: "", limit: 10, policy: .cornerAppChat)

        #expect(ranked.isEmpty)
    }

    @Test("ranked is dedupe, policy and order together — the whole rule in one call")
    func rankedAppliesEveryStage() {
        let items = [
            menuItem("Minimize", path: ["Window", "Minimize"]),
            menuItem("Minimize", path: ["Window", "Minimize"]),
            menuItem("Minimize All", path: ["Window", "Minimize All"]),
            menuItem("Save", path: ["File", "Save"]),
        ]

        let ranked = FrontmostMenuMatcher.ranked(
            items, query: "mini", limit: 10, policy: .cornerAppChat)

        #expect(ranked.map(\.title) == ["Minimize", "Minimize All"])
    }
}
