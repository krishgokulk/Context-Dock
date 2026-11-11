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
        // A "/" row steps into the app (owner 2026-10-16).
        #expect(closed.verb == "Step in")
    }

    /// "Switch to Safari" in an app's dock is an app, not a command (#258 G4).
    @Test func anAppRowIsAnApplication() {
        var pill = DockPill(id: "s", name: "Nowhere", icon: "app", badge: "Switch", execute: {})
        pill.rankingKind = "appSwitch"
        pill.sourceBundleId = "com.example.never-installed"
        let foot = BoardFoot.foot(
            for: .dock(pill), scopeName: "Calculator", scopeBundleID: "com.apple.calculator",
            isGlobal: false)
        #expect(foot.kind == "Application")
        #expect(foot.verb == "Open")
    }

    @Test func appPetReturnRunsMatchedCommandAndAsksAIForQuestions() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "System Settings", bundleID: "com.apple.systempreferences")
        var didQuit = false
        let quitPill = DockPill(id: "quit-settings", name: "Quit System Settings", icon: "xmark.circle", badge: "Menu", execute: {
            didQuit = true
        })

        // Typing "qui" in an App Pet shows Quit at the top: Return runs it instead of sending "qui" to AI.
        model.query = "qui"
        model.rows = [.dock(quitPill)]
        model.focusedMenuIndex = nil
        #expect(!model.skipsTopRowOnBareReturn)
        #expect(model.returnRunsTopRow)
        #expect(model.boardFoot.verb == "Quit")
        #expect(model.runReturnRow(runsTopRow: model.returnRunsTopRow))
        #expect(didQuit)

        // Question-shaped queries in an App Pet do not hijack Return even if a menu row shares a word.
        model.query = "what is on my screen"
        model.rows = [command(["Window", "Minimize"])]
        model.focusedMenuIndex = nil
        #expect(model.skipsTopRowOnBareReturn)
        #expect(!model.returnRunsTopRow)
        #expect(model.boardFoot.verb == "Ask AI")

        // Arrow-focusing a row in the list still overrides and runs that row.
        model.focusedMenuIndex = 0
        #expect(model.boardFoot.verb == "Run")

        // Active conversation (.chat) does not hijack Return.
        model.focusedMenuIndex = nil
        model.query = "qui"
        model.rows = [command(["System Settings", "Quit System Settings"])]
        model.forceOpenChat()
        #expect(!model.returnRunsTopRow)
    }
}
