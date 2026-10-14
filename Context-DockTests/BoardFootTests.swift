import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

/// The result board's foot says what Return acts on and what it does, row by row, as
/// Raycast's does (owner 2026-10-14).
@MainActor
@Suite("Board foot")
struct BoardFootTests {
    private func command(_ path: [String]) -> AppChatRow {
        .command(AXMenuItem(
            title: path.last ?? "", path: path, isEnabled: true,
            element: AXUIElementCreateSystemWide(), children: []))
    }

    @Test func nothingToRunAsksAIInTheScope() {
        let global = BoardFoot.foot(
            for: nil, scopeName: "Global Context", scopeBundleID: "", isGlobal: true)
        #expect(global.title == "Global Context")
        #expect(global.verb == "Ask AI")

        let app = BoardFoot.foot(
            for: nil, scopeName: "Calculator", scopeBundleID: "com.apple.calculator",
            isGlobal: false)
        #expect(app.title == "Calculator")
        #expect(app.bundleID == "com.apple.calculator")
    }

    @Test func aMenuCommandRunsAndAQuitQuits() {
        let run = BoardFoot.foot(
            for: command(["Edit", "Copy"]), scopeName: "Calculator",
            scopeBundleID: "com.apple.calculator", isGlobal: false)
        #expect(run.title == "Calculator · Menu")
        #expect(run.verb == "Run")

        let quit = BoardFoot.foot(
            for: command(["Calculator", "Quit Calculator"]), scopeName: "Calculator",
            scopeBundleID: "com.apple.calculator", isGlobal: false)
        #expect(quit.verb == "Quit")
    }

    @Test func globalQuitRowsNameTheirApp() {
        var pill = DockPill(id: "q", name: "Quit Claude", icon: "xmark.circle", badge: "Claude", execute: {})
        pill.sourceAppName = "Claude"
        pill.sourceBundleId = "com.anthropic.claudefordesktop"
        let foot = BoardFoot.foot(
            for: .dock(pill), scopeName: "Global Context", scopeBundleID: "", isGlobal: true)
        #expect(foot.title == "Claude · Running")
        #expect(foot.verb == "Quit")
        #expect(foot.bundleID == "com.anthropic.claudefordesktop")
    }

    @Test func filesAndFoldersOpen() {
        let folder = BoardFoot.foot(
            for: .file(FileManager.default.temporaryDirectory), scopeName: "Finder",
            scopeBundleID: "com.apple.finder", isGlobal: false)
        #expect(folder.title == "Folder")
        #expect(folder.verb == "Open")
    }

    @Test func theFootFollowsTheRowReturnTakes() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Calculator", bundleID: "com.apple.calculator")
        model.rows = [command(["Edit", "Copy"]), command(["Calculator", "Quit Calculator"])]
        // Nothing arrowed to: Return takes the top row, and so does the foot.
        model.focusedMenuIndex = nil
        #expect(model.boardFoot.verb == "Run")
        model.focusedMenuIndex = 1
        #expect(model.boardFoot.verb == "Quit")
    }

    /// A row's status is the foot's last word: the same kind, never a second wording (#258 G2).
    @Test func aRowsKindIsTheFootsLastWord() {
        let menu = BoardFoot.foot(
            for: command(["Edit", "Copy"]), scopeName: "Calculator",
            scopeBundleID: "com.apple.calculator", isGlobal: false)
        #expect(menu.kind == "Menu")
        let folder = BoardFoot.foot(
            for: .file(FileManager.default.temporaryDirectory), scopeName: "Finder",
            scopeBundleID: "com.apple.finder", isGlobal: false)
        #expect(folder.kind == "Folder")
        #expect(!folder.isRunningApp)
    }

    @Test func aClosedAppOpensAndIsNotRunning() {
        let closed = BoardFoot.foot(
            for: .app(ChatAppEntry(name: "Nowhere", bundleId: "com.example.never-installed", icon: nil, isRunning: false)),
            scopeName: "Global Context", scopeBundleID: "", isGlobal: true)
        #expect(!closed.isRunningApp)
        #expect(closed.kind == "Application")
        #expect(closed.verb == "Open")
    }
}
