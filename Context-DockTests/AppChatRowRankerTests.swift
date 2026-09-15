// AppChatRowRankerTests.swift
// Context-DockTests
//
// The corner's one list holds two different things — the app's adapter actions and its menu
// commands — and has to order them together. #13 was this list being alphabetical, so the
// useful rows never surfaced.

import ApplicationServices
import Testing

@testable import Context_Dock

@MainActor
private func menuItem(_ title: String, path: [String]) -> AXMenuItem {
    AXMenuItem(
        title: title, path: path, isEnabled: true,
        element: AXUIElementCreateSystemWide(), children: [])
}

private func action(
    _ name: String, triggers: [String] = [], description: String = ""
) -> AdapterAction {
    AdapterAction(
        id: name.lowercased(), name: name, icon: "bolt.fill", description: description,
        triggers: triggers, type: .menubar)
}

@Suite("App chat row ranker")
@MainActor
struct AppChatRowRankerTests {

    @Test("With nothing typed, curated actions lead and commands fill the rest")
    func restingListLeadsWithActions() {
        let rows = AppChatRowRanker.rank(
            commands: [menuItem("About This App", path: ["Help", "About This App"])],
            actions: [action("Open Recent Project")],
            query: "",
            limit: 5)

        #expect(rows.first?.isAction == true)
        #expect(rows.count == 2)
    }

    @Test("An action is found by a trigger word it declares, not only by its name")
    func triggersMatch() {
        let rows = AppChatRowRanker.rank(
            commands: [],
            actions: [action("Open Recent Project", triggers: ["reopen", "last"])],
            query: "reopen",
            limit: 5)

        #expect(rows.count == 1)
    }

    @Test("A better-matching command outranks a weakly-matching action")
    func scoreBeatsKind() {
        let rows = AppChatRowRanker.rank(
            commands: [menuItem("Minimize", path: ["Window", "Minimize"])],
            actions: [action("Send Minimal Report")],
            query: "minimize",
            limit: 5)

        #expect(rows.first?.title == "Minimize")
    }

    @Test("On an equal score the curated action wins, because someone chose it")
    func actionsWinTies() {
        let rows = AppChatRowRanker.rank(
            commands: [menuItem("Deploy", path: ["Build", "Deploy"])],
            actions: [action("Deploy")],
            query: "deploy",
            limit: 5)

        #expect(rows.first?.isAction == true)
    }

    @Test("Nothing that fails to match is padded in to fill the limit")
    func nonMatchesAreNotPadded() {
        let rows = AppChatRowRanker.rank(
            commands: [menuItem("Minimize", path: ["Window", "Minimize"])],
            actions: [action("Deploy")],
            query: "zzzz",
            limit: 5)

        #expect(rows.isEmpty)
    }

    @Test("Prose that matches nothing offers nothing — not a list of weak guesses")
    func proseMatchesNothing() {
        // "hi hello hope you g" scored zero against every action, and the tie-breaking
        // edge given to curated actions lifted that zero above the filter — so typing a
        // sentence produced five confident-looking "matches".
        let rows = AppChatRowRanker.rank(
            commands: [menuItem("Minimize", path: ["Window", "Minimize"])],
            actions: [
                action("Add Project to Reminders", description: "Creates a Reminder"),
                action("New Window", description: "Open a new VS Code window"),
            ],
            query: "hi hello hope you g",
            limit: 5)

        #expect(rows.isEmpty)
    }

    @Test("The limit is honoured across both kinds together")
    func limitSpansBothKinds() {
        let commands = (1...6).map { menuItem("Save \($0)", path: ["File", "Save \($0)"]) }
        let actions = (1...6).map { action("Save Action \($0)") }

        let rows = AppChatRowRanker.rank(
            commands: commands, actions: actions, query: "save", limit: 5)

        #expect(rows.count == 5)
    }
}
