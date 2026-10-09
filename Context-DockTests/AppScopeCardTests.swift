// Context-DockTests/AppScopeCardTests.swift
//
// The app's settings card (owner 2026-09-28): what the next turn carries from the app,
// the per-app "run without asking" grants it lists and forgets, and the field staying open
// while the card hangs over it.

import Foundation
import Testing

@testable import Context_Dock

@Suite("App settings card")
struct AppScopeCardTests {

    private static func page(_ url: String, title: String = "Swift") -> BrowserPageSnapshot {
        BrowserPageSnapshot(url: url, title: title, text: "text")
    }

    @Test("Sees now: the page, the selection and attachments, in that order")
    func linesInOrder() {
        let lines = AppScopeContext.lines(
            isBrowser: true, page: Self.page("https://swift.org"),
            selection: AppChatSelectionScope(kind: .text(characters: 42)),
            attachments: [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.png"),
                URL(fileURLWithPath: "/tmp/c.txt")])
        #expect(lines.map(\.title) == ["Swift", "Selection", "Attached"])
        #expect(lines[1].detail == "42 characters of selected text")
        #expect(lines[2].detail == "a.pdf, b.png +1")
        #expect(!lines[0].isRefused)
    }

    @Test("A page DoraX will not read is shown as refused, with the guard's reason")
    func refusedPage() {
        let lines = AppScopeContext.lines(
            isBrowser: true, page: Self.page("https://www.paypal.com/myaccount", title: "PayPal"),
            selection: nil, attachments: [])
        #expect(lines.count == 1)
        #expect(lines[0].isRefused)
        #expect(lines[0].symbol == "lock.fill")
    }

    @Test("A browser with no readable page says so; another app with nothing carries nothing")
    func emptyStates() {
        let browser = AppScopeContext.lines(isBrowser: true, page: nil, selection: nil, attachments: [])
        #expect(browser.map(\.title) == ["No readable page"])
        #expect(AppScopeContext.lines(isBrowser: false, page: nil, selection: nil, attachments: []).isEmpty)
        let files = AppScopeContext.lines(
            isBrowser: false, page: nil, selection: AppChatSelectionScope(kind: .files(count: 1)),
            attachments: [])
        #expect(files.first?.detail == "1 selected file")
    }

    @Test("Grants: one app's are listed and forgotten; another app's stay")
    func grantsPerApp() {
        let store = AppMenuConsentStore.shared
        let app = "com.example.scopecard.\(UUID().uuidString)"
        let other = "com.example.scopecard.other.\(UUID().uuidString)"
        defer { store.forget(bundleId: app); store.forget(bundleId: other) }
        store.allowAlways(bundleId: app, path: ["File", "Export as PDF…"])
        store.allowAlways(bundleId: app, path: ["View", "Show Reader"])
        store.allowAlways(bundleId: other, path: ["File", "Print…"])

        #expect(store.allowedCommands(bundleId: app) == ["file > export as pdf…", "view > show reader"])
        store.forget(bundleId: app)
        #expect(store.allowedCommands(bundleId: app).isEmpty)
        #expect(!store.isAllowed(bundleId: app, path: ["View", "Show Reader"]))
        #expect(store.isAllowed(bundleId: other, path: ["File", "Print…"]))
    }
}

@Suite("App settings card holds the field open")
@MainActor
struct AppScopeCardHoldTests {

    @Test("While the card is open the field's idle clock is stopped; closing restarts it")
    func holdsTheField() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.autoShrinkEnabled = { true }
        model.summon(app: "brew", bundleID: "cli://brew")
        guard !model.isPinned else { return }  // a pinned corner has no clock to stop
        model.touch()
        #expect(model.isStandDownArmed)

        model.isShowingScopeCard = true
        #expect(!model.isStandDownArmed)
        model.hoverEnded()  // the pointer "leaves" onto the card
        #expect(!model.isStandDownArmed)

        model.isShowingScopeCard = false
        #expect(model.isStandDownArmed)
    }
}

@Suite("App settings card in the result sheet's right half")
@MainActor
struct AppScopeCardPlacementTests {

    @Test("Open, the card is the board's right half and keeps the board tall enough for it")
    func theCardIsTheRightHalf() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Notes", bundleID: "com.apple.Notes")
        #expect(model.boardPreview != .appScope(bundleID: "com.apple.Notes", name: "Notes"))

        model.isShowingScopeCard = true
        #expect(model.boardPreview == .appScope(bundleID: "com.apple.Notes", name: "Notes"))
        #expect(model.boardSize.height >= AppScopeBoardMetrics.height)

        model.isShowingScopeCard = false
        #expect(model.boardPreview != .appScope(bundleID: "com.apple.Notes", name: "Notes"))
    }
}
